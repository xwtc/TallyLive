import 'package:tallylive/core/http.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/platforms/platform_client.dart';

/// B 站直播客户端。
///
/// 移植自 TallyLive(Go) 的 internal/platforms/bilibili：
///   - client.go   端点常量、UA、匿名 cookie（buvid3=i;）
///   - stream_url.go  getRoomPlayInfo 参数与 HLS 档位选择
///
/// 实测要点（Go 版注释 2026-10-30 记录，移植时保留）：
///   - getRoomPlayInfo 一次只返回一个 qn，每个清晰度要单独请求；
///   - B 站 FLV 直连会 404，HLS（.m3u8）直连 200 且不需要 Referer，
///     所以这里只暴露 HLS 档位。
class BilibiliClient implements PlatformClient {
  BilibiliClient({LiveHttp? http}) : _http = http ?? LiveHttp();

  final LiveHttp _http;

  @override
  LivePlatform get platform => LivePlatform.bilibili;

  static const String _desktopUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36';
  static const String _referer = 'https://live.bilibili.com/';
  static const String _origin = 'https://live.bilibili.com';

  static const String _urlRoomGetInfo =
      'https://api.live.bilibili.com/room/v1/Room/get_info';
  static const String _urlRoomPlayInfo =
      'https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo';

  /// B 站匿名请求也要求带 buvid3，否则部分接口 412。
  Map<String, String> get _headers => {
        'User-Agent': _desktopUA,
        'Referer': _referer,
        'Origin': _origin,
        'Accept': 'application/json, text/plain, */*',
        'Cookie': 'buvid3=i;',
      };

  /// 拉取房间基本信息。
  ///
  /// roomId 支持短号：接口会返回真正的 room_id（后续取流必须用这个）。
  @override
  Future<RoomInfo> fetchRoomInfo(String roomId) async {
    final json = await _http.getJson(
      _urlRoomGetInfo,
      headers: _headers,
      query: {'room_id': roomId},
    );
    final map = _asMap(json);
    final code = _asInt(map['code']);
    if (code != 0) {
      throw BilibiliApiException('get_info', code, _asString(map['msg']));
    }

    final data = _asMap(map['data']);
    final realRoomId = _asString(data['room_id']);
    final liveStatus = _asInt(data['live_status']);

    return RoomInfo(
      platform: platform,
      roomId: realRoomId.isEmpty ? roomId : realRoomId,
      title: _asString(data['title']),
      // get_info 不返回主播名，需要 getInfoByRoom（下一阶段补）
      nickname: '',
      cover: _asString(data['user_cover']).isNotEmpty
          ? _asString(data['user_cover'])
          : _asString(data['keyframe']),
      category: _asString(data['area_name']),
      online: _asInt(data['online']),
      isLive: liveStatus == 1,
    );
  }

  /// 取播放地址。只返回 HLS 档位。
  @override
  Future<StreamInfoResult> fetchStreamInfo(String roomId) async {
    final info = await fetchRoomInfo(roomId);
    if (!info.isLive) {
      return StreamInfoResult(room: info, variants: const []);
    }

    // 先不带 qn 请求一次，拿到 accept_qn 与默认档位。
    final first = await _fetchPlayInfo(info.roomId, null);
    final acceptQn = first.acceptQn;

    // 按前端展示的档位顺序挑；每个档位单独请求（接口一次只给一个 qn）。
    final variants = <StreamVariant>[];
    for (final qn in _preferredQnOrder) {
      if (!acceptQn.contains(qn)) continue;
      try {
        final detail = await _fetchPlayInfo(info.roomId, qn);
        final hls = detail.hlsUrls;
        if (hls.isEmpty) continue;
        variants.add(StreamVariant(
          id: qn.toString(),
          label: detail.qnDesc[qn] ?? _qnLabel(qn),
          url: hls.first,
          format: 'hls',
          urls: hls,
        ));
      } catch (_) {
        // 单个档位失败不影响其它档位，与 Go 版一致。
        continue;
      }
    }

    // 一个都没拿到时退回第一次请求里的地址（通常是默认档）。
    if (variants.isEmpty) {
      final fallback = first.hlsUrls;
      if (fallback.isNotEmpty) {
        variants.add(StreamVariant(
          id: first.currentQn.toString(),
          label: first.qnDesc[first.currentQn] ?? '默认',
          url: fallback.first,
          format: 'hls',
          urls: fallback,
        ));
      }
    }

    return StreamInfoResult(room: info, variants: variants);
  }

  /// 请求一次 getRoomPlayInfo。qn 为 null 表示不指定。
  Future<_PlayInfo> _fetchPlayInfo(String roomId, int? qn) async {
    final query = <String, String>{
      'room_id': roomId,
      'protocol': '0,1',
      'format': '0,1,2',
      'codec': '0',
      'platform': 'html5',
      'dolby': '5',
      'panorama': '1',
      if (qn != null) 'qn': qn.toString(),
    };

    final json = await _http.getJson(
      _urlRoomPlayInfo,
      headers: _headers,
      query: query,
    );
    final map = _asMap(json);
    final code = _asInt(map['code']);
    if (code != 0) {
      throw BilibiliApiException('getRoomPlayInfo', code, _asString(map['msg']));
    }

    final data = _asMap(map['data']);
    final playurl = _asMap(_asMap(data['playurl_info'])['playurl']);

    final qnDesc = <int, String>{};
    for (final item in _asList(playurl['g_qn_desc'])) {
      final entry = _asMap(item);
      qnDesc[_asInt(entry['qn'])] = _asString(entry['desc']);
    }

    // 收集所有 HLS 地址：protocol_name 为 http_hls，或地址含 .m3u8。
    final hlsUrls = <String>[];
    final acceptQn = <int>{};

    for (final streamItem in _asList(playurl['stream'])) {
      final stream = _asMap(streamItem);
      final protocolName = _asString(stream['protocol_name']).toLowerCase();

      for (final formatItem in _asList(stream['format'])) {
        final format = _asMap(formatItem);
        final formatName = _asString(format['format_name']).toLowerCase();

        for (final codecItem in _asList(format['codec'])) {
          final codec = _asMap(codecItem);
          final baseUrl = _asString(codec['base_url']);

          for (final qnItem in _asList(codec['accept_qn'])) {
            acceptQn.add(_asInt(qnItem));
          }

          // 完整地址 = host + base_url + extra。
          // base_url 是形如 "/live-bvc/904361/live_xxx.m3u8" 的路径，
          // host 才是 "https://d1--cn-gotcha104.bilivideo.com"，
          // 顺序写反会得到一个以 "/" 开头的非法 URL。
          for (final urlInfoItem in _asList(codec['url_info'])) {
            final urlInfo = _asMap(urlInfoItem);
            final fullUrl = joinUrl(
              _asString(urlInfo['host']),
              baseUrl,
              _asString(urlInfo['extra']),
            );
            if (fullUrl.isEmpty) continue;

            final isHls = protocolName.contains('hls') ||
                formatName == 'ts' ||
                fullUrl.contains('.m3u8');
            if (isHls && !hlsUrls.contains(fullUrl)) {
              hlsUrls.add(fullUrl);
            }
          }
        }
      }
    }

    return _PlayInfo(
      currentQn: _asInt(playurl['current_qn']),
      qnDesc: qnDesc,
      acceptQn: acceptQn.toList(),
      hlsUrls: hlsUrls,
    );
  }

  /// 前端展示的 5 档，与 Go 版 preferredQNOrder 一致。
  static const List<int> _preferredQnOrder = [10000, 400, 250, 150, 80];

  static String _qnLabel(int qn) => switch (qn) {
        10000 => '原画',
        400 => '蓝光',
        250 => '超清',
        150 => '高清',
        80 => '流畅',
        _ => 'qn$qn',
      };
}

class _PlayInfo {
  _PlayInfo({
    required this.currentQn,
    required this.qnDesc,
    required this.acceptQn,
    required this.hlsUrls,
  });

  final int currentQn;
  final Map<int, String> qnDesc;
  final List<int> acceptQn;
  final List<String> hlsUrls;
}

class BilibiliApiException implements Exception {
  BilibiliApiException(this.endpoint, this.code, this.message);
  final String endpoint;
  final int code;
  final String message;

  @override
  String toString() => 'B 站接口 $endpoint 返回 code=$code msg=$message';
}

/// 拼 host + base_url + extra，移植自 Go 版 joinURL。
///
/// B 站 playinfo 把地址拆成三部分：`base_url` 是路径（以 "/" 开头），
/// `url_info[].host` 是域名，`url_info[].extra` 是 query（可能以 "?" 开头）。
/// 顺序必须是 host→base→extra，且要处理好 "?"/"&" 的连接符。
String joinUrl(String host, String base, String extra) {
  if (host.isEmpty || base.isEmpty) return '';
  var full = '${host.endsWith('/') ? host.substring(0, host.length - 1) : host}$base';
  if (extra.isNotEmpty) {
    if (!extra.startsWith('?') && !base.contains('?')) {
      full += '?';
    } else if (extra.startsWith('?') && base.contains('?')) {
      extra = extra.substring(1);
      full += '&';
    }
    full += extra;
  }
  return enforceHttps(full);
}

/// B 站部分节点会下发 http:// 地址，统一升级到 https（移植自 Go 版 enforceHTTPS）。
String enforceHttps(String raw) {
  if (raw.startsWith('http://')) {
    return 'https://${raw.substring('http://'.length)}';
  }
  return raw;
}

/* ----------------------------- JSON 容错工具 ----------------------------- */
Map<String, dynamic> _asMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

List<dynamic> _asList(Object? value) => value is List ? value : const [];

String _asString(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  return value.toString();
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
