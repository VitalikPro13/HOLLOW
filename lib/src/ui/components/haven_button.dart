import 'package:flutter/material.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/animations/haven_curves.dart';

/// Button variant for Haven-branded buttons.
enum HavenButtonVariant { filled, ghost, outline, danger }

/// Custom Haven button — no Material ripple, spring physics interactions.
///
/// Four variants:
/// - **filled**: solid accent bg, white text (primary action)
/// - **ghost**: transparent bg, accent text (secondary action, replaces TextButton)
/// - **outline**: 1px accent border, accent text
/// - **danger**: error-red bg, white text (destructive actions)
class HavenButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final Widget child;
  final Widget? icon;
  final HavenButtonVariant variant;
  final bool expand;
  final bool compact;

  const HavenButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.variant = HavenButtonVariant.filled,
    this.expand = false,
    this.compact = false,
  });

  const HavenButton.filled({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expand = false,
    this.compact = false,
  }) : variant = HavenButtonVariant.filled;

  const HavenButton.ghost({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expand = false,
    this.compact = false,
  }) : variant = HavenButtonVariant.ghost;

  const HavenButton.outline({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expand = false,
    this.compact = false,
  }) : variant = HavenButtonVariant.outline;

  const HavenButton.danger({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expand = false,
    this.compact = false,
  }) : variant = HavenButtonVariant.danger;

  @override
  State<HavenButton> createState() => _HavenButtonState();
}

class _HavenButtonState extends State<HavenButton>
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

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);
    final isDisabled = widget.onPressed == null;
    final isInteractive = !isDisabled;

    Color bg;
    Color fg;
    Color hoverBg;
    BoxBorder? border;

    switch (widget.variant) {
      case HavenButtonVariant.filled:
        bg = haven.accent;
        fg = haven.textOnAccent;
        hoverBg = haven.accentHover;
      case HavenButtonVariant.ghost:
        bg = Colors.transparent;
        fg = haven.accent;
        hoverBg = haven.accentMuted;
      case HavenButtonVariant.outline:
        bg = Colors.transparent;
        fg = haven.accent;
        hoverBg = haven.accentMuted;
        border = Border.all(
          color: haven.accent.withValues(alpha: 0.4),
        );
      case HavenButtonVariant.danger:
        bg = haven.error;
        fg = Colors.white;
        hoverBg = haven.error.withValues(alpha: 0.85);
    }

    final effectiveBg =
        _hovering && isInteractive ? hoverBg : bg;

    Widget content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.icon != null) ...[
          IconTheme(
            data: IconThemeData(color: fg, size: 16),
            child: widget.icon!,
          ),
          const SizedBox(width: HavenSpacing.sm),
        ],
        DefaultTextStyle(
          style: HavenTypography.label.copyWith(color: fg),
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
              return Opacity(
                opacity: isDisabled ? 0.4 : _opacityAnimation.value,
                child: Transform.scale(
                  scale: _scaleAnimation.value,
                  child: child,
                ),
              );
            },
            child: AnimatedContainer(
              duration: HavenDurations.fast,
              curve: HavenCurves.subtle,
              padding: EdgeInsets.symmetric(
                horizontal:
                    widget.compact ? HavenSpacing.md : HavenSpacing.lg,
                vertical:
                    widget.compact ? HavenSpacing.sm : HavenSpacing.sm + 2,
              ),
              decoration: BoxDecoration(
                color: effectiveBg,
                border: border,
                borderRadius: BorderRadius.circular(haven.radiusMd),
              ),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
