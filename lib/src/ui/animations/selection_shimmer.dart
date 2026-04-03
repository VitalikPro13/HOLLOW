import 'package:flutter/material.dart';

/// A subtle shimmer overlay for selected list items.
///
/// A transparent-to-highlight-to-transparent gradient sweeps across
/// the widget over [duration] (default 4s), repeating infinitely.
/// Very subtle — just enough to catch the eye.
///
/// Set [vertical] to true for a top-to-bottom sweep (voice channels).
class SelectionShimmer extends StatefulWidget {
  final Widget child;
  final Color highlightColor;
  final Duration duration;
  final BorderRadius? borderRadius;
  final bool vertical;

  const SelectionShimmer({
    super.key,
    required this.child,
    required this.highlightColor,
    this.duration = const Duration(milliseconds: 4000),
    this.borderRadius,
    this.vertical = false,
  });

  @override
  State<SelectionShimmer> createState() => _SelectionShimmerState();
}

class _SelectionShimmerState extends State<SelectionShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // Sweep position: -1.5 to 2.5 range.
        final pos = _controller.value * 4.0 - 1.5;
        final Alignment begin;
        final Alignment end;
        if (widget.vertical) {
          begin = Alignment(0, pos - 0.5);
          end = Alignment(0, pos + 0.5);
        } else {
          begin = Alignment(pos - 0.5, 0);
          end = Alignment(pos + 0.5, 0);
        }
        return Stack(
          children: [
            child!,
            Positioned.fill(
              child: IgnorePointer(
                child: ClipRRect(
                  borderRadius: widget.borderRadius ?? BorderRadius.zero,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: begin,
                        end: end,
                        colors: [
                          Colors.transparent,
                          widget.highlightColor,
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
      child: widget.child,
    );
  }
}
