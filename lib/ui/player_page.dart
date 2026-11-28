import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tallylive/core/danmaku.dart';
import 'package:tallylive/core/danmaku_stats.dart';
import 'package:tallylive/core/follows.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/core/player_session.dart';
import 'package:tallylive/core/settings.dart';
import 'package:tallylive/platforms/danmaku_factory.dart';
import 'package:tallylive/ui/components/atoms.dart';
import 'package:tallylive/ui/components/danmu_panel.dart';
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

  /// 右侧弹幕列表面板（对齐 DTV 的 DanmuPanel）。
  bool _danmuPanelOpen = false;

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
    // 无条件计时：DTV 也是这么做的 —— 控件只是"浮层"，
    // 缓冲/暂停时同样该隐藏，鼠标一动或点击画面再出现。
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
      // 桌面：真全屏 —— window_manager 让窗口进入全屏（覆盖任务栏），
      // 同时让壳层让位（侧栏/顶栏隐藏），两者一起才是 DTV 的 nativeFullscreen。
      try {
        final next = !await windowManager.isFullScreen();
        await windowManager.setFullScreen(next);
        PlayerSession.instance.setNativeFullscreen(next);
        PlayerSession.instance.setChromeHidden(next);
        if (mounted) setState(() {});
      } catch (_) {
        // 极端情况下（非窗口环境）退化成样式全屏
        final session = PlayerSession.instance;
        session.setChromeHidden(!session.chromeHidden);
        if (mounted) setState(() {});
      }
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
    var url = _variant.urlForLine(_lineId);

    // 该线路在当前档位没有地址（斗鱼常见：多个 CDN 里只有部分能签名成功）：
    // 回落到第一个真有地址的线路并明确提示，而不是静默不给选或无脑报错。
    if (url.isEmpty) {
      final fallback = widget.lines.firstWhere(
        (line) => _variant.urlForLine(line.id).isNotEmpty,
        orElse: () => const StreamLine(id: '', label: ''),
      );
      if (fallback.id.isNotEmpty) {
        setState(() => _lineId = fallback.id);
        url = _variant.urlForLine(fallback.id);
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text('该线路暂无地址，已切到 ${fallback.label}')),
          );
        }
      }
    }
    if (url.isEmpty) {
      setState(() => _error = '所有线路都没有可用地址，稍后重试');
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
            if (_danmuPanelOpen)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: DanmuPanel(
                  stream: _danmaku?.messages ??
                      Stream<DanmakuMessage>.empty(),
                  onClose: () => setState(() => _danmuPanelOpen = false),
                ),
              ),
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
                    blockedKeywords: settings.danmakuBlockedList,
                    colorful: settings.danmakuColorful,
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

  /// 顶部信息条（对齐 DTV 的播放器顶栏）：
  ///
  /// ```
  /// (X)  ┌──────────────────────────────────────────┐
  ///      │ (头像) 标题                [直播中] [★ 已关注] │
  ///      │        虎牙 · DANKING · ID:10188          │
  ///      └──────────────────────────────────────────┘
  /// ```
  /// 半透明深色胶囊浮在画面上（不是占位的实心条），随控件一起自动隐藏。
  Widget _buildTopOverlay() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: _AutoHide(
        visible: _controlsVisible,
        alignment: Alignment.topCenter,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.all(TallySpace.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _RoundIconButton(
                  icon: Icons.close,
                  tooltip: '关闭',
                  onTap: widget.onClose ??
                      () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(width: TallySpace.sm),
                Flexible(child: _buildInfoIsland()),
                const Spacer(),
                if (kDiagnosticsEnabled && _danmakuOnline != null)
                  Padding(
                    padding: const EdgeInsets.only(top: TallySpace.sm),
                    child: Tooltip(
                      message: _danmakuOnline! ? '弹幕已连接' : '弹幕重连中',
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _danmakuOnline!
                              ? TallyColors.signalBlue
                              : TallyColors.stateAmber,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 画面上的半透明信息胶囊：头像 + 标题 + 平台·昵称·ID + 直播中 + 星标关注。
  Widget _buildInfoIsland() {
    final room = widget.room;
    final title = room.title.isEmpty
        ? (room.nickname.isEmpty ? '房间 ${room.roomId}' : room.nickname)
        : room.title;
    // 副标题比 DTV 更详细：平台 · 昵称 · 分区 · 人气 · ID
    final subtitleParts = <String>[
      room.platform.label,
      if (room.nickname.isNotEmpty) room.nickname,
      if (room.category.isNotEmpty) room.category,
      if (room.online > 0) '${_formatCount(room.online)} 人气',
      'ID:${room.roomId}',
    ];

    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      padding: const EdgeInsets.fromLTRB(6, 5, 8, 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(TallyRadius.pill),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AvatarBox(
            url: room.avatar,
            fallbackText: title,
            size: 34,
          ),
          const SizedBox(width: TallySpace.sm),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: TallyColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitleParts.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: TallyColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (room.isLive) ...[
            const SizedBox(width: TallySpace.sm),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: TallyColors.tallyRed.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(TallyRadius.pill),
              ),
              child: const Text('直播中', style: TallyType.liveBadge),
            ),
          ],
          const SizedBox(width: 6),
          _buildFollowPill(),
        ],
      ),
    );
  }

  /// 星标关注胶囊：已关注为实心星 + 强调底，未关注为空心星 + 透明底。
  Widget _buildFollowPill() {
    return ListenableBuilder(
      listenable: FollowStore.instance,
      builder: (context, _) {
        final followed = FollowStore.instance.isFollowing(
          widget.room.platform,
          widget.room.roomId,
        );
        return GestureDetector(
          onTap: () async {
            final now = await FollowStore.instance.toggle(
              platform: widget.room.platform,
              roomId: widget.room.roomId,
              nickname: widget.room.nickname,
              title: widget.room.title,
              avatar: widget.room.avatar,
              isLive: widget.room.isLive,
              viewers: widget.room.online,
            );
            if (!mounted) return;
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(content: Text(now ? '已关注' : '已取消关注')),
            );
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: AnimatedContainer(
              duration: TallyDuration.fast,
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: followed ? TallyColors.accentSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(TallyRadius.pill),
                border: Border.all(
                  color: followed
                      ? TallyColors.signalBlue
                      : Colors.white.withValues(alpha: 0.18),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    followed ? Icons.star : Icons.star_border,
                    size: 14,
                    color: followed
                        ? TallyColors.accentInk
                        : TallyColors.textSecondary,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    followed ? '已关注' : '关注',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: followed
                          ? TallyColors.accentInk
                          : TallyColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
  /* --------------------------------------------------------------- 底部控制条 */

  Widget _buildControlBar() {
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
                onPressed: () =>
                    setState(() => _danmuPanelOpen = !_danmuPanelOpen),
                icon: Icon(
                  _danmuPanelOpen
                      ? Icons.view_sidebar
                      : Icons.view_sidebar_outlined,
                  size: 18,
                ),
                color: _danmuPanelOpen
                    ? TallyColors.textPrimary
                    : TallyColors.textTertiary,
                tooltip: '弹幕列表',
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
/// 存活时间 5–20s（步 0.5）、显示区域 10%–100%（步 5%，比 DTV 的 4 档更细）。
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
                // 这里不放弹幕开关：播放控制条上已经有一个，
                // 两处开关同一状态只会让人怀疑哪个生效（去掉重复）。
                Row(
                  children: [
                    Text('弹幕设置',
                        style: TallyType.pageTitle.copyWith(fontSize: 15)),
                    const Spacer(),
                    Text(
                      settings.danmakuEnabled ? '弹幕已开启' : '弹幕已关闭',
                      style: TallyType.meta,
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
                // 显示区域：DTV 只给 0.25/0.5/0.75/1 四档，跨度太粗
                //（25% 一跳，用户没法微调到"刚好避开字幕"）。
                // 这里改成 10%~100%、每 5% 一档（19 档），保留整数百分比更直观。
                _SettingSlider(
                  label: '显示区域',
                  value: settings.danmakuArea,
                  min: 0.10,
                  max: 1,
                  divisions: 18,
                  suffix: '${(settings.danmakuArea * 100).round()}%',
                  onChanged: settings.setDanmakuArea,
                ),
                Row(
                  children: [
                    const SizedBox(
                      width: 68,
                      child: Text('彩色弹幕', style: TallyType.subtitle),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Switch(
                          value: settings.danmakuColorful,
                          activeThumbColor: TallyColors.signalBlue,
                          onChanged: settings.setDanmakuColorful,
                        ),
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
                const SizedBox(height: TallySpace.sm),
                TextFormField(
                  initialValue: settings.danmakuBlocked,
                  style: TallyType.subtitle
                      .copyWith(color: TallyColors.textPrimary),
                  onChanged: settings.setDanmakuBlocked,
                  decoration: InputDecoration(
                    labelText: '屏蔽词（逗号或换行分隔）',
                    labelStyle: TallyType.meta,
                    hintText: '例如：抽奖, 加群',
                    hintStyle: TallyType.meta,
                    filled: true,
                    fillColor: TallyColors.inset,
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(TallyRadius.card),
                      borderSide: BorderSide.none,
                    ),
                  ),
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
/// 画面上的圆形图标按钮（关闭/返回等），半透明底浮在视频上。
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.55),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Icon(icon, size: 18, color: TallyColors.textPrimary),
          ),
        ),
      ),
    );
  }
}