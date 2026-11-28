import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:tallylive/core/danmaku.dart';
import 'package:tallylive/core/danmaku_stats.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/core/player_session.dart';
import 'package:tallylive/core/settings.dart';
import 'package:tallylive/platforms/danmaku_factory.dart';
import 'package:tallylive/ui/danmaku_overlay.dart';
import 'package:tallylive/ui/theme.dart';

/// 播放页。
///
/// 布局（对齐 DTV 的播放器形态，但不做进度条——直播没有索引）：
/// ```
/// Stack
/// ├── 画面舞台：Center + AspectRatio（按视频实际宽高比 letterbox，随窗口自适应）
/// │     ├── Video（libmpv 纹理）
/// │     └── DanmakuOverlay（与画面同一矩形，天然压在画面之上）
/// ├── 顶部信息条（自动隐藏）：返回 / LIVE / 昵称·标题 / 弹幕状态
/// └── 底部控制条（自动隐藏）：播放暂停 / 音量 / 弹幕开关 / 清晰度 / 线路 / 刷新 / 全屏
/// ```
///
/// 控件自动隐藏：播放中静止 3.5 秒淡出，鼠标移动或点击画面重新出现。
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.room,
    required this.variants,
    this.lines = const [],
    this.onClose,
  });

  final RoomInfo room;
  final List<StreamVariant> variants;
  final List<StreamLine> lines;

  /// 关闭播放（壳层里等于关掉播放层；独立页面时为 null 走 Navigator）。
  final VoidCallback? onClose;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final Player _player;
  late final VideoController _controller;
  DanmakuClient? _danmaku;

  late StreamVariant _variant;
  String? _lineId;
  String? _error;

  /// 弹幕连接状态：null=该平台未接入弹幕，true/false=已连接/重连中。
  bool? _danmakuOnline;
  StreamSubscription<bool>? _danmakuStatusSub;

  /// 是否展开弹幕调试面板（右键标题栏切换，仅诊断构建）。
  bool _showStats = false;

  /* ---------------------------------------------------------- 控件显隐/播放态 */

  bool _controlsVisible = true;
  Timer? _hideTimer;

  bool _playing = false;
  double _volume = 100;
  bool _muted = false;
  double _volumeBeforeMute = 100;

  bool _immersive = false;

  @override
  void initState() {
    super.initState();
    _variant = widget.variants.first;
    // 默认用第一条可用线路（StreamInfoResult.usableLines 已过滤掉无地址的）。
    _lineId = widget.lines.isNotEmpty ? widget.lines.first.id : null;

    _player = Player();
    _controller = VideoController(_player);

    _player.stream.error.listen((message) {
      if (!mounted) return;
      setState(() => _error = message);
    });
    _player.stream.playing.listen((playing) {
      if (!mounted) return;
      setState(() => _playing = playing);
      _scheduleHide();
    });
    _player.stream.volume.listen((volume) {
      if (!mounted) return;
      setState(() => _volume = volume);
    });

    _openCurrent();
    _startDanmaku();
    _scheduleHide();
  }

  /// 播放中自动隐藏控件；暂停时保持显示（否则暂停后无从操作）。
  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_playing) {
      if (mounted) setState(() => _controlsVisible = true);
      return;
    }
    _hideTimer = Timer(const Duration(milliseconds: 3500), () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  Future<void> _togglePlay() async {
    await _player.playOrPause();
    _showControls();
  }

  Future<void> _toggleMute() async {
    if (_muted) {
      await _player.setVolume(_volumeBeforeMute <= 0 ? 100 : _volumeBeforeMute);
      setState(() => _muted = false);
    } else {
      _volumeBeforeMute = _volume;
      await _player.setVolume(0);
      setState(() => _muted = true);
    }
    _showControls();
  }

  Future<void> _toggleFullscreen() async {
    final isMobile = defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android;
    if (!isMobile) {
      // 桌面：样式全屏 —— 壳层让位、播放器铺满应用窗口（系统窗口不变）。
      // 真·窗口全屏（覆盖任务栏）需要窗口管理插件，放到 P3 阶段。
      final session = PlayerSession.instance;
      session.setChromeHidden(!session.chromeHidden);
      setState(() {});
      _showControls();
      return;
    }
    _immersive = !_immersive;
    await SystemChrome.setEnabledSystemUIMode(
      _immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    setState(() {});
  }

  /// 启动弹幕。平台未接入时 _danmaku 为 null，UI 自动退化成无弹幕。
  Future<void> _startDanmaku() async {
    final client = createDanmakuClient(widget.room.platform);
    if (client == null) return;
    _danmaku = client;
    // 订阅连接状态：用来区分「弹幕渲染问题」和「WS 在反复重连」。
    _danmakuStatusSub = client.connected.listen((online) {
      if (!mounted) return;
      setState(() => _danmakuOnline = online);
    });
    try {
      await client.start(widget.room.roomId);
    } catch (_) {
      // 弹幕失败不影响看画面，静默降级
    }
  }

  /// 打开「当前档位 + 当前线路」的组合。
  Future<void> _openCurrent() async {
    final url = _variant.urlForLine(_lineId);
    if (url.isEmpty) {
      setState(() => _error = '该线路没有可用地址');
      return;
    }
    setState(() => _error = null);
    await _player.open(
      Media(
        url,
        // 各平台 CDN 对 Referer/UA 的要求不同：
        // B 站 HLS 直连通常不需要 Referer，带上更稳妥；
        // 斗鱼 FLV 需要站点 Referer，否则边缘节点可能 403。
        httpHeaders: {
          'Referer': _refererFor(widget.room.platform, widget.room.roomId),
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
        },
      ),
    );
  }

  String _refererFor(LivePlatform platform, String roomId) {
    return switch (platform) {
      LivePlatform.bilibili => 'https://live.bilibili.com/',
      LivePlatform.douyu => 'https://www.douyu.com/$roomId',
      LivePlatform.huya => 'https://www.huya.com/$roomId',
      LivePlatform.douyin => 'https://live.douyin.com/$roomId',
    };
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _danmakuStatusSub?.cancel();
    _danmaku?.dispose();
    _danmaku = null;
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        // 桌面端：鼠标一动就显示控件
        onHover: (_) => _showControls(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildStage(),
            _buildTopOverlay(),
            _buildControlBar(),
            if (kDiagnosticsEnabled && _showStats)
              Positioned(
                left: 0,
                right: 0,
                bottom: 76,
                child: _buildStatsPanel(),
              ),
          ],
        ),
      ),
    );
  }

  /// 画面舞台：按视频真实宽高比 letterbox，随窗口尺寸自适应。
  Widget _buildStage() {
    final state = _player.state;
    final width = state.width;
    final height = state.height;
    var aspect = 16 / 9;
    if (width != null && height != null && width > 0 && height > 0) {
      final ratio = width / height;
      if (ratio.isFinite && ratio > 0.1 && ratio < 10) aspect = ratio;
    }

    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 直播不需要进度条：media_kit 自带控件含可拖动 seek bar，
            // 而 FLV/HLS 直播没有索引、拖了只会报 "force-seekable"。
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              onDoubleTap: _toggleFullscreen,
              child: Video(
                controller: _controller,
                controls: NoVideoControls,
              ),
            ),
            // 弹幕层：与画面同一矩形，天然压在画面之上。
            ListenableBuilder(
              listenable: AppSettings.instance,
              builder: (context, _) {
                final settings = AppSettings.instance;
                return IgnorePointer(
                  child: DanmakuOverlay(
                    stream: _danmaku?.messages ?? Stream<DanmakuMessage>.empty(),
                    enabled: settings.danmakuEnabled,
                    fontSize: settings.danmakuFontSize,
                    opacity: settings.danmakuOpacity,
                    duration: settings.danmakuDuration,
                    area: settings.danmakuArea,
                  ),
                );
              },
            ),
            // 错误提示（不遮挡控件）
            if (_error != null)
              Positioned(
                left: 16,
                right: 16,
                top: 16,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: TallyColors.raised.withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: TallyColors.hairline),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: TallyColors.tallyRed,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /* --------------------------------------------------------------- 顶部信息条 */

  Widget _buildTopOverlay() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: _AutoHide(
        visible: _controlsVisible,
        alignment: Alignment.topCenter,
        child: Container(
          color: Colors.black.withValues(alpha: 0.55),
          padding: const EdgeInsets.symmetric(
              horizontal: TallySpace.sm, vertical: TallySpace.xs),
          child: Row(
            children: [
              IconButton(
                onPressed: widget.onClose ??
                    () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back, size: 20),
                color: TallyColors.textPrimary,
                tooltip: '返回',
              ),
              if (widget.room.isLive) ...[
                Container(
                  margin: const EdgeInsets.only(right: TallySpace.sm),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: TallyColors.tallyRed.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(TallyRadius.badge),
                  ),
                  child: const Text('LIVE', style: TallyType.liveBadge),
                ),
              ],
              Expanded(
                // 右键标题切换弹幕调试面板（仅非 release 构建有效）
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onSecondaryTap: kDiagnosticsEnabled
                      ? () => setState(() => _showStats = !_showStats)
                      : null,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.room.title.isEmpty
                            ? '房间 ${widget.room.roomId}'
                            : widget.room.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TallyType.nickname.copyWith(fontSize: 14),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          widget.room.platform.label,
                          if (widget.room.nickname.isNotEmpty) widget.room.nickname,
                          if (widget.room.category.isNotEmpty) widget.room.category,
                          if (widget.room.online > 0)
                            '${_formatCount(widget.room.online)} 人气',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TallyType.meta,
                      ),
                    ],
                  ),
                ),
              ),
              // 弹幕连接状态圆点（诊断用，release 剔除）
              if (kDiagnosticsEnabled && _danmakuOnline != null)
                Tooltip(
                  message: _danmakuOnline! ? '弹幕已连接' : '弹幕重连中',
                  child: Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _danmakuOnline!
                          ? TallyColors.signalBlue
                          : TallyColors.stateAmber,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /* --------------------------------------------------------------- 底部控制条 */

  Widget _buildControlBar() {
    final isMobile = defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: _AutoHide(
        visible: _controlsVisible,
        alignment: Alignment.bottomCenter,
        child: Container(
          color: Colors.black.withValues(alpha: 0.62),
          padding: const EdgeInsets.symmetric(
              horizontal: TallySpace.sm, vertical: TallySpace.xs),
          child: Row(
            children: [
              IconButton(
                onPressed: _togglePlay,
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow, size: 22),
                color: TallyColors.textPrimary,
                tooltip: _playing ? '暂停' : '播放',
              ),
              // 音量
              IconButton(
                onPressed: _toggleMute,
                icon: Icon(
                  _muted || _volume <= 0
                      ? Icons.volume_off
                      : (_volume < 50 ? Icons.volume_down : Icons.volume_up),
                  size: 20,
                ),
                color: TallyColors.textPrimary,
                tooltip: '静音',
              ),
              SizedBox(
                width: 88,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 5),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 10),
                  ),
                  child: Slider(
                    value: _volume.clamp(0, 100),
                    max: 100,
                    onChanged: (value) async {
                      await _player.setVolume(value);
                      if (value > 0 && _muted) setState(() => _muted = false);
                      _showControls();
                    },
                  ),
                ),
              ),
              const SizedBox(width: TallySpace.sm),
              // 直播标识（代替进度条）
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: TallyColors.tallyRed,
                ),
              ),
              const SizedBox(width: 5),
              const Text(
                '直播中',
                style: TextStyle(fontSize: 11, color: TallyColors.textSecondary),
              ),
              const Spacer(),
              // 弹幕开关（与设置页共用状态）
              ListenableBuilder(
                listenable: AppSettings.instance,
                builder: (context, _) {
                  final enabled = AppSettings.instance.danmakuEnabled;
                  return IconButton(
                    onPressed: () {
                      AppSettings.instance.setDanmakuEnabled(!enabled);
                      _showControls();
                    },
                    icon: Icon(
                      enabled ? Icons.subtitles : Icons.subtitles_off,
                      size: 18,
                    ),
                    color: enabled
                        ? TallyColors.textPrimary
                        : TallyColors.textTertiary,
                    tooltip: enabled ? '关闭弹幕' : '开启弹幕',
                  );
                },
              ),
              IconButton(
                onPressed: _openDanmakuSettings,
                icon: const Icon(Icons.tune, size: 18),
                color: TallyColors.textSecondary,
                tooltip: '弹幕设置',
              ),              if (widget.lines.length > 1) _buildLineMenu(),
              if (widget.variants.length > 1) _buildQualityMenu(),
              IconButton(
                onPressed: () {
                  _openCurrent();
                  _showControls();
                },
                icon: const Icon(Icons.refresh, size: 18),
                color: TallyColors.textSecondary,
                tooltip: '重新加载',
              ),
              if (isMobile)
                IconButton(
                  onPressed: _toggleFullscreen,
                  icon: Icon(
                    (_immersive || PlayerSession.instance.chromeHidden)
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                    size: 20,
                  ),
                  color: TallyColors.textPrimary,
                  tooltip: '全屏',
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 弹幕设置面板（对齐 DTV 的 DanmuSettingsControl：内联在播放页，没有独立设置页）。
  Future<void> _openDanmakuSettings() async {
    _showControls();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: TallyColors.raised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) => const DanmakuSettingsSheet(),
    );
  }
  /// 线路（CDN）下拉。切线路只会换地址，不会重新取流。
  Widget _buildLineMenu() {
    final current = widget.lines.firstWhere(
      (line) => line.id == _lineId,
      orElse: () => widget.lines.first,
    );
    return PopupMenuButton<String>(
      tooltip: '线路',
      color: TallyColors.raised,
      initialValue: current.id,
      onSelected: (lineId) {
        if (lineId == _lineId) return;
        setState(() => _lineId = lineId);
        _openCurrent();
      },
      itemBuilder: (context) => widget.lines
          .map(
            (line) => PopupMenuItem<String>(
              value: line.id,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      line.label,
                      style: const TextStyle(color: TallyColors.textPrimary),
                    ),
                  ),
                  Text(
                    '${widget.variants.where((v) => v.availableLineIds.contains(line.id)).length}档',
                    style: const TextStyle(
                      color: TallyColors.textTertiary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: TallySpace.sm),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              current.label,
              style: const TextStyle(
                color: TallyColors.textSecondary,
                fontSize: 12,
              ),
            ),
            const Icon(Icons.expand_more,
                size: 15, color: TallyColors.textSecondary),
          ],
        ),
      ),
    );
  }

  /// 清晰度下拉。
  Widget _buildQualityMenu() {
    return PopupMenuButton<StreamVariant>(
      tooltip: '清晰度',
      color: TallyColors.raised,
      initialValue: _variant,
      onSelected: (variant) {
        if (variant.id == _variant.id) return;
        setState(() {
          _variant = variant;
          // 切档位后该档位可能没有当前线路，交给 urlForLine 回退。
        });
        _openCurrent();
      },
      itemBuilder: (context) => widget.variants
          .map(
            (variant) => PopupMenuItem<StreamVariant>(
              value: variant,
              child: Text(
                variant.label,
                style: const TextStyle(color: TallyColors.textPrimary),
              ),
            ),
          )
          .toList(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: TallySpace.sm),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _variant.label,
              style: const TextStyle(
                color: TallyColors.signalBlue,
                fontSize: 12,
              ),
            ),
            const Icon(Icons.expand_more, size: 15, color: TallyColors.signalBlue),
          ],
        ),
      ),
    );
  }

  /// 弹幕管线调试面板（仅诊断构建）。
  Widget _buildStatsPanel() {
    return ListenableBuilder(
      listenable: DanmakuStats.instance,
      builder: (context, _) {
        final stats = DanmakuStats.instance;
        return Container(
          color: TallyColors.raised.withValues(alpha: 0.94),
          padding: const EdgeInsets.symmetric(
              horizontal: TallySpace.md, vertical: TallySpace.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    '弹幕管线',
                    style: TextStyle(
                      color: TallyColors.signalBlue,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: stats.reset,
                    child: const Text(
                      '重置',
                      style:
                          TextStyle(color: TallyColors.textTertiary, fontSize: 11),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SelectableText(
                stats.summary,
                style: const TextStyle(
                  color: TallyColors.textSecondary,
                  fontSize: 11,
                  height: 1.5,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatCount(int value) {
    if (value >= 10000) {
      return '${(value / 10000).toStringAsFixed(1)}万';
    }
    return value.toString();
  }
}

/// 自动隐藏容器：显隐时淡入淡出 + 轻微位移，且完全显示时不拦截点击。
class _AutoHide extends StatelessWidget {
  const _AutoHide({
    required this.visible,
    required this.alignment,
    required this.child,
  });

  final bool visible;
  final Alignment alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isTop = alignment == Alignment.topCenter;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : Offset(0, isTop ? -0.15 : 0.15),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: child,
        ),
      ),
    );
  }
}

/// 弹幕设置面板。
///
/// 参数范围与默认值对齐 DTV 的 `danmuSettings.ts`：
/// 字号 14–30（步 2）、不透明度 0.2–1（步 0.05）、
/// 存活时间 5–20s（步 0.5）、显示区域 0.25/0.5/0.75/1。
///
/// 这是 DTV 的做法：设置是**播放页的内联控件**，不做独立设置页
/// （之前那版单独做了设置页，和这里的弹幕设置重复，已删除）。
class DanmakuSettingsSheet extends StatelessWidget {
  const DanmakuSettingsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: AppSettings.instance,
        builder: (context, _) {
          final settings = AppSettings.instance;
          return Padding(
            padding: const EdgeInsets.fromLTRB(
                TallySpace.lg, TallySpace.md, TallySpace.lg, TallySpace.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('弹幕设置', style: TallyType.pageTitle.copyWith(fontSize: 15)),
                    const Spacer(),
                    Row(
                      children: [
                        Text(settings.danmakuEnabled ? '已开启' : '已关闭',
                            style: TallyType.meta),
                        Switch(
                          value: settings.danmakuEnabled,
                          activeThumbColor: TallyColors.signalBlue,
                          onChanged: settings.setDanmakuEnabled,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: TallySpace.sm),
                _SettingSlider(
                  label: '字号',
                  value: settings.danmakuFontSize,
                  min: 14,
                  max: 30,
                  divisions: 8,
                  suffix: '${settings.danmakuFontSize.round()}',
                  onChanged: settings.setDanmakuFontSize,
                ),
                _SettingSlider(
                  label: '不透明度',
                  value: settings.danmakuOpacity,
                  min: 0.2,
                  max: 1,
                  divisions: 16,
                  suffix: '${(settings.danmakuOpacity * 100).round()}%',
                  onChanged: settings.setDanmakuOpacity,
                ),
                _SettingSlider(
                  label: '存活时间',
                  value: settings.danmakuDuration,
                  min: 5,
                  max: 20,
                  divisions: 30,
                  suffix: '${settings.danmakuDuration.toStringAsFixed(1)}s',
                  onChanged: settings.setDanmakuDuration,
                ),
                _SettingSlider(
                  label: '显示区域',
                  value: settings.danmakuArea,
                  min: 0.25,
                  max: 1,
                  divisions: 3,
                  suffix: '${(settings.danmakuArea * 100).round()}%',
                  onChanged: settings.setDanmakuArea,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SettingSlider extends StatelessWidget {
  const _SettingSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.suffix,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String suffix;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 68,
          child: Text(label, style: TallyType.subtitle),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            suffix,
            textAlign: TextAlign.right,
            style: TallyType.numberSmall.copyWith(
              color: TallyColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}