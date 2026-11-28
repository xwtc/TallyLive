import 'package:flutter/material.dart';
import 'package:tallylive/core/settings.dart';
import 'package:tallylive/ui/components/toast.dart';
import 'package:tallylive/ui/theme.dart';

/// 弹幕屏蔽面板（**对齐 DTV 的 `DanmuBlockControl`**）。
///
/// DTV 的交互（`DanmuBlockControl.tsx` + `.module.css`）：
/// ```
/// 顶部   弹幕屏蔽                    [清空] [×]
/// 输入   输入关键词，回车添加        [+ 添加]
/// 列表   关键词标签（点 × 删除）
/// 空态   还没有屏蔽词，含关键词的弹幕会被隐藏
/// 说明   关键词对所有平台生效
/// ```
/// 上限 40 个关键词、单条 40 字（DTV 的 `DANMU_BLOCK_MAX_KEYWORDS` / `..._LENGTH`）。
class BlockWordsSheet extends StatefulWidget {
  const BlockWordsSheet({super.key});

  @override
  State<BlockWordsSheet> createState() => _BlockWordsSheetState();
}

class _BlockWordsSheetState extends State<BlockWordsSheet> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final raw = _controller.text;
    if (raw.trim().isEmpty) return;
    final store = AppSettings.instance;
    if (store.danmakuBlockedList.length >= AppSettings.maxBlockedKeywords) {
      if (!mounted) return;
      context.showToast(
        '最多 ${AppSettings.maxBlockedKeywords} 个屏蔽词',
        kind: ToastKind.error,
      );
      return;
    }
    final wasDuplicate = store.danmakuBlockedList.contains(raw.trim());
    final added = await store.addBlockedWord(raw);
    if (!mounted) return;
    _controller.clear();
    _focus.requestFocus();
    if (!added && wasDuplicate) {
      context.showToast('「${raw.trim()}」已在屏蔽列表里');
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSettings.instance,
      builder: (context, _) {
        final words = AppSettings.instance.danmakuBlockedList;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                TallySpace.lg, TallySpace.md, TallySpace.lg, TallySpace.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(words),
                const SizedBox(height: TallySpace.md),
                _buildInput(),
                const SizedBox(height: TallySpace.md),
                if (words.isEmpty) _buildEmpty() else _buildChips(words),
                const SizedBox(height: TallySpace.md),
                Text('关键词对所有平台生效', style: TallyType.meta),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(List<String> words) {
    return Row(
      children: [
        const Text('弹幕屏蔽', style: TallyType.pageTitle),
        const Spacer(),
        // 「清空」：有内容才可点，与 DTV 一致
        TextButton(
          onPressed: words.isEmpty
              ? null
              : () async {
                  await AppSettings.instance.clearBlockedWords();
                  if (!mounted) return;
                  setState(() {});
                  context.showToast('已清空屏蔽词');
                },
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 28),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('清空', style: TextStyle(fontSize: 12)),
        ),
        IconButton(
          iconSize: 18,
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.close, color: TallyColors.textTertiary),
        ),
      ],
    );
  }

  Widget _buildInput() {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 38,
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              // 点面板别的地方不希望失焦，回车才提交
              onTapOutside: (_) {},
              onSubmitted: (_) => _add(),
              style: TallyType.subtitle.copyWith(
                color: TallyColors.textPrimary,
                decoration: TextDecoration.none,
              ),
              decoration: InputDecoration(
                isDense: true,
                hintText: '输入关键词，回车添加',
                hintStyle: TallyType.subtitle.copyWith(
                  color: TallyColors.textTertiary,
                ),
                filled: true,
                fillColor: TallyColors.inset,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(TallyRadius.card),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: TallySpace.sm),
        SizedBox(
          height: 38,
          child: FilledButton.icon(
            onPressed: _add,
            style: FilledButton.styleFrom(
              backgroundColor: TallyColors.raised,
              foregroundColor: TallyColors.textPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('添加', style: TextStyle(fontSize: 13)),
          ),
        ),
      ],
    );
  }

  Widget _buildEmpty() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        '还没有屏蔽词，含关键词的弹幕会被隐藏',
        style: TallyType.meta.copyWith(height: 1.4),
      ),
    );
  }

  Widget _buildChips(List<String> words) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 260),
      child: SingleChildScrollView(
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final word in words)
              _KeywordChip(
                word: word,
                onRemove: () async {
                  await AppSettings.instance.removeBlockedWord(word);
                  if (!mounted) return;
                  setState(() {});
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// 一个可删除的关键词标签。
class _KeywordChip extends StatefulWidget {
  const _KeywordChip({required this.word, required this.onRemove});

  final String word;
  final VoidCallback onRemove;

  @override
  State<_KeywordChip> createState() => _KeywordChipState();
}

class _KeywordChipState extends State<_KeywordChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onRemove,
        child: AnimatedContainer(
          duration: TallyDuration.fast,
          padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
          decoration: BoxDecoration(
            color: _hovered
                ? TallyColors.tallyRed.withValues(alpha: 0.14)
                : TallyColors.inset,
            borderRadius: BorderRadius.circular(TallyRadius.pill),
            border: Border.all(
              color: _hovered ? TallyColors.tallyRed : TallyColors.hairline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.word,
                style: TextStyle(
                  fontSize: 12,
                  color: _hovered
                      ? TallyColors.tallyRed
                      : TallyColors.textSecondary,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.close,
                size: 12,
                color: _hovered
                    ? TallyColors.tallyRed
                    : TallyColors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
