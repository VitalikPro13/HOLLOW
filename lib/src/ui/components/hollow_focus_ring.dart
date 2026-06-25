import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// Keyboard-focus ring for Hollow's interactive controls (a11y Phase 2.6).
///
/// Wraps [child] in a [FocusableActionDetector] so the control:
///   - enters the Tab / arrow-key focus chain (and Voice Control's numbered
///     overlays land on it),
///   - draws an accent outline + soft glow **only on keyboard / assistive-tech
///     focus** (never on mouse hover or press — `onShowFocusHighlight` is true
///     only for non-pointer focus), and
///   - activates via Enter / Space / NumpadEnter → [onActivate].
///
/// This is the single chokepoint that makes the whole app keyboard-operable:
/// [HollowPressable], [HollowButton] and [HollowToggle] each wrap their content
/// in one of these, so the ~645 call sites become focusable from three edits.
///
/// **Geometry:** the ring is painted by a [CustomPaint] `foregroundPainter`
/// wrapping [child] directly — so it is drawn at EXACTLY the child's rendered
/// size and position, no matter how an ancestor stretches the control (e.g. a
/// `SizedBox(width: double.infinity)` around a `MainAxisSize.min` button). This
/// is why the ring always hugs the visible control instead of filling a larger
/// stretched box. The stroke is drawn INSET so it stays within the child's
/// footprint and never bleeds onto neighbours or a panel edge in dense rows.
/// `CustomPaint` adds no layout cost and reports the child's size unchanged.
///
/// Pass [enabled] = false (the host control's disabled state) to drop the
/// control out of the focus chain entirely.
class HollowFocusRing extends StatefulWidget {
  final Widget child;

  /// Invoked when the control is activated by keyboard (Enter / Space) while
  /// focused. Should mirror the host control's tap handler. Null = the control
  /// is not activatable (and not focusable).
  final VoidCallback? onActivate;

  /// Whether the control is interactive. False removes it from the focus chain
  /// and never draws a ring.
  final bool enabled;

  /// Corner radius of the ring. Should match the host control's shape so the
  /// ring hugs it (e.g. a pill toggle passes a large radius).
  final BorderRadius borderRadius;

  /// Optional external focus node (rarely needed — the widget creates its own).
  final FocusNode? focusNode;

  /// Whether to autofocus this control when first built.
  final bool autofocus;

  const HollowFocusRing({
    super.key,
    required this.child,
    required this.onActivate,
    required this.borderRadius,
    this.enabled = true,
    this.focusNode,
    this.autofocus = false,
  });

  @override
  State<HollowFocusRing> createState() => _HollowFocusRingState();
}

class _HollowFocusRingState extends State<HollowFocusRing>
    with SingleTickerProviderStateMixin {
  bool _focused = false;

  // Drives the ring fade so a CustomPaint can repaint it (an AnimatedOpacity
  // can't wrap a foregroundPainter without changing layout/size).
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: HollowDurations.animationsDisabled
        ? Duration.zero
        : const Duration(milliseconds: 150),
  );

  // Enter / Space / NumpadEnter → activate. Declared locally so activation
  // works regardless of what shortcuts an ancestor installed; the matching
  // ActivateAction is supplied via [_actions].
  static const Map<ShortcutActivator, Intent> _shortcuts = {
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
  };

  late final Map<Type, Action<Intent>> _actions = {
    ActivateIntent: CallbackAction<ActivateIntent>(
      onInvoke: (_) {
        widget.onActivate?.call();
        return null;
      },
    ),
  };

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  void _onShowFocusHighlight(bool show) {
    if (show == _focused) return;
    _focused = show;
    if (show) {
      _fade.forward();
    } else {
      _fade.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final canFocus = widget.enabled && widget.onActivate != null;

    return FocusableActionDetector(
      enabled: canFocus,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      shortcuts: _shortcuts,
      actions: _actions,
      // Mouse hover/press are handled by the host control's own MouseRegion;
      // we only care about KEYBOARD focus here, surfaced via this callback.
      onShowFocusHighlight: _onShowFocusHighlight,
      mouseCursor: MouseCursor.defer,
      // foregroundPainter draws the ring on top of the child at the child's
      // EXACT size — immune to ancestor stretch. RepaintBoundary keeps the
      // fade repaints from dirtying the child.
      child: RepaintBoundary(
        child: CustomPaint(
          foregroundPainter: _FocusRingPainter(
            color: hollow.focusRing,
            // Contrasting "casing" so the accent ring stays visible even when
            // it sits ON an accent-filled control (filled buttons, an ON
            // toggle's accent track) — there the accent ring alone would
            // disappear. background is the deepest contrast to accent in both
            // themes (near-black on dark, near-white on light).
            casing: hollow.background,
            borderRadius: widget.borderRadius,
            repaint: _fade,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Paints the focus ring at the child's exact painted bounds: a 1px contrasting
/// [casing] stroke just outside a 2px accent [color] stroke, so the ring reads
/// on ANY background — a dark/light surface OR an accent-filled control (where
/// an accent-only ring would vanish). Opacity is driven by [repaint] (0→1) so
/// it fades in/out without any layout/size change.
class _FocusRingPainter extends CustomPainter {
  final Color color;
  final Color casing;
  final BorderRadius borderRadius;
  final Animation<double> repaint;

  _FocusRingPainter({
    required this.color,
    required this.casing,
    required this.borderRadius,
    required this.repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final t = repaint.value;
    if (t <= 0.0) return;

    // An accent ring OUTLINED on both edges by a contrasting casing, so it
    // reads on ANY background — including an accent-filled control where an
    // accent-only ring would vanish. Drawn as a wider casing stroke with the
    // narrower accent stroke centred on top (the casing peeks ~0.75px on each
    // side of the accent band). Both concentric on one path, inset enough to
    // stay fully INSIDE the control's box (no neighbour bleed).
    const ringStroke = 2.0;
    const casingStroke = ringStroke + 1.5; // 3.5px — peeks either side
    final inset = casingStroke / 2 + 0.5; // keep the whole casing inside

    final rect = (Offset.zero & size).deflate(inset);
    if (rect.isEmpty) return;
    final path = RRect.fromRectAndCorners(
      rect,
      topLeft: _shrink(borderRadius.topLeft, inset),
      topRight: _shrink(borderRadius.topRight, inset),
      bottomLeft: _shrink(borderRadius.bottomLeft, inset),
      bottomRight: _shrink(borderRadius.bottomRight, inset),
    );

    // Contrasting casing underneath (full opacity so it separates cleanly).
    canvas.drawRRect(
      path,
      Paint()
        ..color = casing.withValues(alpha: t)
        ..style = PaintingStyle.stroke
        ..strokeWidth = casingStroke,
    );

    // Accent ring on top, centred on the same path.
    canvas.drawRRect(
      path,
      Paint()
        ..color = color.withValues(alpha: t)
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringStroke,
    );
  }

  Radius _shrink(Radius r, double by) => Radius.elliptical(
      (r.x - by).clamp(0.0, double.infinity),
      (r.y - by).clamp(0.0, double.infinity));

  @override
  bool shouldRepaint(_FocusRingPainter old) =>
      old.color != color ||
      old.casing != casing ||
      old.borderRadius != borderRadius;
}
