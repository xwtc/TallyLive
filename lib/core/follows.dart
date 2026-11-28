import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tallylive/core/models.dart';

/// 一条关注（侧栏条目）。
///
/// 字段对齐 DTV 的 follow 结构：平台 + 房间号是唯一键，
/// 昵称/标题/头像缓存下来，侧栏不依赖网络也能渲染。
class FollowRoom {
  const FollowRoom({
    required this.platform,
    required this.roomId,
    required this.nickname,
    this.title = '',
    this.avatar = '',
    this.isLive = false,
    this.viewers = 0,
  });

  final LivePlatform platform;
  final String roomId;
  final String nickname;
  final String title;
  final String avatar;

  /// 最近一次已知的直播状态（仅本地缓存，进入列表时刷新）。
  final bool isLive;
  final int viewers;

  String get key => '${platform.name}:$roomId';

  FollowRoom copyWith({
    String? nickname,
    String? title,
    String? avatar,
    bool? isLive,
    int? viewers,
  }) =>
      FollowRoom(
        platform: platform,
        roomId: roomId,
        nickname: nickname ?? this.nickname,
        title: title ?? this.title,
        avatar: avatar ?? this.avatar,
        isLive: isLive ?? this.isLive,
        viewers: viewers ?? this.viewers,
      );

  /// 序列化格式：`platform|roomId|nickname|title|avatar|isLive|viewers`
  ///
  /// 用单行竖线分隔而不是 JSON，是为了 shared_preferences 的 StringList
  /// 里保持可读、可手工修复（DTV 的 config 也是这种思路）。
  String encode() => [
        platform.name,
        roomId,
        nickname,
        title,
        avatar,
        isLive ? '1' : '0',
        '$viewers',
      ].map((part) => part.replaceAll('|', ' ')).join('|');

  static FollowRoom? decode(String raw) {
    final parts = raw.split('|');
    if (parts.length < 3) return null;
    final platform = LivePlatform.tryParse(parts[0]);
    final roomId = parts[1];
    if (platform == null || roomId.isEmpty) return null;
    return FollowRoom(
      platform: platform,
      roomId: roomId,
      nickname: parts[2],
      title: parts.length > 3 ? parts[3] : '',
      avatar: parts.length > 4 ? parts[4] : '',
      isLive: parts.length > 5 && parts[5] == '1',
      viewers: parts.length > 6 ? (int.tryParse(parts[6]) ?? 0) : 0,
    );
  }
}

/// 关注列表（本地持久化）。
///
/// 与 [AppSettings] 分开：关注是"内容数据"，设置是"偏好"，
/// 将来做局域网同步时只需要同步这一份（DTV 也是分开的）。
class FollowStore extends ChangeNotifier {
  FollowStore._();

  static final FollowStore instance = FollowStore._();

  static const String _key = 'followed_rooms';

  List<FollowRoom> _rooms = const [];
  bool _loaded = false;

  List<FollowRoom> get rooms => _rooms;
  bool get isEmpty => _rooms.isEmpty;
  bool get loaded => _loaded;

  /// 在播的排前面，其余保持用户排序。
  List<FollowRoom> get sortedRooms {
    final live = _rooms.where((room) => room.isLive).toList();
    final offline = _rooms.where((room) => !room.isLive).toList();
    return [...live, ...offline];
  }

  bool isFollowing(LivePlatform platform, String roomId) {
    final key = '${platform.name}:$roomId';
    return _rooms.any((room) => room.key == key);
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const [];
    _rooms = raw
        .map(FollowRoom.decode)
        .whereType<FollowRoom>()
        .toList(growable: true);
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, _rooms.map((room) => room.encode()).toList());
  }

  /// 关注/取关。返回操作后是否处于关注状态。
  Future<bool> toggle({
    required LivePlatform platform,
    required String roomId,
    String nickname = '',
    String title = '',
    String avatar = '',
    bool isLive = true,
    int viewers = 0,
  }) async {
    final existing = _rooms.indexWhere(
      (room) => room.platform == platform && room.roomId == roomId,
    );
    if (existing >= 0) {
      _rooms = [..._rooms]..removeAt(existing);
      await _persist();
      notifyListeners();
      return false;
    }
    _rooms = [
      ..._rooms,
      FollowRoom(
        platform: platform,
        roomId: roomId,
        nickname: nickname,
        title: title,
        avatar: avatar,
        isLive: isLive,
        viewers: viewers,
      ),
    ];
    await _persist();
    notifyListeners();
    return true;
  }

  Future<void> remove(FollowRoom room) async {
    _rooms = _rooms.where((item) => item.key != room.key).toList();
    await _persist();
    notifyListeners();
  }

  /// 拖拽排序后写回。
  Future<void> reorder(int oldIndex, int newIndex) async {
    final list = [..._rooms];
    if (oldIndex < 0 || oldIndex >= list.length) return;
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    if (target < 0 || target >= list.length) return;
    final item = list.removeAt(oldIndex);
    list.insert(target, item);
    _rooms = list;
    await _persist();
    notifyListeners();
  }

  /// 更新某个关注房间的实时状态（换台/刷新时调用）。
  Future<void> updateStatus(
    LivePlatform platform,
    String roomId, {
    bool? isLive,
    int? viewers,
    String? title,
  }) async {
    final index = _rooms.indexWhere(
      (room) => room.platform == platform && room.roomId == roomId,
    );
    if (index < 0) return;
    final room = _rooms[index];
    if (room.isLive == (isLive ?? room.isLive) &&
        room.viewers == (viewers ?? room.viewers) &&
        room.title == (title ?? room.title)) {
      return;
    }
    final list = [..._rooms];
    list[index] = room.copyWith(
      isLive: isLive,
      viewers: viewers,
      title: title,
    );
    _rooms = list;
    await _persist();
    notifyListeners();
  }
}
