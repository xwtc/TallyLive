import 'package:flutter/material.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/core/settings.dart';
import 'package:tallylive/platforms/bilibili/bilibili_client.dart';
import 'package:tallylive/platforms/douyu/douyu_client.dart';
import 'package:tallylive/platforms/platform_client.dart';
import 'package:tallylive/ui/player_page.dart';
import 'package:tallylive/ui/theme.dart';

/// 「直播」Tab：选平台 + 输房间号 + 最近打开。
///
/// 这是临时的验证入口，后续会换成「关注中在播 + 平台精选」的正式首页。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _roomController = TextEditingController();
  final AppSettings _settings = AppSettings.instance;

  final Map<LivePlatform, PlatformClient> _clients = {
    LivePlatform.bilibili: BilibiliClient(),
    LivePlatform.douyu: DouyuClient(),
  };

  LivePlatform _platform = LivePlatform.bilibili;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _roomController.dispose();
    super.dispose();
  }

  Future<void> _openRoom(String roomId) async {
    final trimmed = roomId.trim();
    if (trimmed.isEmpty) return;
    final client = _clients[_platform];
    if (client == null) {
      setState(() => _error = '${_platform.label} 尚未接入');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final info = await client.fetchStreamInfo(trimmed);
      if (!mounted) return;

      if (!info.room.isLive) {
        setState(() {
          _loading = false;
          _error = '房间 ${info.room.roomId} 当前未开播';
        });
        return;
      }
      if (info.variants.isEmpty) {
        setState(() {
          _loading = false;
          _error = '没有取到可播放地址';
        });
        return;
      }

      await _settings.addRecentRoom(_platform, info.room.roomId);
      setState(() => _loading = false);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            room: info.room,
            variants: info.variants,
            lines: info.usableLines,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('TallyLive · 在播')),
      body: ListenableBuilder(
        listenable: _settings,
        builder: (context, _) {
          final recents = _settings.recentRooms;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                '选择平台并输入房间号',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: TallyColors.textSecondary,
                    ),
              ),
              const SizedBox(height: 16),
              SegmentedButton<LivePlatform>(
                segments: _clients.keys
                    .map(
                      (platform) => ButtonSegment<LivePlatform>(
                        value: platform,
                        label: Text(platform.label),
                      ),
                    )
                    .toList(),
                selected: {_platform},
                onSelectionChanged: (selection) {
                  setState(() {
                    _platform = selection.first;
                    _error = null;
                  });
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _roomController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: TallyColors.textPrimary),
                decoration: InputDecoration(
                  labelText: '${_platform.label}房间号',
                  hintText: _platform == LivePlatform.douyu ? '例如 9999' : '例如 6',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.login, size: 18),
                    tooltip: '打开',
                    onPressed: _loading ? null : () => _openRoom(_roomController.text),
                  ),
                ),
                onSubmitted: _openRoom,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _loading ? null : () => _openRoom(_roomController.text),
                icon: _loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow, size: 18),
                label: const Text('打开直播间'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                _ErrorBox(message: _error!),
              ],
              if (recents.isNotEmpty) ...[
                const SizedBox(height: 28),
                Row(
                  children: [
                    Text(
                      '最近打开',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: TallyColors.textSecondary,
                          ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _settings.clearRecentRooms,
                      child: const Text(
                        '清空',
                        style: TextStyle(color: TallyColors.textTertiary, fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                for (final room in recents)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.history,
                      size: 18,
                      color: TallyColors.textTertiary,
                    ),
                    title: Text(
                      '${room.platform.label} · ${room.roomId}',
                      style: const TextStyle(
                        color: TallyColors.textPrimary,
                        fontSize: 14,
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      color: TallyColors.textTertiary,
                      tooltip: '移除',
                      onPressed: () => _settings.removeRecentRoom(room.key),
                    ),
                    onTap: () {
                      setState(() {
                        _platform = room.platform;
                        _roomController.text = room.roomId;
                      });
                      _openRoom(room.roomId);
                    },
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TallyColors.raised,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: TallyColors.hairline),
      ),
      child: Text(
        message,
        style: const TextStyle(color: TallyColors.tallyRed, fontSize: 13),
      ),
    );
  }
}
