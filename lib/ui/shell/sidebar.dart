import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tallylive/core/feed_ui.dart';
import 'package:tallylive/core/follows.dart';
import 'package:tallylive/core/player_session.dart';
import 'package:tallylive/ui/components/atoms.dart';
import 'package:tallylive/ui/components/login_sheet.dart';
import 'package:tallylive/ui/theme.dart';

/// 左侧关注栏。
///
/// 对齐 DTV 的 Sidebar：**播放时依然常驻**，可以在播放中直接换直播间
/// （这是把播放页从"新页面"改成"壳内一层"的核心理由）。
///
/// 能力（第一版）：
/// - 收起/展开（240px ↔ 72px）
/// - 关注列表按"在播优先"排序，可拖拽排序
/// - 点击换台；右键菜单：取消关注 / 复制房间号
/// - 空态引导
class Sidebar extends StatefulWidget {
  const Sidebar({super.key});

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  bool _collapsed = false;

  /// 关注栏内搜索（对齐 DTV 的 FollowsList 搜索）。
  final TextEditingController _search = TextEditingController();
  String _keyword = '';

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
              _buildHeader(store.sortedRooms.where((r) => r.isLive).length,
                  store.rooms.length),
              if (!_collapsed) _buildSearch(),
              const Divider(height: 1),
              Expanded(
                child: rooms.isEmpty
                    ? _buildEmpty()
                    : _buildList(rooms),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 打开登录弹层。
  Future<void> _openLogin() async {
    final platform = FeedUi.instance.platform ??
        sharedRepository.supportedPlatforms.first;
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

  Widget _buildHeader(int liveCount, int totalCount) {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          const SizedBox(width: TallySpace.md),
          if (!_collapsed) ...[
            const Text('关注', style: TallyType.sectionTitle),
            const SizedBox(width: TallySpace.sm),
            Text('$liveCount/$totalCount', style: TallyType.numberSmall.copyWith(
              color: TallyColors.textTertiary,
            )),
          ],
          const Spacer(),
          // 账号登录入口（Cookie 登录，见 UI-DESIGN §4.4.1）
          if (!_collapsed)
            IconButton(
              tooltip: '账号登录',
              iconSize: 15,
              onPressed: _openLogin,
              icon: const Icon(Icons.person_outline,
                  color: TallyColors.textTertiary),
            ),
          IconButton(
            tooltip: _collapsed ? '展开关注栏' : '收起关注栏',
            iconSize: 16,
            onPressed: () => setState(() => _collapsed = !_collapsed),
            icon: Icon(
              _collapsed ? Icons.chevron_right : Icons.chevron_left,
              color: TallyColors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

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
      // 收起态：只留头像，仍然可点换台
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: TallySpace.sm),
        itemCount: rooms.length,
        itemBuilder: (context, index) {
          final room = rooms[index];
          return _SidebarTile(
            room: room,
            collapsed: true,
            onTap: () => _open(room),
            onContextMenu: () => _showMenu(context, room),
          );
        },
      );
    }

    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(vertical: TallySpace.sm),
      buildDefaultDragHandles: false,
      itemCount: rooms.length,
      onReorder: (oldIndex, newIndex) {
        FollowStore.instance.reorder(oldIndex, newIndex);
      },
      itemBuilder: (context, index) {
        final room = rooms[index];
        return ReorderableDragStartListener(
          key: ValueKey(room.key),
          index: index,
          child: _SidebarTile(
            room: room,
            collapsed: false,
            onTap: () => _open(room),
            onContextMenu: () => _showMenu(context, room),
          ),
        );
      },
    );
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
      ],
    );
    if (choice == null) return;
    if (choice == 'copy') {
      await Clipboard.setData(ClipboardData(text: room.roomId));
    } else if (choice == 'unfollow') {
      await FollowStore.instance.remove(room);
    }
  }
}

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
                  if (room.isLive)
                    const Positioned(
                      right: -1,
                      bottom: -1,
                      child: _LiveBadgeDot(),
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

/// 头像角上的直播小点（带深色描边，压在头像上也看得清）。
class _LiveBadgeDot extends StatelessWidget {
  const _LiveBadgeDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: TallyColors.tallyRed,
        border: Border.all(color: TallyColors.surface, width: 1.6),
      ),
    );
  }
}
