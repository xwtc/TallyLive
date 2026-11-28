import 'package:flutter/material.dart';
import 'package:tallylive/core/live_repository.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/ui/components/states.dart';
import 'package:tallylive/ui/player_page.dart';
import 'package:tallylive/ui/theme.dart';

/// 播放入口页：先取流，成功后再渲染 [PlayerPage]。
///
/// 为什么不直接在列表页取流：取流包含 2–4 次网络请求（房间信息 + 每个清晰度），
/// 在列表页等会让点击反馈变慢。这里点击后立刻跳转，本页负责加载/错误态，
/// 体验上"点了就进"。
class PlayerEntryPage extends StatefulWidget {
  const PlayerEntryPage({
    super.key,
    required this.platform,
    required this.roomId,
    this.fallbackTitle = '',
    this.repository,
  });

  final LivePlatform platform;
  final String roomId;

  /// 列表里已有的标题，加载期间先显示，避免空白。
  final String fallbackTitle;
  final LiveRepository? repository;

  @override
  State<PlayerEntryPage> createState() => _PlayerEntryPageState();
}

class _PlayerEntryPageState extends State<PlayerEntryPage> {
  late final LiveRepository _repo = widget.repository ?? createLiveRepository();

  StreamInfoResult? _result;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _repo.fetchStreamInfo(
        platform: widget.platform,
        roomId: widget.roomId,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    if (result != null && result.playable) {
      // 取流成功：直接交给播放页（它是一个完整 Scaffold）
      return PlayerPage(
        room: result.room,
        variants: result.variants,
        lines: result.usableLines,
      );
    }

    return Scaffold(
      backgroundColor: TallyColors.base,
      appBar: AppBar(
        title: Text(
          widget.fallbackTitle.isEmpty
              ? '${widget.platform.label} · ${widget.roomId}'
              : widget.fallbackTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TallyType.nickname.copyWith(fontSize: 15),
        ),
      ),
      body: _buildBody(result),
    );
  }

  Widget _buildBody(StreamInfoResult? result) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: TallyColors.signalBlue,
          ),
        ),
      );
    }
    if (_error != null) {
      return ErrorState(message: _error!, onRetry: _load);
    }
    // 取流成功但没有档位：通常是未开播
    final room = result?.room;
    return EmptyState(
      icon: Icons.tv_off_outlined,
      message: room == null || !room.isLive
          ? '这个直播间当前未开播'
          : '没有取到可播放地址，换个线路或稍后重试',
      actionLabel: '重试',
      onAction: _load,
    );
  }
}
