import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/core/providers/shop_provider.dart' as shop;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// A `hollow://redeem/<code>` link landed. Keep the code, then say what it is
/// and what happens next.
///
/// Redeeming mints a support credential through a blind signature, and that
/// arrives in a later Hollow update. Until then the honest thing is to hold
/// the code rather than pretend to spend it, and to say so plainly: the art
/// works right now through the pack, and the mark comes later.
Future<void> showRedeemCodeDialog(BuildContext context, String code) async {
  bool newlyKept = true;
  String? failure;
  try {
    newlyKept = await shop.keepRedeemCode(code: code);
  } catch (e) {
    failure = e.toString().replaceFirst(RegExp(r'^[A-Za-z]+: '), '');
  }
  if (!context.mounted) return;

  await showHollowDialog<void>(
    context: context,
    builder: (dialogContext) {
      final hollow = HollowTheme.of(dialogContext);
      return HollowDialog(
        title: failure != null
            ? 'That code could not be kept'
            : (newlyKept ? 'Code kept' : 'Code already kept'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              code,
              style: HollowTypography.mono
                  .copyWith(color: hollow.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: HollowSpacing.md),
            Text(
              failure ??
                  'This is a Hollow Shop support code. Redeeming it lights a '
                      'supporter mark on your profile, and that arrives in a '
                      'later Hollow update. Hollow keeps the code until then, '
                      'and the receipt email has it too. Import the pack from '
                      'your order to wear the art now.',
              style: HollowTypography.body
                  .copyWith(color: hollow.textSecondary),
            ),
          ],
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (!dialogContext.mounted) return;
              HollowToast.show(dialogContext, 'Code copied',
                  type: HollowToastType.success);
            },
            child: const Text('Copy code'),
          ),
          HollowButton.filled(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      );
    },
  );
}
