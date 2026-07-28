import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
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
  ///
  /// Never rewinds the controller here: `deactivate()` calls this while the
  /// framework is mid-build, and moving the VALUE notifies the still-mounted
  /// [FadeTransition]/[SlideTransition] inside the entry, which is a
  /// `setState() called during build` crash. `stop()` only fires status
  /// listeners, which nothing here registers. The rewind happens in
  /// [_showTooltip] instead, before the next entry is in the tree.
  void _dismiss() {
    _hovering = false;
    _controller.stop();
    _entry?.remove();
    _entry = null;
  }

  void _showTooltip() {
    if (_entry != null) return;

    final renderBox = context.findRenderObject() as RenderBox;
    final size = renderBox.size;
    final position = overlayAnchorOf(context);
    // Safe rewind: no entry is mounted, so there is no listener to rebuild.
    _controller.value = 0.0;

    _entry = OverlayEntry(
      builder: (context) {
        final hollow = HollowTheme.of(context);

        return Positioned.fill(
          // The layout box spans the whole overlay so the delegate can place
          // the tooltip against the space it MEASURES. It must never take
          // pointers — the control that is being hovered sits underneath.
          child: IgnorePointer(
            child: CustomSingleChildLayout(
              delegate: _TooltipPositionDelegate(
                // `positionDependentBox` centres on the target and flips to
                // the other side when the real tooltip does not fit.
                target: position + Offset(size.width / 2, size.height / 2),
                verticalOffset: size.height / 2 + 6,
                preferBelow: widget.preferBelow,
              ),
              child: FadeTransition(
                opacity: _opacity,
                child: SlideTransition(
                  position: _offset,
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
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

/// Places the tooltip against the overlay it actually renders in, using the
/// tooltip's MEASURED size.
///
/// The old code estimated 7px per character and a flat 28px height and
/// compared them against `MediaQuery.size`. Both were wrong at the bottom of
/// the window: the desktop title bar makes the overlay shorter than the
/// window, so a dock-bar tooltip "fit" below its button and rendered off the
/// bottom edge — the user saw an empty sliver of a box (issue #20). Larger
/// text made it worse, since a wrapped two-line tooltip is nowhere near 28px.
/// [size] here is the overlay's own box and [childSize] is the real tooltip,
/// so neither estimate is needed.
class _TooltipPositionDelegate extends SingleChildLayoutDelegate {
  final Offset target;
  final double verticalOffset;
  final bool preferBelow;

  const _TooltipPositionDelegate({
    required this.target,
    required this.verticalOffset,
    required this.preferBelow,
  });

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    // Loose, minus the margin `positionDependentBox` keeps on each side, so a
    // long label wraps instead of running past the edge.
    return constraints.loosen().copyWith(
          maxWidth: math.max(0.0, constraints.maxWidth - _kTooltipMargin * 2),
        );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    return positionDependentBox(
      size: size,
      childSize: childSize,
      target: target,
      verticalOffset: verticalOffset,
      preferBelow: preferBelow,
      margin: _kTooltipMargin,
    );
  }

  @override
  bool shouldRelayout(_TooltipPositionDelegate old) =>
      old.target != target ||
      old.verticalOffset != verticalOffset ||
      old.preferBelow != preferBelow;
}

const double _kTooltipMargin = 8.0;
