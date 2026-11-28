import 'package:flutter/material.dart';
import 'package:tallylive/core/feed_ui.dart';
import 'package:tallylive/core/follows.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/core/player_session.dart';
import 'package:tallylive/ui/components/atoms.dart';
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
          // 刷新关注状态（转圈 + 进度环）
          _SideAction(
            icon: _refreshing ? null : Icons.refresh,
            busy: _refreshing,
            tooltip: _refreshing
                ? (_refreshTotal > 0
                    ? '正在刷新 $_refreshDone/$_refreshTotal'
                    : '正在刷新…')
                : '刷新关注状态',
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

    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(vertical: TallySpace.sm),
      buildDefaultDragHandles: false,
      itemCount: rooms.length,
      onReorder: (oldIndex, newIndex) {
        FollowStore.instance.reorder(oldIndex, newIndex);
      },
      itemBuilder: (context, index) => ReorderableDragStartListener(
        key: ValueKey(rooms[index].key),
        index: index,
        child: _SidebarTile(
          room: rooms[index],
          collapsed: false,
          onTap: () => _open(rooms[index]),
          onContextMenu: () => _showMenu(context, rooms[index]),
        ),
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
      _toast('刷新失败，请稍后重试');
    }
  }

  Future<void> _createGroup() async {
    // 分组功能未实现（数据模型只有单一关注列表），先明确提示
    _toast('分组功能待接入');
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
      items: const [
        PopupMenuItem(value: 'copy', child: Text('复制房间号')),
        PopupMenuItem(value: 'unfollow', child: Text('取消关注')),
        PopupMenuItem(value: 'login', child: Text('账号登录')),
      ],
    );
    if (choice == null) return;
    switch (choice) {
      case 'copy':
        // ignore: use_build_context_synchronously
        _toast('房间号：${room.roomId}');
      case 'unfollow':
        await FollowStore.instance.remove(room);
      case 'login':
        if (!mounted) return;
        await _openLogin();
    }
  }

  /// 账号登录（只对 B站/斗鱼；其它平台没有登录体系）。
  Future<void> _openLogin() async {
    final platform = FeedUi.instance.platform ??
        sharedRepository.supportedPlatforms.first;
    if (platform != LivePlatform.bilibili && platform != LivePlatform.douyu) {
      _toast('${platform.label} 没有登录体系');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: TallyColors.raised,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (_) => LoginSheet(platform: platform),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
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
