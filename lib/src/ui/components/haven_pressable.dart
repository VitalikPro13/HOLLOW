import 'package:flutter/material.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/ui/animations/haven_curves.dart';

/// Universal interactive widget for Haven — replaces InkWell everywhere.
///
/// On press: dims opacity to 0.85 + scales to 0.98 with spring physics.
/// On hover: smoothly transitions to [hoverColor].
/// No Material ripple, ever.
class HavenPressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final BorderRadius? borderRadius;
  final Color? hoverColor;
  final Color? backgroundColor;
  final EdgeInsetsGeometry? padding;
  final bool disabled;

  const HavenPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.borderRadius,
    this.hoverColor,
    this.backgroundColor,
    this.padding,
    this.disabled = false,
  });

  @override
  State<HavenPressable> createState() => _HavenPressableState();
}

class _HavenPressableState extends State<HavenPressable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _opacityAnimation;

  bool _hovering = false;
  bool _pressing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      reverseDuration: const Duration(milliseconds: 200),
    );

    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.98).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOutCubic,
        reverseCurve: HavenCurves.spring,
      ),
    );

    _opacityAnimation = Tween<double>(begin: 1.0, end: 0.85).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent _) {
    if (widget.disabled || widget.onTap == null) return;
    setState(() => _pressing = true);
    _controller.forward();
  }

  void _onPointerUp(PointerUpEvent _) {
    if (!_pressing) return;
    setState(() => _pressing = false);
    _controller.reverse();
  }

  void _onPointerCancel(PointerCancelEvent _) {
    if (!_pressing) return;
    setState(() => _pressing = false);
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);
    final isInteractive = !widget.disabled && widget.onTap != null;
    final effectiveHoverColor = widget.hoverColor ?? haven.elevated;

    return MouseRegion(
      cursor: isInteractive
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) {
        if (isInteractive) setState(() => _hovering = true);
      },
      onExit: (_) {
        setState(() => _hovering = false);
      },
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        child: GestureDetector(
          onTap: isInteractive ? widget.onTap : null,
          onLongPress:
              isInteractive ? widget.onLongPress : null,
          behavior: HitTestBehavior.opaque,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Opacity(
                opacity: widget.disabled
                    ? 0.4
                    : _opacityAnimation.value,
                child: Transform.scale(
                  scale: _scaleAnimation.value,
                  child: child,
                ),
              );
            },
            child: AnimatedContainer(
              duration: HavenDurations.fast,
              curve: HavenCurves.subtle,
              decoration: BoxDecoration(
                color: _hovering && isInteractive
                    ? effectiveHoverColor
                    : (widget.backgroundColor ?? Colors.transparent),
                borderRadius: widget.borderRadius,
              ),
              padding: widget.padding,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
