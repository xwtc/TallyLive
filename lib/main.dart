import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/platforms/bilibili/bilibili_client.dart';
import 'package:tallylive/platforms/douyu/douyu_client.dart';
import 'package:tallylive/platforms/platform_client.dart';
import 'package:tallylive/ui/player_page.dart';
import 'package:tallylive/ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit 必须在 runApp 之前初始化（它会准备 libmpv 的 native 绑定）。
  MediaKit.ensureInitialized();
  runApp(const TallyApp());
}

class TallyApp extends StatelessWidget {
  const TallyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TallyLive · 在播',
      debugShowCheckedModeBanner: false,
      theme: buildTallyTheme(),
      home: const HomePage(),
    );
  }
}

/// 第一阶段首页：输入房间号直接播放。
///
/// 这个页面是**临时的验证入口**，用于在真机上确认
/// 「B 站协议 → media_kit/libmpv → 画面」这条链路能通。
/// 后续会替换成分区/列表/关注的正规首页。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _roomController =
      TextEditingController(text: '6');
  final Map<LivePlatform, PlatformClient> _clients = {
    LivePlatform.bilibili: BilibiliClient(),
    LivePlatform.douyu: DouyuClient(),
  };

  LivePlatform _platform = LivePlatform.bilibili;
  bool _loading = false;
  String? _error;

  /// 当前可用的平台（已接入客户端的）。
  List<LivePlatform> get _availablePlatforms => _clients.keys.toList();

  @override
  void dispose() {
    _roomController.dispose();
    super.dispose();
  }

  Future<void> _openRoom() async {
    final roomId = _roomController.text.trim();
    if (roomId.isEmpty) return;
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
      final info = await client.fetchStreamInfo(roomId);
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

      setState(() => _loading = false);
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
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '第一阶段验证入口',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: TallyColors.textSecondary,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  '输入房间号，验证协议取流与 libmpv 播放链路。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: TallyColors.textTertiary,
                      ),
                ),
                const SizedBox(height: 20),
                SegmentedButton<LivePlatform>(
                  segments: _availablePlatforms
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
                  ),
                  onSubmitted: (_) => _openRoom(),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _loading ? null : _openRoom,
                  child: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('打开直播间'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: TallyColors.raised,
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
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
