import 'package:flutter/material.dart';
import 'package:tallylive/core/live_repository.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/core/player_session.dart';
import 'package:tallylive/ui/components/states.dart';
import 'package:tallylive/ui/player_page.dart';
import 'package:tallylive/ui/theme.dart';

/// 播放层：壳层里的一层，不是 `Navigator.push` 的新页面。
///
/// 这样做的好处（对齐 DTV 的 AppShell）：
/// 1. 播放时侧栏/顶栏还在 → 可以直接换直播间；
/// 2. 返回列表时列表状态没被销毁 → 不重新请求、不丢滚动位置；
/// 3. 全屏只是"壳层让位"，不需要动路由栈。
///
/// 换房间靠 [ValueKey] 强制重建（`platform:roomId`），
/// 避免复用同一个播放器导致旧直播间声音没断。
class PlayerLayer extends StatelessWidget {
  const PlayerLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PlayerSession.instance,
      builder: (context, _) {
        final target = PlayerSession.instance.target;
        if (target == null) return const SizedBox.shrink();
        return _PlayerHost(
          key: ValueKey<String>(target.key),
          target: target,
        );
      },
    );
  }
}

/// 取流 → 渲染播放页；取流期间显示加载/错误态。
class _PlayerHost extends StatefulWidget {
  const _PlayerHost({super.key, required this.target});

  final PlayerTarget target;

  @override
  State<_PlayerHost> createState() => _PlayerHostState();
}

class _PlayerHostState extends State<_PlayerHost> {
  late final LiveRepository _repo = createLiveRepository();

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
        platform: widget.target.platform,
        roomId: widget.target.roomId,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _friendly(error);
        _loading = false;
      });
    }
  }

  String _friendly(Object error) {
    final text = error.toString();
    if (text.contains('未开播')) return '这个直播间当前未开播';
    return text.length > 140 ? '${text.substring(0, 140)}…' : text;
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    if (result != null && result.playable) {
      return PlayerPage(
        room: result.room,
        variants: result.variants,
        lines: result.usableLines,
        onClose: PlayerSession.instance.close,
      );
    }

    return Material(
      color: TallyColors.base,
      child: Stack(
        children: [
          Center(child: _buildBody(result)),
          Positioned(
            left: TallySpace.sm,
            top: TallySpace.sm,
            child: SafeArea(
              child: IconButton(
                tooltip: '关闭',
                onPressed: PlayerSession.instance.close,
                icon: const Icon(Icons.close, color: TallyColors.textPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(StreamInfoResult? result) {
    if (_loading) {
      return const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: TallyColors.signalBlue,
        ),
      );
    }
    if (_error != null) {
      return ErrorState(message: _error!, onRetry: _load);
    }
    final room = result?.room;
    return EmptyState(
      icon: Icons.tv_off_outlined,
      message: room != null && !room.isLive
          ? '这个直播间当前未开播'
          : '没有取到可播放地址，换个线路或稍后重试',
      actionLabel: '重试',
      onAction: _load,
    );
  }
}
