import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';

/// One tab of a [HollowChipTabs].
class HollowChipTab<T> {
  final T value;
  final String label;

  /// A quiet total after the label ("12" friends).
  final String? hint;

  /// Something waiting on the person (requests to answer), as a count badge.
  final int? count;

  final IconData? icon;

  const HollowChipTab({
    required this.value,
    required this.label,
    this.hint,
    this.count,
    this.icon,
  });
}

/// Every tab row, in a dialog, a page or a place header: a row of
/// [HollowChip]s, 8 apart, one selected. Left and right arrows move between
/// them (Home and End to the ends), selecting as they go.
///
/// [expand] gives the tabs equal widths across the row, for a phone. Otherwise
/// the row wraps rather than overflow at a large text size.
class HollowChipTabs<T> extends StatefulWidget {
  final List<HollowChipTab<T>> tabs;
  final T selected;
  final ValueChanged<T> onSelected;
  final bool expand;

  const HollowChipTabs({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onSelected,
    this.expand = false,
  });

  @override
  State<HollowChipTabs<T>> createState() => _HollowChipTabsState<T>();
}

class _HollowChipTabsState<T> extends State<HollowChipTabs<T>> {
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

  Widget _chip(int i) {
    final tab = widget.tabs[i];
    final selected = tab.value == widget.selected;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: HollowChip(
        label: tab.label,
        hint: tab.hint,
        count: tab.count,
        icon: tab.icon,
        selected: selected,
        expand: widget.expand,
        focusNode: _nodes[i],
        onTap: () => widget.onSelected(tab.value),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _syncNodes();
    final Widget row;
    if (widget.expand) {
      row = Row(
        children: [
          for (var i = 0; i < widget.tabs.length; i++) ...[
            if (i > 0) const SizedBox(width: HollowSpacing.sm),
            Expanded(child: _chip(i)),
          ],
        ],
      );
    } else {
      row = Wrap(
        spacing: HollowSpacing.sm,
        runSpacing: HollowSpacing.sm,
        children: [
          for (var i = 0; i < widget.tabs.length; i++) _chip(i),
        ],
      );
    }
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: row,
    );
  }
}
