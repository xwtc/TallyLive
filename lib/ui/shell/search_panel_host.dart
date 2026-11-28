import 'package:flutter/material.dart';
import 'package:tallylive/ui/theme.dart';

/// 搜索浮层的挂载请求。
class SearchPanelRequest {
  const SearchPanelRequest({required this.anchor, required this.builder});

  /// 输入框的**全局矩形**，用来定位浮层。
  final Rect anchor;

  /// 浮层内容由发起方（InlineSearch）自己构建，这样它的状态都还能用。
  final WidgetBuilder builder;
}

/// 搜索浮层的全局控制器。
///
/// **为什么不用 OverlayEntry**：之前用根 Overlay 承载浮层，
/// 结果浮层能显示但点击不进直播间（祖先链路里少了 Material，
/// 手势竞争也不直观）。现在改为把浮层挂进 shell 自己的 Stack：
/// - 层级明确（在 PlayerLayer 之上，模态框之下）
/// - 与其它层共享同一份 Material/Theme/MediaQuery
/// - 点击命中链路短，不会被子树外的 scrim 抢走
class SearchPanelController {
  SearchPanelController._();

  static final SearchPanelController instance = SearchPanelController._();

  final ValueNotifier<SearchPanelRequest?> state = ValueNotifier(null);

  void show({required Rect anchor, required WidgetBuilder builder}) {
    state.value = SearchPanelRequest(anchor: anchor, builder: builder);
  }

  /// 只更新锚点（输入时窗口可能没动，但换行/滚动后需要重算）。
  void refresh() {
    final current = state.value;
    if (current == null) return;
    state.value = SearchPanelRequest(
      anchor: current.anchor,
      builder: current.builder,
    );
  }

  void hide() {
    if (state.value != null) state.value = null;
  }
}

/// 搜索浮层的宿主：放在 shell 根 Stack 的**最后一个子节点**。
class SearchPanelHost extends StatelessWidget {
  const SearchPanelHost({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SearchPanelRequest?>(
      valueListenable: SearchPanelController.instance.state,
      builder: (context, request, _) {
        if (request == null) return const SizedBox.shrink();
        return _PanelLayer(request: request);
      },
    );
  }
}

class _PanelLayer extends StatelessWidget {
  const _PanelLayer({required this.request});

  final SearchPanelRequest request;

  @override
  Widget build(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    final size = MediaQuery.sizeOf(context);
    // 全局矩形 → 本层局部坐标（宿主铺满窗口，通常就是原值）
    final origin = box == null
        ? request.anchor.topLeft
        : box.globalToLocal(request.anchor.topLeft);

    const panelWidth = 384.0;
    final left = (origin.dx + request.anchor.width - panelWidth)
        .clamp(8.0, (size.width - panelWidth - 8).clamp(8.0, double.infinity));
    final top = origin.dy + request.anchor.height + 6;

    return Stack(
      children: [
        // 点空白处关闭
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: SearchPanelController.instance.hide,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: panelWidth,
          child: Material(
            type: MaterialType.transparency,
            child: request.builder(context),
          ),
        ),
      ],
    );
  }
}

/// 搜索浮层的外壳（统一边框/圆角/阴影，内容由调用方给）。
class SearchPanelSurface extends StatelessWidget {
  const SearchPanelSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 420),
      decoration: BoxDecoration(
        color: TallyColors.raised,
        borderRadius: BorderRadius.circular(TallyRadius.card),
        border: Border.all(color: TallyColors.hairline),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}
