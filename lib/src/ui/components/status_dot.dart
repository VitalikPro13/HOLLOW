import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// A small status indicator (connection / presence / encryption).
///
/// Presence is conveyed by SHAPE as well as colour ([filled] true is a solid
/// disc, false a hollow ring), so the state survives colour blindness.
///
/// Always static: a breathing glow repainted every dot on screen on a shared
/// 60fps clock forever, for an effect nobody looked at.
class StatusDot extends StatelessWidget {
  final Color? color;
  final double size;

  /// Solid disc when true, hollow ring when false: the non-colour cue.
  final bool filled;

  /// Optional screen-reader label (e.g. "Online" / "Offline").
  final String? semanticLabel;

  const StatusDot({
    super.key,
    this.color,
    this.size = 8,
    this.filled = true,
    this.semanticLabel,
  });

  const StatusDot.online({super.key, this.size = 8})
      : color = null, // uses success from theme
        filled = true,
        semanticLabel = 'Online';

  const StatusDot.offline({super.key, this.size = 8, this.color})
      : filled = false,
        semanticLabel = 'Offline';

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final dotColor = color ?? hollow.success;

    final dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: filled ? dotColor : Colors.transparent,
        shape: BoxShape.circle,
        border: filled
            ? null
            : Border.all(color: dotColor, width: size <= 8 ? 1.5 : 2),
      ),
    );

    if (semanticLabel != null) {
      return Semantics(label: semanticLabel, child: dot);
    }
    return dot;
  }
}
