import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/ui/theme.dart';

/// 播放页。
///
/// 结构上与 Simple Live 一致：`Stack` 里第一层是 media_kit 的 `Video`
/// （底层是 libmpv，渲染进 Flutter 纹理），弹幕/控制条作为同级 widget 叠在上面
/// —— 因为它们走同一个合成器，所以不存在 WebView 架构下「原生窗口遮住弹幕」的问题。
///
/// 当前阶段还没有接弹幕，等协议层补上 getDanmuInfo + WebSocket 后，
/// 在这个 Stack 里插入 `DanmakuScreen` 即可。
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.room,
    required this.variants,
    this.lines = const [],
  });

  final RoomInfo room;
  final List<StreamVariant> variants;
  final List<StreamLine> lines;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final Player _player;
  late final VideoController _controller;

  late StreamVariant _variant;
  String? _lineId;
  String? _error;

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

    _openCurrent();
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
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TallyColors.base,
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            _buildTopBar(context),
            ColoredBox(
              color: Colors.black,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Video(
                      controller: _controller,
                      // 控制条先用 media_kit 自带的，后面换成 Tally 风格自绘。
                      controls: AdaptiveVideoControls,
                    ),
                    if (_error != null)
                      Center(
                        child: Container(
                          margin: const EdgeInsets.all(16),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: TallyColors.raised.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: TallyColors.hairline),
                          ),
                          child: Text(
                            _error!,
                            style: const TextStyle(
                              color: TallyColors.tallyRed,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(child: _buildInfo(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Container(
      color: TallyColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
            color: TallyColors.textPrimary,
            tooltip: '返回',
          ),
          const SizedBox(width: 4),
          if (widget.room.isLive)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: TallyColors.tallyRed.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'LIVE',
                style: TextStyle(
                  color: TallyColors.tallyRed,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          Expanded(
            child: Text(
              widget.room.title.isEmpty ? '房间 ${widget.room.roomId}' : widget.room.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: TallyColors.textPrimary,
                fontSize: 15,
              ),
            ),
          ),
          // 线路选择：只在有真实多线路时显示。
          if (widget.lines.length > 1) _buildLineMenu(),
          // 清晰度选择
          if (widget.variants.length > 1) _buildQualityMenu(),
        ],
      ),
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
                  // 该线路在多少档位里可用，便于判断覆盖度。
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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              current.label,
              style: const TextStyle(
                color: TallyColors.textSecondary,
                fontSize: 13,
              ),
            ),
            const Icon(
              Icons.expand_more,
              size: 16,
              color: TallyColors.textSecondary,
            ),
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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _variant.label,
              style: const TextStyle(
                color: TallyColors.signalBlue,
                fontSize: 13,
              ),
            ),
            const Icon(
              Icons.expand_more,
              size: 16,
              color: TallyColors.signalBlue,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfo(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          widget.room.title.isEmpty ? '房间 ${widget.room.roomId}' : widget.room.title,
          style: const TextStyle(
            color: TallyColors.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _chip(widget.room.platform.label),
            const SizedBox(width: 8),
            _chip('房间 ${widget.room.roomId}'),
            if (widget.room.category.isNotEmpty) ...[
              const SizedBox(width: 8),
              _chip(widget.room.category),
            ],
            if (widget.room.online > 0) ...[
              const SizedBox(width: 8),
              _chip('${_formatCount(widget.room.online)} 人气'),
            ],
          ],
        ),
        if (widget.room.nickname.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            widget.room.nickname,
            style: const TextStyle(color: TallyColors.textSecondary, fontSize: 14),
          ),
        ],
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: TallyColors.surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: TallyColors.hairline),
          ),
          child: Text(
            '当前：${_variant.label}（${_variant.format.toUpperCase()}）'
            '${widget.lines.length > 1 ? ' · 线路 ${_currentLineLabel()}' : ''}\n'
            '可切换 ${widget.variants.length} 个清晰度'
            '${widget.lines.length > 1 ? '、${widget.lines.length} 条线路' : ''}。\n'
            '弹幕将在下一阶段接入。',
            style: const TextStyle(
              color: TallyColors.textSecondary,
              fontSize: 13,
              height: 1.6,
            ),
          ),
        ),
      ],
    );
  }

  String _currentLineLabel() {
    for (final line in widget.lines) {
      if (line.id == _lineId) return line.label;
    }
    return widget.lines.isNotEmpty ? widget.lines.first.label : '';
  }

  Widget _chip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: TallyColors.raised,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(color: TallyColors.textSecondary, fontSize: 12),
      ),
    );
  }

  String _formatCount(int value) {
    if (value >= 10000) {
      return '${(value / 10000).toStringAsFixed(1)}万';
    }
    return value.toString();
  }
}
