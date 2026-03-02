import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/components/haven_button.dart';
import 'package:haven/src/ui/components/haven_dialog.dart';
import 'package:haven/src/ui/components/haven_toast.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Shows the 24-word recovery phrase dialog.
void showMnemonicDialog(BuildContext context, String mnemonic) {
  showHavenDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      final haven = HavenTheme.of(dialogContext);

      return HavenDialog(
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
                  HavenTypography.body.copyWith(color: haven.textSecondary),
            ),
            const SizedBox(height: HavenSpacing.lg),
            Container(
              padding: const EdgeInsets.all(HavenSpacing.md),
              decoration: BoxDecoration(
                color: haven.background,
                borderRadius: BorderRadius.circular(haven.radiusMd),
                border:
                    Border.all(color: haven.warning.withValues(alpha: 0.4)),
              ),
              child: SelectableText(
                mnemonic,
                style: HavenTypography.mono.copyWith(
                  color: haven.textPrimary,
                  height: 1.6,
                ),
              ),
            ),
            const SizedBox(height: HavenSpacing.md),
            HavenButton.ghost(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: mnemonic));
                HavenToast.show(
                  dialogContext,
                  'Copied to clipboard',
                  type: HavenToastType.success,
                );
              },
              icon: Icon(LucideIcons.copy, size: 16),
              child: const Text('Copy'),
            ),
          ],
        ),
        actions: [
          HavenButton.filled(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('I\'ve saved it'),
          ),
        ],
      );
    },
  );
}
