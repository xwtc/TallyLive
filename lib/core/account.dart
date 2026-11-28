import 'package:tallylive/core/http.dart';
import 'package:tallylive/core/models.dart';

/// 账号登录信息。
class AccountProfile {
  const AccountProfile({
    required this.loggedIn,
    this.userName = '',
    this.avatar = '',
  });

  final bool loggedIn;
  final String userName;
  final String avatar;

  static const AccountProfile anonymous = AccountProfile(loggedIn: false);
}

/// Cookie 登录。
///
/// **为什么支持 Cookie 而不只是扫码**（UI-DESIGN §4.4.1）：
/// - 扫码要求手机在手且已登录对应 App，桌面场景体验差
/// - DTV 的 `SetDouyuCookie` / `SetBilibiliCookie` 本来就是收原始 Cookie 串，
///   Cookie 登录与移植来源的接口天然对齐
///
/// 两个平台都**不是必须登录**：匿名就能播，登录主要影响清晰度。
class CookieLogin {
  const CookieLogin._();

  /// 从浏览器复制来的文本里提取 Cookie 串。
  ///
  /// 用户常会连 `Cookie:` 前缀一起粘进来，或者带换行，这里统一清理。
  static String normalize(String raw) {
    var text = raw.trim();
    // 去掉 "Cookie:" 前缀（大小写不敏感）
    if (text.toLowerCase().startsWith('cookie:')) {
      text = text.substring('cookie:'.length).trim();
    }
    // 去掉换行（多行粘贴）
    text = text.replaceAll(RegExp(r'[\r\n]+'), ' ');
    return text.trim();
  }

  /// 解析成 k→v（同名只保留第一个）。
  static Map<String, String> parse(String raw) {
    final out = <String, String>{};
    for (final part in normalize(raw).split(';')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final index = trimmed.indexOf('=');
      if (index <= 0) continue;
      final key = trimmed.substring(0, index).trim();
      final value = trimmed.substring(index + 1).trim();
      if (key.isEmpty) continue;
      out.putIfAbsent(key, () => value);
    }
    return out;
  }

  /// 校验 B 站 Cookie。
  ///
  /// 对齐 DTV `LoginProfile`：调 `nav` 接口看 `data.isLogin`。
  /// `-101` 是"未登录"的正常返回，不当错误。
  static Future<AccountProfile> verifyBilibili(
    String cookie, {
    LiveHttp? http,
  }) async {
    final trimmed = normalize(cookie);
    if (trimmed.isEmpty) return AccountProfile.anonymous;

    final client = http ?? LiveHttp();
    try {
      final json = await client.getJson(
        'https://api.bilibili.com/x/web-interface/nav',
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
          'Referer': 'https://live.bilibili.com/',
          'Cookie': trimmed,
        },
      );
      final map = json is Map ? Map<String, dynamic>.from(json) : <String, dynamic>{};
      final data = map['data'] is Map
          ? Map<String, dynamic>.from(map['data'] as Map)
          : <String, dynamic>{};
      final isLogin = data['isLogin'] == true;
      if (!isLogin) return AccountProfile.anonymous;
      var face = (data['face'] ?? '').toString();
      if (face.startsWith('//')) face = 'https:$face';
      if (face.startsWith('http://')) {
        face = 'https://${face.substring('http://'.length)}';
      }
      return AccountProfile(
        loggedIn: true,
        userName: (data['uname'] ?? '').toString(),
        avatar: face,
      );
    } catch (_) {
      return AccountProfile.anonymous;
    }
  }

  /// 校验斗鱼 Cookie。
  ///
  /// 对齐 DTV `CookieValid`：**不发网络请求**，只看 Cookie 里有没有登录字段。
  ///
  /// ⚠️ 斗鱼的关键约束（来自 DTV 注释）：
  /// - 需要 `acf_auth` + `acf_jwt_token` **成对**；只带其一会被边缘直接 403
  /// - 或者改带 `dy_auth`
  /// - `LTP0` 只用于续期，不参与业务请求
  static AccountProfile verifyDouyu(String cookie) {
    final map = parse(cookie);
    if (map.isEmpty) return AccountProfile.anonymous;

    final hasAcfPair =
        map.containsKey('acf_auth') && map.containsKey('acf_jwt_token');
    final hasDyAuth = map.containsKey('dy_auth');
    if (!hasAcfPair && !hasDyAuth) return AccountProfile.anonymous;

    return AccountProfile(
      loggedIn: true,
      userName: map['nickname'] ?? map['username'] ?? '',
    );
  }
}

/// 已登录账号的本地存储（每个平台一份 Cookie）。
class AccountStore {
  AccountStore._();

  static final AccountStore instance = AccountStore._();

  final Map<LivePlatform, String> _cookies = {};

  String cookieOf(LivePlatform platform) => _cookies[platform] ?? '';
  bool hasCookie(LivePlatform platform) => cookieOf(platform).isNotEmpty;

  void setCookie(LivePlatform platform, String cookie) {
    final normalized = CookieLogin.normalize(cookie);
    if (normalized.isEmpty) {
      _cookies.remove(platform);
    } else {
      _cookies[platform] = normalized;
    }
  }

  /// 退出登录：**同时清 Cookie 与请求头**。
  ///
  /// DTV 注释里专门记过「假退出」的坑：只清自己的字段不清客户端，
  /// 请求还带着旧登录态。
  void logout(LivePlatform platform) {
    _cookies.remove(platform);
  }
}
