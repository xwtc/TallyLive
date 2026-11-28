import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:flutter/services.dart' show rootBundle;

import 'package:tallylive/core/http.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/platforms/huya/huya_tars.dart';
import 'package:tallylive/platforms/platform_client.dart';

/// 虎牙直播客户端。
///
/// **1:1 移植自 DTV 的 `internal/platforms/huya/`**：
///   - `client.go`      常量与 JSON 容错
///   - `stream_url.go`  profileRoom 取房间档案、抗伪码、WUP 拿 token、档位组装
///   - `tars.go`        TARS 编解码（见 huya_tars.dart）
///
/// 虎牙取流链路：
/// ```
/// 1. mp.huya.com/cache.php?m=Live&do=profileRoom&roomid=<id>&showSecret=1
///      → liveData / profileInfo / stream.baseSteamInfoList（候选线路）
/// 2. 对选中的线路：POST http://wup.huya.com（TARS，liveui.getCdnTokenInfoEx）
///      → sFlvToken
/// 3. buildAntiCode 用 token 里的 fm 重算 wsSecret
/// 4. 拼成 <sFlvUrl>/<sStreamName>.flv?<anti>&codec=264[&ratio=<码率>]
/// ```
///
/// 注意：虎牙给的是 **HTTP-FLV**，这正是 libmpv 相对 WebView 的价值所在
/// （iOS 的 WKWebView 没有 MSE，播不了 FLV）。
class HuyaClient extends PlatformClient {
  HuyaClient({LiveHttp? http}) : _http = http ?? LiveHttp();

  final LiveHttp _http;

  @override
  LivePlatform get platform => LivePlatform.huya;

  // ------------------------------------------------------------------ 常量

  static const String _urlProfileRoom =
      'https://mp.huya.com/cache.php?m=Live&do=profileRoom&roomid=%s&showSecret=1';
  static const String _urlWup = 'http://wup.huya.com';

  /// 直播列表（iGid = 二级分区 id）。
  static const String _urlLiveList =
      'https://live.huya.com/liveHttpUI/getLiveList?iGid=%s&iPageNo=%d&iPageSize=%d';

  /// WUP 请求头里的 UA / Origin / Referer（DTV 照抄 pure_live 的固定值）。
  static const String _huyaHysdkUA =
      'HYSDK(Windows,30000002)_APP(pc_exe&7080000&official)_SDK(trans&2.34.0.5795)';
  static const String _wupOrigin = 'https://m.huya.com/';
  static const String _wupReferer = 'https://m.huya.com/';

  /// profileRoom 用 Firefox UA（与列表接口的 Chrome UA 不同）。
  static const String _firefoxUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:123.0) Gecko/20100101 Firefox/123.0';
  static const String _referer = 'https://www.huya.com/';

  static const String _wupServant = 'liveui';
  static const String _wupFuncName = 'getCdnTokenInfoEx';
  static const int _wupAppID = 66;
  static const String _wupHyuaUA = 'pc_exe&7060000&official';
  static const int _wupLoopTime = 0;

  /* --------------------------------------------------------- 房间档案（profile） */

  Future<_ProfileData> _fetchProfile(String roomId) async {
    final target = _urlProfileRoom.replaceAll('%s', Uri.encodeQueryComponent(roomId));
    final body = await _http.getText(target, headers: {
      'User-Agent': _firefoxUA,
      'Referer': _referer,
      'Origin': 'https://www.huya.com',
      'Accept': '*/*',
    });

    final root = _asMap(jsonDecode(body));
    if (_asInt(root['status']) != 200) {
      throw HuyaException(
        '虎牙房间档案返回 status=${_asInt(root['status'])}（房间可能不存在）',
      );
    }
    return _ProfileData(_asMap(root['data']));
  }

  @override
  Future<RoomInfo> fetchRoomInfo(String roomId) async {
    final data = await _fetchProfile(roomId);
    final candidates = _parseCandidates(data);
    return RoomInfo(
      platform: platform,
      roomId: roomId,
      title: _firstNonEmpty([
        data.liveDataString('introduction'),
        data.liveDataString('roomName'),
      ]),
      nickname: _firstNonEmpty([
        data.profileInfoString('nick'),
        data.liveDataString('nick'),
      ]),
      avatar: _firstNonEmpty([
        data.profileInfoString('avatar180'),
        data.liveDataString('avatar180'),
      ]),
      isLive: candidates.isNotEmpty,
    );
  }

  /* --------------------------------------------------------------- 取流 */

  @override
  Future<StreamInfoResult> fetchStreamInfo(String roomId) async {
    final data = await _fetchProfile(roomId);
    final candidates = _parseCandidates(data);

    final room = RoomInfo(
      platform: platform,
      roomId: roomId,
      title: _firstNonEmpty([
        data.liveDataString('introduction'),
        data.liveDataString('roomName'),
      ]),
      nickname: _firstNonEmpty([
        data.profileInfoString('nick'),
        data.liveDataString('nick'),
      ]),
      avatar: _firstNonEmpty([
        data.profileInfoString('avatar180'),
        data.liveDataString('avatar180'),
      ]),
      isLive: candidates.isNotEmpty,
    );

    if (candidates.isEmpty) {
      return StreamInfoResult(room: room, variants: const []);
    }

    final lines = [
      for (final candidate in candidates)
        StreamLine(
          id: candidate.cdnType.toLowerCase(),
          label: candidate.cdnType.toUpperCase(),
        ),
    ];

    final selected = candidates.first;
    final bitrates = _availableBitrates(data);
    final variants = <StreamVariant>[];

    // token 与清晰度无关：取一次，再给每个档位拼不同 ratio
    // （DTV 里是每档都调一次 buildStreamURL，会重复请求 WUP，这里合并成一次）
    try {
      final token = await _getCdnToken(selected.flvUrl, selected.streamName);
      final anti = _buildAntiCode(selected.streamName, selected.channelId, token);
      var base = '${selected.flvUrl.replaceFirst(RegExp(r'/+$'), '')}'
          '/${selected.streamName}.flv?$anti&codec=264';
      base = _enforceHttps(base);

      final hdBitrate = bitrates.isNotEmpty ? bitrates.last : 4000;
      final sdBitrate = bitrates.isNotEmpty ? bitrates.first : 2000;

      // 原画不带 ratio；高清取最大码率；标清取最小码率。
      final specs = <({String id, String label, int? ratio})>[
        (id: 'source', label: '原画', ratio: null),
        if (hdBitrate > 0) (id: 'high', label: '高清 ${hdBitrate}K', ratio: hdBitrate),
        if (sdBitrate > 0) (id: 'standard', label: '标清 ${sdBitrate}K', ratio: sdBitrate),
      ];

      for (final spec in specs) {
        final url = spec.ratio == null ? base : '$base&ratio=${spec.ratio}';
        variants.add(StreamVariant(
          id: spec.id,
          label: spec.label,
          format: 'flv',
          urls: [StreamUrl(lineId: selected.cdnType.toLowerCase(), url: url)],
        ));
      }
    } catch (_) {
      // 单个线路/档位失败不抛出，交给上层判断「没有可用档位」
    }

    return StreamInfoResult(room: room, lines: lines, variants: variants);
  }

  /* ------------------------------------------------- 弹幕进房参数 */

  /// 取弹幕进房需要的 ayyuid / topSid / subSid。
  ///
  /// 这三个值只在 profileRoom 的房间档案里（liveData.uid / stream.*），
  /// 弹幕 WS 进房包必须带，所以单独暴露一个方法给弹幕客户端用。
  Future<({int ayyuid, int topSid, int subSid})> fetchHuyaJoinInfo(
    String roomId,
  ) async {
    final data = await _fetchProfile(roomId);
    final candidates = _parseCandidates(data);
    final first = candidates.isNotEmpty ? candidates.first : null;
    final topSid = _asInt(data.raw['topSid']);
    final subSid = _asInt(data.raw['subSid']);
    return (
      ayyuid: _asInt(data.liveData['uid']),
      topSid: topSid != 0 ? topSid : (first?.channelId ?? 0),
      subSid: subSid != 0 ? subSid : (first?.channelId ?? 0),
    );
  }

  /* -------------------------------------------------- 分区 / 直播列表 */

  List<CategoryGroup> _categoryCache = const [];
  DateTime _categoryAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 分区树来自内置资源（DTV 也是 `assets/categories.json`，虎牙没有稳定的分区接口）。
  ///
  /// 结构：`[{title, href, subcategories:[{title, href, id}]}]`，
  /// 分组 id 用下标生成（原表没有分组 id），二级分区用表里的 `id` 当 iGid。
  @override
  Future<List<CategoryGroup>> fetchCategories() async {
    if (_categoryCache.isNotEmpty &&
        DateTime.now().difference(_categoryAt) < const Duration(minutes: 30)) {
      return _categoryCache;
    }
    final raw = await rootBundle.loadString('assets/huya_categories.json');
    final decoded = jsonDecode(raw);
    final groups = <CategoryGroup>[];
    var index = 0;
    for (final item in _asList(decoded)) {
      final group = _asMap(item);
      index++;
      final children = <Category>[];
      for (final sub in _asList(group['subcategories'])) {
        final entry = _asMap(sub);
        final id = _asString(entry['id']);
        if (id.isEmpty) continue;
        children.add(Category(id: id, name: _asString(entry['title'])));
      }
      if (children.isEmpty) continue;
      groups.add(CategoryGroup(
        id: '$index',
        name: _asString(group['title']),
        categories: children,
      ));
    }
    if (groups.isEmpty) throw const HuyaException('虎牙分区表为空');
    _categoryCache = groups;
    _categoryAt = DateTime.now();
    return groups;
  }

  /// 按二级分区拉直播列表；categoryId 为空时用第一个分区兜底。
  @override
  Future<StreamerPage> fetchLiveList({
    String? categoryId,
    int page = 1,
    int limit = 30,
  }) async {
    var gid = (categoryId ?? '').trim();
    if (gid.isEmpty) {
      final groups = await fetchCategories();
      gid = groups.first.categories.first.id;
    }
    final safePage = page < 1 ? 1 : page;
    final safeLimit = limit <= 0 ? 30 : limit;

    final url = _urlLiveList
        .replaceFirst('%s', gid)
        .replaceFirst('%d', '$safePage')
        .replaceFirst('%d', '$safeLimit');

    final json = await _http.getJson(url, headers: {
      'User-Agent': _firefoxUA,
      'Referer': 'https://www.huya.com/',
    });
    final root = _asMap(json);
    // 实测：虎牙 getLiveList 的 vList / iTotalPage 都在【顶层】，
    // 不在 data 里（按 data.vList 读会永远得到空列表 → 页面显示"没有在播"）。
    // 同时兼容两种形状，避免上游改结构后再次静默空列表。
    final data = root['data'] is Map ? _asMap(root['data']) : root;
    final list = _asList(data['vList']);

    final items = <Streamer>[];
    for (final raw in list) {
      final item = _asMap(raw);
      final roomId = _asString(item['lProfileRoom']);
      if (roomId.isEmpty) continue;
      var nickname = _asString(item['sNick']);
      if (nickname.isEmpty) nickname = '房间 $roomId';
      items.add(Streamer(
        platform: platform,
        id: roomId,
        nickname: nickname,
        title: _asString(item['sIntroduction']),
        cover: _enforceHttps(_asString(item['sScreenshot'])),
        avatar: _enforceHttps(_asString(item['sAvatar180'])),
        viewers: _asInt(item['lUserCount']),
        categoryName: _firstNonEmpty([
          _asString(item['sGameFullName']),
          _asString(item['sGameHostName']),
        ]),
        isLive: true,
      ));
    }

    final totalPages = _asInt(data['iTotalPage']);
    return StreamerPage(
      items: items,
      page: safePage,
      hasMore: totalPages > safePage,
      totalPages: totalPages,
    );
  }

  /* --------------------------------------------------------------- 防伪码 */

  /// 用 WUP 拿到的 token 重新构造播放地址的鉴权串。
  ///
  /// 移植自 DTV `buildAntiCode`（对齐 pure_live）：
  /// ```
  /// seqid      = presenterUID + 当前毫秒
  /// secretHash = md5("seqid|ctype|platformId")
  /// wsSecret   = md5("<fm 前缀>_<calcUid>_<streamName>_<secretHash>_<wsTime>")
  /// ```
  String _buildAntiCode(String streamName, int presenterUid, String token) {
    final sanitized = token.replaceAll('&amp;', '&');
    final trimmed = sanitized.replaceFirst(RegExp(r'^[?&]+'), '');
    final params = Uri.splitQueryString(trimmed);

    final fm = params['fm'] ?? '';
    if (fm.isEmpty) {
      // 上游已经给了可用的 query，直接用
      return trimmed;
    }

    final ctype = (params['ctype'] ?? '').isEmpty ? 'huya_pc_exe' : params['ctype']!;
    final platformId = int.tryParse(params['t'] ?? '') ?? 0;
    final isWap = platformId == 103;

    final calcStart = DateTime.now().millisecondsSinceEpoch;
    final seqId = presenterUid + calcStart;
    final secretHash = _md5Hex('$seqId|$ctype|$platformId');

    final convertUid = _rotl32By8(presenterUid);
    final calcUid = isWap ? presenterUid : convertUid;

    final fmDecoded = Uri.decodeQueryComponent(fm);
    final secretPrefix = _base64StdDecode(fmDecoded).split('_').first;
    if (secretPrefix.isEmpty) {
      throw const HuyaException('无法从 fm 推导 wsSecret 前缀');
    }

    final wsTime = params['wsTime'] ?? '';
    if (wsTime.isEmpty) {
      throw const HuyaException('anti-code 缺少 wsTime');
    }

    final secretStr = '${secretPrefix}_${calcUid}_${streamName}_${secretHash}_$wsTime';
    final wsSecret = _md5Hex(secretStr);

    final fs = params['fs'] ?? '';
    if (fs.isEmpty) {
      throw const HuyaException('anti-code 缺少 fs');
    }

    final wsTimeInt = int.tryParse(wsTime.trim(), radix: 16) ?? 0;
    final random = Random();
    final ct = ((wsTimeInt + random.nextDouble()) * 1000).truncate();
    var uuid = ((ct % 10000000000 + random.nextDouble()) * 1000).truncate();
    uuid %= 0xFFFFFFFF;

    final parts = <String>[
      'wsSecret=$wsSecret',
      'wsTime=$wsTime',
      'seqid=$seqId',
      'ctype=$ctype',
      'ver=1',
      'fs=$fs',
      'fm=${Uri.encodeQueryComponent(fm)}',
      't=$platformId',
      // 注意这里是单引号里的 $calcUid 与字符串拼接
      if (isWap) 'uid=$presenterUid' else 'u=$convertUid',
      if (isWap) 'uuid=$uuid',
    ];
    return parts.join('&');
  }

  /// 把 32 位部分循环左移 8 位（对齐 DTV `rotl32By8`）。
  int _rotl32By8(int value) {
    final low = value & 0xFFFFFFFF;
    final rotated = ((low << 8) | (low >> 24)) & 0xFFFFFFFF;
    final high = value & ~0xFFFFFFFF;
    return high | rotated;
  }

  /* --------------------------------------------------------------- WUP */

  /// 调 WUP 的 getCdnTokenInfoEx 拿播放鉴权 token。
  Future<String> _getCdnToken(String flvUrl, String streamName) async {
    final req = TarsWriter();
    req.writeStructBegin(0);
    req.writeString(0, flvUrl);
    req.writeString(1, streamName);
    req.writeInt32(2, _wupLoopTime);
    req.writeStructBegin(3); // HuyaUserId
    req.writeInt64(0, 0);
    req.writeString(1, '');
    req.writeString(2, '');
    req.writeString(3, _wupHyuaUA);
    req.writeString(4, '');
    req.writeInt32(5, 0);
    req.writeString(6, '');
    req.writeString(7, '');
    req.writeStructEnd();
    req.writeInt32(4, _wupAppID);
    req.writeStructEnd();
    final reqBytes = req.toBytes();

    // UniAttribute：map<string,bytes>{"tReq": reqBytes}
    final tup = TarsWriter();
    tup.writeBytesMap(0, 'tReq', reqBytes);

    final packet = _encodeWupRequest(1, _wupServant, _wupFuncName, tup.toBytes());

    final resp = await _http.postBytes(_urlWup, packet, headers: {
      'User-Agent': _huyaHysdkUA,
      'Origin': _wupOrigin,
      'Referer': _wupReferer,
      'Accept': '*/*',
    });

    final decoded = _decodeWupResponse(resp);
    if (decoded.ret != 0) {
      throw HuyaException(
        decoded.desc.isEmpty
            ? '虎牙 WUP 返回 ret=${decoded.ret}'
            : '虎牙 WUP 返回 ret=${decoded.ret}: ${decoded.desc}',
      );
    }
    final token = _decodeTokenFromTup(decoded.payload);
    if (token.isEmpty) {
      throw const HuyaException('虎牙 WUP 没有返回可用 token');
    }
    return token;
  }

  /// 组装 TARS 请求包（4 字节大端总长度 + ResponsePacket）。
  Uint8List _encodeWupRequest(
    int requestId,
    String servant,
    String fn,
    Uint8List tupPayload,
  ) {
    final w = TarsWriter();
    w.writeInt16(1, 3); // iVersion
    w.writeInt8(2, 0); // cPacketType
    w.writeInt32(3, 0); // iMessageType
    w.writeInt32(4, requestId);
    w.writeString(5, servant);
    w.writeString(6, fn);
    w.writeBytes(7, tupPayload);
    w.writeInt32(8, 0); // iTimeout
    w.writeEmptyMap(9);
    w.writeEmptyMap(10);

    final body = w.toBytes();
    final total = body.length + 4;
    final out = Uint8List(total);
    out[0] = (total >> 24) & 0xFF;
    out[1] = (total >> 16) & 0xFF;
    out[2] = (total >> 8) & 0xFF;
    out[3] = total & 0xFF;
    out.setRange(4, total, body);
    return out;
  }

  /// 解开 4 字节长度前缀 + ResponsePacket，返回 (ret, tupPayload, desc)。
  ({int ret, Uint8List payload, String desc}) _decodeWupResponse(Uint8List buf) {
    var payload = buf;
    if (buf.length >= 4) {
      final declared = (buf[0] << 24) | (buf[1] << 16) | (buf[2] << 8) | buf[3];
      if (declared >= 4 && declared <= buf.length) {
        payload = Uint8List.sublistView(buf, 4, declared);
      }
    }

    // 标准布局：iRet(5) + sBuffer(6) + status(7) + sResultDesc(8)
    // 不能先用 find 做布局探测（find 不消费值，会导致后续错位）。
    final r = TarsReader(payload);
    final ret = r.readInt32Tag(5, -1);
    final sBuffer = r.readBytesTag(6);
    if (sBuffer != null) {
      final desc = r.readStringTag(8, '');
      return (ret: ret, payload: sBuffer, desc: desc);
    }

    // 退化布局：sBuffer 在 tag 7
    final r2 = TarsReader(payload);
    final alt = r2.readBytesTag(7);
    if (alt != null) {
      return (ret: 0, payload: alt, desc: '');
    }
    return (ret: -1, payload: Uint8List(0), desc: '');
  }

  /// 从 UniAttribute 里取出 flvToken（兼容两种布局）。
  String _decodeTokenFromTup(Uint8List payload) {
    if (payload.isEmpty) return '';

    final flat = _decodeStringBytesMap(payload);
    if (flat != null && flat.containsKey('tRsp')) {
      final token = _decodeTokenStruct(flat['tRsp']!);
      if (token.isNotEmpty) return token;
    }

    // 复杂布局：tRsp → map<string,bytes>
    final outer = _decodeStringBytesMapReader(TarsReader(payload));
    if (outer == null) return '';
    final inner = outer['tRsp'];
    if (inner == null) return '';

    final nested = _decodeStringBytesMap(inner);
    if (nested != null) {
      final named = nested['GetCdnTokenExResp'];
      if (named != null) {
        final token = _decodeTokenStruct(named);
        if (token.isNotEmpty) return token;
      }
      for (final value in nested.values) {
        final token = _decodeTokenStruct(value);
        if (token.isNotEmpty) return token;
      }
    }
    return _decodeTokenStruct(inner);
  }

  Map<String, Uint8List>? _decodeStringBytesMap(Uint8List payload) =>
      _decodeStringBytesMapReader(TarsReader(payload));

  Map<String, Uint8List>? _decodeStringBytesMapReader(TarsReader r) {
    final head = r.takeHead();
    if (head.type != TarsTypes.map) return null;
    final count = r.readInt32Seq(0);
    if (count < 0 || count > 64) return null;
    final out = <String, Uint8List>{};
    for (var i = 0; i < count; i++) {
      final key = r.readStringTag(0, '');
      final value = r.readBytesTag(1);
      if (value == null) return null;
      out[key] = value;
    }
    return out;
  }

  /// 解 GetCdnTokenExResp（tag0 = sFlvToken）。
  String _decodeTokenStruct(Uint8List payload) {
    final r = TarsReader(payload);
    if (!r.readStructBegin(0)) return '';
    return r.readStringTag(0, '').trim();
  }

  /* --------------------------------------------------------------- 工具 */

  List<_StreamCandidate> _parseCandidates(_ProfileData data) {
    final list = <_StreamCandidate>[];
    final raw = data.baseStreamInfoList();
    if (raw.isEmpty) return list;

    var fallbackUid = 0;
    final firstChannel = _asInt(raw.first['lChannelId']);
    if (firstChannel != 0) fallbackUid = firstChannel;

    for (final item in raw) {
      final cdnType = _asString(item['sCdnType']);
      final flvUrl = _asString(item['sFlvUrl']);
      final streamName = _asString(item['sStreamName']);
      if (cdnType.isEmpty || flvUrl.isEmpty || streamName.isEmpty) continue;

      var channelId = _asInt(item['lChannelId']);
      if (channelId == 0) channelId = fallbackUid;
      if (channelId == 0) continue;

      list.add(_StreamCandidate(
        cdnType: cdnType,
        flvUrl: flvUrl,
        streamName: streamName,
        channelId: channelId,
      ));
    }

    // 线路优先级 tx > al > hs > 其它
    int priority(String cdn) {
      switch (cdn.toLowerCase()) {
        case 'tx':
          return 0;
        case 'al':
          return 1;
        case 'hs':
          return 2;
        default:
          return 3;
      }
    }

    list.sort((a, b) => priority(a.cdnType).compareTo(priority(b.cdnType)));
    return list;
  }

  /// 可用码率：优先 liveData.bitRateInfo，其次 stream.flv.rateArray。
  List<int> _availableBitrates(_ProfileData data) {
    final out = <int>[];

    final bitRateInfo = data.liveDataString('bitRateInfo');
    if (bitRateInfo.isNotEmpty) {
      try {
        final arr = jsonDecode(bitRateInfo);
        if (arr is List) {
          for (final item in arr) {
            final value = _asInt(_asMap(item)['iBitRate']);
            if (value > 0) out.add(value);
          }
        }
      } catch (_) {
        // 解析失败走 fallback
      }
    }

    if (out.isEmpty) {
      final rateArray = data.streamFlvRateArray();
      for (final item in rateArray) {
        final value = _asInt(item['iBitRate']);
        if (value > 0) out.add(value);
      }
    }

    out.sort();
    final deduped = <int>[];
    for (final value in out) {
      if (deduped.isEmpty || deduped.last != value) deduped.add(value);
    }
    return deduped;
  }

  static String _md5Hex(String input) =>
      md5.convert(utf8.encode(input)).toString();

  /// 标准 base64 解码，兼容 URL-safe 变体与缺失 padding。
  static String _base64StdDecode(String input) {
    var std = input.replaceAll('-', '+').replaceAll('_', '/');
    final mod = std.length % 4;
    if (mod != 0) std = std + '=' * (4 - mod);
    try {
      return utf8.decode(base64.decode(std), allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  static String _enforceHttps(String raw) {
    if (raw.startsWith('https://')) return raw;
    if (raw.startsWith('http://')) {
      return 'https://${raw.substring('http://'.length)}';
    }
    return raw;
  }

  static String _firstNonEmpty(List<String> values) {
    for (final value in values) {
      if (value.isNotEmpty) return value;
    }
    return '';
  }
}

/* ------------------------------------------------------------------ 内部类型 */

class _ProfileData {
  _ProfileData(this.raw);
  final Map<String, dynamic> raw;

  Map<String, dynamic> get liveData => _asMap(raw['liveData']);
  Map<String, dynamic> get profileInfo => _asMap(raw['profileInfo']);
  Map<String, dynamic> get stream => _asMap(raw['stream']);

  String liveDataString(String key) => _asString(liveData[key]);
  String profileInfoString(String key) => _asString(profileInfo[key]);

  /// 候选线路列表（字段名 baseSteamInfoList 是虎牙自己的拼写错误）。
  List<Map<String, dynamic>> baseStreamInfoList() {
    final out = <Map<String, dynamic>>[];
    for (final item in _asList(stream['baseSteamInfoList'])) {
      out.add(_asMap(item));
    }
    return out;
  }

  List<Map<String, dynamic>> streamFlvRateArray() {
    final flv = _asMap(stream['flv']);
    final out = <Map<String, dynamic>>[];
    for (final item in _asList(flv['rateArray'])) {
      out.add(_asMap(item));
    }
    return out;
  }
}

class _StreamCandidate {
  const _StreamCandidate({
    required this.cdnType,
    required this.flvUrl,
    required this.streamName,
    required this.channelId,
  });

  final String cdnType;
  final String flvUrl;
  final String streamName;
  final int channelId;
}

class HuyaException implements Exception {
  const HuyaException(this.message);
  final String message;

  @override
  String toString() => message;
}

/* ------------------------------------------------------------------ JSON 容错 */

Map<String, dynamic> _asMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

List<dynamic> _asList(Object? value) => value is List ? value : const [];

String _asString(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is double) {
    return value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
  }
  return value.toString();
}

/// 虎牙的 lChannelId / uid 有时是 `2.367547387e+09` 这种浮点，有时是字符串。
int _asInt(Object? value) {
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 0;
    return int.tryParse(trimmed) ?? double.tryParse(trimmed)?.toInt() ?? 0;
  }
  return 0;
}
