import 'package:flutter/material.dart';
import 'package:hollow/src/core/shared_tickers.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// A small colored circle indicating connection/encryption status.
///
/// Set [pulse] to true for a breathing glow animation — a soft ring
/// that fades in/out over 3 seconds. All pulsing dots share a single
/// ticker via [SharedTickers.pulse] instead of per-instance controllers.
class StatusDot extends StatelessWidget {
  final Color? color;
  final double size;
  final bool pulse;

  const StatusDot({
    super.key,
    this.color,
    this.size = 8,
    this.pulse = false,
  });

  /// Online status (green) with optional pulse.
  const StatusDot.online({super.key, this.size = 8, this.pulse = false})
      : color = null; // uses success from theme

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final dotColor = color ?? hollow.success;

    if (!pulse) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: dotColor,
          shape: BoxShape.circle,
        ),
      );
    }

    return ValueListenableBuilder<double>(
      valueListenable: SharedTickers.instance.pulse,
      builder: (context, value, _) {
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: dotColor.withValues(alpha: 0.4 * value),
                blurRadius: 3 * value,
                spreadRadius: 1.5 * value,
              ),
            ],
          ),
        );
      },
    );
  }
}
