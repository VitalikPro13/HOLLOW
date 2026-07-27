import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Connection stage for the status indicator.
enum ConnectionStage {
  /// YOU are not connected — no relay link (or, in a DM header, no session
  /// with that person). Never used just because nobody else is around.
  offline,

  /// Connected, but nobody else is here yet.
  alone,

  /// Fully encrypted session established.
  encrypted,

  /// User is on a custom (non-official) relay network.
  customNetwork,
}

/// Header status pill: "Offline", "Only you", lock + "Encrypted", or
/// "Custom Network".
class ConnectionProgress extends StatelessWidget {
  final ConnectionStage stage;

  /// Overrides the default hover explanation — the same [ConnectionStage] means
  /// something slightly different in a DM header (the person) and a channel
  /// header (the relay + the other members).
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
          'End-to-end encrypted — nobody in between can read this',
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
          "You're connected — nobody else is online here right now",
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
