import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
/// [expand] gives the tabs equal widths across the row, for a phone, and
/// stacks them full width when a label would not fit its share. Otherwise the
/// row wraps rather than overflow at a large text size.
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
      row = HollowEqualRow(
        children: [
          for (var i = 0; i < widget.tabs.length; i++) _chip(i),
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

/// Equal-width children on one line, 8 apart, while every child's label fits
/// its share; otherwise one full-width child per line, in order. A narrow
/// phone or a large text size then stacks the choices instead of cutting
/// their labels to "Images o...".
class HollowEqualRow extends MultiChildRenderObjectWidget {
  const HollowEqualRow({super.key, required super.children});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderHollowEqualRow();
}

class _EqualRowParentData extends ContainerBoxParentData<RenderBox> {}

class RenderHollowEqualRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _EqualRowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _EqualRowParentData> {
  static const _gap = HollowSpacing.sm;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _EqualRowParentData) {
      child.parentData = _EqualRowParentData();
    }
  }

  List<RenderBox> get _children {
    final out = <RenderBox>[];
    var child = firstChild;
    while (child != null) {
      out.add(child);
      child = childAfter(child);
    }
    return out;
  }

  /// Each child's share of [width] when they sit on one line.
  double _share(double width, int count) =>
      count == 0 ? 0 : (width - _gap * (count - 1)) / count;

  bool _fitsOneLine(List<RenderBox> kids, double width) {
    if (!width.isFinite) return true;
    final share = _share(width, kids.length);
    return kids.every(
        (c) => c.getMaxIntrinsicWidth(double.infinity) <= share + 0.5);
  }

  @override
  double computeMinIntrinsicWidth(double height) => _children.fold<double>(
      0, (m, c) => math.max(m, c.getMinIntrinsicWidth(height)));

  @override
  double computeMaxIntrinsicWidth(double height) {
    final kids = _children;
    if (kids.isEmpty) return 0;
    final widest = kids.fold<double>(
        0, (m, c) => math.max(m, c.getMaxIntrinsicWidth(height)));
    return widest * kids.length + _gap * (kids.length - 1);
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    final kids = _children;
    if (kids.isEmpty) return 0;
    if (_fitsOneLine(kids, width)) {
      final share = _share(width, kids.length);
      return kids.fold<double>(
          0, (m, c) => math.max(m, c.getMinIntrinsicHeight(share)));
    }
    return kids.fold<double>(0, (s, c) => s + c.getMinIntrinsicHeight(width)) +
        _gap * (kids.length - 1);
  }

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final kids = _children;
    final width = constraints.maxWidth;
    if (kids.isEmpty) return constraints.smallest;
    if (_fitsOneLine(kids, width)) {
      final shareWidth = width.isFinite
          ? _share(width, kids.length)
          : kids.fold<double>(0,
              (m, c) => math.max(m, c.getMaxIntrinsicWidth(double.infinity)));
      final share = BoxConstraints.tightFor(width: shareWidth);
      final height = kids.fold<double>(
          0, (m, c) => math.max(m, c.getDryLayout(share).height));
      return constraints.constrain(Size(
          shareWidth * kids.length + _gap * (kids.length - 1), height));
    }
    final full = BoxConstraints.tightFor(width: width);
    var height = _gap * (kids.length - 1);
    for (final c in kids) {
      height += c.getDryLayout(full).height;
    }
    return constraints.constrain(Size(width, height));
  }

  @override
  void performLayout() {
    final kids = _children;
    final width = constraints.maxWidth;
    if (kids.isEmpty) {
      size = constraints.smallest;
      return;
    }
    if (_fitsOneLine(kids, width)) {
      // Unbounded, every child takes the widest one's natural width.
      final share = width.isFinite
          ? _share(width, kids.length)
          : kids.fold<double>(0,
              (m, c) => math.max(m, c.getMaxIntrinsicWidth(double.infinity)));
      var height = 0.0;
      for (final c in kids) {
        c.layout(BoxConstraints.tightFor(width: share), parentUsesSize: true);
        height = math.max(height, c.size.height);
      }
      var x = 0.0;
      for (final c in kids) {
        (c.parentData! as _EqualRowParentData).offset =
            Offset(x, (height - c.size.height) / 2);
        x += share + _gap;
      }
      size = constraints.constrain(Size(x - _gap, height));
      return;
    }
    var y = 0.0;
    for (var i = 0; i < kids.length; i++) {
      if (i > 0) y += _gap;
      kids[i].layout(BoxConstraints.tightFor(width: width),
          parentUsesSize: true);
      (kids[i].parentData! as _EqualRowParentData).offset = Offset(0, y);
      y += kids[i].size.height;
    }
    size = constraints.constrain(Size(width, y));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
}
