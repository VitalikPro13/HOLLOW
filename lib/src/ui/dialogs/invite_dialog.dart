import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/components/haven_button.dart';
import 'package:haven/src/ui/components/haven_dialog.dart';
import 'package:haven/src/ui/components/haven_pressable.dart';
import 'package:haven/src/ui/components/haven_toast.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Shows the invite link dialog after creating a room.
void showInviteDialog(
    BuildContext context, String link, String roomCode) {
  showHavenDialog(
    context: context,
    builder: (dialogContext) {
      final haven = HavenTheme.of(dialogContext);

      return HavenDialog(
        title: 'Invite Link Created',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Share this link to invite someone to your room:',
              style: HavenTypography.body
                  .copyWith(color: haven.textSecondary),
            ),
            const SizedBox(height: HavenSpacing.lg),
            Container(
              padding: const EdgeInsets.all(HavenSpacing.md),
              decoration: BoxDecoration(
                color: haven.background,
                borderRadius: BorderRadius.circular(haven.radiusMd),
                border: Border.all(
                  color: haven.accent.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      link,
                      style: HavenTypography.mono.copyWith(
                        color: haven.accent,
                      ),
                    ),
                  ),
                  HavenPressable(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: link));
                      HavenToast.show(
                        dialogContext,
                        'Invite link copied to clipboard',
                        type: HavenToastType.success,
                      );
                    },
                    borderRadius:
                        BorderRadius.circular(haven.radiusSm),
                    padding: const EdgeInsets.all(HavenSpacing.xs),
                    child: Icon(LucideIcons.copy,
                        size: 18, color: haven.accent),
                  ),
                ],
              ),
            ),
            const SizedBox(height: HavenSpacing.md),
            Text(
              'Room code: $roomCode',
              style: HavenTypography.caption.copyWith(
                color: haven.textSecondary,
              ),
            ),
          ],
        ),
        actions: [
          HavenButton.filled(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Done'),
          ),
        ],
      );
    },
  );
}
