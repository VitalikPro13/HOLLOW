import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/providers/duress_provider.dart';
import 'package:hollow/src/core/services/destroy_flow.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/wipe.dart' as wipe_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';

/// Wire values of the destroy scope. They are persisted and read by Rust, so
/// they are never derived from a label.
const String kDuressScopeDevice = 'device';
const String kDuressScopeDeviceRevoke = 'device_revoke';
const String kDuressScopeIdentity = 'identity';

/// Every scope a duress code may carry.
const List<(String, String)> _duressScopes = [
  (kDuressScopeDevice, 'This device'),
  (kDuressScopeDeviceRevoke, 'This device and unlink it'),
  (kDuressScopeIdentity, 'My whole identity'),
];

/// The Danger zone drops the device-only scope: erasing just this device is
/// what the Profile tab's Erase already does, and two buttons for one action is
/// how they drift apart.
const List<(String, String)> _dangerZoneScopes = [
  (kDuressScopeDeviceRevoke, 'This device and unlink it'),
  (kDuressScopeIdentity, 'My whole identity'),
];

String _scopeEffect(String scope) => switch (scope) {
      kDuressScopeDeviceRevoke =>
        "Deletes this device's data and unlinks it from your identity, so your "
            'other devices drop it.',
      kDuressScopeIdentity => 'Deletes your data on every device.',
      _ => "Deletes this device's data. Your other devices keep theirs.",
    };

/// The word a destroy confirmation has to be typed out in full.
const String _confirmWord = 'DESTROY';

/// How an order for the whole identity actually travels, said once wherever
/// that scope is offered.
const String _identityDelivery =
    'Devices that are offline get the order when they next connect. The relay '
    'holds it for up to a year.';

/// Where a surface can only ever take the code at a COLD launch, nothing can be
/// signed for the rest of the identity.
const String _localOnlyNote =
    'On a computer the code is typed at launch, so it destroys this device '
    "only. The wider scopes live on a phone's App Lock and in the Danger zone.";

/// A computer's app lock re-unlocks a running app, so the keys are in memory
/// and a wider order can be signed there.
const String _desktopScopeNote =
    'The wider scopes reach your other devices from the app lock prompt. If '
    'Hollow asks for the password before it starts, a code typed there '
    'destroys this computer only.';

/// The same fact on a phone, where App Lock re-unlocks a running app.
const String _mobileScopeNote =
    'The wider scopes reach your other devices from the App Lock prompt, '
    'whether Hollow was open or not.';

bool get _isMobile => Platform.isAndroid || Platform.isIOS;

/// The running-app fact in the words of the device it is read on.
String get _scopeNote => _isMobile ? _mobileScopeNote : _desktopScopeNote;

/// One line under a set code saying what it destroys.
String _setSummary(identity_api.DuressStatus status) => switch (status.scope) {
      kDuressScopeDeviceRevoke =>
        "Deletes this device's data and unlinks it from your identity.",
      kDuressScopeIdentity => status.notifyFriends
          ? 'Deletes your data on every device and tells your friends.'
          : 'Deletes your data on every device.',
      _ => "Deletes this device's data. Your other devices keep theirs.",
    };

/// Duress code: a second code typed at the unlock prompt that destroys data
/// instead of unlocking. Renders as one settings row.
///
/// Availability rides [identityProtectionProvider], the same answer the
/// password row reloads, so turning a password on cannot leave this row stale.
///
/// [wideScopes] is false only where the code can never be typed into a RUNNING
/// app: nothing can be signed for the rest of the identity at a cold launch.
/// Both shipped surfaces re-unlock a running app, so both pass true.
class DuressCodeCard extends ConsumerStatefulWidget {
  final bool wideScopes;

  const DuressCodeCard({super.key, required this.wideScopes});

  @override
  ConsumerState<DuressCodeCard> createState() => _DuressCodeCardState();
}

class _DuressCodeCardState extends ConsumerState<DuressCodeCard> {
  static const _title = 'Duress code';

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(duressStatusProvider);

    return switch (status) {
      AsyncData(:final value) => _row(value),
      AsyncError() => const SettingsRow(
          title: _title,
          subtitle: "Couldn't read the duress code setting.",
        ),
      _ => const SettingsRow(title: _title, trailing: HollowSpinner()),
    };
  }

  Widget _row(identity_api.DuressStatus status) {
    if (!status.available) {
      // The control for the missing piece is the password row above.
      return const SettingsRow(
        title: _title,
        subtitle: 'Needs a password first',
        enabled: false,
      );
    }

    if (!status.enabled) {
      return SettingsRow(
        title: _title,
        subtitle: widget.wideScopes
            ? 'A second code that deletes your data instead of opening Hollow'
            : 'A second code that deletes this device\'s data instead of '
                'opening Hollow',
        trailing: HollowButton.outline(
          compact: true,
          onPressed: _setCode,
          child: const Text('Set up'),
        ),
      );
    }

    return SettingsRow(
      title: _title,
      subtitle: _setSummary(status),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          HollowButton.ghost(
            compact: true,
            onPressed: _setCode,
            child: const Text('Change'),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.ghost(
            compact: true,
            onPressed: _removeCode,
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  Future<void> _setCode() async {
    final current = ref.read(duressStatusProvider).valueOrNull;
    final saved = await showHollowDialog<bool>(
      context: context,
      builder: (ctx) => _DuressCodeDialog(
        wideScopes: widget.wideScopes,
        initialScope: widget.wideScopes
            ? (current?.scope ?? kDuressScopeDevice)
            : kDuressScopeDevice,
        initialNotifyFriends: current?.notifyFriends ?? false,
        isChange: current?.enabled ?? false,
        onSave: (entry) => identity_api.setDuressCode(
          password: entry.password,
          duressCode: entry.code,
          scope: entry.scope,
          notifyFriends: entry.notifyFriends,
        ),
      ),
    );
    if (saved != true || !mounted) return;
    ref.invalidate(duressStatusProvider);
    HollowToast.show(context, 'Duress code saved',
        type: HollowToastType.success);
  }

  Future<void> _removeCode() async {
    final removed = await showHollowDialog<bool>(
      context: context,
      builder: (ctx) => _PasswordPromptDialog(
        title: 'Remove duress code',
        message: 'Enter your app password to remove the duress code.',
        confirmLabel: 'Remove',
        onSubmit: (password) =>
            identity_api.clearDuressCode(password: password),
      ),
    );
    if (removed != true || !mounted) return;
    ref.invalidate(duressStatusProvider);
    HollowToast.show(context, 'Duress code removed',
        type: HollowToastType.info);
  }
}

/// Account-level destruction, as the Danger zone's two rows. Separate from the
/// per-server danger zone: this one ends the identity, not a membership.
class AccountDangerZoneCard extends ConsumerStatefulWidget {
  const AccountDangerZoneCard({super.key});

  @override
  ConsumerState<AccountDangerZoneCard> createState() =>
      _AccountDangerZoneCardState();
}

class _AccountDangerZoneCardState extends ConsumerState<AccountDangerZoneCard> {
  /// The scope whose destroy is running, or null. Both buttons wait on it.
  String? _busyScope;

  @override
  Widget build(BuildContext context) {
    final busy = _busyScope != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingsRow(
          title: 'Destroy this device',
          subtitle: 'Unlinks this device from your identity and deletes your '
              'messages, files and keys on it. Your other devices keep theirs.',
          trailing: HollowButton.outline(
            danger: true,
            compact: true,
            onPressed:
                busy ? null : () => _destroy(kDuressScopeDeviceRevoke),
            loading: _busyScope == kDuressScopeDeviceRevoke,
            child: const Text('Destroy device'),
          ),
        ),
        SettingsRow(
          title: 'Destroy my identity everywhere',
          subtitle: 'Every linked device wipes itself. Without the recovery '
              "phrase it can't come back.",
          trailing: HollowButton.outline(
            danger: true,
            compact: true,
            onPressed: busy ? null : () => _destroy(kDuressScopeIdentity),
            loading: _busyScope == kDuressScopeIdentity,
            child: const Text('Destroy identity'),
          ),
        ),
      ],
    );
  }

  Future<void> _destroy(String initialScope) async {
    final destroyed = await showHollowDialog<bool>(
      context: context,
      builder: (ctx) => _DestroyDialog(
        initialScope: initialScope,
        onDestroy: (choice) => wipe_api.destroyWithScope(
          scope: choice.scope,
          notifyFriends: choice.notifyFriends,
        ),
      ),
    );
    if (destroyed != true || !mounted) return;
    setState(() => _busyScope = initialScope);
    await clearLocalSecretsAfterDestroy();
    await relaunchApp();
  }
}

/// True when [error] says the typed app password does not open the identity.
bool isWrongPasswordError(Object error) =>
    error.toString().toLowerCase().contains('wrong password');

/// What the password field says when the typed password is not the app's.
const String kWrongPasswordText = "That password isn't right.";

class _DuressEntry {
  final String password;
  final String code;
  final String scope;
  final bool notifyFriends;

  const _DuressEntry(this.password, this.code, this.scope, this.notifyFriends);
}

/// Sets or changes the code. The save runs inside, so a wrong password lands
/// on its field and nothing typed is lost.
class _DuressCodeDialog extends StatefulWidget {
  final bool wideScopes;
  final String initialScope;
  final bool initialNotifyFriends;
  final bool isChange;
  final Future<void> Function(_DuressEntry entry) onSave;

  const _DuressCodeDialog({
    required this.wideScopes,
    required this.initialScope,
    required this.initialNotifyFriends,
    required this.isChange,
    required this.onSave,
  });

  @override
  State<_DuressCodeDialog> createState() => _DuressCodeDialogState();
}

class _DuressCodeDialogState extends State<_DuressCodeDialog>
    with HollowDialogAction {
  final _password = TextEditingController();
  final _code = TextEditingController();
  final _repeat = TextEditingController();
  late String _scope = widget.initialScope;
  late bool _notifyFriends = widget.initialNotifyFriends;
  String? _passwordError;
  String? _codeError;
  String? _repeatError;

  @override
  void dispose() {
    _password.dispose();
    _code.dispose();
    _repeat.dispose();
    super.dispose();
  }

  bool get _filled =>
      _password.text.trim().isNotEmpty &&
      _code.text.trim().isNotEmpty &&
      _repeat.text.trim().isNotEmpty;

  Future<void> _submit() async {
    if (actionRunning || !_filled) return;
    final password = _password.text.trim();
    final code = _code.text.trim();
    if (code != _repeat.text.trim()) {
      setState(() => _repeatError = "The codes don't match.");
      return;
    }
    if (code == password) {
      setState(() => _codeError =
          'The duress code has to be different from your password.');
      return;
    }
    Object? raw;
    final ok = await runDialogAction(() async {
      try {
        await widget
            .onSave(_DuressEntry(password, code, _scope, _notifyFriends));
      } catch (e) {
        raw = e;
        rethrow;
      }
    });
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    final error = raw;
    if (error == null) return;
    if (isWrongPasswordError(error)) {
      setState(() {
        _passwordError = kWrongPasswordText;
        actionError = null;
      });
    } else if (error.toString().contains('different from your password')) {
      setState(() {
        _codeError = actionError;
        actionError = null;
      });
    }
  }

  void _clearErrors() {
    setState(() {
      _passwordError = null;
      _codeError = null;
      _repeatError = null;
      actionError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return HollowDialog(
      title: widget.isChange ? 'Change duress code' : 'Set a duress code',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HollowDialogText(
            'Typed at the unlock prompt, this code deletes your data and '
            'restarts Hollow at first-time setup. It never shows an error, and '
            'there is no undo.',
          ),
          const SizedBox(height: HollowSpacing.lg),
          const SettingsFieldLabel(label: 'App password'),
          const SizedBox(height: HollowSpacing.xs),
          HollowTextField(
            controller: _password,
            obscureText: true,
            autofocus: true,
            errorText: _passwordError,
            onChanged: (_) => _clearErrors(),
          ),
          const SizedBox(height: HollowSpacing.md),
          const SettingsFieldLabel(label: 'Duress code'),
          const SizedBox(height: HollowSpacing.xs),
          HollowTextField(
            controller: _code,
            obscureText: true,
            errorText: _codeError,
            onChanged: (_) => _clearErrors(),
          ),
          const SizedBox(height: HollowSpacing.md),
          const SettingsFieldLabel(label: 'Repeat the duress code'),
          const SizedBox(height: HollowSpacing.xs),
          HollowTextField(
            controller: _repeat,
            obscureText: true,
            errorText: _repeatError,
            onChanged: (_) => _clearErrors(),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: HollowSpacing.lg),
          if (widget.wideScopes)
            _ScopePicker(
              choices: _duressScopes,
              scope: _scope,
              notifyFriends: _notifyFriends,
              onScope: (value) => setState(() => _scope = value),
              onNotifyFriends: (value) => setState(() => _notifyFriends = value),
              note: _scopeNote,
            )
          else
            Text(
              '${_scopeEffect(kDuressScopeDevice)} $_localOnlyNote',
              style: HollowTypography.bodySmall
                  .copyWith(color: hollow.textSecondary),
            ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _filled ? _submit : null,
          loading: actionRunning,
          child: Text(widget.isChange ? 'Change code' : 'Set code'),
        ),
      ],
    );
  }
}

class _DestroyChoice {
  final String scope;
  final bool notifyFriends;

  const _DestroyChoice(this.scope, this.notifyFriends);
}

class _DestroyDialog extends StatefulWidget {
  final String initialScope;
  final Future<void> Function(_DestroyChoice choice) onDestroy;

  const _DestroyDialog({required this.initialScope, required this.onDestroy});

  @override
  State<_DestroyDialog> createState() => _DestroyDialogState();
}

class _DestroyDialogState extends State<_DestroyDialog>
    with HollowDialogAction {
  final _confirm = TextEditingController();
  late String _scope = widget.initialScope;
  bool _notifyFriends = false;

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _destroy() async {
    final ok = await runDialogAction(
      () => widget.onDestroy(_DestroyChoice(_scope, _notifyFriends)),
      fallback: "Couldn't destroy the data. Try again.",
    );
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final ready = _confirm.text.trim() == _confirmWord;

    return HollowDialog(
      title: 'Destroy your data',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HollowDialogText(
            'Hollow deletes your messages, files and keys, then restarts and '
            'opens first-time setup.',
          ),
          const SizedBox(height: HollowSpacing.lg),
          _ScopePicker(
            choices: _dangerZoneScopes,
            scope: _scope,
            notifyFriends: _notifyFriends,
            onScope: (value) => setState(() => _scope = value),
            onNotifyFriends: (value) => setState(() => _notifyFriends = value),
          ),
          const SizedBox(height: HollowSpacing.lg),
          const SettingsFieldLabel(label: 'Type $_confirmWord to confirm'),
          const SizedBox(height: HollowSpacing.xs),
          HollowTextField(
            controller: _confirm,
            autofocus: true,
            hintText: _confirmWord,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.danger(
          onPressed: ready ? _destroy : null,
          loading: actionRunning,
          child: const Text('Destroy'),
        ),
      ],
    );
  }
}

/// Scope chips plus the friend announcement, shared by both flows so the wire
/// values and the wording cannot drift apart.
class _ScopePicker extends StatelessWidget {
  final List<(String, String)> choices;
  final String scope;
  final bool notifyFriends;
  final ValueChanged<String> onScope;
  final ValueChanged<bool> onNotifyFriends;

  /// When a wider scope can reach anything; said only once one is chosen.
  final String? note;

  const _ScopePicker({
    required this.choices,
    required this.scope,
    required this.notifyFriends,
    required this.onScope,
    required this.onNotifyFriends,
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final effect = [
      _scopeEffect(scope),
      if (scope == kDuressScopeIdentity) _identityDelivery,
      if (note != null && scope != kDuressScopeDevice) note!,
    ].join(' ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SettingsFieldLabel(label: 'What gets destroyed'),
        const SizedBox(height: HollowSpacing.sm),
        Wrap(
          spacing: HollowSpacing.sm,
          runSpacing: HollowSpacing.sm,
          children: [
            for (final (value, label) in choices)
              Semantics(
                selected: scope == value,
                inMutuallyExclusiveGroup: true,
                child: HollowChip(
                  label: label,
                  selected: scope == value,
                  onTap: () => onScope(value),
                ),
              ),
          ],
        ),
        const SizedBox(height: HollowSpacing.sm),
        Text(
          effect,
          style:
              HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
        ),
        if (scope == kDuressScopeIdentity) ...[
          const SizedBox(height: HollowSpacing.sm),
          SettingsSwitchRow(
            title: 'Tell my friends',
            subtitle: 'Their chat with you shows a note that this identity '
                'was destroyed, and their verification of you is cleared.',
            value: notifyFriends,
            onChanged: onNotifyFriends,
          ),
        ],
      ],
    );
  }
}

/// Asks for the app password and runs [onSubmit] with it inside, so a wrong
/// password lands on the field instead of closing the dialog.
class _PasswordPromptDialog extends StatefulWidget {
  final String title;
  final String message;
  final String confirmLabel;
  final Future<void> Function(String password) onSubmit;

  const _PasswordPromptDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.onSubmit,
  });

  @override
  State<_PasswordPromptDialog> createState() => _PasswordPromptDialogState();
}

class _PasswordPromptDialogState extends State<_PasswordPromptDialog>
    with HollowDialogAction {
  final _controller = TextEditingController();
  String? _fieldError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final value = _controller.text.trim();
    if (value.isEmpty || actionRunning) return;
    Object? raw;
    final ok = await runDialogAction(() async {
      try {
        await widget.onSubmit(value);
      } catch (e) {
        raw = e;
        rethrow;
      }
    });
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    final error = raw;
    setState(() {
      _fieldError = error != null && isWrongPasswordError(error)
          ? kWrongPasswordText
          : actionError;
      actionError = null;
    });
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
          HollowDialogText(widget.message),
          const SizedBox(height: HollowSpacing.md),
          HollowTextField(
            controller: _controller,
            obscureText: true,
            autofocus: true,
            hintText: 'App password',
            errorText: _fieldError,
            onChanged: (_) => setState(() => _fieldError = null),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _controller.text.trim().isEmpty ? null : _submit,
          loading: actionRunning,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
