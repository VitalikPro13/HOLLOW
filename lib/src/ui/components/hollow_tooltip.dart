import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// Hollow-styled tooltip — dark, compact, fast.
///
/// Appears after 400ms hover delay. Fades in 100ms + slides from 4px offset.
/// Edge-aware: automatically repositions to stay within window bounds.
/// Replaces Material Tooltip everywhere.
///
/// IMPORTANT: Hide always removes the overlay entry immediately (no reverse
/// animation). This prevents orphaned tooltips when parent widgets rebuild
/// or leave the tree during hover (e.g., call bar buttons disappearing).
class HollowTooltip extends StatefulWidget {
  final String message;
  final Widget child;
  final bool preferBelow;

  const HollowTooltip({
    super.key,
    required this.message,
    required this.child,
    this.preferBelow = true,
  });

  @override
  State<HollowTooltip> createState() => _HollowTooltipState();
}

class _HollowTooltipState extends State<HollowTooltip>
    with SingleTickerProviderStateMixin {
  OverlayEntry? _entry;
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;

  bool _hovering = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.animationsDisabled ? Duration.zero : const Duration(milliseconds: 100),
    );
    _opacity = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
    _offset = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));
  }

  @override
  void didUpdateWidget(covariant HollowTooltip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message != widget.message) {
      _dismiss();
    }
  }

  @override
  void deactivate() {
    _dismiss();
    super.deactivate();
  }

  @override
  void dispose() {
    _dismiss();
    _controller.dispose();
    super.dispose();
  }

  /// Immediately kill the tooltip overlay — no animation, no delay.
  void _dismiss() {
    _hovering = false;
    _controller.stop();
    _controller.reset();
    _entry?.remove();
    _entry = null;
  }

  void _showTooltip() {
    if (_entry != null) return;

    final renderBox = context.findRenderObject() as RenderBox;
    final size = renderBox.size;
    final position = renderBox.localToGlobal(Offset.zero);

    _entry = OverlayEntry(
      builder: (context) {
        final hollow = HollowTheme.of(context);
        final screenSize = MediaQuery.of(context).size;
        const padding = 8.0;
        const gap = 6.0;

        // Measure tooltip width estimate (rough: 7px per char + padding).
        final tooltipWidth =
            (widget.message.length * 7.0 + HollowSpacing.sm * 2 + 4)
                .clamp(40.0, screenSize.width - padding * 2);

        // Center horizontally on the widget.
        double left = position.dx + size.width / 2 - tooltipWidth / 2;

        // Clamp horizontal to stay within window.
        if (left < padding) left = padding;
        if (left + tooltipWidth > screenSize.width - padding) {
          left = screenSize.width - tooltipWidth - padding;
        }

        // Vertical: prefer below, but flip above if it would overflow.
        final belowY = position.dy + size.height + gap;
        final aboveY = position.dy - gap;
        // Estimate tooltip height ~28px.
        const tooltipHeight = 28.0;

        final bool showBelow;
        if (widget.preferBelow) {
          showBelow = belowY + tooltipHeight <= screenSize.height - padding;
        } else {
          showBelow = aboveY - tooltipHeight < padding;
        }

        final double top;
        if (showBelow) {
          top = belowY;
        } else {
          top = aboveY - tooltipHeight;
        }

        return Positioned(
          left: left,
          top: top,
          child: FadeTransition(
            opacity: _opacity,
            child: SlideTransition(
              position: _offset,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: screenSize.width - padding * 2,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.sm + 2,
                    vertical: HollowSpacing.xs + 2,
                  ),
                  decoration: BoxDecoration(
                    color: hollow.elevated,
                    borderRadius:
                        BorderRadius.circular(hollow.radiusSm),
                    border: Border.all(color: hollow.border),
                  ),
                  child: Text(
                    widget.message,
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    Overlay.of(context).insert(_entry!);
    _controller.forward();
  }

  void _onHoverStart() {
    _hovering = true;
    Future.delayed(const Duration(milliseconds: 400), () {
      if (_hovering && mounted) _showTooltip();
    });
  }

  void _onHoverEnd() {
    _hovering = false;
    _dismiss();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _onHoverStart(),
      onExit: (_) => _onHoverEnd(),
      child: widget.child,
    );
  }
}
