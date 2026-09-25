import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';

/// One row of a dense list: leading, title, subtitle, trailing.
///
/// Anything repeated more than three times is a list of these, not a grid of
/// cards, unless the item IS the art.
///
/// The hover fill belongs to the WHOLE row and the rows sit flush, so a pointer
/// travelling down a list never crosses a dead gap where the highlight drops
/// out. Padding lives inside the row for the same reason: a margin would put
/// unreachable space between two hover targets.
class HollowListRow extends StatelessWidget {
  /// An avatar, a status dot, an icon that carries meaning. Never an icon in a
  /// tinted box.
  final Widget? leading;

  final String title;
  final String? subtitle;

  /// A badge, a count, a ghost action.
  final Widget? trailing;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Persistent selection, as in a sidebar. Distinct from hover and press.
  final bool selected;

  /// Usually null: [title] names the row.
  final String? semanticLabel;

  /// Phone metrics (design language 5.4): at least 48 tall, type one step up,
  /// full bleed so the row meets the screen edges.
  final bool touch;

  /// Content aligns to the text edge of whatever sits above the row, and the
  /// hover fill bleeds past it by the row's own [insetOf]. Null follows the
  /// nearest [HollowFlushRows], which a padded dialog provides. A flush row
  /// inside a scroll view needs the view widened by [HollowBleed], or the
  /// view's clip cuts the fill at the text edge.
  final bool? flush;

  /// The smallest a [touch] row may be.
  static const double touchMinHeight = 48;

  /// The horizontal padding between the row's fill and its content.
  static double insetOf({bool touch = false}) =>
      touch ? HollowSpacing.lg : HollowSpacing.md;

  const HollowListRow({
    super.key,
    required this.title,
    this.leading,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.semanticLabel,
    this.touch = false,
    this.flush,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final inset = insetOf(touch: touch);

    final row = HollowPressable(
      onTap: onTap,
      onLongPress: onLongPress,
      // A row is not a button: it stays actionable for assistive tech without
      // claiming the button role.
      semanticButton: false,
      semanticLabel: semanticLabel,
      // Hover colour only. A row must not scale or dim under the pointer: at
      // list density that reads as the whole list twitching.
      subtle: true,
      borderRadius:
          touch ? BorderRadius.zero : BorderRadius.circular(hollow.radiusMd),
      backgroundColor: selected ? hollow.accentMuted : null,
      padding:
          EdgeInsets.symmetric(horizontal: inset, vertical: HollowSpacing.sm),
      child: ConstrainedBox(
        constraints: BoxConstraints(
            minHeight: touch ? touchMinHeight - 2 * HollowSpacing.sm : 0),
        child: Row(
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: HollowSpacing.md),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: (touch
                            ? HollowTypography.bodyTouch
                                .copyWith(fontWeight: FontWeight.w500)
                            : HollowTypography.label)
                        .copyWith(
                      color: selected ? hollow.accentText : hollow.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: (touch
                              ? HollowTypography.body
                              : HollowTypography.bodySmall)
                          .copyWith(color: hollow.textSecondary),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: HollowSpacing.md),
              trailing!,
            ],
          ],
        ),
      ),
    );
    if (!(flush ?? HollowFlushRows.of(context))) return row;
    return HollowBleed(horizontal: inset, child: row);
  }
}

/// Makes the [HollowListRow]s below it flush by default: their content sits on
/// the surrounding text edge. A padded [HollowDialogSurface] provides it.
class HollowFlushRows extends InheritedWidget {
  final bool flush;

  const HollowFlushRows({super.key, this.flush = true, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HollowFlushRows>()?.flush ??
      false;

  @override
  bool updateShouldNotify(HollowFlushRows oldWidget) =>
      oldWidget.flush != flush;
}

/// Lays its child out [horizontal] wider on each side than its own box, the
/// negative margin Flutter lacks. The box keeps the content's edges, the child
/// paints and takes hits past them. Hits only arrive where every ancestor's box
/// also reaches, so the bleed zone is hoverable only as far as they allow.
class HollowBleed extends SingleChildRenderObjectWidget {
  final double horizontal;

  const HollowBleed({super.key, required this.horizontal, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderHollowBleed(horizontal);

  @override
  void updateRenderObject(
      BuildContext context, RenderHollowBleed renderObject) {
    renderObject.horizontal = horizontal;
  }
}

/// The layout behind [HollowBleed].
class RenderHollowBleed extends RenderShiftedBox {
  RenderHollowBleed(this._horizontal) : super(null);

  double _horizontal;
  set horizontal(double value) {
    if (value == _horizontal) return;
    _horizontal = value;
    markNeedsLayout();
  }

  BoxConstraints _widen(BoxConstraints c) => BoxConstraints(
        minWidth: c.minWidth + 2 * _horizontal,
        maxWidth: c.maxWidth + 2 * _horizontal,
        minHeight: c.minHeight,
        maxHeight: c.maxHeight,
      );

  Size _narrow(Size childSize, BoxConstraints c) => c.constrain(Size(
      (childSize.width - 2 * _horizontal).clamp(0.0, double.infinity),
      childSize.height));

  @override
  double computeMinIntrinsicWidth(double height) =>
      ((child?.getMinIntrinsicWidth(height) ?? 0) - 2 * _horizontal)
          .clamp(0.0, double.infinity);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      ((child?.getMaxIntrinsicWidth(height) ?? 0) - 2 * _horizontal)
          .clamp(0.0, double.infinity);

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(width + 2 * _horizontal) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(width + 2 * _horizontal) ?? 0;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final c = child;
    if (c == null) return constraints.smallest;
    return _narrow(c.getDryLayout(_widen(constraints)), constraints);
  }

  @override
  void performLayout() {
    final c = child;
    if (c == null) {
      size = constraints.smallest;
      return;
    }
    c.layout(_widen(constraints), parentUsesSize: true);
    size = _narrow(c.size, constraints);
    (c.parentData! as BoxParentData).offset = Offset(-_horizontal, 0);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final bled = Rect.fromLTWH(
        -_horizontal, 0, size.width + 2 * _horizontal, size.height);
    if (!bled.contains(position)) return false;
    if (hitTestChildren(result, position: position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }
}
