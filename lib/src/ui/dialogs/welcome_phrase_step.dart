import 'package:flutter/material.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/profile_registry.dart';
import 'package:hollow/src/core/services/phrase_restore.dart';
import 'package:hollow/src/core/services/privacy_screen.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/dialogs/keychain_protection_dialogs.dart';
import 'package:hollow/src/ui/dialogs/recovery_phrase_dialogs.dart';
import 'package:hollow/src/ui/dialogs/welcome_frame.dart';
import 'package:hollow/src/ui/settings/device_management_shared.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:hollow/src/ui/shell/data_recovery.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Welcome's "Use your recovery phrase" step (PHRASE_RESTORE_DESIGN 1.1): one
/// question about the old device, then the words. The whole step is a secret
/// screen, and the typed words are dropped once the restore returns.
class WelcomePhraseStep extends StatefulWidget {
  final VoidCallback onBack;

  /// False when Welcome cannot start yet (a relay typo); Welcome then says why.
  final bool Function() canStart;

  final void Function(PhraseRestoreBranch branch) onRestored;

  /// The last restore's identity was set aside: say so once.
  final bool afterSetAside;

  /// The relay this restore lands on when it is not the default, shown so a
  /// relay picked earlier (or the set-aside identity's) is never a surprise.
  final String? relayDomain;

  /// Opens the relay field on Welcome's first screen.
  final VoidCallback? onChangeRelay;

  const WelcomePhraseStep({
    super.key,
    required this.onBack,
    required this.canStart,
    required this.onRestored,
    this.afterSetAside = false,
    this.relayDomain,
    this.onChangeRelay,
  });

  @override
  State<WelcomePhraseStep> createState() => _WelcomePhraseStepState();
}

/// What the person chose on a kept-data dialog. Null = closed, nothing done.
enum _KeptChoice { restoreAnyway, checkWords }

class _WelcomePhraseStepState extends State<WelcomePhraseStep> {
  final _phrase = TextEditingController();
  PhraseRestoreBranch? _branch;
  LastHadAnswer? _lastHad;
  int? _lostSinceMs;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phrase.dispose();
    super.dispose();
  }

  String get _typed =>
      _phrase.text.trim().split(RegExp(r'\s+')).join(' ').toLowerCase();

  /// Restore needs a branch, and on Yes a time to judge the old device from.
  bool get _ready => restoreReady(
        branch: _branch,
        lostSinceMs: _lostSinceMs,
        typed: _phrase.text,
      );

  Future<void> _restore({bool checkKept = true}) async {
    if (_busy || !_ready) return;
    if (!widget.canStart()) return;
    final branch = _branch!;
    setState(() {
      _busy = true;
      _error = null;
    });
    final identity_api.RestoreOutcome outcome;
    try {
      outcome = await identity_api.welcomeRestore(
        phrase: _typed,
        mode: welcomeRestoreMode(branch, lostSinceMs: _lostSinceMs),
        checkKept: checkKept,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = phraseErrorText(e) ?? friendlyError(e);
      });
      return;
    }
    if (!mounted) return;
    // Without the check Rust lands or refuses; a kept-data answer then would
    // only ask the same question again.
    if (!checkKept && outcome is! identity_api.RestoreOutcome_Restored) {
      setState(() {
        _busy = false;
        _error = kGenericErrorSentence;
      });
      return;
    }
    switch (outcome) {
      case identity_api.RestoreOutcome_Restored(:final lockedToKeychain):
        _phrase.clear();
        if (lockedToKeychain) showKeychainLockedToast();
        widget.onRestored(branch);
      case identity_api.RestoreOutcome_KeptMatch(:final path, :final profileName):
        setState(() => _busy = false);
        // Phones have no profiles to switch to, and a portable copy lists none:
        // the kept folder stays for a later destroy.
        if (!keptMatchOffersSwitch()) return _restore(checkKept: false);
        final again = await _askKeptMatch(path, profileName);
        if (again == _KeptChoice.restoreAnyway) await _restore(checkKept: false);
      case identity_api.RestoreOutcome_KeptNoneOpens():
        setState(() => _busy = false);
        final again = await showHollowDialog<_KeptChoice>(
          context: context,
          builder: (_) => const _KeptNoneOpensDialog(),
        );
        if (again == _KeptChoice.restoreAnyway) await _restore(checkKept: false);
    }
  }

  Future<_KeptChoice?> _askKeptMatch(String path, String? profileName) {
    final day = keptDayOf(path) ?? DateTime.now().toUtc();
    return showHollowDialog<_KeptChoice>(
      context: context,
      builder: (_) => _KeptMatchDialog(
        path: path,
        profileName: profileName ?? listedProfileName(path) ?? keptProfileName(day),
        day: day,
      ),
    );
  }

  Future<void> _pickLastHad(LastHadAnswer answer, int sinceMs) async {
    setState(() {
      _lastHad = answer;
      _lostSinceMs = sinceMs;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final phone = WelcomeFrame.fullScreen(context);
    final secondary = HollowTypography.bodySmall.copyWith(
      color: hollow.textSecondary,
    );
    final branch = _branch;
    final relay = widget.relayDomain;

    Widget option(PhraseRestoreBranch value, String title, String subtitle) {
      final chosen = branch == value;
      return Semantics(
        selected: chosen,
        inMutuallyExclusiveGroup: true,
        child: HollowListRow(
          key: ValueKey('phrase-branch-${value.name}'),
          touch: phone,
          wrap: true,
          selected: chosen,
          leading: Icon(
            chosen ? LucideIcons.circleDot : LucideIcons.circle,
            size: 20,
            color: chosen ? hollow.accentText : hollow.textTertiary,
          ),
          title: title,
          subtitle: subtitle,
          onTap: _busy
              ? null
              : () => setState(() {
                    _branch = value;
                    _error = null;
                  }),
        ),
      );
    }

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.afterSetAside) ...[
          Text(
            'The identity those words made is set aside. Type your phrase '
            'again and check each word.',
            style: HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.lg),
        ],
        const SettingsFieldLabel(
            label: 'Could someone else have your old device?'),
        const SizedBox(height: HollowSpacing.xs),
        option(
          PhraseRestoreBranch.admit,
          'No',
          "It broke, or you wiped it. If it ever turns on again, it's still "
              'yours.',
        ),
        option(
          PhraseRestoreBranch.recover,
          "Yes, or I'm not sure",
          'Hollow cuts off your old device and undoes what it changed in your '
              'servers after you last had it.',
        ),
        if (branch == PhraseRestoreBranch.recover) ...[
          const SizedBox(height: HollowSpacing.lg),
          const SettingsFieldLabel(label: 'When did you last have it?'),
          const SizedBox(height: HollowSpacing.sm),
          LastHadPicker(
            answer: _lastHad,
            sinceMs: _lostSinceMs,
            enabled: !_busy,
            onAnswer: _pickLastHad,
          ),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            "If you're not sure, pick an earlier time. What your friends and "
            'other members changed stays either way.',
            style: secondary,
          ),
        ],
        const SizedBox(height: HollowSpacing.xl),
        const SettingsFieldLabel(label: 'Recovery phrase'),
        const SizedBox(height: HollowSpacing.xs),
        IgnorePointer(
          ignoring: _busy,
          child: ExcludeFocus(
            excluding: _busy,
            child: RecoveryPhraseField(
              key: const ValueKey('welcome-phrase-field'),
              controller: _phrase,
              errorText: _error,
              onChanged: (_) => setState(() => _error = null),
            ),
          ),
        ),
        if (branch != null) ...[
          const SizedBox(height: HollowSpacing.md),
          Text(
            branch == PhraseRestoreBranch.admit
                ? 'Hollow brings your identity back on this device. Add your '
                      'friends again and they accept you right away. Most '
                      'servers you share with them come back on their own, '
                      'with the messages they kept.'
                : 'Hollow brings your identity back on this device and cuts '
                      'off your old one. Add your friends again, and Hollow '
                      'asks the members of each server you own how it looked '
                      'before you lost your device.',
            style: secondary,
          ),
        ],
        const SizedBox(height: HollowSpacing.md),
        Text(
          "Messages and files that were only on your old device don't come "
          'back. Your name, picture, settings and blocks start fresh.',
          style: secondary,
        ),
        const SizedBox(height: HollowSpacing.md),
        Text(
          'Still have a device with Hollow? Link this one from it instead. '
          'That brings everything back.',
          style: HollowTypography.caption.copyWith(color: hollow.textTertiary),
        ),
      ],
    );

    return SecretScreen(
      child: WelcomeFrame(
        title: 'Restore with your recovery phrase',
        backEnabled: !_busy,
        onBack: widget.onBack,
        body: body,
        bottom: WelcomeActions(
          lead: relay == null
              ? null
              : Align(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: 1,
                  child: HollowButton.ghost(
                    key: const ValueKey('phrase-step-relay'),
                    compact: !phone,
                    touch: phone,
                    semanticLabel: 'Change the relay, $relay',
                    icon: const Icon(LucideIcons.server, size: 14),
                    onPressed: _busy ? null : widget.onChangeRelay,
                    // The button cannot ellipsize its label.
                    child: Text(relay.length > 32
                        ? '${relay.substring(0, 31)}\u2026'
                        : relay),
                  ),
                ),
          children: [
            HollowButton.filled(
              expand: phone,
              touch: phone,
              loading: _busy,
              onPressed: _ready ? _restore : null,
              child: const Text('Restore'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Whether a kept folder the words open can become a profile to switch to:
/// never on a phone or a portable copy. Tests stand in for it.
@visibleForTesting
bool Function() keptMatchOffersSwitch = listsKeptProfilesHere;

/// The name the profile list gives the kept folder at [path], if it lists it
/// (Rust names no profile; the list is Dart's).
@visibleForTesting
String? listedProfileName(String path) {
  try {
    for (final row in listProfileRows(readProfileRegistrySync())) {
      if (sameProfilePath(row.path, path)) return row.name;
    }
  } catch (_) {}
  return null;
}

/// Whether Restore may run: a branch picked, on Yes a time answered, and some
/// words typed (Rust judges the words).
@visibleForTesting
bool restoreReady({
  required PhraseRestoreBranch? branch,
  required int? lostSinceMs,
  required String typed,
}) =>
    branch != null &&
    (branch == PhraseRestoreBranch.admit || lostSinceMs != null) &&
    typed.trim().isNotEmpty;

/// "Your data is still here": switching opens the earlier data in its own
/// profile, which Hollow lists first.
class _KeptMatchDialog extends StatefulWidget {
  final String path;
  final String profileName;
  final DateTime day;

  const _KeptMatchDialog({
    required this.path,
    required this.profileName,
    required this.day,
  });

  @override
  State<_KeptMatchDialog> createState() => _KeptMatchDialogState();
}

class _KeptMatchDialogState extends State<_KeptMatchDialog>
    with HollowDialogAction {
  Future<void> _switch() async {
    await runDialogAction(() async {
      await keepOldDataProfile(widget.path, widget.day);
      await switchProfileAndRestart(widget.path);
    });
  }

  @override
  Widget build(BuildContext context) {
    return HollowDialog(
      title: 'Your data is still here',
      width: 420,
      // Closing does nothing: the step stays with the words typed.
      showClose: true,
      busy: actionRunning,
      error: actionError,
      content: HollowDialogText(
        'This computer still has your earlier data for this identity, in the '
        'profile ${widget.profileName}. Switch to it to get everything back.',
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning
              ? null
              : () => Navigator.of(context).pop(_KeptChoice.restoreAnyway),
          child: const Text('Restore here anyway'),
        ),
        HollowButton.filled(
          loading: actionRunning,
          onPressed: actionRunning ? null : _switch,
          child: const Text('Switch to it'),
        ),
      ],
    );
  }
}

/// Kept data here that these words do not open: most likely a wrong word.
class _KeptNoneOpensDialog extends StatelessWidget {
  const _KeptNoneOpensDialog();

  @override
  Widget build(BuildContext context) {
    return HollowDialog(
      title: 'Check your recovery phrase',
      width: 420,
      content: const HollowDialogText(
        "There's earlier Hollow data on this device, and these words don't "
        'open it. If that data is yours, one of the words is probably wrong.',
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(_KeptChoice.restoreAnyway),
          child: const Text('Restore anyway'),
        ),
        HollowButton.filled(
          onPressed: () => Navigator.of(context).pop(_KeptChoice.checkWords),
          child: const Text('Check the words'),
        ),
      ],
    );
  }
}
