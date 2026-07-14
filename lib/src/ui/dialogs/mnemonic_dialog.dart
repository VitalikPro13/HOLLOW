import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Shows the 24-word recovery phrase dialog.
void showMnemonicDialog(BuildContext context, String mnemonic) {
  showHollowDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      final hollow = HollowTheme.of(dialogContext);

      return HollowDialog(
        title: 'Your Recovery Phrase',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This is your 24-word recovery phrase. Write it down and keep '
              'it safe. You will need it to restore your identity if you lose '
              'access to this device.',
              style:
                  HollowTypography.body.copyWith(color: hollow.textSecondary),
            ),
            const SizedBox(height: HollowSpacing.lg),
            Container(
              padding: const EdgeInsets.all(HollowSpacing.md),
              decoration: BoxDecoration(
                color: hollow.background,
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                border:
                    Border.all(color: hollow.warning.withValues(alpha: 0.4)),
              ),
              child: SelectableText(
                mnemonic,
                style: HollowTypography.mono.copyWith(
                  color: hollow.textPrimary,
                  height: 1.6,
                ),
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
            HollowButton.ghost(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: mnemonic));
                HollowToast.show(
                  dialogContext,
                  'Copied to clipboard',
                  type: HollowToastType.success,
                );
              },
              icon: const Icon(LucideIcons.copy, size: 16),
              child: const Text('Copy'),
            ),
          ],
        ),
        actions: [
          HollowButton.filled(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('I\'ve saved it'),
          ),
        ],
      );
    },
  );
}
