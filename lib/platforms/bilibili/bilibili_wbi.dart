import 'dart:convert';

import 'package:crypto/crypto.dart';

/// B 站 WBI 签名。
///
/// 移植自 TallyLive(Go) 的 internal/platforms/bilibili/wbi.go。
///
/// B 站有两套签名，**不能混用**：
///   1. 直播列表用固定密钥的 md5（listSignSecret）——本项目暂未用到；
///   2. 房间信息 / 弹幕服务器用 WBI：nav 接口下发 img_key/sub_key，
///      按 [mixinKeyEncTab] 重排出 32 位 mixin_key，参数按 key 升序、
///      值做特殊 url 编码后拼串，再接 mixin_key 取 md5。
///
/// 值编码与标准 urlencode 的差别：`!'()*` 要**丢弃**而不是转义，
/// 空格要编成 %20（标准实现会给 `+`）。写错只会拿到 -352 或静默空数据。
class WbiSigner {
  WbiSigner({required this.fetchKeys});

  /// 获取 (imgKey, subKey)。由调用方提供，便于复用同一个 HTTP 客户端与缓存。
  final Future<({String imgKey, String subKey})> Function() fetchKeys;

  ({String imgKey, String subKey})? _cached;
  DateTime _fetchedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// WBI key 每天换一次，这里取 30 分钟保守值（与 Go 版一致）。
  static const Duration cacheTTL = Duration(minutes: 30);

  /// 拿缓存的 key，过期则重新拉取。
  Future<({String imgKey, String subKey})> keys() async {
    final cached = _cached;
    if (cached != null && DateTime.now().difference(_fetchedAt) < cacheTTL) {
      return cached;
    }
    final fresh = await fetchKeys();
    if (fresh.imgKey.isNotEmpty && fresh.subKey.isNotEmpty) {
      _cached = fresh;
      _fetchedAt = DateTime.now();
    }
    return fresh;
  }

  /// 失效缓存（签名失败时调用一次重试）。
  void invalidate() {
    _cached = null;
    _fetchedAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// 生成带 wts 与 w_rid 的完整 query。
  Future<String> sign(Map<String, String> params) async {
    // 注意：不能把局部变量命名成 keys，否则会遮蔽同名方法并在声明前被引用。
    final pair = await keys();
    if (pair.imgKey.isEmpty || pair.subKey.isEmpty) {
      throw const WbiException('WBI key 为空，无法签名');
    }
    return wbiSignedQuery(
      params,
      pair.imgKey,
      pair.subKey,
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }
}

/// WBI 的字段重排表（与 Go 版、B 站前端 chunk 中的表一致）。
const List<int> mixinKeyEncTab = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
  27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
  37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
  22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
];

/// 由 img_key + sub_key 重排出 32 位 mixin_key。
String mixinKey(String imgKey, String subKey) {
  final origin = '$imgKey$subKey';
  final buffer = StringBuffer();
  for (final index in mixinKeyEncTab) {
    if (index < origin.length) {
      buffer.write(origin[index]);
    }
  }
  final key = buffer.toString();
  return key.length > 32 ? key.substring(0, 32) : key;
}

/// 按 WBI 规范对值做转义：`!'()*` 丢弃，空格等其余字符百分号编码。
String wbiEncodeValue(String value) {
  const banned = "!'()*";
  final buffer = StringBuffer();
  // 按 UTF-8 字节处理，保证中文等非 ASCII 字符被正确编码。
  for (final byte in utf8.encode(value)) {
    final isAlnum = (byte >= 0x30 && byte <= 0x39) || // 0-9
        (byte >= 0x41 && byte <= 0x5A) || // A-Z
        (byte >= 0x61 && byte <= 0x7A); // a-z
    final isSafe = isAlnum ||
        byte == 0x2D || // -
        byte == 0x5F || // _
        byte == 0x2E || // .
        byte == 0x7E; // ~
    if (isSafe) {
      buffer.writeCharCode(byte);
    } else if (byte < 0x80 && banned.codeUnits.contains(byte)) {
      // 丢弃
      continue;
    } else {
      buffer.write('%');
      buffer.write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return buffer.toString();
}

/// 生成 WBI 签名 query（含 wts 与 w_rid）。
String wbiSignedQuery(
  Map<String, String> params,
  String imgKey,
  String subKey,
  int wts,
) {
  final merged = Map<String, String>.from(params)..['wts'] = wts.toString();
  final sortedKeys = merged.keys.toList()..sort();

  final parts = <String>[];
  for (final key in sortedKeys) {
    parts.add('${wbiEncodeValue(key)}=${wbiEncodeValue(merged[key]!)}');
  }
  final query = parts.join('&');
  final mixin = mixinKey(imgKey, subKey);
  final wRid = md5.convert(utf8.encode('$query$mixin')).toString();
  return '$query&w_rid=$wRid';
}

/// 从 wbi_img 的 url 里取出 key（去掉目录与扩展名）。
///
/// 形如 https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png
/// → 7cd084941338484aae1ad9425b84077c
String wbiKeyFromUrl(String url) {
  if (url.isEmpty) return '';
  final segments = Uri.tryParse(url)?.pathSegments;
  final name = (segments != null && segments.isNotEmpty)
      ? segments.last
      : url.split('/').last;
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

class WbiException implements Exception {
  const WbiException(this.message);
  final String message;

  @override
  String toString() => 'WBI 签名失败：$message';
}
