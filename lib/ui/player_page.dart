import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:tallylive/platforms/bilibili/bilibili_client.dart';
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
  });

  final BilibiliRoomInfo room;
  final List<StreamVariant> variants;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final Player _player;
  late final VideoController _controller;

  late StreamVariant _variant;
  String? _error;

  @override
  void initState() {
    super.initState();
    _variant = widget.variants.first;

    _player = Player();
    _controller = VideoController(_player);

    _player.stream.error.listen((message) {
      if (!mounted) return;
      setState(() => _error = message);
    });

    _openVariant(_variant);
  }

  Future<void> _openVariant(StreamVariant variant) async {
    setState(() => _error = null);
    await _player.open(
      Media(
        variant.url,
        // B 站 HLS 直连不需要 Referer，但带上更稳妥（部分 CDN 节点会校验）。
        httpHeaders: const {
          'Referer': 'https://live.bilibili.com/',
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
        },
      ),
    );
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
          if (widget.variants.length > 1)
            PopupMenuButton<StreamVariant>(
              tooltip: '清晰度',
              color: TallyColors.raised,
              initialValue: _variant,
              onSelected: (variant) {
                setState(() => _variant = variant);
                _openVariant(variant);
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
            ),
        ],
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
            _chip('房间 ${widget.room.roomId}'),
            const SizedBox(width: 8),
            if (widget.room.areaName.isNotEmpty) _chip(widget.room.areaName),
            const SizedBox(width: 8),
            if (widget.room.online > 0) _chip('${_formatCount(widget.room.online)} 人气'),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: TallyColors.surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: TallyColors.hairline),
          ),
          child: Text(
            '弹幕将在下一阶段接入（需要 getDanmuInfo + WBI 签名 + WebSocket）。\n'
            '当前页面用于验证：B 站取流协议 → media_kit/libmpv → 画面显示。',
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
