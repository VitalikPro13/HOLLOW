import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_chip_tabs.dart';
import 'package:hollow/src/ui/components/hollow_count_badge.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';

/// The sections of a whole surface (the expression picker's Emoji, GIFs and
/// Stickers; the Friends manager's Friends, Requests and Add friend), as equal
/// tabs across its top with an accent bar under the open one.
///
/// Only where the row IS the surface's header. Anything that filters or
/// chooses inside content stays [HollowChipTabs]: a chip row under these tabs
/// then reads as a second level instead of a second copy of the first.
/// Left and right arrows move between tabs (Home and End to the ends).
class HollowTabBar<T> extends StatefulWidget {
  final List<HollowChipTab<T>> tabs;
  final T selected;
  final ValueChanged<T> onSelected;

  /// Phone height (48) instead of desktop (40).
  final bool touch;

  /// Overrides the height, for a header that must also centre a control
  /// beside the tabs with even margins.
  final double? height;

  const HollowTabBar({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onSelected,
    this.touch = false,
    this.height,
  });

  @override
  State<HollowTabBar<T>> createState() => _HollowTabBarState<T>();
}

class _HollowTabBarState<T> extends State<HollowTabBar<T>> {
  final List<FocusNode> _nodes = [];

  @override
  void dispose() {
    for (final node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _syncNodes() {
    while (_nodes.length < widget.tabs.length) {
      _nodes.add(FocusNode());
    }
    while (_nodes.length > widget.tabs.length) {
      _nodes.removeLast().dispose();
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final count = widget.tabs.length;
    if (count == 0) return KeyEventResult.ignored;
    final current = widget.tabs.indexWhere((t) => t.value == widget.selected);
    final key = event.logicalKey;
    final int next;
    if (key == LogicalKeyboardKey.arrowRight) {
      next = (current + 1) % count;
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      next = (current - 1 + count) % count;
    } else if (key == LogicalKeyboardKey.home) {
      next = 0;
    } else if (key == LogicalKeyboardKey.end) {
      next = count - 1;
    } else {
      return KeyEventResult.ignored;
    }
    if (next != current) widget.onSelected(widget.tabs[next].value);
    _nodes[next].requestFocus();
    return KeyEventResult.handled;
  }

  Widget _tab(HollowTheme hollow, int i) {
    final tab = widget.tabs[i];
    final selected = tab.value == widget.selected;
    final count = tab.count;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: HollowPressable(
        semanticLabel: [
          tab.label,
          ?tab.hint,
          if (count != null && count > 0) '$count waiting',
        ].join(', '),
        focusNode: _nodes[i],
        onTap: () => widget.onSelected(tab.value),
        child: Stack(
          children: [
            Center(
              child: ExcludeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        tab.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HollowTypography.label.copyWith(
                          color: selected
                              ? hollow.textPrimary
                              : hollow.textSecondary,
                        ),
                      ),
                    ),
                    if (tab.hint != null) ...[
                      const SizedBox(width: HollowSpacing.xs),
                      Text(
                        tab.hint!,
                        style: HollowTypography.caption
                            .copyWith(color: hollow.textTertiary),
                      ),
                    ],
                    if (count != null && count > 0) ...[
                      const SizedBox(width: HollowSpacing.xs),
                      HollowCountBadge(count: count),
                    ],
                  ],
                ),
              ),
            ),
            if (selected)
              Positioned(
                left: HollowSpacing.lg,
                right: HollowSpacing.lg,
                bottom: 0,
                height: 2,
                child: ColoredBox(color: hollow.accent),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _syncNodes();
    final hollow = HollowTheme.of(context);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: SizedBox(
        height: widget.height ?? (widget.touch ? 48 : 40),
        child: Row(
          children: [
            for (var i = 0; i < widget.tabs.length; i++)
              Expanded(child: _tab(hollow, i)),
          ],
        ),
      ),
    );
  }
}
