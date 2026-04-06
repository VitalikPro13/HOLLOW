import 'package:flutter/material.dart';
import 'package:hollow/src/core/shared_tickers.dart';

/// A subtle shimmer overlay for selected list items.
///
/// A transparent-to-highlight-to-transparent gradient sweeps across
/// the widget over 4s, repeating infinitely via [SharedTickers].
/// Very subtle — just enough to catch the eye.
///
/// Set [vertical] to true for a top-to-bottom sweep (voice channels).
class SelectionShimmer extends StatelessWidget {
  final Widget child;
  final Color highlightColor;
  final BorderRadius? borderRadius;
  final bool vertical;

  const SelectionShimmer({
    super.key,
    required this.child,
    required this.highlightColor,
    this.borderRadius,
    this.vertical = false,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: SharedTickers.instance.shimmer,
      builder: (context, value, child) {
        // Sweep position: -1.5 to 2.5 range.
        final pos = value * 4.0 - 1.5;
        final Alignment begin;
        final Alignment end;
        if (vertical) {
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
                  borderRadius: borderRadius ?? BorderRadius.zero,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: begin,
                        end: end,
                        colors: [
                          Colors.transparent,
                          highlightColor,
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
      child: child,
    );
  }
}
