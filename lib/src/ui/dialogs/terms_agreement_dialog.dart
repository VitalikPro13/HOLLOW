import 'package:flutter/material.dart';
import 'package:hollow/src/core/services/terms_agreement.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_link.dart';
import 'package:hollow/src/ui/settings/about_section.dart' show showLegalDocument;

/// The rule in a sentence, then both documents one tap away. Shared by
/// Welcome and the one-time question, so the two can never say different
/// things.
class TermsSummary extends StatelessWidget {
  /// Opens the documents as a phone sheet instead of a dialog.
  final bool touch;
  final TextAlign align;

  const TermsSummary({super.key, this.touch = false, this.align = TextAlign.start});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final centred = align == TextAlign.center;
    return Column(
      crossAxisAlignment:
          centred ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Hollow does not tolerate objectionable content or abusive users. '
          'An identity that breaks these rules can be banned from our relay.',
          textAlign: align,
          style: HollowTypography.body.copyWith(color: hollow.textSecondary),
        ),
        const SizedBox(height: HollowSpacing.sm),
        Wrap(
          alignment: centred ? WrapAlignment.center : WrapAlignment.start,
          spacing: HollowSpacing.lg,
          runSpacing: HollowSpacing.xs,
          children: [
            HollowTextLink(
              'Terms of Use',
              onTap: () => showLegalDocument(context,
                  title: 'Terms of Use',
                  assetPath: 'legal/TERMS_OF_USE.md',
                  touch: touch),
            ),
            HollowTextLink(
              'Privacy Policy',
              onTap: () => showLegalDocument(context,
                  title: 'Privacy Policy',
                  assetPath: 'legal/PRIVACY_POLICY.md',
                  touch: touch),
            ),
          ],
        ),
      ],
    );
  }
}

/// Asks an identity made before the Terms step once, after unlock. It has no
/// way out but agreeing, and it closes only once the agreement is saved.
Future<void> showTermsAgreementDialog(BuildContext context) {
  return showHollowDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _TermsAgreementDialog(),
  );
}

class _TermsAgreementDialog extends StatefulWidget {
  const _TermsAgreementDialog();

  @override
  State<_TermsAgreementDialog> createState() => _TermsAgreementDialogState();
}

class _TermsAgreementDialogState extends State<_TermsAgreementDialog>
    with HollowDialogAction {
  Future<void> _agree() async {
    final saved = await runDialogAction(recordTermsAgreement,
        fallback: "Couldn't save your answer. Try again.");
    if (saved && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: HollowDialog(
        title: 'Our Terms of Use',
        width: 440,
        busy: actionRunning,
        error: actionError,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const HollowDialogText(
              'Hollow now asks everyone to agree to its Terms of Use. You '
              'only need to do this once.',
            ),
            const SizedBox(height: HollowSpacing.md),
            TermsSummary(touch: HollowDialogSurface.isCompact(context)),
          ],
        ),
        actions: [
          HollowButton.filled(
            onPressed: _agree,
            loading: actionRunning,
            child: const Text('Agree and continue'),
          ),
        ],
      ),
    );
  }
}
