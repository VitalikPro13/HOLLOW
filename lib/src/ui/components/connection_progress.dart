import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

enum ConnectionStage {
  /// OUR link is down: no relay, or in a DM header no session with that
  /// person. Never used just because nobody else is around.
  offline,

  alone,

  encrypted,

  customNetwork,
}

/// Header status pill: "Offline", "Only you", lock + "Encrypted", or
/// "Custom Network".
class ConnectionProgress extends StatelessWidget {
  final ConnectionStage stage;

  /// Overrides the hover explanation: one [ConnectionStage] means something
  /// different in a DM header and in a channel header.
  final String? tooltip;

  const ConnectionProgress({super.key, required this.stage, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final (IconData icon, String label, Color color, String tip) =
        switch (stage) {
      ConnectionStage.encrypted => (
          LucideIcons.lock,
          'Encrypted',
          hollow.success,
          'End-to-end encrypted. Nobody in between can read this',
        ),
      ConnectionStage.customNetwork => (
          LucideIcons.radio,
          'Custom Network',
          hollow.warning,
          'Connected through a custom relay',
        ),
      ConnectionStage.alone => (
          LucideIcons.users,
          'Only you',
          hollow.textSecondary,
          "You're connected. Nobody else is online here right now",
        ),
      ConnectionStage.offline => (
          LucideIcons.wifiOff,
          'Offline',
          hollow.textSecondary,
          'Not connected',
        ),
    };

    return HollowTooltip(
      message: tooltip ?? tip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: HollowSpacing.xs),
          Text(
            label,
            style: HollowTypography.caption.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
