import 'package:flutter/foundation.dart';
import 'package:tallylive/core/models.dart';

/// 当前正在播放的直播间。
class PlayerTarget {
  const PlayerTarget({
    required this.platform,
    required this.roomId,
    this.title = '',
  });

  final LivePlatform platform;
  final String roomId;

  /// 列表里已有的标题，加载期间先显示，避免空白。
  final String title;

  /// 换房间时用来强制重建播放层（对齐 DTV 的 `key={platform:roomId}`）。
  ///
  /// 不加 key 的话，从 A 房间切到 B 房间会复用同一个播放器实例，
  /// 出现"旧直播间声音没断、新的只是叠上去"的问题（DTV 注释里记过这个坑）。
  String get key => '${platform.name}:$roomId';
}

/// 播放会话：壳层与播放层共享的全局状态。
///
/// 为什么需要它：**播放页不再是 `Navigator.push` 的新页面，而是壳层里的一层**。
/// 侧栏、顶栏需要知道"现在在播什么、是否全屏"，才能决定自己是否让位。
///
/// 两种全屏（对齐 DTV 的 PlayerUiProvider）：
/// - [chromeHidden]（对应 DTV `cssFullscreen`）：壳层让位、视频铺满应用窗口，
///   系统窗口不变、任务栏可见；
/// - [nativeFullscreen]（对应 DTV 的窗口全屏）：真正覆盖任务栏，
///   桌面端需要窗口管理插件（P3 阶段接入），移动端走 SystemChrome。
class PlayerSession extends ChangeNotifier {
  PlayerSession._();

  static final PlayerSession instance = PlayerSession._();

  PlayerTarget? _target;
  bool _chromeHidden = false;
  bool _nativeFullscreen = false;
  bool _danmakuPanelOpen = false;

  PlayerTarget? get target => _target;
  bool get isOpen => _target != null;
  bool get chromeHidden => _chromeHidden;
  bool get nativeFullscreen => _nativeFullscreen;

  /// 任一种全屏 —— 壳层隐藏自身（侧栏/顶栏让位）。
  bool get isFullscreen => _chromeHidden || _nativeFullscreen;
  bool get danmakuPanelOpen => _danmakuPanelOpen;

  void open(PlayerTarget target) {
    if (_target?.key == target.key) return;
    _target = target;
    // 换房间时退出全屏与侧栏状态，避免上一个房间的全屏态残留
    _chromeHidden = false;
    _nativeFullscreen = false;
    _danmakuPanelOpen = false;
    notifyListeners();
  }

  void close() {
    if (_target == null) return;
    _target = null;
    _chromeHidden = false;
    _nativeFullscreen = false;
    _danmakuPanelOpen = false;
    notifyListeners();
  }

  void setChromeHidden(bool value) {
    if (_chromeHidden == value) return;
    _chromeHidden = value;
    notifyListeners();
  }

  void setNativeFullscreen(bool value) {
    if (_nativeFullscreen == value) return;
    _nativeFullscreen = value;
    notifyListeners();
  }

  void toggleDanmakuPanel() {
    _danmakuPanelOpen = !_danmakuPanelOpen;
    notifyListeners();
  }
}
