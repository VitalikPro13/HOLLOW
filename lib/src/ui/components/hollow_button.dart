import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// Button variant for Hollow-branded buttons.
enum HollowButtonVariant { filled, ghost, outline, danger }

/// Custom Hollow button — no Material ripple, spring physics interactions.
///
/// Four variants:
/// - **filled**: solid accent bg, white text (primary action)
/// - **ghost**: transparent bg, accent text (secondary action, replaces TextButton)
/// - **outline**: 1px accent border, accent text
/// - **danger**: error-red bg, white text (destructive actions)
class HollowButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final Widget child;
  final Widget? icon;
  final HollowButtonVariant variant;
  final bool expand;
  final bool compact;

  const HollowButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.variant = HollowButtonVariant.filled,
    this.expand = false,
    this.compact = false,
  });

  const HollowButton.filled({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expand = false,
    this.compact = false,
  }) : variant = HollowButtonVariant.filled;

  const HollowButton.ghost({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expand = false,
    this.compact = false,
  }) : variant = HollowButtonVariant.ghost;

  const HollowButton.outline({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expand = false,
    this.compact = false,
  }) : variant = HollowButtonVariant.outline;

  const HollowButton.danger({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expand = false,
    this.compact = false,
  }) : variant = HollowButtonVariant.danger;

  @override
  State<HollowButton> createState() => _HollowButtonState();
}

class _HollowButtonState extends State<HollowButton>
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
      duration: HollowDurations.animationsDisabled ? Duration.zero : const Duration(milliseconds: 120),
      reverseDuration: HollowDurations.animationsDisabled ? Duration.zero : const Duration(milliseconds: 200),
    );

    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.98).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOutCubic,
        reverseCurve: HollowCurves.spring,
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

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final isDisabled = widget.onPressed == null;
    final isInteractive = !isDisabled;

    Color bg;
    Color fg;
    Color hoverBg;
    Color glowColor;
    BoxBorder? border;

    switch (widget.variant) {
      case HollowButtonVariant.filled:
        bg = hollow.accent;
        fg = hollow.textOnAccent;
        hoverBg = hollow.accentHover;
        glowColor = hollow.accent;
      case HollowButtonVariant.ghost:
        bg = Colors.transparent;
        fg = hollow.accent;
        hoverBg = hollow.accentMuted;
        glowColor = hollow.accent;
      case HollowButtonVariant.outline:
        bg = Colors.transparent;
        fg = hollow.accent;
        hoverBg = hollow.accentMuted;
        glowColor = hollow.accent;
        border = Border.all(
          color: _hovering && isInteractive
              ? hollow.accent.withValues(alpha: 0.6)
              : hollow.accent.withValues(alpha: 0.4),
        );
      case HollowButtonVariant.danger:
        bg = hollow.error;
        fg = Colors.white;
        hoverBg = hollow.error.withValues(alpha: 0.85);
        glowColor = hollow.error;
    }

    final effectiveBg =
        _hovering && isInteractive ? hoverBg : bg;

    // Subtle glow on hover for filled, outline, and danger variants.
    final hoverShadow = _hovering && isInteractive &&
            widget.variant != HollowButtonVariant.ghost
        ? [
            BoxShadow(
              color: glowColor.withValues(alpha: 0.2),
              blurRadius: 8,
              spreadRadius: 0,
            ),
          ]
        : <BoxShadow>[];

    Widget content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (widget.icon != null) ...[
          SizedBox(
            width: 16,
            height: 16,
            child: IconTheme(
              data: IconThemeData(color: fg, size: 14),
              child: widget.icon!,
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
        ],
        DefaultTextStyle(
          style: HollowTypography.label.copyWith(color: fg, height: 1.0),
          child: widget.child,
        ),
      ],
    );

    if (widget.expand) {
      content = SizedBox(
        width: double.infinity,
        child: content,
      );
    }

    return MouseRegion(
      cursor: isInteractive
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) {
        if (isInteractive) setState(() => _hovering = true);
      },
      onExit: (_) => setState(() => _hovering = false),
      child: Listener(
        onPointerDown: (_) {
          if (!isInteractive) return;
          setState(() => _pressing = true);
          _controller.forward();
        },
        onPointerUp: (_) {
          if (!_pressing) return;
          setState(() => _pressing = false);
          _controller.reverse();
        },
        onPointerCancel: (_) {
          if (!_pressing) return;
          setState(() => _pressing = false);
          _controller.reverse();
        },
        child: GestureDetector(
          onTap: isInteractive ? widget.onPressed : null,
          behavior: HitTestBehavior.opaque,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return FadeTransition(
                opacity: isDisabled
                    ? const AlwaysStoppedAnimation(0.4)
                    : _opacityAnimation,
                child: ScaleTransition(
                  scale: _scaleAnimation,
                  child: child,
                ),
              );
            },
            child: AnimatedContainer(
              duration: HollowDurations.fast,
              curve: HollowCurves.subtle,
              padding: EdgeInsets.symmetric(
                horizontal:
                    widget.compact ? HollowSpacing.md : HollowSpacing.lg,
                vertical:
                    widget.compact ? HollowSpacing.sm : HollowSpacing.sm + 2,
              ),
              decoration: BoxDecoration(
                color: effectiveBg,
                border: border,
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                boxShadow: hoverShadow,
              ),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
