import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';

enum HollowButtonVariant { filled, ghost, outline, danger }

/// Custom Hollow button: no Material ripple, spring physics. `filled` is the
/// primary action, `ghost` the secondary, `outline` a bordered variant, and
/// `danger` is reserved for destructive confirmations.
class HollowButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final Widget child;
  final Widget? icon;
  final HollowButtonVariant variant;
  final bool expand;
  final bool compact;

  /// Tints an [HollowButton.outline] with the error colour, to flag a
  /// cautionary action without the solid `.danger` fill that confirm dialogs
  /// own. No effect on other variants.
  final bool danger;

  /// Usually null, because the [child] text auto-names the button. Set it for
  /// an icon-only button, or when the visible text is the wrong announcement.
  final String? semanticLabel;

  const HollowButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.variant = HollowButtonVariant.filled,
    this.expand = false,
    this.compact = false,
    this.semanticLabel,
    this.danger = false,
  });

  const HollowButton.filled({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expand = false,
    this.compact = false,
    this.semanticLabel,
  })  : variant = HollowButtonVariant.filled,
        danger = false;

  const HollowButton.ghost({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expand = false,
    this.compact = false,
    this.semanticLabel,
  })  : variant = HollowButtonVariant.ghost,
        danger = false;

  const HollowButton.outline({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expand = false,
    this.compact = false,
    this.semanticLabel,
    this.danger = false,
  }) : variant = HollowButtonVariant.outline;

  const HollowButton.danger({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expand = false,
    this.compact = false,
    this.semanticLabel,
  })  : variant = HollowButtonVariant.danger,
        danger = false;

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
      duration: HollowDurations.animationsDisabled
          ? Duration.zero
          : const Duration(milliseconds: 120),
      reverseDuration: HollowDurations.animationsDisabled
          ? Duration.zero
          : const Duration(milliseconds: 200),
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
    BoxBorder? border;

    switch (widget.variant) {
      case HollowButtonVariant.filled:
        bg = hollow.accent;
        fg = hollow.textOnAccent;
        hoverBg = hollow.accentHover;
      case HollowButtonVariant.ghost:
        // The hover colour at zero alpha, NOT Colors.transparent: that is
        // transparent BLACK, and the lerp flashes dark on hover and unhover.
        bg = hollow.accentMuted.withValues(alpha: 0.0);
        fg = hollow.accent;
        hoverBg = hollow.accentMuted;
      case HollowButtonVariant.outline:
        final tint = widget.danger ? hollow.error : hollow.accent;
        bg = tint.withValues(alpha: 0.0);
        fg = tint;
        hoverBg =
            widget.danger ? hollow.error.withValues(alpha: 0.12) : hollow.accentMuted;
        border = Border.all(
          color: _hovering && isInteractive
              ? tint.withValues(alpha: 0.6)
              : tint.withValues(alpha: 0.4),
        );
      case HollowButtonVariant.danger:
        bg = hollow.error;
        fg = Colors.white;
        hoverBg = hollow.error.withValues(alpha: 0.85);
    }

    final effectiveBg = _hovering && isInteractive ? hoverBg : bg;
    // No hover glow: a blurred halo paints OUTSIDE the button's outline, and
    // hover must never read bigger than the control.

    // The label scales with the OS text setting, so the icon has to as well or
    // it looks small beside it.
    final textScaler = MediaQuery.textScalerOf(context);
    final iconBox = textScaler.scale(16);
    final iconGlyph = textScaler.scale(14);

    Widget content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (widget.icon != null) ...[
          SizedBox(
            width: iconBox,
            height: iconBox,
            child: IconTheme(
              data: IconThemeData(color: fg, size: iconGlyph),
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
      content = SizedBox(width: double.infinity, child: content);
    }

    return MergeSemantics(
      child: HollowFocusRing(
        enabled: isInteractive,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        onActivate: widget.onPressed,
        child: MouseRegion(
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
          child: Semantics(
            // The semantic onTap mirrors the gesture handler.
            button: true,
            enabled: isInteractive,
            label: widget.semanticLabel,
            onTap: isInteractive ? widget.onPressed : null,
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
                    horizontal: widget.compact
                        ? HollowSpacing.md
                        : HollowSpacing.lg,
                    vertical: widget.compact
                        ? HollowSpacing.sm
                        : HollowSpacing.sm + 2,
                  ),
                  decoration: BoxDecoration(
                    color: effectiveBg,
                    border: border,
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                  ),
                  child: content,
                ),
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }
}
