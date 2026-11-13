import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';

/// The two children of [BesideOrBelow].
enum BesideOrBelowSlot { lead, trail }

/// [trail] on the trailing edge beside [lead] when it fits on one line and
/// leaves [lead] its natural width or [leadShare] of the row, whichever is less;
/// otherwise [trail] goes under [lead] at its own width. A Wrap of buttons in
/// a Row never wraps (its width is unbounded there), so a row of actions
/// takes this instead.
class BesideOrBelow extends SlottedMultiChildRenderObjectWidget<BesideOrBelowSlot, RenderBox> {
  final Widget lead;
  final Widget trail;

  /// Pins [trail] to the top beside [lead] instead of centring it.
  final bool top;

  final double leadShare;

  static const double defaultLeadShare = 0.4;

  const BesideOrBelow({
    super.key,
    required this.lead,
    required this.trail,
    this.top = false,
    this.leadShare = defaultLeadShare,
  });

  @override
  Iterable<BesideOrBelowSlot> get slots => BesideOrBelowSlot.values;

  @override
  Widget? childForSlot(BesideOrBelowSlot slot) => switch (slot) {
        BesideOrBelowSlot.lead => lead,
        BesideOrBelowSlot.trail => trail,
      };

  @override
  RenderBesideOrBelow createRenderObject(BuildContext context) =>
      RenderBesideOrBelow(
          textDirection: Directionality.of(context),
          top: top,
          leadShare: leadShare);

  @override
  void updateRenderObject(
      BuildContext context, RenderBesideOrBelow renderObject) {
    renderObject
      ..textDirection = Directionality.of(context)
      ..top = top
      ..leadShare = leadShare;
  }
}

class RenderBesideOrBelow extends RenderBox
    with SlottedContainerRenderObjectMixin<BesideOrBelowSlot, RenderBox> {
  RenderBesideOrBelow(
      {required TextDirection textDirection,
      required bool top,
      double leadShare = BesideOrBelow.defaultLeadShare})
      : _textDirection = textDirection,
        _top = top,
        _leadShare = leadShare;

  static const double _besideGap = HollowSpacing.lg;
  static const double _belowGap = HollowSpacing.md;

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  bool _top;
  set top(bool value) {
    if (value == _top) return;
    _top = value;
    markNeedsLayout();
  }

  double _leadShare;
  set leadShare(double value) {
    if (value == _leadShare) return;
    _leadShare = value;
    markNeedsLayout();
  }

  RenderBox get _lead => childForSlot(BesideOrBelowSlot.lead)!;
  RenderBox get _trail => childForSlot(BesideOrBelowSlot.trail)!;

  /// [trail]'s width on one line. A dry layout, since some buttons report a
  /// max intrinsic width a little under the width they lay out at.
  double get _trailLine => _trail.getDryLayout(const BoxConstraints()).width;

  /// Whether the row lays out side by side at [width].
  bool besideAt(double width) {
    final leadNeed = math.max(
      _lead.getMinIntrinsicWidth(double.infinity),
      math.min(_lead.getMaxIntrinsicWidth(double.infinity), width * _leadShare),
    );
    return _trailLine + _besideGap + leadNeed <= width;
  }

  @override
  double computeMinIntrinsicWidth(double height) => math.max(
      _lead.getMinIntrinsicWidth(height), _trail.getMinIntrinsicWidth(height));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _lead.getMaxIntrinsicWidth(height) + _besideGap + _trailLine;

  @override
  double computeMinIntrinsicHeight(double width) =>
      _layout(BoxConstraints(maxWidth: width), dry: true).height;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _layout(BoxConstraints(maxWidth: width), dry: true).height;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  void performLayout() {
    size = _layout(constraints, dry: false);
  }

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : computeMaxIntrinsicWidth(double.infinity);
    Size measure(RenderBox child, BoxConstraints c) {
      if (dry) return child.getDryLayout(c);
      child.layout(c, parentUsesSize: true);
      return child.size;
    }

    void place(RenderBox child, double x, double y) {
      if (!dry) (child.parentData! as BoxParentData).offset = Offset(x, y);
    }

    final ltr = _textDirection == TextDirection.ltr;
    if (besideAt(width)) {
      final t = measure(_trail, BoxConstraints(maxWidth: _trailLine));
      final l = measure(
          _lead, BoxConstraints.tightFor(width: width - t.width - _besideGap));
      final h = math.max(l.height, t.height);
      double y(Size s) => _top ? 0 : (h - s.height) / 2;
      place(_lead, ltr ? 0 : width - l.width, y(l));
      place(_trail, ltr ? width - t.width : 0, y(t));
      return constraints.constrain(Size(width, h));
    }
    final l = measure(_lead, BoxConstraints.tightFor(width: width));
    final t = measure(_trail, BoxConstraints(maxWidth: width));
    place(_lead, 0, 0);
    place(_trail, ltr ? 0 : width - t.width, l.height + _belowGap);
    return constraints
        .constrain(Size(width, l.height + _belowGap + t.height));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in [_lead, _trail]) {
      context.paintChild(
          child, (child.parentData! as BoxParentData).offset + offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in [_trail, _lead]) {
      final offset = (child.parentData! as BoxParentData).offset;
      final hit = result.addWithPaintOffset(
        offset: offset,
        position: position,
        hitTest: (result, transformed) =>
            child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }
}
