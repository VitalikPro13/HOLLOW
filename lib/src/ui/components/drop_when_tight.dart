import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A row of [lead] then [extra], where [extra] is dropped whole when both do
/// not fit at their natural widths. [lead] keeps what is left and may then
/// ellipsize; [extra] is never squeezed.
///
/// For a status word beside something that must stay (a badge beside a call
/// timer). [lead] must report intrinsic widths: no LayoutBuilder inside it.
class DropWhenTight extends MultiChildRenderObjectWidget {
  /// The space between [lead] and [extra] when both show.
  final double gap;

  DropWhenTight({
    super.key,
    required Widget lead,
    required Widget extra,
    required this.gap,
  }) : super(children: [lead, extra]);

  @override
  RenderDropWhenTight createRenderObject(BuildContext context) =>
      RenderDropWhenTight(gap: gap);

  @override
  void updateRenderObject(
      BuildContext context, RenderDropWhenTight renderObject) {
    renderObject.gap = gap;
  }
}

class _DropParentData extends ContainerBoxParentData<RenderBox> {}

class RenderDropWhenTight extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _DropParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _DropParentData> {
  RenderDropWhenTight({required double gap}) : _gap = gap;

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  /// Whether the extra child fitted at the last layout.
  bool get showsExtra => _showsExtra;
  bool _showsExtra = false;

  RenderBox get _lead => firstChild!;
  RenderBox get _extra => lastChild!;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _DropParentData) {
      child.parentData = _DropParentData();
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _lead.getMinIntrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) {
    final extra = _extra.getMaxIntrinsicWidth(height);
    return _lead.getMaxIntrinsicWidth(height) + (extra > 0 ? _gap + extra : 0);
  }

  @override
  double computeMinIntrinsicHeight(double width) => math.max(
      _lead.getMinIntrinsicHeight(width), _extra.getMinIntrinsicHeight(width));

  @override
  double computeMaxIntrinsicHeight(double width) => math.max(
      _lead.getMaxIntrinsicHeight(width), _extra.getMaxIntrinsicHeight(width));

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  void performLayout() {
    size = _layout(constraints, dry: false);
  }

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final height = constraints.maxHeight;
    final room = constraints.maxWidth;
    final loose = BoxConstraints(maxHeight: height);
    final extraSize = dry
        ? _extra.getDryLayout(loose)
        : (_extra..layout(loose, parentUsesSize: true)).size;
    final leadNatural = _lead.getMaxIntrinsicWidth(height);
    final extraWidth = extraSize.width > 0 ? _gap + extraSize.width : 0.0;
    final shows = extraWidth > 0 && leadNatural + extraWidth <= room;

    final leadConstraints = BoxConstraints(
        maxWidth: shows ? room - extraWidth : room, maxHeight: height);
    final leadSize = dry
        ? _lead.getDryLayout(leadConstraints)
        : (_lead..layout(leadConstraints, parentUsesSize: true)).size;
    final rowHeight =
        shows ? math.max(leadSize.height, extraSize.height) : leadSize.height;
    final out = constraints.constrain(Size(
        leadSize.width + (shows ? extraWidth : 0), rowHeight));
    if (dry) return out;

    _showsExtra = shows;
    (_lead.parentData! as _DropParentData).offset =
        Offset(0, (out.height - leadSize.height) / 2);
    (_extra.parentData! as _DropParentData).offset = Offset(
        leadSize.width + _gap, (out.height - extraSize.height) / 2);
    return out;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    context.paintChild(
        _lead, offset + (_lead.parentData! as _DropParentData).offset);
    if (_showsExtra) {
      context.paintChild(
          _extra, offset + (_extra.parentData! as _DropParentData).offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in [if (_showsExtra) _extra, _lead]) {
      final at = (child.parentData! as _DropParentData).offset;
      final hit = result.addWithPaintOffset(
        offset: at,
        position: position,
        hitTest: (result, transformed) =>
            child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    visitor(_lead);
    if (_showsExtra) visitor(_extra);
  }
}
