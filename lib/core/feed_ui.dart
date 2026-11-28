import 'package:flutter/foundation.dart';
import 'package:tallylive/core/live_repository.dart';
import 'package:tallylive/core/models.dart';

/// 列表页的全局 UI 状态（平台选择）。
///
/// 为什么单独抽出来：DTV 的顶栏 `PlatformTabs` 和内容区是**同一个状态源**
/// （顶栏切换平台 → 内容区换数据）。我们也必须这样，
/// 否则顶栏一套高亮、内容区另一套数据，用户会看到"tab 在 A、列表是 B"。
///
/// 只放"纯 UI 选择"，不放数据加载（数据仍由各页面自己管）。
class FeedUi extends ChangeNotifier {
  FeedUi._();

  static final FeedUi instance = FeedUi._();

  List<LivePlatform> _platforms = const [];
  LivePlatform? _platform;

  /// 可选平台（由仓库实现决定；虎牙/抖音列表未接入时不在其中）。
  List<LivePlatform> get platforms => _platforms;
  LivePlatform? get platform => _platform;

  /// 首次进入时初始化可选平台。重复调用不会重置用户选择。
  void ensurePlatforms(List<LivePlatform> platforms) {
    if (_platforms.length == platforms.length &&
        _platforms.every(platforms.contains)) {
      return;
    }
    _platforms = List<LivePlatform>.unmodifiable(platforms);
    _platform ??= _platforms.isNotEmpty ? _platforms.first : null;
    if (_platform != null && !_platforms.contains(_platform)) {
      _platform = _platforms.isNotEmpty ? _platforms.first : null;
    }
    notifyListeners();
  }

  void select(LivePlatform platform) {
    if (_platform == platform) return;
    _platform = platform;
    notifyListeners();
  }
}

/// 全局仓库实例（页面与壳层共用一个，避免重复建 Client / 丢缓存）。
final LiveRepository sharedRepository = createLiveRepository();
