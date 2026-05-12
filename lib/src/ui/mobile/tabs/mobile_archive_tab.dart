import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:lucide_icons/lucide_icons.dart';

class MobileArchiveTab extends StatelessWidget {
  const MobileArchiveTab({super.key});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.archive,
            size: 48,
            color: hollow.textSecondary.withValues(alpha: 0.4),
          ),
          const SizedBox(height: HollowSpacing.lg),
          Text(
            'Archive',
            style: HollowTypography.heading.copyWith(
              color: hollow.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
