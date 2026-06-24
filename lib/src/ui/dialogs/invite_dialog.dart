import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Shows the invite link dialog after creating a room or server invite.
void showInviteDialog(
    BuildContext context, String link, String code) {
  final isServer = link.contains('server=');
  final subtitle = isServer
      ? 'Share this link to invite someone to your server:'
      : 'Share this link to invite someone to your room:';
  final codeLabel = isServer ? 'Server ID' : 'Room code';

  showHollowDialog(
    context: context,
    builder: (dialogContext) {
      final hollow = HollowTheme.of(dialogContext);

      return HollowDialog(
        title: 'Invite Link',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              subtitle,
              style: HollowTypography.body
                  .copyWith(color: hollow.textSecondary),
            ),
            const SizedBox(height: HollowSpacing.lg),
            Container(
              padding: const EdgeInsets.all(HollowSpacing.md),
              decoration: BoxDecoration(
                color: hollow.background,
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                border: Border.all(
                  color: hollow.accent.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      link,
                      style: HollowTypography.mono.copyWith(
                        color: hollow.accent,
                      ),
                    ),
                  ),
                  HollowPressable(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: link));
                      HollowToast.show(
                        dialogContext,
                        'Invite link copied to clipboard',
                        type: HollowToastType.success,
                      );
                    },
                    borderRadius:
                        BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    semanticLabel: 'Copy invite link',
                    child: Icon(LucideIcons.copy,
                        size: 18, color: hollow.accent),
                  ),
                ],
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
            Text(
              '$codeLabel: $code',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
              ),
            ),
          ],
        ),
        actions: [
          HollowButton.filled(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Done'),
          ),
        ],
      );
    },
  );
}
