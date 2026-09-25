import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/home_setup_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Shows the 24-word recovery phrase dialog.
void showMnemonicDialog(BuildContext context, String mnemonic) {
  final container = ProviderScope.containerOf(context, listen: false);
  showHollowDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return HollowDialog(
        title: 'Your recovery phrase',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const HollowDialogText(
              'These 24 words bring back your identity if you lose this '
              'device. Write them down in order and keep them somewhere safe.',
            ),
            const SizedBox(height: HollowSpacing.lg),
            RecoveryPhraseGrid(mnemonic: mnemonic),
          ],
        ),
        leadingActions: [
          HollowButton.ghost(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: mnemonic));
              HollowToast.show(
                dialogContext,
                'Copied',
                type: HollowToastType.success,
              );
            },
            icon: const Icon(LucideIcons.copy, size: 16),
            child: const Text('Copy'),
          ),
        ],
        actions: [
          HollowButton.filled(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              // The phrase is already written down; only the reminder is at
              // stake, so a failed write is said, never a reason to keep the
              // dialog up.
              container
                  .read(homeSetupProvider.notifier)
                  .markPhraseSaved()
                  .catchError((Object e) {
                if (context.mounted) {
                  HollowToast.show(
                    context,
                    friendlyError(e,
                        fallback: "Hollow couldn't note that you saved it, so "
                            'it may remind you again.'),
                    type: HollowToastType.error,
                  );
                }
              });
            },
            child: const Text('I\'ve saved it'),
          ),
        ],
      );
    },
  );
}

/// The phrase as numbered words, read left to right: three columns on a
/// desktop, two on a phone, so each word is copied by hand in order.
class RecoveryPhraseGrid extends StatelessWidget {
  final String mnemonic;

  const RecoveryPhraseGrid({super.key, required this.mnemonic});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final words = mnemonic.trim().split(RegExp(r'\s+'));
    final columns = HollowDialogSurface.isCompact(context) ? 2 : 3;
    final rows = (words.length / columns).ceil();
    final number = HollowTypography.monoSmall.copyWith(
      color: hollow.textTertiary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final word = HollowTypography.mono.copyWith(color: hollow.textPrimary);

    Widget cell(int i) => Row(
          children: [
            SizedBox(
              width: HollowSpacing.lg + HollowSpacing.xs,
              child: Text('${i + 1}', style: number, textAlign: TextAlign.end),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(child: Text(words[i], style: word)),
          ],
        );

    return SelectionArea(
      child: Column(
        children: [
          for (var r = 0; r < rows; r++) ...[
            if (r > 0) const SizedBox(height: HollowSpacing.sm),
            Row(
              children: [
                for (var c = 0; c < columns; c++)
                  Expanded(
                    child: r * columns + c < words.length
                        ? cell(r * columns + c)
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
