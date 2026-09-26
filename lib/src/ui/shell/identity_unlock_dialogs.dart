import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/call/call_actions.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/shell/voice_quick_controls.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Results [UnlockDialog] pops besides the typed secret.
const kUnlockRecover = '__recover__';
const kUnlockBiometric = '__biometric__';

/// The launch and app-lock prompt for the app PIN or password. Pops the typed
/// secret, [kUnlockRecover] or [kUnlockBiometric]; the caller checks the
/// secret and reopens it with [wrong] set when it did not match.
///
/// Errors sit on the field, never in a toast: the lock cover is up while this
/// shows and silences toasts.
///
/// A call keeps running under the lock, so while one does the prompt offers to
/// end it without unlocking, the way a phone's lock screen does.
class UnlockDialog extends ConsumerStatefulWidget {
  final bool isPin;
  final bool hasBiometric;
  final bool wrong;

  const UnlockDialog({
    super.key,
    required this.isPin,
    required this.hasBiometric,
    this.wrong = false,
  });

  @override
  ConsumerState<UnlockDialog> createState() => _UnlockDialogState();
}

class _UnlockDialogState extends ConsumerState<UnlockDialog> {
  final _controller = TextEditingController();
  late bool _wrong = widget.wrong;
  bool _ending = false;

  Future<void> _endCall() async {
    setState(() => _ending = true);
    final dm = ref.read(callProvider).status != CallStatus.idle;
    try {
      if (dm) {
        await leaveDmCall(context, ref);
      } else {
        await leaveVoiceRoom(context, ref);
      }
    } finally {
      if (mounted) setState(() => _ending = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final secret = _controller.text.trim();
    if (secret.isNotEmpty) Navigator.of(context).pop(secret);
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.isPin ? 'PIN' : 'password';
    return HollowDialog(
      title: 'Unlock Hollow',
      width: 420,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowDialogText('Enter your app $label to unlock your identity.'),
          if (watchHasQuickControls(ref)) ...[
            const SizedBox(height: HollowSpacing.md),
            _CallStillGoing(ending: _ending, onEnd: _endCall),
          ],
          const SizedBox(height: HollowSpacing.lg),
          HollowTextField(
            controller: _controller,
            obscureText: true,
            autofocus: true,
            hintText: widget.isPin ? 'PIN' : 'Password',
            keyboardType: widget.isPin ? TextInputType.number : null,
            errorText: _wrong ? 'Wrong $label. Try again.' : null,
            onChanged: (_) {
              if (_wrong) setState(() => _wrong = false);
            },
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      leadingActions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(kUnlockRecover),
          child: Text(widget.isPin ? 'Forgot PIN?' : 'Forgot password?'),
        ),
        if (widget.hasBiometric)
          HollowIconButton(
            icon: LucideIcons.fingerprint,
            label: 'Unlock with biometrics',
            size: HollowDialogSurface.isCompact(context) ? 44 : 32,
            onPressed: () => Navigator.of(context).pop(kUnlockBiometric),
          ),
      ],
      actions: [
        HollowButton.filled(
          onPressed: _submit,
          child: const Text('Unlock'),
        ),
      ],
    );
  }
}

/// The call running under the lock, and the one way to end it from here.
class _CallStillGoing extends StatelessWidget {
  final bool ending;
  final VoidCallback onEnd;

  const _CallStillGoing({required this.ending, required this.onEnd});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      children: [
        Icon(LucideIcons.phone, size: 16, color: hollow.success),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Text(
            'Your call is still going',
            style: HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.outline(
          danger: true,
          compact: !HollowDialogSurface.isCompact(context),
          touch: HollowDialogSurface.isCompact(context),
          loading: ending,
          icon: const Icon(LucideIcons.phoneOff),
          onPressed: onEnd,
          child: const Text('End call'),
        ),
      ],
    );
  }
}

/// How many words a recovery phrase has.
const kRecoveryPhraseWords = 24;

/// The field error for a phrase with the wrong number of words, or null when
/// the count is right.
String? recoveryPhraseCountError(String phrase) {
  final trimmed = phrase.trim();
  final count = trimmed.isEmpty ? 0 : trimmed.split(RegExp(r'\s+')).length;
  if (count == kRecoveryPhraseWords) return null;
  return 'A recovery phrase is $kRecoveryPhraseWords words. '
      'This one has $count.';
}

/// Asks for the 24-word recovery phrase and runs [onRecover] with it inside
/// the dialog: the confirm loads, a failure lands on the field with the phrase
/// kept, and the dialog pops true once it worked. [cancellable] is false for
/// the launch prompt, which has nowhere to go back to.
class RecoveryPhraseDialog extends StatefulWidget {
  final String title;
  final List<String> paragraphs;
  final String confirmLabel;
  final bool cancellable;
  final Future<void> Function(String phrase) onRecover;

  const RecoveryPhraseDialog({
    super.key,
    required this.title,
    required this.paragraphs,
    required this.confirmLabel,
    required this.onRecover,
    this.cancellable = true,
  });

  @override
  State<RecoveryPhraseDialog> createState() => _RecoveryPhraseDialogState();
}

class _RecoveryPhraseDialogState extends State<RecoveryPhraseDialog>
    with HollowDialogAction {
  final _controller = TextEditingController();
  String? _fieldError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _recover() async {
    final phrase = _controller.text.trim().split(RegExp(r'\s+')).join(' ');
    final countError = recoveryPhraseCountError(phrase);
    if (countError != null) {
      setState(() => _fieldError = countError);
      return;
    }
    final ok = await runDialogAction(
      () => widget.onRecover(phrase),
      fallback: "That phrase didn't open this identity. Check each word and "
          'try again.',
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _fieldError = actionError);
    }
  }

  @override
  Widget build(BuildContext context) {
    return HollowDialog(
      title: widget.title,
      width: 420,
      busy: actionRunning,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final p in widget.paragraphs) ...[
            HollowDialogText(p),
            const SizedBox(height: HollowSpacing.md),
          ],
          const SizedBox(height: HollowSpacing.xs),
          HollowTextField(
            controller: _controller,
            autofocus: true,
            minLines: 3,
            maxLines: 4,
            hintText: 'Your $kRecoveryPhraseWords words, in order',
            errorText: _fieldError,
            onChanged: (_) {
              if (_fieldError != null) setState(() => _fieldError = null);
            },
          ),
        ],
      ),
      actions: [
        if (widget.cancellable)
          HollowButton.ghost(
            onPressed:
                actionRunning ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
        HollowButton.filled(
          onPressed: _recover,
          loading: actionRunning,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
