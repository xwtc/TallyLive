import 'package:flutter/material.dart';
import 'package:tallylive/core/feed_ui.dart';
import 'package:tallylive/core/follows.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/core/player_session.dart';
import 'package:tallylive/ui/components/atoms.dart';
import 'package:tallylive/ui/components/ring_progress.dart';
import 'package:tallylive/ui/components/toast.dart';
import 'package:tallylive/ui/components/login_sheet.dart';
import 'package:tallylive/ui/theme.dart';

/// 左侧关注栏（对齐 DTV 的 FollowsList + Sidebar）。
///
/// 头部工具组（展开态）：`刷新 · 新建分组 · 展开全部 · 收起侧栏`
/// 折叠态：`展开侧栏 · 展开全部主播`（图标竖排）
///
/// 在线状态：头像右下角 12px 圆点，**在播绿 `#10b981`、未播灰 `#475569`**
/// （颜色取自 DTV 的 `.liveDotOn` / `.liveDotOff`）。
class Sidebar extends StatefulWidget {
  const Sidebar({super.key});

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  bool _collapsed = false;

  /// 关注栏内搜索。
  final TextEditingController _search = TextEditingController();
  String _keyword = '';

  /// 刷新进度（已完成 / 总数）。
  bool _refreshing = false;
  int _refreshDone = 0;
  int _refreshTotal = 0;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = _collapsed ? TallySize.sidebarCollapsed : TallySize.sidebar;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      width: width,
      color: TallyColors.surface,
      child: ListenableBuilder(
        listenable: FollowStore.instance,
        builder: (context, _) {
          final store = FollowStore.instance;
          final keyword = _keyword.trim().toLowerCase();
          final rooms = store.sortedRooms
              .where((room) =>
                  keyword.isEmpty ||
                  room.nickname.toLowerCase().contains(keyword) ||
                  room.title.toLowerCase().contains(keyword))
              .toList();
          return Column(
            children: [
              _buildHeader(store),
              if (!_collapsed) _buildSearch(),
              const Divider(height: 1),
              Expanded(
                child: rooms.isEmpty ? _buildEmpty() : _buildList(rooms),
              ),
            ],
          );
        },
      ),
    );
  }

  /* ------------------------------------------------------------------ 头部 */

  Widget _buildHeader(FollowStore store) {
    final liveCount = store.sortedRooms.where((room) => room.isLive).length;
    final total = store.rooms.length;

    if (_collapsed) {
      // 折叠态：竖排图标（对齐 DTV 的 collapsedHeader）
      return Column(
        children: [
          const SizedBox(height: TallySpace.sm),
          _SideAction(
            icon: Icons.chevron_right,
            tooltip: '展开侧栏',
            onTap: () => setState(() => _collapsed = false),
          ),
          _SideAction(
            icon: Icons.unfold_more,
            tooltip: '展开全部主播',
            onTap: () => setState(() => _collapsed = false),
          ),
          const Divider(height: 1),
        ],
      );
    }

    return SizedBox(
      height: 48,
      child: Row(
        children: [
          const SizedBox(width: TallySpace.md),
          const Icon(Icons.people_outline,
              size: 16, color: TallyColors.textSecondary),
          const SizedBox(width: TallySpace.sm),
          Text('关注', style: TallyType.sectionTitle),
          const SizedBox(width: TallySpace.sm),
          Text('$liveCount/$total',
              style: TallyType.numberSmall.copyWith(
                color: TallyColors.textTertiary,
              )),
          const Spacer(),
          // 刷新关注状态：转圈图标 + 外圈进度环（对齐 DTV 的 RingProgress）
          _RefreshAction(
            refreshing: _refreshing,
            progress: _refreshTotal > 0 ? _refreshDone / _refreshTotal : 0,
            done: _refreshDone,
            total: _refreshTotal,
            onTap: _refreshing ? null : _refreshStatuses,
          ),
          _SideAction(
            icon: Icons.create_new_folder_outlined,
            tooltip: '新建分组',
            onTap: _createGroup,
          ),
          _SideAction(
            icon: Icons.unfold_more,
            tooltip: '展开全部主播',
            onTap: () {},
          ),
          _SideAction(
            icon: Icons.chevron_left,
            tooltip: '收起侧栏',
            onTap: () => setState(() => _collapsed = true),
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }

  /// 关注栏内搜索框（窄、矮，和侧栏宽度匹配）。
  Widget _buildSearch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          TallySpace.sm, 0, TallySpace.sm, TallySpace.sm),
      child: SizedBox(
        height: 32,
        child: TextField(
          controller: _search,
          onChanged: (value) => setState(() => _keyword = value),
          style: TallyType.subtitle.copyWith(color: TallyColors.textPrimary),
          decoration: InputDecoration(
            isDense: true,
            hintText: '搜索关注',
            hintStyle: TallyType.meta,
            prefixIcon: const Icon(Icons.search,
                size: 15, color: TallyColors.textTertiary),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 28, minHeight: 28),
            filled: true,
            fillColor: TallyColors.inset,
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(TallyRadius.pill),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }

  /* ------------------------------------------------------------------ 列表 */

  Widget _buildEmpty() {
    if (_collapsed) {
      return const Center(
        child: Icon(Icons.star_border, size: 20, color: TallyColors.textTertiary),
      );
    }
    return const Padding(
      padding: EdgeInsets.all(TallySpace.md),
      child: Align(
        alignment: Alignment.topCenter,
        child: Text(
          '还没有关注\n在直播列表里右键卡片即可关注',
          textAlign: TextAlign.center,
          style: TallyType.meta,
        ),
      ),
    );
  }

  Widget _buildList(List<FollowRoom> rooms) {
    if (_collapsed) {
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: TallySpace.sm),
        itemCount: rooms.length,
        itemBuilder: (context, index) => _SidebarTile(
          room: rooms[index],
          collapsed: true,
          onTap: () => _open(rooms[index]),
          onContextMenu: () => _showMenu(context, rooms[index]),
        ),
      );
    }

    final groups = FollowStore.instance.groups;
    // 未分组房间 + 各分组（分组作为小标题出现在列表里）
    final ungrouped = rooms.where((room) => room.groupId.isEmpty).toList();

    final entries = <Widget>[];
    if (ungrouped.isNotEmpty) {
      if (groups.isNotEmpty) {
        entries.add(_groupHeader('未分组', ungrouped.length));
      }
      for (final room in ungrouped) {
        entries.add(KeyedSubtree(key: ValueKey(room.key), child: _buildTile(room)));
      }
    }
    for (final group in groups) {
      final items = rooms.where((room) => room.groupId == group.id).toList();
      entries.add(_groupHeader(group.name, items.length, groupId: group.id));
      for (final room in items) {
        entries.add(KeyedSubtree(key: ValueKey(room.key), child: _buildTile(room)));
      }
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: TallySpace.sm),
      children: entries,
    );
  }

  Widget _buildTile(FollowRoom room) {
    return _SidebarTile(
      room: room,
      collapsed: false,
      onTap: () => _open(room),
      onContextMenu: () => _showMenu(context, room),
    );
  }

  Widget _groupHeader(String name, int count, {String groupId = ''}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          TallySpace.md, TallySpace.sm, TallySpace.sm, 2),
      child: Row(
        children: [
          Icon(
            groupId.isEmpty ? Icons.folder_open : Icons.folder,
            size: 12,
            color: TallyColors.textTertiary,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TallyType.tiny.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text('$count', style: TallyType.tiny),
          if (groupId.isNotEmpty)
            _MiniAction(
              icon: Icons.close,
              tooltip: '删除分组',
              onTap: () => FollowStore.instance.removeGroup(groupId),
            ),
        ],
      ),
    );
  }

  /* ---------------------------------------------------------------- 动作 */

  /// 刷新关注列表的直播状态（并发刷新，带进度）。
  Future<void> _refreshStatuses() async {
    final rooms = FollowStore.instance.rooms;
    if (rooms.isEmpty) {
      _toast('还没有关注任何主播');
      return;
    }
    setState(() {
      _refreshing = true;
      _refreshDone = 0;
      _refreshTotal = rooms.length;
    });

    var updated = 0;
    var failed = 0;
    for (final room in rooms) {
      try {
        final info = await sharedRepository.fetchRoomInfo(
          platform: room.platform,
          roomId: room.roomId,
        );
        await FollowStore.instance.updateStatus(
          room.platform,
          room.roomId,
          isLive: info.isLive,
          viewers: info.online,
          title: info.title.isEmpty ? null : info.title,
        );
        updated++;
      } catch (_) {
        failed++;
      }
      if (!mounted) return;
      setState(() => _refreshDone++);
    }

    if (!mounted) return;
    setState(() => _refreshing = false);
    if (failed == 0) {
      _toast('已刷新 $updated 位主播');
    } else if (updated > 0) {
      _toast('已刷新 $updated 位，$failed 位暂时无法获取状态');
    } else {
      _toast('刷新失败，请稍后重试', kind: ToastKind.error);
    }
  }

  /// 新建分组：弹输入框，写进 FollowStore。
  Future<void> _createGroup() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: TallyColors.raised,
        title: const Text('新建分组', style: TallyType.nickname),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TallyType.subtitle.copyWith(color: TallyColors.textPrimary),
          decoration: InputDecoration(
            hintText: '分组名称',
            hintStyle: TallyType.meta,
            filled: true,
            fillColor: TallyColors.inset,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(TallyRadius.card),
              borderSide: BorderSide.none,
            ),
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    await FollowStore.instance.addGroup(name);
    _toast('已创建分组「${name.trim()}」');
  }

  void _open(FollowRoom room) {
    PlayerSession.instance.open(PlayerTarget(
      platform: room.platform,
      roomId: room.roomId,
      title: room.title.isEmpty ? room.nickname : room.title,
    ));
  }

  Future<void> _showMenu(BuildContext context, FollowRoom room) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final position = box.localToGlobal(Offset.zero);
    final choice = await showMenu<String>(
      context: context,
      color: TallyColors.raised,
      position: RelativeRect.fromLTRB(
        position.dx + 40,
        position.dy + 20,
        position.dx + 240,
        position.dy + 200,
      ),
      items: [
        const PopupMenuItem(value: 'copy', child: Text('复制房间号')),
        const PopupMenuItem(value: 'unfollow', child: Text('取消关注')),
        if (FollowStore.instance.groups.isNotEmpty)
          PopupMenuItem(
            value: 'group',
            child: Text(room.groupId.isEmpty ? '移动到分组…' : '更换分组…'),
          ),
      ],
    );
    if (choice == null) return;
    switch (choice) {
      case 'copy':
        // ignore: use_build_context_synchronously
        _toast('房间号：${room.roomId}');
      case 'unfollow':
        await FollowStore.instance.remove(room);
      case 'group':
        if (!mounted) return;
        await _pickGroup(room);
    }
  }

  /// 选择目标分组。
  Future<void> _pickGroup(FollowRoom room) async {
    final groups = FollowStore.instance.groups;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: TallyColors.raised,
        title: const Text('移动到分组', style: TallyType.nickname),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(''),
            child: const Text('未分组'),
          ),
          for (final group in groups)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(group.id),
              child: Text(group.name),
            ),
        ],
      ),
    );
    if (choice == null) return;
    await FollowStore.instance.moveToGroup(room.key, choice);
  }

  void _toast(String message, {ToastKind kind = ToastKind.info}) {
    if (!mounted) return;
    // 右下角小卡片，不用 SnackBar（后者会横跨整个底部、挡住控件条）
    context.showToast(message, kind: kind);
  }
}

/// 侧栏头部的小图标按钮（28×28，对齐 DTV 的 `.actionBtn`）。
class _SideAction extends StatefulWidget {
  const _SideAction({
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.busy = false,
  });

  final IconData? icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool busy;

  @override
  State<_SideAction> createState() => _SideActionState();
}

class _SideActionState extends State<_SideAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: widget.onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 28,
            height: 28,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: _hovered && widget.onTap != null
                  ? TallyColors.raised
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: widget.busy
                ? const Padding(
                    padding: EdgeInsets.all(7),
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: TallyColors.signalBlue,
                    ),
                  )
                : Icon(
                    widget.icon,
                    size: 15,
                    color: _hovered && widget.onTap != null
                        ? TallyColors.textPrimary
                        : TallyColors.textTertiary,
                  ),
          ),
        ),
      ),
    );
  }
}

/// 刷新按钮：刷新中显示「自转图标 + 外圈进度环」。
///
/// 对齐 DTV：图标照常转圈，圆环的弧长表示「已刷新 / 总数」。
class _RefreshAction extends StatefulWidget {
  const _RefreshAction({
    required this.refreshing,
    required this.progress,
    required this.done,
    required this.total,
    required this.onTap,
  });

  final bool refreshing;
  final double progress;
  final int done;
  final int total;
  final VoidCallback? onTap;

  @override
  State<_RefreshAction> createState() => _RefreshActionState();
}

class _RefreshActionState extends State<_RefreshAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tooltip = widget.refreshing
        ? (widget.total > 0
            ? '正在刷新 ${widget.done}/${widget.total}'
            : '正在刷新…')
        : '刷新关注状态';

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: widget.onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 28,
            height: 28,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: _hovered && widget.onTap != null
                  ? TallyColors.raised
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 外圈进度环（只在刷新中或已有进度时画）
                if (widget.refreshing || widget.progress > 0)
                  RingProgress(
                    value: widget.progress,
                    size: 26,
                    stroke: 2,
                  ),
                widget.refreshing
                    ? const SpinningIcon(
                        icon: Icons.rotate_right,
                        size: 13,
                        color: TallyColors.signalBlue,
                      )
                    : Icon(
                        Icons.refresh,
                        size: 15,
                        color: _hovered && widget.onTap != null
                            ? TallyColors.textPrimary
                            : TallyColors.textTertiary,
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 关注栏条目。
class _SidebarTile extends StatefulWidget {
  const _SidebarTile({
    required this.room,
    required this.collapsed,
    required this.onTap,
    required this.onContextMenu,
  });

  final FollowRoom room;
  final bool collapsed;
  final VoidCallback onTap;
  final VoidCallback onContextMenu;

  @override
  State<_SidebarTile> createState() => _SidebarTileState();
}

class _SidebarTileState extends State<_SidebarTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    final active = PlayerSession.instance.target?.key == room.key;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTap: widget.onContextMenu,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          height: 52,
          margin: const EdgeInsets.symmetric(
              horizontal: TallySpace.sm, vertical: 1),
          padding: EdgeInsets.symmetric(
              horizontal: widget.collapsed ? 0 : TallySpace.sm),
          decoration: BoxDecoration(
            color: active
                ? TallyColors.raised
                : (_hovered ? TallyColors.raised : Colors.transparent),
            borderRadius: BorderRadius.circular(TallyRadius.card),
            border: Border.all(
              color: active ? TallyColors.signalBlue : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisAlignment: widget.collapsed
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AvatarBox(
                    url: room.avatar,
                    fallbackText: room.nickname,
                    size: 30,
                  ),
                  // 在线状态点：在播绿、未播灰（12px，带深色描边压在头像上）
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: _LiveDot(on: room.isLive),
                  ),
                ],
              ),
              if (!widget.collapsed) ...[
                const SizedBox(width: TallySpace.sm),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        room.nickname.isEmpty ? room.roomId : room.nickname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: room.isLive
                              ? TallyColors.textPrimary
                              : TallyColors.textSecondary,
                        ),
                      ),
                      if (room.title.isNotEmpty)
                        Text(
                          room.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TallyType.meta,
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 在线状态圆点（对齐 DTV 的 `.liveDotOn` / `.liveDotOff`）。
class _LiveDot extends StatelessWidget {
  const _LiveDot({required this.on});

  final bool on;

  static const Color _onColor = Color(0xFF10B981);
  static const Color _offColor = Color(0xFF475569);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? _onColor : _offColor,
        // 压在头像上要描一圈底色，否则边界糊在一起
        border: Border.all(color: TallyColors.surface, width: 2),
      ),
    );
  }
}

/// 分组标题右侧的小图标（删除分组等）。
class _MiniAction extends StatelessWidget {
  const _MiniAction({
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
          child: SizedBox(
            width: 18,
            height: 18,
            child: Icon(icon, size: 12, color: TallyColors.textTertiary),
          ),
        ),
      ),
    );
  }
}