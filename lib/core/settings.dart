import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tallylive/core/models.dart';

/// 一个最近打开的直播间。
class RecentRoom {
  const RecentRoom({required this.platform, required this.roomId, required this.at});

  final LivePlatform platform;
  final String roomId;

  /// 最近一次打开的时间戳（毫秒），用于排序。
  final int at;

  String get key => '${platform.name}:$roomId';

  Map<String, String> toMap() => {
        'platform': platform.name,
        'roomId': roomId,
        'at': at.toString(),
      };

  static RecentRoom? fromMap(Map<String, String> map) {
    final platform = LivePlatform.tryParse(map['platform'] ?? '');
    final roomId = map['roomId'] ?? '';
    if (platform == null || roomId.isEmpty) return null;
    return RecentRoom(
      platform: platform,
      roomId: roomId,
      at: int.tryParse(map['at'] ?? '') ?? 0,
    );
  }
}

/// 应用设置与本地状态。
///
/// 用 `ChangeNotifier` + `ListenableBuilder`，不额外引入状态管理库。
/// 所有字段写盘前先调 [save]，读用 [load]（在 main 里 await 一次）。
class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  static const String _kDanmakuEnabled = 'danmaku_enabled';
  static const String _kDanmakuFontSize = 'danmaku_font_size';
  static const String _kDanmakuOpacity = 'danmaku_opacity';
  static const String _kDanmakuDuration = 'danmaku_duration';
  static const String _kDanmakuArea = 'danmaku_area';
  static const String _kDanmakuBlocked = 'danmaku_blocked';
  static const String _kRecentRooms = 'recent_rooms';
  static const int _maxRecentRooms = 20;

  bool _danmakuEnabled = true;
  double _danmakuFontSize = 20;
  double _danmakuOpacity = 1;
  double _danmakuDuration = 10;
  double _danmakuArea = 0.5;

  /// 屏蔽词（逗号/换行分隔）。命中的弹幕不渲染。
  String _danmakuBlocked = '';
  List<RecentRoom> _recentRooms = const [];

  bool get danmakuEnabled => _danmakuEnabled;

  String get danmakuBlocked => _danmakuBlocked;

  /// 拆分后的屏蔽词列表（去空、去重）。
  List<String> get danmakuBlockedList => _danmakuBlocked
      .split(RegExp(r'[,，\n]'))
      .map((word) => word.trim())
      .where((word) => word.isNotEmpty)
      .toSet()
      .toList();
  double get danmakuFontSize => _danmakuFontSize;
  double get danmakuOpacity => _danmakuOpacity;
  double get danmakuDuration => _danmakuDuration;
  double get danmakuArea => _danmakuArea;
  List<RecentRoom> get recentRooms => List.unmodifiable(_recentRooms);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _danmakuEnabled = prefs.getBool(_kDanmakuEnabled) ?? true;
    _danmakuFontSize = prefs.getDouble(_kDanmakuFontSize) ?? 18;
    _danmakuOpacity = prefs.getDouble(_kDanmakuOpacity) ?? 0.95;
    _danmakuDuration = prefs.getDouble(_kDanmakuDuration) ?? 8;
    _danmakuArea = prefs.getDouble(_kDanmakuArea) ?? 0.5;
    _danmakuBlocked = prefs.getString(_kDanmakuBlocked) ?? '';

    final raw = prefs.getStringList(_kRecentRooms) ?? const [];
    final rooms = <RecentRoom>[];
    for (final item in raw) {
      // 存成 "platform|roomId|at"，比 JSON 少一层依赖
      final parts = item.split('|');
      if (parts.length != 3) continue;
      final room = RecentRoom.fromMap({
        'platform': parts[0],
        'roomId': parts[1],
        'at': parts[2],
      });
      if (room != null) rooms.add(room);
    }
    rooms.sort((a, b) => b.at.compareTo(a.at));
    _recentRooms = rooms;
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDanmakuEnabled, _danmakuEnabled);
    await prefs.setDouble(_kDanmakuFontSize, _danmakuFontSize);
    await prefs.setDouble(_kDanmakuOpacity, _danmakuOpacity);
    await prefs.setDouble(_kDanmakuDuration, _danmakuDuration);
    await prefs.setDouble(_kDanmakuArea, _danmakuArea);
    await prefs.setString(_kDanmakuBlocked, _danmakuBlocked);
    await prefs.setStringList(
      _kRecentRooms,
      _recentRooms.map((r) => '${r.platform.name}|${r.roomId}|${r.at}').toList(),
    );
  }

  Future<void> setDanmakuEnabled(bool value) async {
    _danmakuEnabled = value;
    notifyListeners();
    await _save();
  }

  Future<void> setDanmakuFontSize(double value) async {
    _danmakuFontSize = value.clamp(14, 30).toDouble();
    notifyListeners();
    await _save();
  }

  Future<void> setDanmakuOpacity(double value) async {
    _danmakuOpacity = value.clamp(0.2, 1.0).toDouble();
    notifyListeners();
    await _save();
  }

  Future<void> setDanmakuDuration(double value) async {
    _danmakuDuration = value.clamp(5, 20).toDouble();
    notifyListeners();
    await _save();
  }

  Future<void> setDanmakuArea(double value) async {
    _danmakuArea = value.clamp(0.10, 1.0).toDouble();
    notifyListeners();
    await _save();
  }
  /// 设置屏蔽词（逗号/换行分隔）。
  Future<void> setDanmakuBlocked(String value) async {
    _danmakuBlocked = value;
    notifyListeners();
    await _save();
  }

  /// 记录一次打开，去重后置顶。
  Future<void> addRecentRoom(LivePlatform platform, String roomId) async {
    final trimmed = roomId.trim();
    if (trimmed.isEmpty) return;
    final entry = RecentRoom(
      platform: platform,
      roomId: trimmed,
      at: DateTime.now().millisecondsSinceEpoch,
    );
    final list = _recentRooms.where((r) => r.key != entry.key).toList()
      ..insert(0, entry);
    _recentRooms = list.take(_maxRecentRooms).toList();
    notifyListeners();
    await _save();
  }

  Future<void> removeRecentRoom(String key) async {
    _recentRooms = _recentRooms.where((r) => r.key != key).toList();
    notifyListeners();
    await _save();
  }

  Future<void> clearRecentRooms() async {
    _recentRooms = const [];
    notifyListeners();
    await _save();
  }
}
