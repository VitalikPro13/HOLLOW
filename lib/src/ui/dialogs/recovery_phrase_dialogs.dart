import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/services/privacy_screen.dart';
import 'package:hollow/src/rust/api/roster.dart' as roster_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';

/// Where the recovery phrase is typed (design ID-1). Nothing here keeps the
/// phrase: it goes to Rust, which turns it into keys and drops it.

/// The field a phrase is typed into: a few lines of words, no suggestions.
class RecoveryPhraseField extends StatelessWidget {
  final TextEditingController controller;
  final String? errorText;
  final ValueChanged<String>? onChanged;
  final bool autofocus;

  const RecoveryPhraseField({
    super.key,
    required this.controller,
    this.errorText,
    this.onChanged,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return SecretScreen(
      child: HollowTextField(
        controller: controller,
        hintText: 'The 12 or 24 words, in order',
        minLines: 2,
        maxLines: 4,
        autofocus: autofocus,
        errorText: errorText,
        onChanged: onChanged,
        keyboardType: TextInputType.visiblePassword,
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z\s]')),
        ],
      ),
    );
  }
}

/// What a typed phrase that is not this identity's says.
const kWrongPhraseText =
    "That isn't your recovery phrase. Check each word and the order.";

/// Type the phrase to make sure the copy kept is right. True when it was.
Future<bool> showCheckPhraseDialog(BuildContext context) async {
  final ok = await showHollowDialog<bool>(
    context: context,
    builder: (_) => _PhraseDialog(
      title: 'Check your recovery phrase',
      body: "Type it from the copy you keep. Hollow doesn't store it, so this "
          'is how you know the copy is right.',
      confirmLabel: 'Check',
      onSubmit: (_, _) async {},
    ),
  );
  return ok ?? false;
}

/// Type the phrase and keep this device plus the devices picked: every other
/// device stops counting at once. [initiallyKept] starts ticked.
Future<bool> showRecoverWithPhraseDialog(
  BuildContext context, {
  required roster_api.RosterStatus status,
  required String title,
  required String body,
  required String confirmLabel,
  bool danger = false,
  Set<String> initiallyKept = const {},
}) async {
  final others = status.devices.where((d) => !d.thisDevice).toList();
  final ok = await showHollowDialog<bool>(
    context: context,
    builder: (_) => _PhraseDialog(
      title: title,
      body: body,
      confirmLabel: confirmLabel,
      danger: danger,
      devices: others.map((d) => d.devicePeerId).toList(),
      initiallyKept: initiallyKept,
      onSubmit: (phrase, keep) =>
          roster_api.recoverWithPhrase(phrase: phrase, keep: keep.toList()),
    ),
  );
  return ok ?? false;
}

/// Type the phrase to choose whether a device restored from a backup may join by
/// nobody refusing it for seven days. True when the choice was made.
Future<bool> showBackupWaitDialog(BuildContext context, {required bool allowed}) async {
  final ok = await showHollowDialog<bool>(
    context: context,
    builder: (_) => _PhraseDialog(
      title: allowed ? 'Let backups join on their own' : 'Stop backups joining on their own',
      body: allowed
          ? 'A device restored from a backup joins after seven days if none of '
              'your devices refuses it. Someone who steals a backup and its '
              "password can get in the same way if you're away for a week. A "
              "device that's waiting to join right now has to ask again."
          : 'A device restored from a backup then joins only when one of your '
              'devices approves it, or when your recovery phrase is typed on it. '
              'If you ever lose every device and the phrase, a backup can\'t '
              "bring this identity back. A device that's waiting to join right "
              'now has to ask again.',
      confirmLabel: allowed ? 'Turn on' : 'Turn off',
      onSubmit: (phrase, _) =>
          roster_api.setBackupWait(phrase: phrase, allowed: allowed),
    ),
  );
  return ok ?? false;
}

/// Type the phrase on a device waiting to join: it joins at once.
Future<bool> showJoinWithPhraseDialog(BuildContext context) async {
  final ok = await showHollowDialog<bool>(
    context: context,
    builder: (_) => _PhraseDialog(
      title: 'Join with your recovery phrase',
      body: 'Typing it adds this device to your identity right away, without '
          'waiting for another device.',
      confirmLabel: 'Join',
      onSubmit: (phrase, _) => roster_api.joinWithPhrase(phrase: phrase),
    ),
  );
  return ok ?? false;
}

class _PhraseDialog extends ConsumerStatefulWidget {
  final String title;
  final String body;
  final String confirmLabel;
  final bool danger;
  final List<String> devices;
  final Set<String> initiallyKept;
  final Future<void> Function(String phrase, Set<String> keep) onSubmit;

  const _PhraseDialog({
    required this.title,
    required this.body,
    required this.confirmLabel,
    required this.onSubmit,
    this.danger = false,
    this.devices = const [],
    this.initiallyKept = const {},
  });

  @override
  ConsumerState<_PhraseDialog> createState() => _PhraseDialogState();
}

class _PhraseDialogState extends ConsumerState<_PhraseDialog>
    with HollowDialogAction {
  final _phrase = TextEditingController();
  late final Set<String> _keep = {...widget.initiallyKept};
  String? _phraseError;

  @override
  void dispose() {
    _phrase.dispose();
    super.dispose();
  }

  String get _typed => _phrase.text.trim().split(RegExp(r'\s+')).join(' ');

  Future<void> _submit() async {
    if (actionRunning || _phrase.text.trim().isEmpty) return;
    final phrase = _typed.toLowerCase();
    var wrong = false;
    final ok = await runDialogAction(() async {
      if (!await roster_api.checkRecoveryPhrase(phrase: phrase)) {
        wrong = true;
        return;
      }
      await widget.onSubmit(phrase, _keep);
    });
    if (!mounted) return;
    if (wrong) {
      // The action "succeeded" without a pop, so the running state is ours to end.
      setState(() {
        actionRunning = false;
        _phraseError = kWrongPhraseText;
      });
      return;
    }
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final labels = ref.watch(deviceLabelProvider);
    final kinds = ref.watch(deviceKindProvider);
    String name(String id) =>
        deviceGivenName(id, labels: labels, kinds: kinds) ?? shortenPeerId(id);
    final filled = _phrase.text.trim().isNotEmpty;
    return HollowDialog(
      title: widget.title,
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowDialogText(widget.body),
          const SizedBox(height: HollowSpacing.lg),
          const SettingsFieldLabel(label: 'Recovery phrase'),
          const SizedBox(height: HollowSpacing.xs),
          RecoveryPhraseField(
            controller: _phrase,
            autofocus: true,
            errorText: _phraseError,
            onChanged: (_) => setState(() {
              _phraseError = null;
              actionError = null;
            }),
          ),
          if (widget.devices.isNotEmpty) ...[
            const SizedBox(height: HollowSpacing.lg),
            const SettingsFieldLabel(label: 'Other devices to keep'),
            const SizedBox(height: HollowSpacing.sm),
            Wrap(
              spacing: HollowSpacing.sm,
              runSpacing: HollowSpacing.sm,
              children: [
                for (final id in widget.devices)
                  HollowChip(
                    label: name(id),
                    selected: _keep.contains(id),
                    onTap: () => setState(() {
                      if (!_keep.remove(id)) _keep.add(id);
                    }),
                  ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        widget.danger
            ? HollowButton.danger(
                onPressed: filled ? _submit : null,
                loading: actionRunning,
                child: Text(widget.confirmLabel),
              )
            : HollowButton.filled(
                onPressed: filled ? _submit : null,
                loading: actionRunning,
                child: Text(widget.confirmLabel),
              ),
      ],
    );
  }
}
