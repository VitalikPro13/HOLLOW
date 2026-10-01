import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/home_setup_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/rust/api/roster.dart' as roster_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Shows a new identity's recovery phrase, once, and asks for a few words back.
/// Hollow keeps no copy (design ID-1): once confirmed, the app forgets it.
void showMnemonicDialog(BuildContext context, String mnemonic) {
  final container = ProviderScope.containerOf(context, listen: false);
  showHollowDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PhraseRevealDialog(
      mnemonic: mnemonic,
      title: 'Your recovery phrase',
      intro: 'These words are the only way back into your identity, and they '
          'have the last word on which devices are yours. Write them down in '
          "order and keep them somewhere safe. Hollow doesn't keep a copy, so "
          'nobody can show them to you again.',
      onConfirmed: () async {
        container.read(identityProvider.notifier).forgetMnemonic();
        await container.read(homeSetupProvider.notifier).markPhraseSaved();
      },
    ),
  );
}

/// The first start of an identity from before the phrase became its root: the
/// phrase it stored is shown one last time, checked, made the root, and erased.
/// "Later" keeps it stored and leaves a reminder.
Future<bool> showPhraseUpgradeDialog(BuildContext context, String stored) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final done = await showHollowDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PhraseRevealDialog(
      mnemonic: stored,
      title: 'Confirm your recovery phrase',
      intro: 'Your recovery phrase now decides which devices are yours, so '
          'Hollow stops keeping a copy. Here it is one last time. Check that '
          'the copy you keep matches it.',
      laterAllowed: true,
      onConfirmed: () async {
        final status = await roster_api.rosterStatus();
        final keep = status.devices
            .where((d) => d.state == 'member' && !d.thisDevice)
            .map((d) => d.devicePeerId)
            .toList();
        await roster_api.recoverWithPhrase(phrase: stored, keep: keep);
        await container.read(homeSetupProvider.notifier).markPhraseSaved();
        container.invalidate(phraseUpgradePendingProvider);
      },
    ),
  );
  return done ?? false;
}

class _PhraseRevealDialog extends StatefulWidget {
  final String mnemonic;
  final String title;
  final String intro;
  final bool laterAllowed;
  final Future<void> Function() onConfirmed;

  const _PhraseRevealDialog({
    required this.mnemonic,
    required this.title,
    required this.intro,
    required this.onConfirmed,
    this.laterAllowed = false,
  });

  @override
  State<_PhraseRevealDialog> createState() => _PhraseRevealDialogState();
}

class _PhraseRevealDialogState extends State<_PhraseRevealDialog> with HollowDialogAction {
  late final List<String> _words = widget.mnemonic.trim().split(RegExp(r'\s+'));

  /// Which words are asked back, in order, picked at random each time.
  late final List<int> _asked = () {
    final picks = <int>{};
    final rng = Random.secure();
    while (picks.length < min(3, _words.length)) {
      picks.add(rng.nextInt(_words.length));
    }
    return picks.toList()..sort();
  }();
  late final List<TextEditingController> _answers =
      List.generate(_asked.length, (_) => TextEditingController());
  bool _checking = false;
  String? _mismatch;

  @override
  void dispose() {
    for (final c in _answers) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _answered => _answers.every((c) => c.text.trim().isNotEmpty);

  Future<void> _check() async {
    final right = [
      for (var i = 0; i < _asked.length; i++)
        _answers[i].text.trim().toLowerCase() == _words[_asked[i]].toLowerCase(),
    ].every((ok) => ok);
    if (!right) {
      setState(() => _mismatch = "Those words don't match. Check your copy.");
      return;
    }
    final ok = await runDialogAction(widget.onConfirmed,
        fallback: "Hollow couldn't confirm your phrase. Try again.");
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return _checking ? _askBack(context) : _reveal(context);
  }

  Widget _reveal(BuildContext context) {
    return HollowDialog(
      title: widget.title,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowDialogText(widget.intro),
          const SizedBox(height: HollowSpacing.lg),
          RecoveryPhraseGrid(mnemonic: widget.mnemonic),
        ],
      ),
      leadingActions: [
        HollowButton.ghost(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: widget.mnemonic));
            HollowToast.show(context, 'Copied', type: HollowToastType.success);
          },
          icon: const Icon(LucideIcons.copy, size: 16),
          child: const Text('Copy'),
        ),
      ],
      actions: [
        if (widget.laterAllowed)
          HollowButton.ghost(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Later'),
          ),
        HollowButton.filled(
          onPressed: () => setState(() => _checking = true),
          child: const Text("I've written it down"),
        ),
      ],
    );
  }

  Widget _askBack(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowDialog(
      title: 'Check your copy',
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HollowDialogText('Type these words from the copy you wrote down.'),
          for (var i = 0; i < _asked.length; i++) ...[
            const SizedBox(height: HollowSpacing.md),
            SettingsFieldLabel(label: 'Word ${_asked[i] + 1}'),
            const SizedBox(height: HollowSpacing.xs),
            HollowTextField(
              controller: _answers[i],
              autofocus: i == 0,
              keyboardType: TextInputType.visiblePassword,
              onChanged: (_) => setState(() => _mismatch = null),
              onSubmitted: (_) => _answered ? _check() : null,
            ),
          ],
          if (_mismatch != null) ...[
            const SizedBox(height: HollowSpacing.sm),
            Text(
              _mismatch!,
              style: HollowTypography.bodySmall.copyWith(color: hollow.error),
            ),
          ],
        ],
      ),
      leadingActions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => setState(() => _checking = false),
          child: const Text('Show the words'),
        ),
      ],
      actions: [
        HollowButton.filled(
          onPressed: _answered && !actionRunning ? _check : null,
          loading: actionRunning,
          child: const Text('Check'),
        ),
      ],
    );
  }
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
