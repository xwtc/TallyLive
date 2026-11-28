import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tallylive/core/follows.dart';
import 'package:tallylive/core/models.dart';

/// 局域网同步 —— **与 DTV 完全兼容**（可直接与 DTV 客户端互传）。
///
/// 协议常量直接取自 DTV `internal/services/lan_sync_service.go`：
/// ```
/// lanSyncKind        = "dtv-lan-sync"
/// lanSyncVersion     = 1
/// lanSyncPort        = 38999          ← HTTP 端口
/// lanSyncHTTPPath    = "/dtv-sync"          返回 manifest
/// lanSyncPayloadPath = "/dtv-sync/payload"  返回完整 payload
/// lanSyncDefaultToken = "dtv"         ← 固定令牌（老 Tauri 版一致）
/// ```
///
/// 数据格式（字段名必须一致，否则 DTV 读不了）：
/// ```json
/// {
///   "kind": "dtv-lan-sync",
///   "version": 1,
///   "exportedAt": "2026-11-28T23:00:00Z",
///   "source": {"client": "tallylive", "appVersion": "0.1.0"},
///   "entries": { "…key…": "…value…" }
/// }
/// ```
/// `entries` 是 `map<string,string>`：DTV 用它装 follows / followFolders /
/// followOrder / subscriptions / danmuKeywords。我们目前只写 follows 与
/// followFolders 两组，读取时忽略不认识的键（向前兼容）。
class LanSync {
  LanSync._();

  static const String kind = 'dtv-lan-sync';
  static const int version = 1;
  static const int port = 38999;
  static const String httpPath = '/dtv-sync';
  static const String payloadPath = '/dtv-sync/payload';
  static const String defaultToken = 'dtv';

  /// entries 的键名**必须与 DTV 的 localStorage 键完全一致**
  /// （见 DTV `frontend/src/lib/storage.ts` 的 STORAGE_KEYS），
  /// 否则 DTV 侧读不到我们的数据。
  static const String _followsKey = 'followedStreamers';
  static const String _foldersKey = 'followFolders';
  static const String _orderKey = 'followListOrder';

  /* ------------------------------------------------------------------ 导出 */

  /// 构造 payload（**entries 的键与值结构与 DTV 完全一致**）。
  ///
  /// DTV 侧的记录结构（`store.ts` / `FollowRecord`）：
  /// ```ts
  /// interface FollowRecord {
  ///   id: string; platform: LivePlatform; nickname: string; title: string;
  ///   avatar: string; viewers: number; isLive: boolean; followedAt: number;
  /// }
  /// interface FolderRecord { id: string; name: string; collapsed: boolean; keys: string[] }
  /// ```
  /// `keys` 里放的是 `platform:roomId` 形式的房间键。
  static Map<String, dynamic> buildPayload() {
    final store = FollowStore.instance;

    final follows = [
      for (final room in store.rooms)
        {
          'id': room.roomId,
          'platform': room.platform.name,
          'nickname': room.nickname,
          'title': room.title,
          'avatar': room.avatar,
          'viewers': room.viewers,
          'isLive': room.isLive,
          'followedAt': 0,
        },
    ];

    final folders = [
      for (final group in store.groups)
        {
          'id': group.id,
          'name': group.name,
          'collapsed': false,
          'keys': [
            for (final room in store.rooms)
              if (room.groupId == group.id) room.key,
          ],
        },
    ];

    return {
      'kind': kind,
      'version': version,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'source': {
        'client': 'tallylive',
        'appVersion': '0.1.0',
      },
      'entries': {
        _followsKey: jsonEncode(follows),
        _foldersKey: jsonEncode(folders),
        _orderKey: jsonEncode([for (final room in store.rooms) room.key]),
      },
    };
  }

  /// 构造 manifest（**与 DTV 的 LanSyncManifest 同结构**：只有摘要，不带 entries）。
  static Map<String, dynamic> buildManifest() {
    final store = FollowStore.instance;
    final payload = buildPayload();
    final totalBytes = utf8.encode(jsonEncode(payload)).length;
    return {
      'kind': kind,
      'version': version,
      'exportedAt': payload['exportedAt'],
      'source': payload['source'],
      'summary': {
        'follows': store.rooms.length,
        'followFolders': store.groups.length,
        'followOrder': store.rooms.length,
        'subscriptions': 0,
        'danmuKeywords': 0,
        'totalBytes': totalBytes,
      },
    };
  }

  /* ------------------------------------------------------------------ 导入 */

  /// 从对端 payload 导入（**兼容 DTV 的 entries 结构**）。
  ///
  /// 优先按 DTV 的 `entries`（键名 + 对象数组）解析；
  /// 如果对端给的是 `{entries: {k: v}}` 之外的形状，也尽量兜住。
  static Future<int> importPayload(Map<String, dynamic> payload) async {
    final raw = payload['entries'];
    final entries = raw is Map ? Map<String, dynamic>.from(raw) : payload;

    final rooms = <FollowRoom>[];
    final groups = <FollowGroup>[];
    // 房间键 → 分组 id（由 folders[].keys 反推）
    final groupOfRoom = <String, String>{};

    // 1) 分组：{id, name, collapsed, keys}
    for (final item in _decodeObjects(entries[_foldersKey])) {
      final id = _str(item['id']);
      final name = _str(item['name']);
      if (id.isEmpty) continue;
      groups.add(FollowGroup(id: id, name: name.isEmpty ? '未命名分组' : name));
      for (final key in (item['keys'] as List? ?? const [])) {
        groupOfRoom[_str(key)] = id;
      }
    }

    // 2) 关注记录：{id, platform, nickname, title, avatar, viewers, isLive}
    for (final item in _decodeObjects(entries[_followsKey])) {
      final roomId = _str(item['id']);
      final platformName = _str(item['platform']);
      if (roomId.isEmpty) continue;
      final platform = _platformFromName(platformName);
      if (platform == null) continue;
      final room = FollowRoom(
        platform: platform,
        roomId: roomId,
        nickname: _str(item['nickname']),
        title: _str(item['title']),
        avatar: _str(item['avatar']),
        isLive: item['isLive'] == true,
        viewers: item['viewers'] is num
            ? (item['viewers'] as num).toInt()
            : 0,
        groupId: groupOfRoom['${platform.name}:$roomId'] ?? '',
      );
      rooms.add(room);
    }

    if (rooms.isEmpty && groups.isEmpty) {
      throw const LanSyncException('对端没有可导入的关注数据');
    }
    await FollowStore.instance.replaceAll(rooms: rooms, groups: groups);
    return rooms.length;
  }

  static String _str(Object? raw) => raw == null ? '' : raw.toString();

  /// 平台名 → 枚举（与 DTV 的 LIVE_PLATFORMS 字符串一致）。
  static LivePlatform? _platformFromName(String name) {
    for (final platform in LivePlatform.values) {
      if (platform.name == name) return platform;
    }
    return null;
  }

  /// 把 entries 里的值解析成对象列表。
  ///
  /// entries 的值是 **JSON 字符串**（DTV 的 localStorage 原样搬运），
  /// 但也可能已经是数组（某些实现对 payload 做过解析）。
  static List<Map<String, dynamic>> _decodeObjects(Object? raw) {
    if (raw == null) return const [];
    Object? parsed = raw;
    if (raw is String) {
      final text = raw.trim();
      if (text.isEmpty) return const [];
      try {
        parsed = jsonDecode(text);
      } catch (_) {
        return const [];
      }
    }
    if (parsed is! List) return const [];
    return [
      for (final item in parsed)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  /* ------------------------------------------------------------------ 发现 */

  /// 扫描局域网内的 DTV / TallyLive 同步服务。
  ///
  /// 用 HTTP 探测而不是 UDP 广播：Flutter 三端对 UDP 广播的支持不一致
  /// （iOS 需要额外权限），而 HTTP 探测在已知网段上更可控。
  /// 默认扫 `/24` 网段，端口 38999。DTV 的 UDP beacon 在 38998，
  /// 我们只用它做可选增强，不依赖。
  static Future<List<LanSyncPeer>> discover({
    Duration timeout = const Duration(milliseconds: 600),
    void Function(int done, int total)? onProgress,
  }) async {
    final localIps = await _localIPv4Addresses();
    if (localIps.isEmpty) return const [];

    final peers = <LanSyncPeer>[];
    for (final local in localIps) {
      final parts = local.split('.');
      if (parts.length != 4) continue;
      final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
      final targets = <String>[];
      for (var i = 1; i < 255; i++) {
        final host = '$prefix.$i';
        if (host == local) continue;
        targets.add(host);
      }

      var done = 0;
      // 并发探测：一次 32 个，避免打爆本机 socket
      const batch = 32;
      for (var start = 0; start < targets.length; start += batch) {
        final slice = targets.skip(start).take(batch);
        final results = await Future.wait(slice.map((host) async {
          final peer = await _probe(host, timeout);
          return peer;
        }));
        for (final peer in results) {
          if (peer != null) peers.add(peer);
        }
        done += batch;
        onProgress?.call(done > targets.length ? targets.length : done,
            targets.length);
        if (peers.isNotEmpty) break; // 找到就停，避免无谓扫描
      }
      if (peers.isNotEmpty) break;
    }
    return peers;
  }

  static Future<LanSyncPeer?> _probe(String host, Duration timeout) async {
    final client = HttpClient()
      ..connectionTimeout = timeout;
    try {
      final uri = Uri.parse('http://$host:$port$httpPath?token=$defaultToken');
      final request = await client.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      final map = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
      if (map['kind'] != kind) return null;
      final source = map['source'] is Map
          ? Map<String, dynamic>.from(map['source'] as Map)
          : <String, dynamic>{};
      final summary = map['summary'] is Map
          ? Map<String, dynamic>.from(map['summary'] as Map)
          : <String, dynamic>{};
      return LanSyncPeer(
        host: host,
        port: port,
        name: (source['client'] ?? 'DTV').toString(),
        follows: (summary['follows'] is num)
            ? (summary['follows'] as num).toInt()
            : 0,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 从对端拉取并导入。
  static Future<int> pull(LanSyncPeer peer) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final uri = Uri.parse(
          'http://${peer.host}:${peer.port}$payloadPath?token=$defaultToken');
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw LanSyncException('对端返回 HTTP ${response.statusCode}');
      }
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      final map = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
      // 必须 await：在 try/finally 里直接返回裸 Future 会让 finally 先跑（关连接），
      // 也会触发 unawaited_return_in_try_block。
      return await importPayload(map);
    } finally {
      client.close(force: true);
    }
  }

  /// 本机所有 IPv4 地址。
  static Future<List<String>> _localIPv4Addresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      return [
        for (final interface in interfaces)
          for (final address in interface.addresses) address.address,
      ];
    } catch (_) {
      return const [];
    }
  }

  /* ------------------------------------------------------------------ 本机服务 */

  static HttpServer? _server;

  /// 启动本机同步服务（让其它设备能从本机拉取）。
  ///
  /// 返回本机可被访问的地址列表；无可用网卡时返回空。
  static Future<List<String>> startServer() async {
    if (_server != null) {
      final ips = await _localIPv4Addresses();
      return [for (final ip in ips) 'http://$ip:$port$httpPath'];
    }
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _server!.listen((request) async {
        final token = request.uri.queryParameters['token'] ?? '';
        if (token != defaultToken) {
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
          return;
        }
        final path = request.uri.path;
        final payload = path == payloadPath ? buildPayload() : buildManifest();
        request.response.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        request.response.write(jsonEncode(payload));
        await request.response.close();
      });
      final ips = await _localIPv4Addresses();
      return [for (final ip in ips) 'http://$ip:$port$httpPath'];
    } catch (error) {
      throw LanSyncException('启动同步服务失败：$error');
    }
  }

  static Future<void> stopServer() async {
    await _server?.close(force: true);
    _server = null;
  }

  static bool get serverRunning => _server != null;
}

/// 局域网内发现的对端。
class LanSyncPeer {
  const LanSyncPeer({
    required this.host,
    required this.port,
    required this.name,
    required this.follows,
  });

  final String host;
  final int port;
  final String name;
  final int follows;
}

class LanSyncException implements Exception {
  const LanSyncException(this.message);
  final String message;

  @override
  String toString() => message;
}
