import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Connection stage for the status indicator.
enum ConnectionStage {
  /// Peer/members offline.
  offline,

  /// Fully encrypted session established.
  encrypted,
}

/// Simple connection status indicator: "Offline" or lock + "Encrypted".
class ConnectionProgress extends StatelessWidget {
  final ConnectionStage stage;

  const ConnectionProgress({super.key, required this.stage});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    if (stage == ConnectionStage.encrypted) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.lock, size: 14, color: hollow.success),
          const SizedBox(width: HollowSpacing.xs),
          Text(
            'Encrypted',
            style: HollowTypography.caption.copyWith(color: hollow.success),
          ),
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.wifiOff, size: 14, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.xs),
        Text(
          'Offline',
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
        ),
      ],
    );
  }
}
