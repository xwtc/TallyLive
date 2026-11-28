import 'package:flutter/material.dart';
import 'package:tallylive/core/lan_sync.dart';
import 'package:tallylive/core/webdav_sync.dart';
import 'package:tallylive/ui/components/toast.dart';
import 'package:tallylive/ui/theme.dart';

/// 数据同步弹窗（对齐 DTV 的 `LanSyncModal` + 新增 WebDAV）。
///
/// 两种方式：
/// - **局域网同步**：与 DTV 完全兼容（同端口 38999、同路径、同 token "dtv"）
/// - **WebDAV 同步**：坚果云 / Nextcloud，跨网络
class SyncSheet extends StatefulWidget {
  const SyncSheet({super.key});

  @override
  State<SyncSheet> createState() => _SyncSheetState();
}

class _SyncSheetState extends State<SyncSheet> {
  bool _lanMode = true;

  // 局域网状态
  bool _serverRunning = false;
  List<String> _serverUrls = const [];
  List<LanSyncPeer> _peers = const [];
  bool _scanning = false;
  int _scanDone = 0;
  int _scanTotal = 0;

  // WebDAV 状态
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  WebDavConfig? _config;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final config = await WebDavSync.loadConfig();
    if (!mounted) return;
    setState(() {
      _config = config;
      if (config != null) {
        _urlController.text = config.baseUrl;
        _userController.text = config.username;
        _passController.text = config.password;
      }
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passController.dispose();
    super.dispose();
  }

  /* ---------------------------------------------------------------- 局域网 */

  Future<void> _toggleServer() async {
    if (_serverRunning) {
      await LanSync.stopServer();
      if (!mounted) return;
      setState(() {
        _serverRunning = false;
        _serverUrls = const [];
      });
      return;
    }
    try {
      final urls = await LanSync.startServer();
      if (!mounted) return;
      setState(() {
        _serverRunning = true;
        _serverUrls = urls;
      });
    } catch (error) {
      if (!mounted) return;
      context.showToast('$error', kind: ToastKind.error);
    }
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _peers = const [];
      _scanDone = 0;
      _scanTotal = 0;
    });
    try {
      final peers = await LanSync.discover(
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _scanDone = done;
            _scanTotal = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _peers = peers;
        _scanning = false;
      });
      if (peers.isEmpty) {
        context.showToast('没找到可同步的设备（需要对方也开着同步服务）');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _scanning = false);
      context.showToast('扫描失败：$error', kind: ToastKind.error);
    }
  }

  Future<void> _pull(LanSyncPeer peer) async {
    setState(() => _busy = true);
    try {
      final count = await LanSync.pull(peer);
      if (!mounted) return;
      context.showToast('已从 ${peer.name} 同步 $count 个关注',
          kind: ToastKind.success);
      Navigator.of(context).maybePop();
    } catch (error) {
      if (!mounted) return;
      context.showToast('同步失败：$error', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /* ---------------------------------------------------------------- WebDAV */

  Future<void> _webdavUpload() async {
    final config = _readConfig();
    if (config == null) return;
    setState(() => _busy = true);
    try {
      await WebDavSync.saveConfig(config);
      await WebDavSync().upload(config);
      await WebDavSync.saveLastSync(DateTime.now().millisecondsSinceEpoch);
      if (!mounted) return;
      context.showToast('已上传到 WebDAV', kind: ToastKind.success);
      await _loadConfig();
    } catch (error) {
      if (!mounted) return;
      context.showToast('上传失败：$error', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _webdavDownload() async {
    final config = _readConfig();
    if (config == null) return;
    setState(() => _busy = true);
    try {
      await WebDavSync.saveConfig(config);
      final count = await WebDavSync().download(config);
      await WebDavSync.saveLastSync(DateTime.now().millisecondsSinceEpoch);
      if (!mounted) return;
      context.showToast('已从 WebDAV 同步 $count 个关注',
          kind: ToastKind.success);
      await _loadConfig();
    } catch (error) {
      if (!mounted) return;
      context.showToast('下载失败：$error', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  WebDavConfig? _readConfig() {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      context.showToast('请先填 WebDAV 地址', kind: ToastKind.error);
      return null;
    }
    return WebDavConfig(
      baseUrl: url,
      username: _userController.text.trim(),
      password: _passController.text,
    );
  }

  /* ------------------------------------------------------------------ UI */

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            TallySpace.lg, TallySpace.md, TallySpace.lg, TallySpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Text('数据同步', style: TallyType.pageTitle),
                const Spacer(),
                IconButton(
                  iconSize: 18,
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close,
                      color: TallyColors.textTertiary),
                ),
              ],
            ),
            const SizedBox(height: TallySpace.sm),
            // 模式切换
            Container(
              padding: const EdgeInsets.all(3),
              decoration: TallyDecor.inset,
              child: Row(
                children: [
                  _ModeTab(
                    label: '局域网',
                    selected: _lanMode,
                    onTap: () => setState(() => _lanMode = true),
                  ),
                  _ModeTab(
                    label: 'WebDAV',
                    selected: !_lanMode,
                    onTap: () => setState(() => _lanMode = false),
                  ),
                ],
              ),
            ),
            const SizedBox(height: TallySpace.md),
            if (_lanMode) _buildLan() else _buildWebDav(),
          ],
        ),
      ),
    );
  }

  Widget _buildLan() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '与 DTV 完全兼容（端口 $LanSync.port、token "${LanSync.defaultToken}"），'
          '可与 DTV 客户端互传关注列表。',
          style: TallyType.meta,
        ),
        const SizedBox(height: TallySpace.md),

        // 本机服务
        _SectionCard(
          title: '共享本机关注',
          trailing: SizedBox(
            height: 26,
            child: FilledButton(
              onPressed: _toggleServer,
              style: FilledButton.styleFrom(
                backgroundColor: _serverRunning
                    ? TallyColors.raised
                    : TallyColors.signalBlue,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: Text(
                _serverRunning ? '已开启' : '开启',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
          child: _serverRunning
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('其它设备可从这里拉取：',
                        style: TallyType.tiny),
                    const SizedBox(height: 4),
                    if (_serverUrls.isEmpty)
                      const Text('（没有检测到局域网 IP）',
                          style: TallyType.tiny)
                    else
                      for (final url in _serverUrls)
                        Text(url,
                            style: TallyType.tiny.copyWith(
                              fontFamily: 'monospace',
                            )),
                  ],
                )
              : const Text('开启后，其它设备（含 DTV）可以扫描并拉取你的关注列表',
                  style: TallyType.tiny),
        ),
        const SizedBox(height: TallySpace.sm),

        // 扫描对端
        _SectionCard(
          title: '从其它设备拉取',
          trailing: SizedBox(
            height: 26,
            child: FilledButton(
              onPressed: _scanning || _busy ? null : _scan,
              style: FilledButton.styleFrom(
                backgroundColor: TallyColors.signalBlue,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: Text(
                _scanning
                    ? (_scanTotal > 0 ? '$_scanDone/$_scanTotal' : '扫描中')
                    : '扫描',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
          child: _peers.isEmpty
              ? const Text('点「扫描」查找同一局域网内的设备',
                  style: TallyType.tiny)
              : Column(
                  children: [
                    for (final peer in _peers)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${peer.name}（${peer.host}）',
                          style: TallyType.subtitle.copyWith(
                            color: TallyColors.textPrimary,
                          ),
                        ),
                        subtitle: Text('${peer.follows} 个关注',
                            style: TallyType.tiny),
                        trailing: const Icon(Icons.download,
                            size: 16, color: TallyColors.signalBlue),
                        onTap: _busy ? null : () => _pull(peer),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildWebDav() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('支持坚果云 / Nextcloud 等 WebDAV 服务，可跨网络同步。',
            style: TallyType.meta),
        const SizedBox(height: TallySpace.md),
        _SyncField(
          controller: _urlController,
          label: '服务器地址',
          hint: 'https://dav.jianguoyun.com/dav/',
        ),
        const SizedBox(height: TallySpace.sm),
        _SyncField(
          controller: _userController,
          label: '账号',
          hint: '邮箱',
        ),
        const SizedBox(height: TallySpace.sm),
        _SyncField(
          controller: _passController,
          label: '密码 / 应用密码',
          hint: '',
          obscure: true,
        ),
        const SizedBox(height: TallySpace.md),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : _webdavDownload,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: TallyColors.hairline),
                ),
                child: const Text('下载并覆盖'),
              ),
            ),
            const SizedBox(width: TallySpace.sm),
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : _webdavUpload,
                style: FilledButton.styleFrom(
                  backgroundColor: TallyColors.signalBlue,
                ),
                child: const Text('上传本机'),
              ),
            ),
          ],
        ),
        if (_config != null && _config!.lastSyncAt > 0) ...[
          const SizedBox(height: TallySpace.sm),
          Text(
            '上次同步：${_formatTime(_config!.lastSyncAt)}',
            style: TallyType.tiny,
          ),
        ],
      ],
    );
  }

  String _formatTime(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }
}

class _ModeTab extends StatelessWidget {
  const _ModeTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: TallyDuration.fast,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? TallyColors.raised : Colors.transparent,
            borderRadius: BorderRadius.circular(TallyRadius.pill),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color:
                  selected ? TallyColors.textPrimary : TallyColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(TallySpace.md),
      decoration: TallyDecor.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title, style: TallyType.sectionTitle),
              const Spacer(),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: TallySpace.sm),
          child,
        ],
      ),
    );
  }
}

class _SyncField extends StatelessWidget {
  const _SyncField({
    required this.controller,
    required this.label,
    required this.hint,
    this.obscure = false,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: TallyType.subtitle.copyWith(color: TallyColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TallyType.meta,
        hintText: hint.isEmpty ? null : hint,
        hintStyle: TallyType.tiny,
        isDense: true,
        filled: true,
        fillColor: TallyColors.inset,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TallyRadius.card),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
