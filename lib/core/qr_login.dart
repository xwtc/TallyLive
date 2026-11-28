import 'dart:convert';

import 'package:tallylive/core/http.dart';

/// 扫码登录的二维码内容。
class QrLoginCode {
  const QrLoginCode({
    required this.url,
    required this.key,
    required this.expiresIn,
  });

  /// 二维码里真正要编码的字符串。
  final String url;

  /// 只用于轮询状态，不要展示给用户。
  final String key;
  final int expiresIn;
}

/// 扫码状态。
enum QrLoginStatus {
  pending('等待手机扫码'),
  scanned('已扫码，请在手机上确认'),
  expired('二维码已失效，请刷新'),
  success('登录成功'),
  error('登录失败');

  const QrLoginStatus(this.label);
  final String label;
}

class QrLoginResult {
  const QrLoginResult({required this.status, this.message = '', this.cookie = ''});

  final QrLoginStatus status;
  final String message;

  /// 仅 success 时有值（格式与浏览器 Cookie 头一致）。
  final String cookie;
}

/// 斗鱼扫码登录。
///
/// **移植自 DTV `internal/platforms/douyu/qrlogin.go`**：
/// ```
/// 1. POST https://passport.douyu.com/scan/generateCode
///      form: client_id=1, isMultiAccount=0
///      → data.code（轮询用 key）+ data.url（二维码内容）
/// 2. GET  https://passport.douyu.com/japi/scan/auth?time=<ms>&code=<key>
///      error:  0=已确认  1=已扫码  -2=等待  -1=失效
/// 3. 确认后 data.url 是登录回调地址，GET 一次收集 Set-Cookie
/// ```
class DouyuQrLogin {
  DouyuQrLogin({LiveHttp? http}) : _http = http ?? LiveHttp();

  final LiveHttp _http;

  Map<String, String> get _headers => {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
        'Referer': 'https://www.douyu.com/',
        'Origin': 'https://www.douyu.com',
      };

  /// 申请二维码。
  Future<QrLoginCode> generate() async {
    // postForm 返回原始字符串（表单按 key 排序拼接），要自己解析 JSON
    final raw = await _http.postForm(
      'https://passport.douyu.com/scan/generateCode',
      <String, String>{'client_id': '1', 'isMultiAccount': '0'},
      headers: _headers,
    );
    final decoded = jsonDecode(raw);
    final map = decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : <String, dynamic>{};
    final error = map['error'];
    if (error != null && error != 0) {
      throw DouyuQrException('申请二维码失败：error=$error （${map['msg'] ?? ''}）');
    }
    final data = map['data'] is Map
        ? Map<String, dynamic>.from(map['data'] as Map)
        : <String, dynamic>{};
    final code = (data['code'] ?? '').toString();
    final url = (data['url'] ?? '').toString();
    if (code.isEmpty || url.isEmpty) {
      throw const DouyuQrException('斗鱼未返回有效的二维码内容');
    }
    final expire = (data['expire'] is num)
        ? (data['expire'] as num).toInt()
        : 300;
    return QrLoginCode(url: url, key: code, expiresIn: expire);
  }

  /// 查询一次扫码状态；确认后自动走登录回调拿 Cookie。
  Future<QrLoginResult> poll(String key) async {
    final target =
        'https://passport.douyu.com/japi/scan/auth'
        '?time=${DateTime.now().millisecondsSinceEpoch}'
        '&code=${Uri.encodeQueryComponent(key)}';
    final json = await _http.getJson(target, headers: _headers);
    final map = json is Map ? Map<String, dynamic>.from(json) : <String, dynamic>{};
    final error = map['error'] is num ? (map['error'] as num).toInt() : null;
    final message = (map['msg'] ?? '').toString();

    switch (error) {
      case 0:
        final data = map['data'];
        if (data is! Map) {
          return const QrLoginResult(
            status: QrLoginStatus.error,
            message: '斗鱼返回了无法识别的数据',
          );
        }
        final loginPath = (data['url'] ?? '').toString();
        if (loginPath.isEmpty) {
          return const QrLoginResult(
            status: QrLoginStatus.error,
            message: '斗鱼未返回回调地址',
          );
        }
        return _finishLogin(loginPath);
      case 1:
        return QrLoginResult(
          status: QrLoginStatus.scanned,
          message: message.isEmpty ? '已扫码，请在手机上确认登录' : message,
        );
      case -2:
        return QrLoginResult(
          status: QrLoginStatus.pending,
          message: message.isEmpty ? '等待手机扫码' : message,
        );
      case -1:
        return QrLoginResult(
          status: QrLoginStatus.expired,
          message: message.isEmpty ? '二维码已失效，请刷新' : message,
        );
      default:
        return QrLoginResult(
          status: QrLoginStatus.pending,
          message: message.isEmpty ? '等待手机扫码' : message,
        );
    }
  }

  /// 用回调地址走一次登录，收集 Set-Cookie。
  Future<QrLoginResult> _finishLogin(String rawUrl) async {
    var login = rawUrl.trim();
    if (login.startsWith('//')) {
      login = 'https:$login';
    } else if (!login.startsWith('http')) {
      login = 'https://passport.douyu.com/${login.replaceFirst(RegExp(r'^/+'), '')}';
    }

    final response = await _http.getTextWithHeaders(login, headers: _headers);
    final cookies = <String>[];
    for (final raw in response.setCookies) {
      final first = raw.split(';').first.trim();
      if (first.isEmpty) continue;
      cookies.add(first);
    }
    if (cookies.isEmpty) {
      return const QrLoginResult(
        status: QrLoginStatus.error,
        message: '登录成功但没有拿到 Cookie',
      );
    }
    return QrLoginResult(
      status: QrLoginStatus.success,
      cookie: cookies.join('; '),
    );
  }
}

/// B 站扫码登录。
///
/// 流程（对齐 DTV `bilibili/qrlogin.go`）：
/// ```
/// 1. GET https://passport.bilibili.com/x/passport-login/web/qrcode/generate
///      → data.url（二维码内容）+ data.qrcode_key（轮询用）
/// 2. GET .../qrcode/poll?qrcode_key=<key>
///      code: 0=成功  86101=未扫码  86090=已扫码  86038=已失效
/// 3. 成功时从响应的 Set-Cookie 里取 SESSDATA 等
/// ```
class BilibiliQrLogin {
  BilibiliQrLogin({LiveHttp? http}) : _http = http ?? LiveHttp();

  final LiveHttp _http;

  Map<String, String> get _headers => {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
        'Referer': 'https://www.bilibili.com/',
      };

  Future<QrLoginCode> generate() async {
    final json = await _http.getJson(
      'https://passport.bilibili.com/x/passport-login/web/qrcode/generate',
      headers: _headers,
    );
    final map = json is Map ? Map<String, dynamic>.from(json) : <String, dynamic>{};
    if (map['code'] != 0) {
      throw BilibiliQrException('申请二维码失败：code=${map['code']}');
    }
    final data = map['data'] is Map
        ? Map<String, dynamic>.from(map['data'] as Map)
        : <String, dynamic>{};
    final url = (data['url'] ?? '').toString();
    final key = (data['qrcode_key'] ?? '').toString();
    if (url.isEmpty || key.isEmpty) {
      throw const BilibiliQrException('B站未返回有效的二维码内容');
    }
    return QrLoginCode(url: url, key: key, expiresIn: 180);
  }

  Future<QrLoginResult> poll(String key) async {
    final target =
        'https://passport.bilibili.com/x/passport-login/web/qrcode/poll'
        '?qrcode_key=${Uri.encodeQueryComponent(key)}';
    final response = await _http.getTextWithHeaders(target, headers: _headers);
    Map<String, dynamic> map;
    try {
      final decoded = jsonDecode(response.body);
      map = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } catch (_) {
      return const QrLoginResult(
        status: QrLoginStatus.error,
        message: 'B站返回了无法识别的数据',
      );
    }

    final data = map['data'] is Map
        ? Map<String, dynamic>.from(map['data'] as Map)
        : <String, dynamic>{};
    final code = data['code'] is num ? (data['code'] as num).toInt() : -1;

    switch (code) {
      case 0:
        final cookies = <String>[];
        for (final raw in response.setCookies) {
          final first = raw.split(';').first.trim();
          if (first.isEmpty) continue;
          cookies.add(first);
        }
        if (cookies.isEmpty) {
          return const QrLoginResult(
            status: QrLoginStatus.error,
            message: '登录成功但没有拿到 Cookie',
          );
        }
        return QrLoginResult(
          status: QrLoginStatus.success,
          cookie: cookies.join('; '),
        );
      case 86101:
        return const QrLoginResult(
          status: QrLoginStatus.pending,
          message: '等待手机扫码',
        );
      case 86090:
        return const QrLoginResult(
          status: QrLoginStatus.scanned,
          message: '已扫码，请在手机上确认',
        );
      case 86038:
        return const QrLoginResult(
          status: QrLoginStatus.expired,
          message: '二维码已失效，请刷新',
        );
      default:
        return QrLoginResult(
          status: QrLoginStatus.error,
          message: '登录失败：code=$code',
        );
    }
  }

  /// 校验保存的 Cookie（调 nav 接口）。
  Future<AccountProfileCheck> verify(String cookie) async {
    try {
      final json = await _http.getJson(
        'https://api.bilibili.com/x/web-interface/nav',
        headers: {..._headers, 'Cookie': cookie},
      );
      final map = json is Map ? Map<String, dynamic>.from(json) : <String, dynamic>{};
      final data = map['data'] is Map
          ? Map<String, dynamic>.from(map['data'] as Map)
          : <String, dynamic>{};
      final loggedIn = data['isLogin'] == true;
      var face = (data['face'] ?? '').toString();
      if (face.startsWith('//')) face = 'https:$face';
      return AccountProfileCheck(
        loggedIn: loggedIn,
        userName: (data['uname'] ?? '').toString(),
        avatar: face,
      );
    } catch (_) {
      return const AccountProfileCheck(loggedIn: false);
    }
  }
}

class AccountProfileCheck {
  const AccountProfileCheck({
    required this.loggedIn,
    this.userName = '',
    this.avatar = '',
  });

  final bool loggedIn;
  final String userName;
  final String avatar;
}

class DouyuQrException implements Exception {
  const DouyuQrException(this.message);
  final String message;

  @override
  String toString() => message;
}

class BilibiliQrException implements Exception {
  const BilibiliQrException(this.message);
  final String message;

  @override
  String toString() => message;
}