import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tallylive/core/follows.dart';

/// WebDAV 同步（关注列表）。
///
/// 为什么选 WebDAV 而不是局域网同步：
/// - 局域网同步要求两端同时在线，还要处理服务发现与配对（DTV 的 lanSync.ts 587 行）
/// - WebDAV 可对接坚果云 / Nextcloud，**跨设备、跨网络、离线后仍可恢复**
/// - 协议极简：一个 PUT 上传、一个 GET 下载，出错面小
///
/// 文件格式（`tallylive-follows.json`）：
/// ```json
/// {
///   "version": 1,
///   "updatedAt": 1795862400000,
///   "groups": [{"id":"g1","name":"游戏"}],
///   "rooms": ["platform|roomId|nickname|title|avatar|isLive|viewers|groupId", ...]
/// }
/// ```
/// `rooms` 直接复用 `FollowRoom.encode()` 的竖线格式，避免再写一套序列化。
class WebDavSync {
  WebDavSync({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 20),
              // WebDAV 的 PUT/MKCOL 会返回 201/204/207，都算成功
              validateStatus: (status) =>
                  status != null && status >= 200 && status < 300,
            ));

  final Dio _dio;

  static const String _fileName = 'tallylive-follows.json';
  static const String _kUrl = 'sync_webdav_url';
  static const String _kUser = 'sync_webdav_user';
  static const String _kPassword = 'sync_webdav_password';
  static const String _kLastSync = 'sync_last_at';

  /// 读取已保存的配置。
  static Future<WebDavConfig?> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_kUrl) ?? '';
    if (url.isEmpty) return null;
    return WebDavConfig(
      baseUrl: url,
      username: prefs.getString(_kUser) ?? '',
      password: prefs.getString(_kPassword) ?? '',
      lastSyncAt: prefs.getInt(_kLastSync) ?? 0,
    );
  }

  /// 保存配置。
  static Future<void> saveConfig(WebDavConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUrl, config.baseUrl);
    await prefs.setString(_kUser, config.username);
    await prefs.setString(_kPassword, config.password);
  }

  static Future<void> saveLastSync(int at) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kLastSync, at);
  }

  static Future<void> clearConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUrl);
    await prefs.remove(_kUser);
    await prefs.remove(_kPassword);
    await prefs.remove(_kLastSync);
  }

  Map<String, String> _authHeaders(WebDavConfig config) {
    if (config.username.isEmpty && config.password.isEmpty) {
      return const {};
    }
    final raw = '${config.username}:${config.password}';
    return {
      'Authorization': 'Basic ${base64Encode(utf8.encode(raw))}',
    };
  }

  /// 目标文件地址（baseUrl 末尾斜杠归一化）。
  String _fileUrl(WebDavConfig config) {
    var base = config.baseUrl.trim();
    if (!base.endsWith('/')) base = '$base/';
    return '$base$_fileName';
  }

  /// 上传当前关注列表。
  Future<void> upload(WebDavConfig config) async {
    final store = FollowStore.instance;
    final payload = jsonEncode({
      'version': 1,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'groups': store.groups.map((group) => group.encode()).toList(),
      'rooms': store.rooms.map((room) => room.encode()).toList(),
    });

    await _dio.put<void>(
      _fileUrl(config),
      data: payload,
      options: Options(
        headers: {
          ..._authHeaders(config),
          'Content-Type': 'application/json; charset=utf-8',
        },
      ),
    );
  }

  /// 下载并覆盖本地关注列表。返回同步的条目数。
  Future<int> download(WebDavConfig config) async {
    final response = await _dio.get<dynamic>(
      _fileUrl(config),
      options: Options(
        headers: _authHeaders(config),
        responseType: ResponseType.plain,
      ),
    );
    final body = response.data;
    final text = body is String ? body : body?.toString() ?? '';
    if (text.trim().isEmpty) {
      throw const WebDavSyncException('远端文件为空');
    }

    Map<String, dynamic> map;
    try {
      final decoded = jsonDecode(text);
      map = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } catch (_) {
      throw const WebDavSyncException('远端文件不是合法的 JSON');
    }

    final rooms = <FollowRoom>[];
    for (final raw in (map['rooms'] as List? ?? const [])) {
      final room = FollowRoom.decode(raw.toString());
      if (room != null) rooms.add(room);
    }
    final groups = <FollowGroup>[];
    for (final raw in (map['groups'] as List? ?? const [])) {
      final group = FollowGroup.decode(raw.toString());
      if (group != null) groups.add(group);
    }

    await FollowStore.instance.replaceAll(rooms: rooms, groups: groups);
    return rooms.length;
  }

  /// 连通性测试（对 baseUrl 发 PROPFIND）。
  Future<void> test(WebDavConfig config) async {
    var base = config.baseUrl.trim();
    if (!base.endsWith('/')) base = '$base/';
    await _dio.request<void>(
      base,
      data: '<?xml version="1.0"?><propfind xmlns="DAV:"><prop><resourcetype/></prop></dav:prop></propfind>',
      options: Options(
        method: 'PROPFIND',
        headers: {
          ..._authHeaders(config),
          'Depth': '0',
          'Content-Type': 'application/xml; charset=utf-8',
        },
      ),
    );
  }
}

/// WebDAV 配置。
class WebDavConfig {
  const WebDavConfig({
    required this.baseUrl,
    this.username = '',
    this.password = '',
    this.lastSyncAt = 0,
  });

  final String baseUrl;
  final String username;
  final String password;
  final int lastSyncAt;

  WebDavConfig copyWith({
    String? baseUrl,
    String? username,
    String? password,
    int? lastSyncAt,
  }) =>
      WebDavConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        username: username ?? this.username,
        password: password ?? this.password,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      );
}

class WebDavSyncException implements Exception {
  const WebDavSyncException(this.message);
  final String message;

  @override
  String toString() => message;
}
