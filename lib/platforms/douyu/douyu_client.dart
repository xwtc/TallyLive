import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'package:tallylive/core/http.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/platforms/platform_client.dart';

/// 斗鱼直播客户端。
///
/// 移植自 TallyLive(Go) 的 internal/platforms/douyu：
///   - client.go     did 生成、Cookie 裁剪、JSON 容错、头像补全
///   - room_info.go  betard 接口（4 种响应包装兜底）
///   - stream_url.go getEncryption + MD5 签名链 + getH5PlayV1 + 多 CDN 档位解析
///
/// 斗鱼取流是**纯 MD5 计算**，不依赖 JS 引擎，所以 Dart 侧可以完整复刻。
///
/// 关键实测结论（Go 版注释，移植时保留）：
///   - 每个进程随机一个 32 位 hex 的 did，而不是固定游客号；
///   - getH5PlayV1 接口一次只返回一条 URL，所以每个清晰度都要单独请求；
///   - 拿到的 ws CDN 直链可能只有 300 秒（expire=300&fcdn=ws），
///     需要补 `&expire=0` 让 CDN 按默认时长签发。
class DouyuClient extends PlatformClient {
  DouyuClient({LiveHttp? http}) : _http = http ?? LiveHttp() {
    _did = _generateDeviceId();
  }

  final LiveHttp _http;

  @override
  LivePlatform get platform => LivePlatform.douyu;

  static const String _desktopUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  static const String _defaultDID = '10000000000000000000000000001501';
  static const String _coverPrefix = 'https://rpic.douyucdn.cn/';

  static const String _urlBetard = 'https://www.douyu.com/betard/';
  static const String _urlCateList = 'https://m.douyu.com/api/cate/list';
  static const String _urlGetEncryption =
      'https://www.douyu.com/wgapi/livenc/liveweb/websec/getEncryption';
  static const String _urlGetH5Play =
      'https://www.douyu.com/lapi/live/getH5PlayV1/';

  /// 加密描述符缓存时长（与 Go 版一致：5 分钟）。
  static const Duration _encryptionCacheMaxAge = Duration(minutes: 5);
  static const int _encryptionExpiryGuardSeconds = 30;

  String _did = _defaultDID;

  _EncryptionData? _enc;
  DateTime _encFetchedAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _encDID = '';

  /// 生成 32 位十六进制的浏览器 did（每进程一个随机值）。
  String _generateDeviceId() {
    try {
      final random = Random.secure();
      final bytes = List<int>.generate(16, (_) => random.nextInt(256));
      return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    } catch (_) {
      return _defaultDID;
    }
  }

  /// 匿名/登录都给一份带 dy_did / acf_did 的 Cookie。
  ///
  /// 未登录时只发 did；登录后 Go 版会按 H5/Web 两套会话做裁剪，
  /// 当前阶段尚未接入登录，这里只处理匿名形态。
  String get _cookie => 'dy_did=$_did; acf_did=$_did';

  Map<String, String> _headersFor(String roomId) => {
        'accept': 'application/json, text/plain, */*',
        'accept-language': 'zh-CN,zh;q=0.9,en;q=0.7',
        'origin': 'https://www.douyu.com',
        'referer': 'https://www.douyu.com/$roomId',
        'user-agent': _desktopUA,
        'cookie': _cookie,
      };

  /* ------------------------------ 房间信息 ------------------------------ */

  @override
  Future<RoomInfo> fetchRoomInfo(String roomId) async {
    if (roomId.isEmpty) {
      throw const DouyuException('缺少房间号');
    }

    final json = await _http.getJson(
      '$_urlBetard$roomId',
      headers: {
        'User-Agent': _desktopUA,
        'Referer': 'https://www.douyu.com/$roomId',
      },
    );

    final room = _locateRoomObject(_asMap(json));
    if (room.isEmpty) {
      throw DouyuException('房间 $roomId 未返回房间数据（可能房间不存在）');
    }

    final realRoomId = _asString(room['room_id']);
    final showStatus = _asInt(room['show_status']);
    final videoLoop = _asInt(room['videoLoop']);
    final isLoop = _asInt(room['isLoop']);

    return RoomInfo(
      platform: platform,
      roomId: realRoomId.isEmpty ? roomId : realRoomId,
      title: _asString(room['room_name']),
      nickname: _firstNonEmpty([
        _asString(room['nickname']),
        _asString(room['owner_name']),
        '房间 $roomId',
      ]),
      avatar: _douyuAvatarUrl(_firstNonEmpty([
        _asString(room['avatar_mid']),
        _nestedString(room, ['avatar', 'middle']),
      ])),
      cover: _fullUrl(_coverPrefix, _asString(room['room_src'])),
      category: _firstNonEmpty([
        _asString(room['second_lvl_name']),
        _asString(room['cate2_name']),
      ]),
      isLive: _isLiveFromFlags(showStatus, isLoop, videoLoop),
    );
  }

  /// betard 的响应有 4 种包装，逐个兜底（与 Go 版 locateRoomObject 一致）。
  Map<String, dynamic> _locateRoomObject(Map<String, dynamic> payload) {
    final data = payload['data'];
    if (data is Map) {
      final dataMap = Map<String, dynamic>.from(data);
      final room = dataMap['room'];
      if (room is Map) return Map<String, dynamic>.from(room);
      return dataMap;
    }
    final room = payload['room'];
    if (room is Map) return Map<String, dynamic>.from(room);
    return payload;
  }

  /// 直播中判定：show_status==1 且不是轮播。
  bool _isLiveFromFlags(int showStatus, int isLoop, int videoLoop) {
    if (showStatus != 1) return false;
    return isLoop != 1 && videoLoop != 1;
  }

  /* ------------------------------ 取流 ------------------------------ */

  @override
  Future<StreamInfoResult> fetchStreamInfo(String roomId) async {
    final room = await fetchRoomInfo(roomId);
    if (!room.isLive) {
      return StreamInfoResult(room: room, variants: const []);
    }

    // 第一次不指定档位：拿到清晰度列表 + 线路列表 + 默认线路下的地址。
    final first = await _requestPlayData(room.roomId, -1, '');
    final rates = _parsePlayQualities(first.data);
    final allLines = _parseCdns(first.data);
    final defaultRate = _asInt(first.data['rate']);

    // 每个档位对每条线路各请求一次，得到可切换的完整线路表。
    // 请求数 = 档位数 × 线路数，两个都设上限，避免把上游打毛。
    final lines = allLines.take(_maxLinesPerVariant).toList();
    final variants = <StreamVariant>[];
    final seenLabels = <String>{};

    for (final rate in rates.take(_maxRates)) {
      final urls = <StreamUrl>[];
      for (final line in lines) {
        try {
          // 默认档位 + 默认线路可以直接复用第一次请求的结果。
          final reuseFirst = rate.rate == defaultRate &&
              line.id == (lines.isNotEmpty ? lines.first.id : '');
          final data = reuseFirst
              ? first.data
              : (await _requestPlayData(room.roomId, rate.rate, line.id)).data;

          final url = _parsePlayUrl(data);
          if (url.isEmpty) continue;
          urls.add(StreamUrl(lineId: line.id, url: url));
        } catch (_) {
          // 某条线路失败不影响其它线路。
          continue;
        }
      }
      if (urls.isEmpty) continue;

      final label = rate.name.isEmpty ? '默认' : rate.name;
      if (!seenLabels.add(label)) continue;

      variants.add(StreamVariant(
        id: rate.rate.toString(),
        label: label,
        format: douyuFormatOf(urls.first.url),
        urls: urls,
      ));
    }

    return StreamInfoResult(room: room, lines: lines, variants: variants);
  }

  /// 每个档位最多请求几条线路（信号源质量差异不大，3 条足够）。
  static const int _maxLinesPerVariant = 3;

  /// 最多保留几个清晰度档位。
  static const int _maxRates = 5;

  /// 请求一次 getH5PlayV1。
  ///
  /// 失败时强制刷新加密描述符重试一次（描述符可能刚过期）。
  Future<_PlayResponse> _requestPlayData(
    String roomId,
    int rate,
    String cdn,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final signed = await _sign(roomId, rate, cdn, force: attempt > 0);
        final url = '$_urlGetH5Play$roomId';
        final body = await _http.postForm(
          url,
          signed.form,
          headers: _headersFor(roomId),
        );
        final json = jsonDecode(body);
        final map = _asMap(json);

        var code = _asInt(map['error']);
        if (code == 0) code = _asInt(map['code']);
        final data = map['data'];

        if (code != 0) {
          throw DouyuException(
            '斗鱼取流接口返回 error=$code msg=${_asString(map['msg'])}'
            '（rate=$rate cdn=$cdn）',
          );
        }
        if (data is! Map) {
          throw DouyuException('斗鱼取流接口未返回 data（rate=$rate cdn=$cdn）');
        }
        return _PlayResponse(Map<String, dynamic>.from(data));
      } catch (error) {
        lastError = error;
        continue;
      }
    }
    throw DouyuException('斗鱼取流失败：$lastError');
  }

  /// 生成签名表单。
  ///
  /// 算法与 Go 版 sign / pure_live 一致：
  ///   secret = rand_str
  ///   循环 enc_time 次： secret = md5(secret + key)
  ///   auth   = md5(secret + key + (is_special==1 ? "" : roomID+ts))
  Future<_SignedForm> _sign(
    String roomId,
    int rate,
    String cdn, {
    required bool force,
  }) async {
    final enc = await _ensureEncryption(force);

    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final suffix = enc.isSpecial == 1 ? '' : '$roomId$ts';

    final secret = douyuSignSecret(
      randStr: enc.randStr,
      key: enc.key,
      encTime: enc.encTime,
    );

    final form = <String, String>{
      'enc_data': enc.encData,
      'tt': ts.toString(),
      'did': enc.did,
      'auth': douyuSignAuth(secret: secret, key: enc.key, suffix: suffix),
      'cdn': cdn,
      'rate': rate.toString(),
      'hevc': '0',
      'fa': '0',
      'ive': '0',
      'ver': 'Douyu_new',
      'iar': '0',
    };
    return _SignedForm(form);
  }

  /// 获取/复用加密描述符。
  Future<_EncryptionData> _ensureEncryption(bool force) async {
    final now = DateTime.now();
    final cached = _enc;
    if (!force &&
        cached != null &&
        _encDID == _did &&
        now.difference(_encFetchedAt) < _encryptionCacheMaxAge &&
        cached.expireAt >
            now.millisecondsSinceEpoch ~/ 1000 + _encryptionExpiryGuardSeconds &&
        cached.encTime >= 1 &&
        cached.encTime <= 8 &&
        cached.key.isNotEmpty &&
        cached.randStr.isNotEmpty &&
        cached.encData.isNotEmpty) {
      return cached;
    }

    final json = await _http.getJson(
      _urlGetEncryption,
      headers: _headersFor(''),
      query: {'did': _did},
    );
    final map = _asMap(json);

    if (_asInt(map['error']) != 0) {
      throw DouyuException(
        '斗鱼签名接口返回 error=${_asInt(map['error'])} msg=${_asString(map['msg'])}',
      );
    }
    final data = _asMap(map['data']);
    final key = _asString(data['key']);
    final randStr = _asString(data['rand_str']);
    final encData = _asString(data['enc_data']);
    final encTime = _asInt(data['enc_time']);
    if (key.isEmpty || randStr.isEmpty || encData.isEmpty) {
      throw const DouyuException('斗鱼签名接口未返回有效参数');
    }
    if (encTime < 1 || encTime > 8) {
      throw DouyuException('斗鱼签名接口 enc_time 非法：$encTime');
    }

    final encryption = _EncryptionData(
      did: _did,
      key: key,
      randStr: randStr,
      encTime: encTime,
      encData: encData,
      isSpecial: _asInt(data['is_special']),
      expireAt: _asInt(data['expire_at']),
    );
    _enc = encryption;
    _encFetchedAt = now;
    _encDID = _did;
    return encryption;
  }

  /// 解析清晰度列表：保持斗鱼下发顺序，rate 作为稳定 id。
  ///
  /// 注意斗鱼的 rate 是「请求码」不是码率，不能按数值排序
  /// （原画常见 0，蓝光4M 是 4，超清 3，高清 2）。
  List<_RateVariant> _parsePlayQualities(Map<String, dynamic> data) {
    final result = <_RateVariant>[];
    final seen = <int>{};

    for (final item in _asList(data['multirates'])) {
      final entry = _asMap(item);
      final rate = _asInt(entry['rate']);
      if (!seen.add(rate)) continue;
      result.add(_RateVariant(
        name: _asString(entry['name']).trim(),
        rate: rate,
        bit: _asInt(entry['bit']),
      ));
    }

    if (result.isEmpty) {
      final rate = _asInt(data['rate']);
      result.add(_RateVariant(name: '默认', rate: rate == 0 ? -1 : rate, bit: 0));
    }
    return result;
  }

  /// 解析线路列表：cdnsWithName 优先，rtmp_cdn 未出现时插到最前，
  /// scdn* 线路排到最后（与 Go 版 parseCDNs 一致）。
  List<StreamLine> _parseCdns(Map<String, dynamic> data) {
    final result = <StreamLine>[];
    final seen = <String>{};

    void add(String id, String label) {
      final trimmed = id.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) return;
      result.add(StreamLine(
        id: trimmed,
        label: label.trim().isEmpty ? trimmed : label.trim(),
      ));
    }

    for (final item in _asList(data['cdnsWithName'])) {
      final entry = _asMap(item);
      add(_asString(entry['cdn']), _asString(entry['name']));
    }

    final current = _asString(data['rtmp_cdn']).trim();
    if (current.isNotEmpty && !seen.contains(current)) {
      result.insert(0, StreamLine(id: current, label: current));
    }
    if (result.isEmpty) {
      result.add(const StreamLine(id: '', label: '默认'));
    }

    result.sort((a, b) {
      final aScdn = a.id.toLowerCase().startsWith('scdn');
      final bScdn = b.id.toLowerCase().startsWith('scdn');
      if (aScdn == bScdn) return 0;
      return aScdn ? 1 : -1;
    });
    return result;
  }

  /// 从 playData 里拼出可播放地址（与 Go 版 parsePlayURL 的顺序一致）。
  String _parsePlayUrl(Map<String, dynamic> data) {
    final live = _htmlUnescape(_asString(data['rtmp_live'])).trim();
    if (_isPlayableUrl(live)) return douyuApplyExpirePatch(live);

    for (final baseRaw in [_asString(data['rtmp_url']), _asString(data['flv_url'])]) {
      final base = _htmlUnescape(baseRaw).trim();
      if (base.isEmpty || live.isEmpty) continue;
      final combined =
          '${base.replaceFirst(RegExp(r'/+$'), '')}/${live.replaceFirst(RegExp(r'^/+'), '')}';
      if (_isPlayableUrl(combined)) return douyuApplyExpirePatch(combined);
    }

    for (final candidateRaw in [
      _asString(data['player_1']),
      _asString(data['stream_url']),
      _asString(data['url']),
    ]) {
      final candidate = _htmlUnescape(candidateRaw).trim();
      if (_isPlayableUrl(candidate)) return douyuApplyExpirePatch(candidate);
    }

    final flv = _htmlUnescape(_asString(data['flv_url'])).trim();
    if (_isDirectMediaUrl(flv)) return douyuApplyExpirePatch(flv);
    return '';
  }

  bool _isPlayableUrl(String value) {
    if (value.isEmpty) return false;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return false;
    return uri.scheme == 'http' || uri.scheme == 'https' || uri.scheme == 'rtmp';
  }

  bool _isDirectMediaUrl(String value) {
    if (!_isPlayableUrl(value)) return false;
    final path = Uri.tryParse(value)?.path.toLowerCase() ?? '';
    return path.endsWith('.flv') ||
        path.endsWith('.m3u8') ||
        path.endsWith('.mp4');
  }

  /* ------------------------------ 工具 ------------------------------ */

  /// 只做最常见的 HTML 实体反转义（斗鱼部分字段会带 &amp; / &quot;）。
  String _htmlUnescape(String raw) => raw
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  /// 头像补全：目录接口给的是 `avatar_v3/202004/<hash>`（无扩展名），
  /// 正确文件名要在末尾补 `_big.jpg`，否则 404。
  String _douyuAvatarUrl(String raw) {
    final full = _fullUrl('https://apic.douyucdn.cn/upload/', raw);
    if (full.isEmpty) return full;

    final uri = Uri.tryParse(full);
    if (uri == null || !uri.host.toLowerCase().contains('douyucdn.cn')) return full;
    if (!uri.path.contains('/upload/')) return full;

    final name = uri.path.split('/').last;
    if (name.isEmpty || name.contains('.')) return full;

    return uri.replace(path: '${uri.path}_big.jpg').toString();
  }

  /// 给相对路径补 CDN 前缀；已是完整 URL 的原样返回。
  String _fullUrl(String prefix, String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) return trimmed;
    if (trimmed.startsWith('//')) return 'https:$trimmed';
    return '$prefix${trimmed.replaceFirst(RegExp(r'^/+'), '')}';
  }

  String _nestedString(Map<String, dynamic> obj, List<String> path) {
    dynamic current = obj;
    for (var i = 0; i < path.length; i++) {
      if (current is! Map) return '';
      final next = current[path[i]];
      if (i == path.length - 1) return _asString(next);
      current = next;
    }
    return '';
  }

  String _firstNonEmpty(List<String> values) {
    for (final value in values) {
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  /* -------------------------------------------------- 分区 / 直播列表 */

  List<CategoryGroup> _categoryCache = const [];
  DateTime _categoryAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 斗鱼移动端 UA（分区接口走 m.douyu.com）。
  static const String _mobileUA =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 '
      'Mobile/15E148 Safari/604.1';

  /// 分区树：接口给的是**扁平**的 cate1Info + cate2Info，按 cate1Id 关联。
  @override
  Future<List<CategoryGroup>> fetchCategories() async {
    if (_categoryCache.isNotEmpty &&
        DateTime.now().difference(_categoryAt) < const Duration(minutes: 30)) {
      return _categoryCache;
    }

    final json = await _http.getJson(
      _urlCateList,
      headers: {'User-Agent': _mobileUA, 'Referer': 'https://m.douyu.com/'},
    );
    final map = _asMap(json);
    if (_asInt(map['code']) != 0) {
      throw DouyuException('斗鱼分区接口返回 code=${_asInt(map['code'])}');
    }
    final data = _asMap(map['data']);
    final cate1List = _asList(data['cate1Info']).map(_asMap).toList();
    final cate2List = _asList(data['cate2Info']).map(_asMap).toList();

    final groups = <CategoryGroup>[];
    for (final c1 in cate1List) {
      final parentId = _asString(c1['cate1Id']);
      if (parentId.isEmpty) continue;

      final children = <Category>[];
      final seen = <String>{};
      var hasTogetherWatch = false;

      for (final c2 in cate2List) {
        if (_asString(c2['cate1Id']) != parentId) continue;
        final childId = _asString(c2['cate2Id']);
        if (childId.isEmpty || !seen.add(childId)) continue;
        final name = _asString(c2['cate2Name']);
        if (name == '一起看') {
          // 同名的「一起看」只保留一个（上游可能给不同 id）
          if (hasTogetherWatch) continue;
          hasTogetherWatch = true;
        }
        children.add(Category(id: childId, name: name));
      }

      // 旧接口不下发「一起看」，网页端有这个入口；缺失时补一次
      if (parentId == '2' && !hasTogetherWatch) {
        children.add(const Category(id: '208', name: '一起看'));
      }
      if (children.isEmpty) continue;

      groups.add(CategoryGroup(
        id: parentId,
        name: _asString(c1['cate1Name']),
        categories: children,
      ));
    }

    if (groups.isEmpty) throw const DouyuException('斗鱼分区表为空');
    _categoryCache = groups;
    _categoryAt = DateTime.now();
    return groups;
  }

  /// 按二级分区拉直播列表；categoryId 为空时用「英雄联盟」(1) 兜底。
  @override
  Future<StreamerPage> fetchLiveList({
    String? categoryId,
    int page = 1,
    int limit = 30,
  }) async {
    final cate2 = (categoryId ?? '').isEmpty ? '1' : categoryId!;
    final safePage = page < 1 ? 1 : page;
    final safeLimit = limit <= 0 ? 30 : limit;

    final target = 'https://www.douyu.com/gapi/rkc/directory/2_$cate2/'
        '$safePage?limit=$safeLimit';

    final json = await _http.getJson(
      target,
      headers: {
        'User-Agent': _desktopUA,
        'Referer': 'https://www.douyu.com/',
      },
    );
    final map = _asMap(json);
    if (_asInt(map['code']) != 0) {
      throw DouyuException(
        '斗鱼列表接口返回 code=${_asInt(map['code'])} msg=${_asString(map['msg'])}',
      );
    }

    final data = _asMap(map['data']);
    final totalPages = _asInt(data['pgcnt']);
    final items = <Streamer>[];
    for (final raw in _asList(data['rl'])) {
      final item = _asMap(raw);
      final roomId = _asString(item['rid']);
      if (roomId.isEmpty) continue;

      var cover = _fullUrl(_coverPrefix, _asString(item['rs16']));
      if (cover.isEmpty) {
        cover = _fullUrl(_coverPrefix, _asString(item['rs1']));
      }
      var nickname = _asString(item['nn']);
      if (nickname.isEmpty) nickname = '房间 $roomId';

      // 三级分区响应带 type：1=直播中，0=录播/离线
      var isLive = true;
      if (item['type'] != null) isLive = _asInt(item['type']) == 1;

      items.add(Streamer(
        platform: platform,
        id: roomId,
        nickname: nickname,
        title: _asString(item['rn']),
        cover: cover,
        avatar: _douyuAvatarUrl(_asString(item['av'])),
        viewers: _asInt(item['ol']),
        categoryName: _asString(item['c2name']),
        isLive: isLive,
      ));
    }

    // 接口忽略 limit、最多返回 120 条，这里按请求页大小截断，让「一页」可预期
    final sliced = items.length > safeLimit ? items.sublist(0, safeLimit) : items;

    return StreamerPage(
      items: sliced,
      page: safePage,
      hasMore: totalPages > safePage,
      totalPages: totalPages,
    );
  }
}

/* ------------------------------ 签名纯函数 ------------------------------ */

/// 计算签名用的 secret：从 rand_str 开始，做 enc_time 次 `md5(secret + key)`。
///
/// 与 Go 版 sign / pure_live 完全一致。抽成纯函数是为了可单测
/// （网络与时间都不可控，但这一步必须是确定的）。
String douyuSignSecret({
  required String randStr,
  required String key,
  required int encTime,
}) {
  var secret = randStr;
  for (var i = 0; i < encTime; i++) {
    secret = douyuMd5Hex('$secret$key');
  }
  return secret;
}

/// 计算 auth 字段：`md5(secret + key + suffix)`。
///
/// suffix 在 is_special==1 时为空串，否则是 `roomID + 秒级时间戳`。
String douyuSignAuth({
  required String secret,
  required String key,
  required String suffix,
}) =>
    douyuMd5Hex('$secret$key$suffix');

/// 小写 32 位 MD5。
String douyuMd5Hex(String input) => md5.convert(utf8.encode(input)).toString();

/// ws CDN 的直链只有 300 秒，补 expire=0 让 CDN 按默认时长签发。
String douyuApplyExpirePatch(String url) {
  if (url.contains('expire=300') && url.contains('fcdn=ws')) {
    return '$url&expire=0';
  }
  return url;
}

/// 根据地址后缀判断格式：m3u8 走 HLS，其余按 FLV 处理。
String douyuFormatOf(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  return path.endsWith('.m3u8') ? 'hls' : 'flv';
}

/* ------------------------------ 内部类型 ------------------------------ */

class _EncryptionData {
  const _EncryptionData({
    required this.did,
    required this.key,
    required this.randStr,
    required this.encTime,
    required this.encData,
    required this.isSpecial,
    required this.expireAt,
  });

  final String did;
  final String key;
  final String randStr;
  final int encTime;
  final String encData;
  final int isSpecial;

  /// 秒级时间戳；缺失时为 0（此时不会被当作有效缓存）。
  final int expireAt;
}

class _SignedForm {
  const _SignedForm(this.form);
  final Map<String, String> form;
}

class _PlayResponse {
  const _PlayResponse(this.data);
  final Map<String, dynamic> data;
}

class _RateVariant {
  const _RateVariant({required this.name, required this.rate, required this.bit});
  final String name;
  final int rate;
  final int bit;
}

class DouyuException implements Exception {
  const DouyuException(this.message);
  final String message;

  @override
  String toString() => message;
}

/* ------------------------------ JSON 容错 ------------------------------ */

Map<String, dynamic> _asMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

List<dynamic> _asList(Object? value) => value is List ? value : const [];

String _asString(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is double) {
    // 避免 7734200.0 这种形式
    return value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
  }
  return value.toString();
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 0;
    final parsed = int.tryParse(trimmed);
    if (parsed != null) return parsed;
    // "101.8万" / "2.3亿" 这类人气文案
    return _parseChineseCount(trimmed);
  }
  return 0;
}

int _parseChineseCount(String raw) {
  var text = raw.trim();
  var multiplier = 1;
  if (text.contains('亿')) {
    multiplier = 100000000;
    text = text.replaceAll('亿', '');
  } else if (text.contains('万')) {
    multiplier = 10000;
    text = text.replaceAll('万', '');
  }
  final value = double.tryParse(text.trim());
  if (value == null) return 0;
  return (value * multiplier).round();
}
