import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/hover_scope.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';

/// Universal interactive widget for Hollow, replacing InkWell everywhere. No
/// Material ripple, ever. [subtle] is for list items: hover colour only, no
/// press dim or scale.
///
/// With [onTap] set the widget is exposed to screen readers and Voice Control
/// as a button. Pass [semanticLabel] for an icon-only control, and set
/// [semanticButton] false for a tappable row or card, which stays actionable
/// without claiming the button role.
class HollowPressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final BorderRadius? borderRadius;
  final Color? hoverColor;
  final Color? backgroundColor;
  final EdgeInsetsGeometry? padding;
  final bool disabled;
  final bool subtle;

  /// Screen-reader label. Only needed when [child] has no readable text
  /// (icon-only buttons). Null = let the child supply the name.
  final String? semanticLabel;

  /// Whether to announce the "button" role; false for a tappable row or card,
  /// which stays actionable without it.
  final bool semanticButton;

  const HollowPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.borderRadius,
    this.hoverColor,
    this.backgroundColor,
    this.padding,
    this.disabled = false,
    this.subtle = false,
    this.semanticLabel,
    this.semanticButton = true,
  });

  @override
  State<HollowPressable> createState() => _HollowPressableState();
}

class _HollowPressableState extends State<HollowPressable>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _scaleAnimation;
  Animation<double>? _opacityAnimation;

  bool _hovering = false;
  bool _pressing = false;

  /// Row-hover for descendants ([HoverScope]). A notifier rather than another
  /// setState, so a pointer crossing a member list rebuilds only the avatars
  /// that listen. Set even when the row is NOT interactive.
  final ValueNotifier<bool> _rowHovered = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    if (!widget.subtle) {
      _controller = AnimationController(
        vsync: this,
        duration: HollowDurations.animationsDisabled
            ? Duration.zero
            : const Duration(milliseconds: 120),
        reverseDuration: HollowDurations.animationsDisabled
            ? Duration.zero
            : const Duration(milliseconds: 200),
      );
      _scaleAnimation = Tween<double>(begin: 1.0, end: 0.98).animate(
        CurvedAnimation(
          parent: _controller!,
          curve: Curves.easeOutCubic,
          reverseCurve: HollowCurves.spring,
        ),
      );
      _opacityAnimation = Tween<double>(begin: 1.0, end: 0.85).animate(
        CurvedAnimation(
          parent: _controller!,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeOutCubic,
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _rowHovered.dispose();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent _) {
    if (widget.disabled || widget.onTap == null || widget.subtle) return;
    setState(() => _pressing = true);
    _controller?.forward();
  }

  void _onPointerUp(PointerUpEvent _) {
    if (!_pressing || !mounted) return;
    setState(() => _pressing = false);
    _controller?.reverse();
  }

  void _onPointerCancel(PointerCancelEvent _) {
    if (!_pressing || !mounted) return;
    setState(() => _pressing = false);
    _controller?.reverse();
  }

  /// Hover lift for a control with an explicit background: toward white on a
  /// dark fill, toward black on a light one, where white would be invisible.
  static Color _hoverLift(Color base) {
    final toward =
        base.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    return Color.lerp(base, toward, base.computeLuminance() > 0.5 ? 0.08 : 0.15)!;
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final isInteractive = !widget.disabled && widget.onTap != null;
    final effectiveHoverColor = widget.hoverColor ?? hollow.elevated;

    final container = AnimatedContainer(
      duration: HollowDurations.fast,
      curve: HollowCurves.subtle,
      decoration: BoxDecoration(
        // Resting colour is the hover colour at ZERO ALPHA, never
        // Colors.transparent: that is transparent BLACK, and lerping RGB and
        // alpha together flashes dark on hover and unhover. Same-RGB endpoints
        // make it a pure fade.
        color: _hovering && isInteractive
            ? (widget.backgroundColor != null
                  ? _hoverLift(widget.backgroundColor!)
                  : effectiveHoverColor)
            : (widget.backgroundColor ??
                  effectiveHoverColor.withValues(alpha: 0.0)),
        borderRadius: widget.borderRadius,
        // No hover glow: a blurred halo paints OUTSIDE the control's bounds,
        // and hover must never read bigger than the outline.
      ),
      padding: widget.padding,
      child: HoverScope(hovered: _rowHovered, child: widget.child),
    );

    final Widget inner;
    if (widget.subtle) {
      inner = AnimatedOpacity(
        opacity: widget.disabled ? 0.4 : 1.0,
        duration: HollowDurations.fast,
        child: container,
      );
    } else {
      inner = AnimatedBuilder(
        animation: _controller!,
        builder: (context, child) {
          return FadeTransition(
            opacity: widget.disabled
                ? const AlwaysStoppedAnimation(0.4)
                : _opacityAnimation!,
            child: ScaleTransition(scale: _scaleAnimation!, child: child),
          );
        },
        child: container,
      );
    }

    final Widget result = MouseRegion(
      cursor: isInteractive
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) {
        _rowHovered.value = true;
        if (isInteractive) setState(() => _hovering = true);
      },
      onExit: (_) {
        _rowHovered.value = false;
        setState(() => _hovering = false);
      },
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        child: Semantics(
          // The semantic onTap mirrors the gesture handler and cannot
          // double-fire with it: one is a pointer event, the other an
          // assistive-tech action.
          button: isInteractive && widget.semanticButton,
          label: widget.semanticLabel,
          enabled: isInteractive,
          onTap: isInteractive ? widget.onTap : null,
          onLongPress: isInteractive ? widget.onLongPress : null,
          child: GestureDetector(
            onTap: isInteractive ? widget.onTap : null,
            onLongPress: isInteractive ? widget.onLongPress : null,
            behavior: HitTestBehavior.opaque,
            child: inner,
          ),
        ),
      ),
    );

    if (!isInteractive) return result;

    // Keyboard focus and the focus ring (a11y 2.6), then one merged
    // screen-reader node so a row is a single stop rather than several.
    return MergeSemantics(
      child: HollowFocusRing(
        borderRadius: widget.borderRadius ?? BorderRadius.zero,
        onActivate: widget.onTap,
        child: result,
      ),
    );
  }
}
