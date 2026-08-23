import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// A small status indicator (connection / presence / encryption).
///
/// To satisfy "Differentiate Without Color", presence is conveyed by SHAPE as
/// well as color: [filled] true = solid disc (online/active), false = a hollow
/// ring with a transparent center (offline). A screen reader picks up
/// [semanticLabel] when provided.
///
/// Always static. It used to offer a breathing glow, which meant every dot on
/// screen repainted on a shared 60fps clock forever — for an effect nobody
/// looked at. A status dot's job is the shape and colour it is showing right
/// now, not motion.
class StatusDot extends StatelessWidget {
  final Color? color;
  final double size;

  /// Solid disc when true (online); hollow ring when false (offline). The
  /// shape difference is the non-color cue.
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

  /// Online status (green).
  const StatusDot.online({super.key, this.size = 8})
      : color = null, // uses success from theme
        filled = true,
        semanticLabel = 'Online';

  /// Offline status — hollow ring (shape cue).
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
        // Hollow ring for offline: transparent fill + colored border.
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
