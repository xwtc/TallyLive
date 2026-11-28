import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;

import 'package:tallylive/core/http.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/platforms/douyin/douyin_abogus.dart';
import 'package:tallylive/platforms/platform_client.dart';

/// 抖音客户端。
///
/// **移植自 DTV `internal/platforms/douyin/`**：
/// - `abogus.go`   → `douyin_abogus.dart`（已逐字节对齐线上 JS）
/// - `livelist.go` → 分区直播列表
/// - `room_info.go`→ 房间信息 + 取流（含 HEVC 识别）
/// - `categories.go` → 内置 `assets/douyin_categories.json`
///
/// 关键结论（都经过本机实测验证）：
/// ```
/// 1. 分区列表：partition/detail/room/v2，参数含 partition_type / partition
/// 2. 房间信息：先打开 https://live.douyin.com/<web_rid> 页面，从内嵌 JSON 抠
///    「内部 roomId（19 位）」——**reflow 只认内部 roomId，传 web_rid 会报错**
/// 3. 取流：reflow/info，返回 stream_url；原画不在 flv_pull_url 里，
///    要去 live_core_sdk_data.pull_data.stream_data 的内嵌 JSON 取
/// 4. msToken 传空串也能通（实测），传随机串同样可通
/// ```
class DouyinClient extends PlatformClient {
  DouyinClient({LiveHttp? http}) : _http = http ?? LiveHttp();

  final LiveHttp _http;

  @override
  LivePlatform get platform => LivePlatform.douyin;

  /// 桌面 UA（a_bogus 的 UA 必须与请求头一致，否则签名不过）。
  /// 桌面 UA（签名脚本的 navigator.userAgent 要对齐）。
  static const String desktopUserAgent = _ua;

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/116.0.5845.97 Safari/537.36 Core/1.116.567.400 QQBrowser/19.7.6764.400';

  static const String _authority = 'live.douyin.com';
  static const String _referer = 'https://live.douyin.com/';

  // 注意路径是 web/partition（不是 room/partition）：
  // 写成 /webcast/room/partition/... 会 404（实测）。
  static const String _urlPartition =
      'https://live.douyin.com/webcast/web/partition/detail/room/v2/';
  static const String _urlReflow =
      'https://webcast.amemv.com/webcast/room/reflow/info/';

  /// msToken 用的字符集（线上就是字母数字加 -_）。
  static const String _msCharset =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

  /// 用 a_bogus 签名并拼出最终 URL。
  String _signed(String endpoint, List<List<String>> params) {
    final query = params
        .map((kv) =>
            '${Uri.encodeQueryComponent(kv[0])}=${Uri.encodeQueryComponent(kv[1])}')
        .join('&');
    final sign = ABogus.generate(query, _ua);
    return '$endpoint?$query&a_bogus=${Uri.encodeQueryComponent(sign)}';
  }

  Map<String, String> get _headers => {
        'User-Agent': _ua,
        'Referer': _referer,
        'Authority': _authority,
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'zh-CN,zh;q=0.9',
      };

  static String _msToken(int length) {
    final random = Random();
    return List<String>.generate(
        length, (_) => _msCharset[random.nextInt(_msCharset.length)]).join();
  }

  /* ---------------------------------------------------------------- 分区 */

  List<CategoryGroup> _categoryCache = const [];

  /// 缓存的 ttwid cookie（弹幕 WS 需要）。
  String _ttwid = '';

  /// 分区树来自内置资源（DTV 同样处理：抖音没有稳定的分区接口）。
  /// 分区 id 形如 `1_1010032`（partition_type_partition）。
  @override
  Future<List<CategoryGroup>> fetchCategories() async {
    if (_categoryCache.isNotEmpty) return _categoryCache;
    final raw = await rootBundle.loadString('assets/douyin_categories.json');
    final decoded = jsonDecode(raw);
    final groups = <CategoryGroup>[];
    for (final item in _asList(decoded)) {
      final group = _asMap(item);
      final children = <Category>[];
      for (final sub in _asList(group['categories'])) {
        final entry = _asMap(sub);
        final id = _asString(entry['id']);
        if (id.isEmpty) continue;
        children.add(Category(id: id, name: _asString(entry['name'])));
      }
      if (children.isEmpty) continue;
      groups.add(CategoryGroup(
        id: _asString(group['id']).isEmpty
            ? '${groups.length + 1}'
            : _asString(group['id']),
        name: _asString(group['name']),
        categories: children,
      ));
    }
    if (groups.isEmpty) throw const DouyinException('抖音分区表为空');
    _categoryCache = groups;
    return groups;
  }

  /* ------------------------------------------------------------ 直播列表 */

  @override
  Future<StreamerPage> fetchLiveList({
    String? categoryId,
    int page = 1,
    int limit = 15,
  }) async {
    var cateId = (categoryId ?? '').trim();
    if (cateId.isEmpty) {
      final groups = await fetchCategories();
      cateId = groups.first.categories.first.id;
    }
    final parts = cateId.split('_');
    if (parts.length < 2) {
      throw DouyinException('抖音分区 id 应为 partition_type_partition，实际 "$cateId"');
    }
    final partitionType = parts[parts.length - 2];
    final partition = parts[parts.length - 1];

    final safePage = page < 1 ? 1 : page;
    final pageSize = (limit <= 0 || limit > 15) ? 15 : limit;
    final offset = (safePage - 1) * pageSize;

    final url = _signed(_urlPartition, [
      ['aid', '6383'],
      ['app_name', 'douyin_web'],
      ['live_id', '1'],
      ['device_platform', 'web'],
      ['language', 'zh-CN'],
      ['enter_from', 'web_homepage_hot'],
      ['cookie_enabled', 'true'],
      ['screen_width', '1920'],
      ['screen_height', '1080'],
      ['browser_language', 'zh-CN'],
      ['browser_platform', 'Win32'],
      ['browser_name', 'Chrome'],
      ['browser_version', '116.0.0.0'],
      ['count', '$pageSize'],
      ['offset', '$offset'],
      ['partition', partition],
      ['partition_type', partitionType],
      ['req_from', '2'],
      ['msToken', _msToken(107)],
    ]);

    final json = await _http.getJson(url, headers: _headers);
    final root = _asMap(json);
    final code = _asInt(root['status_code']);
    if (code != 0) {
      throw DouyinException('抖音分区列表返回 status_code=$code');
    }

    final wrapper = _asMap(root['data']);
    final items = <Streamer>[];
    for (final raw in _asList(wrapper['data'])) {
      final entry = _asMap(raw);
      final webRid = _asString(entry['web_rid']);
      final room = _asMap(entry['room']);
      // 列表项里的房间 id 是内部 roomId；播放要 web_rid，所以这里保存 web_rid。
      final id = webRid.isNotEmpty ? webRid : _asString(room['id_str']);
      if (id.isEmpty) continue;
      final owner = _asMap(room['owner']);
      final stats = _asMap(room['stats']);
      items.add(Streamer(
        platform: platform,
        id: id,
        nickname: _asString(owner['nickname']),
        title: _asString(room['title']),
        cover: _firstUrl(room['cover']),
        avatar: _firstUrl(owner['avatar_thumb']),
        viewers: _parseViewerText(_asString(stats['total_user_str'])),
        isLive: true,
      ));
    }

    final hasMore = wrapper['has_more'] == true || items.length >= pageSize;
    return StreamerPage(items: items, page: safePage, hasMore: hasMore);
  }

  /* ------------------------------------------------------------- 房间信息 */

  /* --------------------------------------------------------------- 搜索 */

  /// 抖音**只支持用房间号直接进入**（不做关键词搜索）。
  ///
  /// 原因：`aweme/v1/web/live/search` 实测返回 **2483 风控**（未登录态），
  /// 关键词搜索拿不到数据。与其给一个"永远失败"的搜索，
  /// 不如明确只接受房间号：
  /// - 纯数字（web_rid，如 123456789）→ 直接查房间信息返回一条结果
  /// - 完整链接 `https://live.douyin.com/123456789` → 从链接里取数字
  /// - 其它关键词 → 抛异常，界面提示"抖音只支持房间号"
  @override
  Future<List<SearchHit>> search(String keyword, {int page = 1}) async {
    final raw = keyword.trim();
    if (raw.isEmpty) return const [];

    final roomId = _extractRoomId(raw);
    if (roomId == null) {
      throw const DouyinException(
        '抖音只支持用房间号进入。\n'
        '请输入纯数字房间号，或粘贴直播间链接。',
      );
    }

    // 用房间信息补齐昵称/标题/头像，查不到也返回一条可用结果
    try {
      final info = await fetchRoomInfo(roomId);
      return [
        SearchHit(
          platform: platform,
          id: roomId,
          nickname: info.nickname.isEmpty ? '房间 $roomId' : info.nickname,
          title: info.title,
          avatar: info.avatar,
          isLive: info.isLive,
        ),
      ];
    } catch (_) {
      return [
        SearchHit(
          platform: platform,
          id: roomId,
          nickname: '房间 $roomId',
          title: '点击进入直播间',
        ),
      ];
    }
  }

  /// 从输入里提取房间号：纯数字，或链接末尾的数字。
  String? _extractRoomId(String raw) {
    // 纯数字
    if (RegExp(r'^\d{3,}$').hasMatch(raw)) return raw;

    // 链接或带前缀的串：取第一段连续数字（长度 ≥ 3）
    final match = RegExp(r'(\d{3,})').firstMatch(raw);
    return match?.group(1);
  }

  @override
  Future<RoomInfo> fetchRoomInfo(String roomId) async {
    final bundle = await _resolveRoom(roomId);
    final room = bundle.room;
    final owner = _asMap(room['owner']);
    return RoomInfo(
      platform: platform,
      roomId: bundle.webRid,
      title: _asString(room['title']),
      nickname: _asString(owner['nickname']),
      avatar: _firstUrl(owner['avatar_thumb']),
      cover: _firstUrl(room['cover']),
      online: _parseViewerText(_asString(_asMap(room['stats'])['total_user_str'])),
      isLive: _asInt(room['status']) == 2,
    );
  }

  @override
  Future<StreamInfoResult> fetchStreamInfo(String roomId) async {
    final bundle = await _resolveRoom(roomId);
    final room = bundle.room;
    final info = RoomInfo(
      platform: platform,
      roomId: bundle.webRid,
      title: _asString(room['title']),
      nickname: _asString(_asMap(room['owner'])['nickname']),
      avatar: _firstUrl(_asMap(room['owner'])['avatar_thumb']),
      cover: _firstUrl(room['cover']),
      online: _parseViewerText(_asString(_asMap(room['stats'])['total_user_str'])),
      isLive: _asInt(room['status']) == 2,
    );
    if (!info.isLive) return StreamInfoResult(room: info, variants: const []);

    final variants = _buildVariants(_asMap(room['stream_url']));
    return StreamInfoResult(room: info, variants: variants);
  }

  /// 取 ttwid cookie。
  ///
  /// 弹幕 WS 握手少了它会返回 HTTP 200 而不是 101（实测），
  /// 所以必须先访问一次直播首页把它收下来。
  Future<String> fetchTtwid() async {
    if (_ttwid.isNotEmpty) return _ttwid;
    try {
      final response = await _http.getTextWithHeaders(
        'https://live.douyin.com/',
        headers: {
          'User-Agent': _ua,
          'Accept': 'text/html,application/xhtml+xml',
        },
      );
      for (final cookie in response.setCookies) {
        final first = cookie.split(';').first.trim();
        if (first.startsWith('ttwid=')) {
          _ttwid = first;
          break;
        }
      }
    } catch (_) {
      // 取不到也继续（可能仍能连上）
    }
    return _ttwid;
  }

  /// 取内部 roomId（19 位）。弹幕用的是它，不是 web_rid。
  Future<String> fetchInternalRoomId(String roomId) async {
    final bundle = await _resolveRoom(roomId);
    return bundle.internalId;
  }

  /// 解析房间：先拿内部 roomId，再用 reflow 取详情。
  Future<_RoomBundle> _resolveRoom(String roomId) async {
    final webRid = _normalizeRoomId(roomId);
    if (webRid.isEmpty) throw const DouyinException('缺少直播间号');

    final html = await _http.getText(
      'https://live.douyin.com/$webRid',
      headers: {
        'User-Agent': _ua,
        'Referer': _referer,
        'Accept': 'text/html,application/xhtml+xml',
      },
    );
    final internalId = _extractInternalRoomId(html);
    if (internalId.isEmpty) {
      throw const DouyinException('房间页里没找到内部 roomId（直播间号可能不存在）');
    }

    // reflow 必须用内部 roomId（19 位），传 web_rid 会报 room invalid。
    final url = _signed(_urlReflow, [
      ['type_id', '0'],
      ['live_id', '1'],
      ['version_code', '99.99.99'],
      ['app_id', '1128'],
      ['room_id', internalId],
      ['msToken', _msToken(107)],
    ]);
    final json = await _http.getJson(url, headers: {
      'User-Agent': _ua,
      'Referer': _referer,
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
    });
    final root = _asMap(json);
    final code = _asInt(root['status_code']);
    if (code != 0) {
      throw DouyinException(
        '抖音房间接口返回 status_code=$code（${_asString(_asMap(root['data'])['message'])}）',
      );
    }
    final room = _asMap(_asMap(root['data'])['room']);
    if (room.isEmpty) throw const DouyinException('抖音房间数据为空');
    return _RoomBundle(webRid: webRid, internalId: internalId, room: room);
  }

  /// 从房间页内嵌 JSON 里抠内部 roomId（19 位）。
  static String _extractInternalRoomId(String html) {
    for (final pattern in [
      RegExp(r'\\"roomId\\":\\"(\d{10,})\\"'),
      RegExp(r'"roomId":"(\d{10,})"'),
    ]) {
      final match = pattern.firstMatch(html);
      if (match != null) return match.group(1)!;
    }
    return '';
  }

  /// 把「房间号 / 直播间链接」统一成 web_rid。
  static String _normalizeRoomId(String input) {
    var text = input.trim();
    if (text.isEmpty) return '';
    final slash = text.lastIndexOf('live.douyin.com/');
    if (slash >= 0) text = text.substring(slash + 'live.douyin.com/'.length);
    text = text.split('?').first;
    final match = RegExp(r'\d{6,}').firstMatch(text);
    return match?.group(0) ?? '';
  }

  /* --------------------------------------------------------------- 取流 */

  /// 构造清晰度列表。
  ///
  /// **原画不在 flv_pull_url 里**：抖音的 `flv_pull_url` / `hls_pull_url_map` 只有
  /// FULL_HD1/HD1/SD1/SD2 四个转码档，真正的 origin 在
  /// `live_core_sdk_data.pull_data.stream_data` 的内嵌 JSON 里。
  /// 所以优先用 stream_data，失败才退回 flv_pull_url。
  List<StreamVariant> _buildVariants(Map<String, dynamic> streamUrl) {
    final variants = <StreamVariant>[];
    final tiers = _parseStreamData(streamUrl);

    if (tiers.isNotEmpty) {
      // 阶梯顺序（实测）：origin 原画 > uhd 蓝光 > hd 超清 > sd 高清 > ld 标清 > md 流畅
      const order = ['origin', 'uhd', 'hd', 'sd', 'ld', 'md'];
      const labels = {
        'origin': '原画',
        'uhd': '蓝光',
        'hd': '超清',
        'sd': '高清',
        'ld': '标清',
        'md': '流畅',
      };
      for (final key in order) {
        final tier = tiers[key];
        if (tier == null) continue;
        final url = tier.flv.isNotEmpty ? tier.flv : tier.hls;
        if (url.isEmpty) continue;
        variants.add(StreamVariant(
          id: key,
          label: _tierLabel(labels[key] ?? key, tier),
          format: tier.flv.isNotEmpty ? 'flv' : 'hls',
          urls: [StreamUrl(lineId: 'default', url: url)],
        ));
      }
    }

    if (variants.isEmpty) {
      final flv = _asMap(streamUrl['flv_pull_url']);
      for (final key in ['FULL_HD1', 'HD1', 'SD1', 'SD2']) {
        final url = _asString(flv[key]);
        if (url.isEmpty) continue;
        variants.add(StreamVariant(
          id: key.toLowerCase(),
          label: key == 'FULL_HD1' ? '超清' : (key == 'HD1' ? '高清' : '标清'),
          format: 'flv',
          urls: [StreamUrl(lineId: 'default', url: url)],
        ));
      }
    }
    return variants;
  }

  /// 标签加编码/分辨率提示，便于判断 HEVC（libmpv 能解，WebView 不行）。
  static String _tierLabel(String base, _Tier tier) {
    final parts = <String>[base];
    if (tier.resolution.isNotEmpty) parts.add(tier.resolution);
    if (tier.isHevc) parts.add('H.265');
    return parts.join(' · ');
  }

  /// 解析 `stream_data` 内嵌 JSON 成「档位 → 流」。
  static Map<String, _Tier> _parseStreamData(Map<String, dynamic> streamUrl) {
    final core = _asMap(streamUrl['live_core_sdk_data']);
    final pull = _asMap(core['pull_data']);
    var raw = _asString(pull['stream_data']).trim();
    if (raw.isEmpty) {
      // 兼容 pull_datas[<key>].stream_data
      for (final entry in _asMap(streamUrl['pull_datas']).values) {
        final text = _asString(_asMap(entry)['stream_data']).trim();
        if (text.isNotEmpty) {
          raw = text;
          break;
        }
      }
    }
    if (raw.isEmpty) return const {};

    try {
      final outer = _asMap(jsonDecode(raw));
      final data = _asMap(outer['data']);
      final out = <String, _Tier>{};
      for (final entry in data.entries) {
        final main = _asMap(_asMap(entry.value)['main']);
        final flv = _asString(main['flv']).trim();
        final hls = _asString(main['hls']).trim();
        if (flv.isEmpty && hls.isEmpty) continue;

        var codec = '';
        var resolution = '';
        final sdkParams = _asString(main['sdk_params']).trim();
        if (sdkParams.isNotEmpty) {
          try {
            final params = _asMap(jsonDecode(sdkParams));
            codec = _asString(params['VCodec']);
            resolution = _asString(params['resolution']);
          } catch (_) {
            // 参数解析失败不影响取流
          }
        }
        out[entry.key] = _Tier(
          flv: flv,
          hls: hls,
          codec: codec,
          resolution: resolution,
        );
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  /* --------------------------------------------------------------- 工具 */

  static String _firstUrl(Object? value) {
    final list = _asList(_asMap(value)['url_list']);
    for (final item in list) {
      final text = _asString(item);
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  static Map<String, dynamic> _asMap(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  static List<dynamic> _asList(Object? value) =>
      value is List ? value : const [];

  static String _asString(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    return value.toString();
  }

  /// 抖音人气是「10万+」「1.2万」这类文案，转成数字用于排序/展示。
  static int _parseViewerText(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return 0;
    final number = double.tryParse(RegExp(r'[\d.]+').firstMatch(text)?.group(0) ?? '');
    if (number == null) return 0;
    if (text.contains('亿')) return (number * 100000000).round();
    if (text.contains('万')) return (number * 10000).round();
    return number.round();
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }
}

class _RoomBundle {
  const _RoomBundle({
    required this.webRid,
    required this.internalId,
    required this.room,
  });

  final String webRid;
  final String internalId;
  final Map<String, dynamic> room;
}

class _Tier {
  const _Tier({
    required this.flv,
    required this.hls,
    required this.codec,
    required this.resolution,
  });

  final String flv;
  final String hls;
  final String codec;
  final String resolution;

  bool get isHevc {
    switch (codec.toLowerCase().trim()) {
      case 'h265':
      case '265':
      case 'hevc':
      case 'hvc1':
        return true;
      default:
        return false;
    }
  }
}

class DouyinException implements Exception {
  const DouyinException(this.message);
  final String message;

  @override
  String toString() => message;
}