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
  static const String _kDanmakuColorful = 'danmaku_colorful';
  static const String _kRecentRooms = 'recent_rooms';
  static const String _kDanmakuPanelWidth = 'danmaku_panel_width';
  static const String _kSidebarCollapsed = 'sidebar_collapsed';
  static const String _kQualityPrefs = 'quality_prefs';
  static const String _kLinePrefs = 'line_prefs';
  static const int _maxRecentRooms = 20;

  bool _danmakuEnabled = true;
  double _danmakuFontSize = 20;
  double _danmakuOpacity = 1;
  double _danmakuDuration = 10;
  double _danmakuArea = 0.5;

  /// 播放页右侧弹幕面板宽度（DTV 同样的默认 196、范围 168~320）。
  double _danmakuPanelWidth = 196;

  /// 侧栏是否收起。
  bool _sidebarCollapsed = false;

  /// 平台 → 上次选择的质量档 id / 线路 id。
  final Map<String, String> _qualityPrefs = {};
  final Map<String, String> _linePrefs = {};

  /// 屏蔽词（逗号/换行分隔）。命中的弹幕不渲染。
  String _danmakuBlocked = '';

  /// 彩色弹幕（关掉则统一白色，对齐 DTV 的 colorful）。
  bool _danmakuColorful = true;
  List<RecentRoom> _recentRooms = const [];

  bool get danmakuEnabled => _danmakuEnabled;

  String get danmakuBlocked => _danmakuBlocked;

  bool get danmakuColorful => _danmakuColorful;

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

  /// 弹幕面板宽度。
  double get danmakuPanelWidth => _danmakuPanelWidth;
  set danmakuPanelWidth(double value) {
    final clamped = value.clamp(168.0, 320.0);
    if (clamped == _danmakuPanelWidth) return;
    _danmakuPanelWidth = clamped;
    notifyListeners();
    _save();
  }

  /// 侧栏收起状态。
  bool get sidebarCollapsed => _sidebarCollapsed;
  set sidebarCollapsed(bool value) {
    if (value == _sidebarCollapsed) return;
    _sidebarCollapsed = value;
    notifyListeners();
    _save();
  }

  /// 上次用的清晰度档 id（找不到就由调用方回退首档）。
  String? qualityOf(LivePlatform platform) => _qualityPrefs[platform.name];

  Future<void> setQuality(LivePlatform platform, String variantId) async {
    if (variantId.isEmpty) return;
    _qualityPrefs[platform.name] = variantId;
    notifyListeners();
    await _save();
  }

  /// 上次用的线路 id。
  String? lineOf(LivePlatform platform) => _linePrefs[platform.name];

  Future<void> setLine(LivePlatform platform, String lineId) async {
    if (lineId.isEmpty) return;
    _linePrefs[platform.name] = lineId;
    notifyListeners();
    await _save();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _danmakuEnabled = prefs.getBool(_kDanmakuEnabled) ?? true;
    _danmakuFontSize = prefs.getDouble(_kDanmakuFontSize) ?? 18;
    _danmakuOpacity = prefs.getDouble(_kDanmakuOpacity) ?? 0.95;
    _danmakuDuration = prefs.getDouble(_kDanmakuDuration) ?? 8;
    _danmakuArea = prefs.getDouble(_kDanmakuArea) ?? 0.5;
    _danmakuBlocked = prefs.getString(_kDanmakuBlocked) ?? '';
    _danmakuColorful = prefs.getBool(_kDanmakuColorful) ?? true;
    _danmakuPanelWidth = (prefs.getDouble(_kDanmakuPanelWidth) ?? 196).clamp(168.0, 320.0);
    _sidebarCollapsed = prefs.getBool(_kSidebarCollapsed) ?? false;
    _qualityPrefs
      ..clear()
      ..addAll(_decodePrefMap(prefs.getStringList(_kQualityPrefs)));
    _linePrefs
      ..clear()
      ..addAll(_decodePrefMap(prefs.getStringList(_kLinePrefs)));

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
    await prefs.setBool(_kDanmakuColorful, _danmakuColorful);
    await prefs.setDouble(_kDanmakuPanelWidth, _danmakuPanelWidth);
    await prefs.setBool(_kSidebarCollapsed, _sidebarCollapsed);
    await prefs.setStringList(_kQualityPrefs, _encodePrefMap(_qualityPrefs));
    await prefs.setStringList(_kLinePrefs, _encodePrefMap(_linePrefs));
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
  /// 彩色弹幕开关。
  Future<void> setDanmakuColorful(bool value) async {
    _danmakuColorful = value;
    notifyListeners();
    await _save();
  }

  /// 设置屏蔽词（逗号/换行分隔）。
  Future<void> setDanmakuBlocked(String value) async {
    _danmakuBlocked = value;
    notifyListeners();
    await _save();
  }

  /// 屏蔽词上限（对齐 DTV 的 `DANMU_BLOCK_MAX_KEYWORDS = 40`）。
  static const int maxBlockedKeywords = 40;

  /// 单个屏蔽词长度上限（对齐 DTV 的 `DANMU_BLOCK_MAX_LENGTH = 40`）。
  static const int maxBlockedKeywordLength = 40;

  /// 追加一个屏蔽词（去重、限长、限量）。返回是否真的加进去了。
  Future<bool> addBlockedWord(String raw) async {
    final word = raw.trim();
    if (word.isEmpty) return false;
    final clipped = word.length > maxBlockedKeywordLength
        ? word.substring(0, maxBlockedKeywordLength)
        : word;
    final list = danmakuBlockedList;
    if (list.contains(clipped)) return false;
    if (list.length >= maxBlockedKeywords) return false;
    // 用换行作为落盘分隔符（与 setDanmakuBlocked 的解析规则一致）
    await setDanmakuBlocked([...list, clipped].join('\n'));
    return true;
  }

  /// 删除一个屏蔽词。
  Future<void> removeBlockedWord(String word) async {
    final list = danmakuBlockedList.where((item) => item != word).toList();
    await setDanmakuBlocked(list.join('\n'));
  }

  /// 清空全部屏蔽词。
  Future<void> clearBlockedWords() async {
    await setDanmakuBlocked('');
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
  /// 偏好表存成 "platform|id" 列表，比 JSON 少一层依赖且好排错。
  static List<String> _encodePrefMap(Map<String, String> map) =>
      [for (final entry in map.entries) '${entry.key}|${entry.value}'];

  static Map<String, String> _decodePrefMap(List<String>? raw) {
    final out = <String, String>{};
    for (final item in raw ?? const <String>[]) {
      final parts = item.split('|');
      if (parts.length < 2 || parts[0].isEmpty || parts[1].isEmpty) continue;
      out[parts[0]] = parts[1];
    }
    return out;
  }
}