import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// Keyboard-focus ring for Hollow's interactive controls (a11y Phase 2.6).
///
/// Wraps [child] in a [FocusableActionDetector]: the control joins the Tab and
/// arrow-key focus chain, activates on Enter / Space, and draws its outline
/// only on keyboard or assistive-tech focus, never on hover or press. It is the
/// one chokepoint that makes the app keyboard-operable, so [HollowPressable],
/// [HollowButton] and [HollowToggle] each wrap their content in one.
///
/// The ring is a [CustomPaint] `foregroundPainter` around [child] directly, so
/// it is drawn at the child's rendered size however an ancestor stretches the
/// control, and inset so the stroke never bleeds onto a neighbour in a dense
/// row. Pass [enabled] false to drop the control out of the focus chain.
class HollowFocusRing extends StatefulWidget {
  final Widget child;

  /// Mirrors the host control's tap handler. Null makes the control neither
  /// activatable nor focusable.
  final VoidCallback? onActivate;

  /// False removes the control from the focus chain and never draws a ring.
  final bool enabled;

  /// Should match the host control's shape so the ring hugs it.
  final BorderRadius borderRadius;

  /// Optional external focus node (rarely needed — the widget creates its own).
  final FocusNode? focusNode;

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

  // Declared locally so activation works regardless of what shortcuts an
  // ancestor installed.
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
      // Only KEYBOARD focus matters here; the host control owns hover and
      // press.
      onShowFocusHighlight: _onShowFocusHighlight,
      mouseCursor: MouseCursor.defer,
      // The boundary keeps the fade's repaints from dirtying the child.
      child: RepaintBoundary(
        child: CustomPaint(
          foregroundPainter: _FocusRingPainter(
            color: hollow.focusRing,
            // The accent ring alone would vanish on an accent-filled control,
            // and background is the deepest contrast to it in both themes.
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

/// Paints the focus ring at the child's exact painted bounds: a contrasting
/// [casing] stroke outside the accent [color] stroke, so the ring reads on any
/// background. [repaint] drives the fade without touching layout.
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

    // Both strokes are concentric on one path, inset enough to stay inside the
    // control's box so a dense row gets no bleed.
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
