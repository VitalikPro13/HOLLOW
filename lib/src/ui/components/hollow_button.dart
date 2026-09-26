import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';

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

  /// Phones: at least [touchHeight] tall, the platforms' minimum target.
  /// Desktop leaves it off, so its rows keep their density.
  final bool touch;

  static const double touchHeight = 44;

  /// Tints an [HollowButton.outline] with the error colour, to flag a
  /// cautionary action without the solid `.danger` fill that confirm dialogs
  /// own. No effect on other variants.
  final bool danger;

  /// Usually null, because the [child] text auto-names the button. Set it for
  /// an icon-only button, or when the visible text is the wrong announcement.
  final String? semanticLabel;

  /// A request this button started is running: the label gives way to a
  /// spinner in the same colours at the same width, and presses are ignored.
  /// Loading, never disabled, so the button does not fade while it works.
  final bool loading;

  const HollowButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.variant = HollowButtonVariant.filled,
    this.expand = false,
    this.compact = false,
    this.touch = false,
    this.semanticLabel,
    this.loading = false,
    this.danger = false,
  });

  const HollowButton.filled({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expand = false,
    this.compact = false,
    this.touch = false,
    this.semanticLabel,
    this.loading = false,
  })  : variant = HollowButtonVariant.filled,
        danger = false;

  const HollowButton.ghost({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expand = false,
    this.compact = false,
    this.touch = false,
    this.semanticLabel,
    this.loading = false,
  })  : variant = HollowButtonVariant.ghost,
        danger = false;

  const HollowButton.outline({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expand = false,
    this.compact = false,
    this.touch = false,
    this.semanticLabel,
    this.loading = false,
    this.danger = false,
  }) : variant = HollowButtonVariant.outline;

  const HollowButton.danger({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expand = false,
    this.compact = false,
    this.touch = false,
    this.semanticLabel,
    this.loading = false,
  })  : variant = HollowButtonVariant.danger,
        danger = false;

  @override
  State<HollowButton> createState() => _HollowButtonState();
}

/// Turns on [HollowButton.touch] for every button below it, for a container
/// that knows it is on a phone (a compact dialog's action row) when the
/// buttons it was handed do not.
class HollowButtonTouchScope extends InheritedWidget {
  final bool touch;

  const HollowButtonTouchScope({
    super.key,
    required this.touch,
    required super.child,
  });

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<HollowButtonTouchScope>()
          ?.touch ??
      false;

  @override
  bool updateShouldNotify(HollowButtonTouchScope oldWidget) =>
      touch != oldWidget.touch;
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
    _controller = AnimationController(vsync: this);
    // Same press as HollowPressable: the reverse curve runs on t going 1 to 0,
    // so ease-in is a release that leaves quickly and settles.
    final curve = CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.enter,
      reverseCurve: HollowCurves.exit,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.98).animate(curve);
    _opacityAnimation = Tween<double>(begin: 1.0, end: 0.85).animate(curve);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final isDisabled = widget.onPressed == null && !widget.loading;
    final isInteractive = widget.onPressed != null && !widget.loading;
    final touch = widget.touch || HollowButtonTouchScope.of(context);

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
        // Grey, not accent: the accent means THE primary action, and ghost is
        // everything that is not. The hover fill fades from its own RGB at
        // zero alpha, never Colors.transparent (that lerps through black).
        fg = _hovering && isInteractive
            ? hollow.textPrimary
            : hollow.textSecondary;
        hoverBg = hollow.textPrimary.withValues(alpha: 0.06);
        bg = hoverBg.withValues(alpha: 0.0);
      case HollowButtonVariant.outline:
        final tint = widget.danger ? hollow.error : hollow.accent;
        bg = tint.withValues(alpha: 0.0);
        fg = widget.danger ? hollow.error : hollow.accentText;
        hoverBg =
            widget.danger ? hollow.error.withValues(alpha: 0.12) : hollow.accentMuted;
        border = Border.all(
          color: _hovering && isInteractive
              ? tint.withValues(alpha: 0.6)
              : tint.withValues(alpha: 0.4),
        );
      case HollowButtonVariant.danger:
        bg = hollow.errorFill;
        fg = hollow.textOnError;
        hoverBg = hollow.errorFill.withValues(alpha: 0.85);
    }

    // Disabled goes NEUTRAL rather than a faded accent: a 40% fade of a 40%
    // outline all but vanished on the light theme.
    if (isDisabled) {
      fg = hollow.textTertiary;
      switch (widget.variant) {
        case HollowButtonVariant.filled:
        case HollowButtonVariant.danger:
          bg = hollow.textPrimary.withValues(alpha: 0.08);
        case HollowButtonVariant.outline:
          border = Border.all(color: hollow.textTertiary.withValues(alpha: 0.4));
        case HollowButtonVariant.ghost:
          break;
      }
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
        // IconTheme as well as the text style: an icon-only button passes its
        // glyph as the CHILD, not the icon slot, and without this it renders in
        // the ambient icon colour rather than the variant's foreground.
        IconTheme(
          data: IconThemeData(color: fg, size: iconGlyph),
          child: DefaultTextStyle(
            style: HollowTypography.label.copyWith(color: fg, height: 1.0),
            child: widget.child,
          ),
        ),
      ],
    );

    if (widget.expand) {
      content = SizedBox(width: double.infinity, child: content);
    }

    if (widget.loading) {
      content = Stack(
        alignment: Alignment.center,
        children: [
          Visibility(
            visible: false,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            // A screen reader still hears what the button is, then "Loading".
            maintainSemantics: true,
            child: content,
          ),
          // Positioned so the spinner, a pixel taller than a label line,
          // paints over the label's box instead of growing the button.
          Positioned.fill(
            child: OverflowBox(
              // Zero minimums, or the label's tight width stretches the
              // spinner into an oval.
              minWidth: 0,
              minHeight: 0,
              maxWidth: double.infinity,
              maxHeight: double.infinity,
              child: HollowSpinner(color: fg),
            ),
          ),
        ],
      );
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
            _controller
              ..duration = HollowDurations.exit
              ..reverseDuration = HollowDurations.fast
              ..forward();
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
                        ? const AlwaysStoppedAnimation(1.0)
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
                  // The Row centres its label in the extra height.
                  constraints: touch
                      ? const BoxConstraints(minHeight: HollowButton.touchHeight)
                      : null,
                  // The outline's 1 px border comes out of the padding, so
                  // swapping a variant never moves the layout around it.
                  padding: EdgeInsets.symmetric(
                    horizontal: (widget.compact
                            ? HollowSpacing.md
                            : HollowSpacing.lg) -
                        (border != null ? 1 : 0),
                    vertical: (widget.compact
                            ? HollowSpacing.sm
                            : HollowSpacing.sm + 2) -
                        (border != null ? 1 : 0),
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
