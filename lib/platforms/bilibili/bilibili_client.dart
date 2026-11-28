import 'package:tallylive/core/http.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/platforms/bilibili/bilibili_wbi.dart';
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
class BilibiliClient extends PlatformClient {
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
  static const String _urlDanmuInfo =
      'https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo';
  static const String _urlWbiNav = 'https://api.bilibili.com/x/web-interface/nav';
  static const String _urlAreaList =
      'https://api.live.bilibili.com/room/v1/Area/getList';
  static const String _urlLiveList =
      'https://api.live.bilibili.com/xlive/web-interface/v1/second/getList';

  /// 直播列表签名的固定密钥（B 站前端 chunk 里硬编码的同一个值）。
  static const String _listSignSecret = 'ea1db124af3c7062474693fa704f4ff8';

  /// 可能带 access_id（w_webid）的入口页。
  ///
  /// 同一个页面有时返回完整 SSR、有时只给空壳，所以多试几个并允许沿用旧值。
  static const List<String> _wWebIdPages = [
    'https://live.bilibili.com/lol',
    'https://live.bilibili.com/',
    'https://live.bilibili.com/p/eden/area-tags',
  ];

  String _wWebId = '';
  DateTime _wWebIdAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _wWebIdTTL = Duration(minutes: 30);

  List<CategoryGroup> _categoryCache = const [];
  DateTime _categoryAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// WBI 签名器（key 内部缓存 30 分钟）。
  late final WbiSigner _wbi = WbiSigner(fetchKeys: _fetchWbiKeys);

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

    // 线路 = playinfo 里 url_info 的不同 host。用第一次响应的 host 顺序作为规范顺序，
    // 这样各档位的线路顺序一致，UI 切换时不会错位。
    final lines = first.lines;

    // 按前端展示的档位顺序挑；每个档位单独请求（接口一次只给一个 qn）。
    final variants = <StreamVariant>[];
    for (final qn in _preferredQnOrder) {
      if (!acceptQn.contains(qn)) continue;
      try {
        final detail = await _fetchPlayInfo(info.roomId, qn);
        if (detail.urls.isEmpty) continue;
        variants.add(StreamVariant(
          id: qn.toString(),
          label: detail.qnDesc[qn] ?? _qnLabel(qn),
          format: 'hls',
          urls: detail.urls,
        ));
      } catch (_) {
        // 单个档位失败不影响其它档位，与 Go 版一致。
        continue;
      }
    }

    // 一个都没拿到时退回第一次请求里的地址（通常是默认档）。
    if (variants.isEmpty && first.urls.isNotEmpty) {
      variants.add(StreamVariant(
        id: first.currentQn.toString(),
        label: first.qnDesc[first.currentQn] ?? '默认',
        format: 'hls',
        urls: first.urls,
      ));
    }

    return StreamInfoResult(room: info, lines: lines, variants: variants);
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

    // 收集 HLS 地址，并按 host 归到不同线路：
    // protocol_name 为 http_hls，或地址含 .m3u8 都算 HLS。
    final urls = <StreamUrl>[];
    final lineOrder = <String>[];
    final seenLine = <String>{};
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
            final host = _asString(urlInfo['host']);
            final fullUrl = joinUrl(
              host,
              baseUrl,
              _asString(urlInfo['extra']),
            );
            if (fullUrl.isEmpty) continue;

            final isHls = protocolName.contains('hls') ||
                formatName == 'ts' ||
                fullUrl.contains('.m3u8');
            if (!isHls) continue;

            // 同一条线路（host）只保留一条地址，避免重复。
            if (!seenLine.add(host)) continue;
            lineOrder.add(host);
            urls.add(StreamUrl(lineId: host, url: fullUrl));
          }
        }
      }
    }

    // 线路展示名用「线路N」：B 站的 host 形如 d1--cn-gotcha104.bilivideo.com，
    // 直接展示对用户没有意义，只用于内部区分。
    final lines = <StreamLine>[
      for (var i = 0; i < lineOrder.length; i++)
        StreamLine(id: lineOrder[i], label: '线路${i + 1}'),
    ];

    return _PlayInfo(
      currentQn: _asInt(playurl['current_qn']),
      qnDesc: qnDesc,
      acceptQn: acceptQn.toList(),
      urls: urls,
      lines: lines,
    );
  }

  /// 取弹幕服务器 token 与域名列表（需要 WBI 签名）。
  ///
  /// 与 Go 版 danmuInfo 一致：参数为 id / type=0 / web_location=444.8，
  /// 域名列表里同一个 host 可能重复出现（不同端口），去重保序。
  Future<({String token, List<String> hosts})> fetchDanmuInfo(
    String roomId,
  ) async {
    final query = await _wbi.sign({
      'id': roomId,
      'type': '0',
      'web_location': '444.8',
    });

    final json = await _http.getJson('$_urlDanmuInfo?$query', headers: _headers);
    final map = _asMap(json);
    final code = _asInt(map['code']);
    if (code != 0) {
      throw BilibiliApiException('getDanmuInfo', code, _asString(map['msg']));
    }

    final data = _asMap(map['data']);
    final token = _asString(data['token']);

    final hosts = <String>[];
    final seen = <String>{};
    for (final item in _asList(data['host_list'])) {
      final host = _asString(_asMap(item)['host']).trim();
      if (host.isEmpty || !seen.add(host)) continue;
      hosts.add(host);
    }
    return (token: token, hosts: hosts);
  }

  /// 从 nav 接口取 WBI 的 img_key / sub_key。
  ///
  /// 未登录时 nav 会返回 code=-101，但 data.wbi_img 仍然有值，所以不校验 code。
  Future<({String imgKey, String subKey})> _fetchWbiKeys() async {
    final json = await _http.getJson(_urlWbiNav, headers: _headers);
    final data = _asMap(_asMap(json)['data']);
    final wbiImg = _asMap(data['wbi_img']);
    return (
      imgKey: wbiKeyFromUrl(_asString(wbiImg['img_url'])),
      subKey: wbiKeyFromUrl(_asString(wbiImg['sub_url'])),
    );
  }

  /* -------------------------------------------------- 分区 / 直播列表 */

  /// 分区树：12 个父分区，每个下面若干子分区，id 编码成「父_子」（如 2_86）。
  @override
  Future<List<CategoryGroup>> fetchCategories() async {
    if (_categoryCache.isNotEmpty &&
        DateTime.now().difference(_categoryAt) < const Duration(minutes: 30)) {
      return _categoryCache;
    }

    final json = await _http.getJson(
      '$_urlAreaList?show_pinyin=1',
      headers: _headers,
    );
    final map = _asMap(json);
    final code = _asInt(map['code']);
    if (code != 0) {
      throw BilibiliApiException('Area/getList', code, _asString(map['msg']));
    }

    final groups = <CategoryGroup>[];
    for (final groupItem in _asList(map['data'])) {
      final group = _asMap(groupItem);
      final groupId = _asString(group['id']);
      final children = <Category>[];
      for (final childItem in _asList(group['list'])) {
        final child = _asMap(childItem);
        final childId = _asString(child['id']);
        if (childId.isEmpty) continue;
        var parentId = _asString(child['parent_id']);
        if (parentId.isEmpty) parentId = groupId;
        children.add(Category(
          id: '${parentId}_$childId',
          name: _asString(child['name']).trim(),
        ));
      }
      if (children.isEmpty) continue;
      groups.add(CategoryGroup(
        id: groupId,
        name: _asString(group['name']).trim(),
        categories: children,
      ));
    }
    if (groups.isEmpty) {
      throw const BilibiliApiException('Area/getList', -1, '分区表为空');
    }
    _categoryCache = groups;
    _categoryAt = DateTime.now();
    return groups;
  }

  /// 拉某个分区的直播列表。categoryId 为空时用「英雄联盟」(2_86) 兜底。
  @override
  Future<StreamerPage> fetchLiveList({
    String? categoryId,
    int page = 1,
    int limit = 30,
  }) async {
    var areaId = categoryId ?? '';
    if (areaId.isEmpty) areaId = '2_86';

    final parts = areaId.split('_');
    if (parts.length != 2) {
      throw BilibiliApiException('second/getList', -1, '分区 id 需形如 2_86');
    }
    final parentId = parts[0];
    final childId = parts[1];
    final safePage = page < 1 ? 1 : page;

    final wWebId = await _wWebIdValue();

    // ⚠️ 参数顺序必须与 DTV 完全一致：签名是把 "k=v" 按这个顺序拼串再加 secret。
    final params = <List<String>>[
      ['area_id', childId],
      ['page', '$safePage'],
      ['parent_area_id', parentId],
      ['platform', 'web'],
      ['sort_type', ''],
      ['vajra_business_key', ''],
      ['w_webid', wWebId],
      ['web_location', '444.253'],
    ];
    final signed = _listSignQuery(params, DateTime.now().millisecondsSinceEpoch ~/ 1000);

    final json = await _http.getJson(
      '$_urlLiveList?${signed.query}&w_rid=${signed.wRid}',
      headers: _headers,
    );
    final map = _asMap(json);
    final code = _asInt(map['code']);
    if (code != 0) {
      if (code == -352) {
        _wWebId = '';
        throw const BilibiliApiException(
          'second/getList',
          -352,
          'B 站人机校验拦截（w_webid 可能失效），已清缓存，请重试',
        );
      }
      throw BilibiliApiException(
        'second/getList',
        code,
        _asString(map['message']),
      );
    }

    final data = _asMap(map['data']);
    final items = <Streamer>[];
    for (final raw in _asList(data['list'])) {
      final item = _asMap(raw);
      final roomId = _asString(item['roomid']);
      if (roomId.isEmpty || roomId == '0') continue;
      var title = _asString(item['title']);
      if (title.isEmpty) title = _asString(item['area_name']);
      items.add(Streamer(
        platform: platform,
        id: roomId,
        nickname: _asString(item['uname']),
        title: _stripEmTags(title).trim(),
        cover: _httpsUrl(_firstNonEmpty([
          _asString(item['cover']),
          _asString(item['user_cover']),
          _asString(item['system_cover']),
        ])),
        avatar: _httpsUrl(_asString(item['face'])),
        viewers: _asInt(item['online']),
        categoryName: _firstNonEmpty([
          _asString(item['area_name']),
          _asString(item['area_v2_name']),
          _asString(item['parent_name']),
        ]),
        // 该接口只返回在播房间
        isLive: true,
      ));
    }

    var hasMore = _asBool(data['has_more']);
    if (data['has_more'] == null && items.length >= 40) hasMore = true;

    return StreamerPage(items: items, page: safePage, hasMore: hasMore);
  }

  /// 取 w_webid（直播列表签名必需，来自入口页里的 access_id）。
  Future<String> _wWebIdValue() async {
    if (_wWebId.isNotEmpty &&
        DateTime.now().difference(_wWebIdAt) < _wWebIdTTL) {
      return _wWebId;
    }
    final stale = _wWebId;
    for (final pageUrl in _wWebIdPages) {
      try {
        final html = await _http.getText(
          pageUrl,
          headers: {
            'User-Agent': _desktopUA,
            'Referer': 'https://live.bilibili.com/',
          },
        );
        final id = _extractAccessId(html);
        if (id.isNotEmpty) {
          _wWebId = id;
          _wWebIdAt = DateTime.now();
          return id;
        }
      } catch (_) {
        continue;
      }
    }
    // JWT ttl 24h：刷新失败时沿用旧值还能顶一会儿
    if (stale.isNotEmpty) return stale;
    throw const BilibiliApiException('w_webid', -1, '入口页里找不到 access_id');
  }

  static String _extractAccessId(String html) {
    for (final needle in ['"access_id":"', '"access_id": "']) {
      final index = html.indexOf(needle);
      if (index < 0) continue;
      final rest = html.substring(index + needle.length);
      final end = rest.indexOf('"');
      if (end > 0) return rest.substring(0, end);
    }
    return '';
  }

  /// 直播列表签名：把 "k=v" 按**传入顺序**拼串，再接固定 secret 取 md5。
  ///
  /// 注意不做 url 转义（与 DTV 一致）——参数值都是数字/固定串，
  /// 加了转义反而会让签名和线上不一致。
  ({String query, String wRid}) _listSignQuery(
    List<List<String>> params,
    int wts,
  ) {
    final parts = <String>[
      for (final kv in params) '${kv[0]}=${kv[1]}',
      'wts=$wts',
    ];
    final query = parts.join('&');
    final wRid = md5.convert(utf8.encode('$query$_listSignSecret')).toString();
    return (query: query, wRid: wRid);
  }

  /// 搜索结果里标题常含 `<em class="keyword">`，去掉标签只留文字。
  static String _stripEmTags(String text) {
    if (!text.contains('<')) return text;
    return text.replaceAll(RegExp(r'<[^>]*>'), '');
  }

  static String _httpsUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('//')) return 'https:$trimmed';
    if (trimmed.startsWith('http://')) {
      return 'https://${trimmed.substring('http://'.length)}';
    }
    return trimmed;
  }

  static String _firstNonEmpty(List<String> values) {
    for (final value in values) {
      if (value.trim().isNotEmpty) return value;
    }
    return '';
  }

  static bool _asBool(Object? value) {
    if (value is bool) return value;
    if (value is int) return value != 0;
    if (value is String) return value == '1' || value.toLowerCase() == 'true';
    return false;
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
    required this.urls,
    required this.lines,
  });

  final int currentQn;
  final Map<int, String> qnDesc;
  final List<int> acceptQn;

  /// 各线路地址（顺序与 [lines] 一致）。
  final List<StreamUrl> urls;

  /// 线路列表。
  final List<StreamLine> lines;
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
