import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/duress_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/app_lock_service.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/app_lock_card.dart';
import 'package:hollow/src/ui/settings/backup_section.dart';
import 'package:hollow/src/ui/settings/duress_section.dart';
import 'package:hollow/src/ui/settings/pages/security_page.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Which secrets a prompt asks for.
enum SecretAsk {
  /// The secret already set: to confirm it, or to turn it off.
  current,

  /// A new secret, typed twice.
  create,

  /// The current secret, then a new one typed twice.
  change,
}

/// The app password (or a phone's PIN) prompt. [onSubmit] runs INSIDE the
/// dialog with the current and the new secret (empty when not asked): the
/// confirm loads, a wrong current secret lands on its field, and nothing typed
/// is lost. Resolves to the secret that is now set (the new one for
/// [SecretAsk.create] and [SecretAsk.change]), or null on Cancel.
Future<String?> askSecretDialog(
  BuildContext context, {
  required String title,
  required SecretAsk ask,
  required String confirmLabel,
  required Future<void> Function(String current, String next) onSubmit,
  String? message,
  bool isPin = false,
}) {
  return showHollowDialog<String>(
    context: context,
    builder: (_) => _SecretDialog(
      title: title,
      ask: ask,
      confirmLabel: confirmLabel,
      onSubmit: onSubmit,
      message: message,
      isPin: isPin,
    ),
  );
}

class _SecretDialog extends StatefulWidget {
  final String title;
  final SecretAsk ask;
  final String confirmLabel;
  final Future<void> Function(String current, String next) onSubmit;
  final String? message;
  final bool isPin;

  const _SecretDialog({
    required this.title,
    required this.ask,
    required this.confirmLabel,
    required this.onSubmit,
    required this.message,
    required this.isPin,
  });

  @override
  State<_SecretDialog> createState() => _SecretDialogState();
}

class _SecretDialogState extends State<_SecretDialog> with HollowDialogAction {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _repeat = TextEditingController();
  String? _currentError;
  String? _nextError;
  String? _repeatError;

  bool get _asksCurrent => widget.ask != SecretAsk.create;
  bool get _asksNext => widget.ask != SecretAsk.current;
  String get _word => widget.isPin ? 'PIN' : 'password';
  String get _capWord => widget.isPin ? 'PIN' : 'Password';

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _repeat.dispose();
    super.dispose();
  }

  // A PIN or password is used exactly as typed, so nothing is trimmed.
  bool get _filled =>
      (!_asksCurrent || _current.text.isNotEmpty) &&
      (!_asksNext || (_next.text.isNotEmpty && _repeat.text.isNotEmpty));

  Future<void> _submit() async {
    if (actionRunning || !_filled) return;
    final current = _asksCurrent ? _current.text : '';
    final next = _asksNext ? _next.text : '';
    if (_asksNext && widget.isPin && next.length < 4) {
      setState(() => _nextError = 'A PIN needs at least 4 digits.');
      return;
    }
    if (_asksNext && next != _repeat.text) {
      setState(() => _repeatError = "The ${_word}s don't match.");
      return;
    }
    Object? raw;
    final ok = await runDialogAction(() async {
      try {
        await widget.onSubmit(current, next);
      } catch (e) {
        raw = e;
        rethrow;
      }
    });
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(_asksNext ? next : current);
      return;
    }
    final error = raw;
    if (error != null && _asksCurrent && isWrongPasswordError(error)) {
      setState(() {
        _currentError = "That $_word isn't right.";
        actionError = null;
      });
    } else if (error != null &&
        _asksNext &&
        error.toString().contains('duress code')) {
      setState(() {
        _nextError = actionError;
        actionError = null;
      });
    }
  }

  void _clearErrors() {
    setState(() {
      _currentError = null;
      _nextError = null;
      _repeatError = null;
      actionError = null;
    });
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    required String? errorText,
    bool autofocus = false,
    bool last = false,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsFieldLabel(label: label),
        const SizedBox(height: HollowSpacing.xs),
        HollowTextField(
          controller: controller,
          obscureText: true,
          autofocus: autofocus,
          keyboardType: widget.isPin ? TextInputType.number : null,
          inputFormatters:
              widget.isPin ? [FilteringTextInputFormatter.digitsOnly] : null,
          maxLength: widget.isPin ? 8 : null,
          showCounter: false,
          errorText: errorText,
          onChanged: (_) => _clearErrors(),
          onSubmitted: (_) =>
              last ? _submit() : FocusScope.of(context).nextFocus(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final change = widget.ask == SecretAsk.change;
    final fields = <Widget>[
      if (_asksCurrent)
        _field(_current, change ? 'Current $_word' : _capWord,
            errorText: _currentError,
            autofocus: true,
            last: !_asksNext),
      if (_asksNext) ...[
        _field(_next, change ? 'New $_word' : _capWord,
            errorText: _nextError, autofocus: !_asksCurrent),
        _field(_repeat, change ? 'Repeat the new $_word' : 'Repeat the $_word',
            errorText: _repeatError, last: true),
      ],
    ];
    return HollowDialog(
      title: widget.title,
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.message != null) ...[
            HollowDialogText(widget.message!),
            const SizedBox(height: HollowSpacing.lg),
          ],
          for (var i = 0; i < fields.length; i++) ...[
            if (i > 0) const SizedBox(height: HollowSpacing.md),
            fields[i],
          ],
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
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

String get _biometricName =>
    Platform.isIOS ? 'Face ID or Touch ID' : 'Fingerprint or face unlock';

/// The phone's first step: PIN or password. Null when dismissed.
Future<String?> _chooseLockType(BuildContext context) {
  final hollow = HollowTheme.of(context);
  return showHollowSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm),
            child: Text('Choose a lock',
                style: HollowTypography.subheading
                    .copyWith(color: hollow.textPrimary)),
          ),
          HollowListRow(
            touch: true,
            title: 'PIN',
            subtitle: '4 to 8 digits, quick to type',
            trailing: Icon(LucideIcons.chevronRight,
                size: 16, color: hollow.textSecondary),
            onTap: () => Navigator.pop(ctx, 'pin'),
          ),
          HollowListRow(
            touch: true,
            title: 'Password',
            subtitle: 'Anything you like, stronger',
            trailing: Icon(LucideIcons.chevronRight,
                size: 16, color: hollow.textSecondary),
            onTap: () => Navigator.pop(ctx, 'password'),
          ),
          // A biometric sits on top of a PIN or password rather than being a
          // lock of its own; it is listed so people know it exists.
          HollowListRow(
            touch: true,
            title: _biometricName,
            subtitle: 'Available once a PIN or password is set',
          ),
          const SizedBox(height: HollowSpacing.lg),
        ],
      ),
    ),
  );
}

/// Kept for the legacy settings dialog, which still names it.
typedef SecurityTab = SecuritySettingsPage;

/// "Always relay calls": forces every real-time connection through the relay,
/// so co-participants never see this device's IP address.
class AlwaysRelayCallsToggle extends ConsumerWidget {
  const AlwaysRelayCallsToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsSwitchRow(
      title: 'Always relay calls',
      subtitle: 'Calls, video, screen shares and file transfers go through '
          'the relay, so nobody sees your IP address. Quality may drop a '
          'little. Applies after a restart.',
      value: ref.watch(alwaysRelayCallsProvider),
      onChanged: (val) async {
        final notifier = ref.read(alwaysRelayCallsProvider.notifier);
        try {
          await notifier.setEnabled(val);
        } catch (e) {
          if (context.mounted) {
            HollowToast.show(context, friendlyError(e),
                type: HollowToastType.error);
          }
          return;
        }
        if (notifier.needsRestart && context.mounted) {
          await _offerRestart(context, ref);
        }
      },
    );
  }

  /// The policy is read when the node starts, so the change waits for a
  /// restart. A phone cannot relaunch itself: it closes and is reopened.
  static Future<void> _offerRestart(BuildContext context, WidgetRef ref) {
    final phone = Platform.isAndroid || Platform.isIOS;
    final inCall = ref.read(callProvider).status != CallStatus.idle ||
        ref.read(voiceChannelProvider).currentChannelId != null;
    return showHollowConfirm(
      context: context,
      title: phone ? 'Close Hollow now?' : 'Restart Hollow now?',
      message: [
        phone
            ? 'Always relay calls starts working the next time you open '
                'Hollow.'
            : 'Always relay calls starts working after Hollow restarts.',
        if (inCall) 'Your call ends when Hollow closes.',
      ].join(' '),
      confirmLabel: phone ? 'Close Hollow' : 'Restart now',
      cancelLabel: 'Later',
      onConfirm: () => relaunchApp(),
    );
  }
}

/// "Help carry screen shares" (peer media forwarding): while watching a screen
/// share, this desktop may serve as a blind packet forwarder carrying the still
/// end-to-end encrypted stream to viewers who cannot connect directly. On by
/// default, desktop only.
class PeerForwardingToggle extends ConsumerWidget {
  const PeerForwardingToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsSwitchRow(
      title: 'Help carry screen shares',
      subtitle: "Pass a share you watch on to viewers who can't connect "
          'directly. Uses some upload.',
      value: ref.watch(peerForwardingProvider),
      onChanged: (val) async {
        try {
          await ref.read(peerForwardingProvider.notifier).setEnabled(val);
        } catch (e) {
          if (context.mounted) {
            HollowToast.show(context, friendlyError(e),
                type: HollowToastType.error);
          }
        }
      },
    );
  }
}

/// The "App lock" section: the password, the idle lock, the cold-start prompt
/// and the duress code.
class SecurityAppLockSection extends ConsumerStatefulWidget {
  const SecurityAppLockSection({super.key});
  @override
  ConsumerState<SecurityAppLockSection> createState() =>
      _SecurityAppLockSectionState();
}

class _SecurityAppLockSectionState
    extends ConsumerState<SecurityAppLockSection> {
  bool _hasPassword = false;
  bool _hasOsKeychain = false;
  bool _hasLaunchSecret = false;
  bool _protectionLoading = true;

  /// The status read failed: the controls stay hidden, since defaults would
  /// offer a password holder "Set password".
  bool _protectionFailed = false;

  // A phone's lock is a PIN or a password, optionally opened by a biometric
  // that stores the secret behind the OS prompt.
  static bool get _phone => Platform.isAndroid || Platform.isIOS;
  String? _lockType;
  bool _canBiometric = false;
  bool _biometricEnabled = false;

  bool get _isPin => _lockType == 'pin';
  String get _secretWord => _isPin ? 'PIN' : 'password';

  /// Hollow asks for the password before it starts: nothing holds the key for
  /// a silent start.
  bool get _askBeforeStart => !_hasOsKeychain && !_hasLaunchSecret;

  @override
  void initState() {
    super.initState();
    _loadProtectionStatus();
  }

  Future<void> _loadProtectionStatus() async {
    try {
      final status = await identity_api.getIdentityProtectionStatus();
      final appLock = AppLockService();
      final launchSecret = await appLock.hasLaunchSecret();
      if (_phone) {
        _lockType = await appLock.getLockType();
        _canBiometric = await appLock.canUseBiometrics();
        _biometricEnabled = await appLock.isBiometricEnabled();
      }
      if (!mounted) return;
      // The one funnel every protection change already runs through, so the
      // duress row's availability can never lag behind this section's own
      // state. Past the first await: initState also calls this, and an
      // invalidate there asserts.
      ref.invalidate(identityProtectionProvider);
      setState(() {
        _hasPassword = status.hasPassword;
        _hasOsKeychain = status.hasOsKeychain;
        _hasLaunchSecret = launchSecret;
        _protectionLoading = false;
        _protectionFailed = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _protectionLoading = false;
        _protectionFailed = true;
      });
    }
  }

  void _retryProtectionStatus() {
    setState(() {
      _protectionLoading = true;
      _protectionFailed = false;
    });
    _loadProtectionStatus();
  }

  Widget _protectionFailedRow(String title) => SettingsRow(
        title: title,
        subtitle: "Couldn't read your lock settings",
        trailing: HollowButton.ghost(
          compact: true,
          touch: _phone,
          onPressed: _retryProtectionStatus,
          child: const Text('Try again'),
        ),
      );

  Future<void> _enablePassword() async {
    final passphrase = await askSecretDialog(
      context,
      title: 'Set app password',
      ask: SecretAsk.create,
      confirmLabel: 'Set password',
      message: 'Hollow asks for it whenever it locks. If you forget it, only '
          'your recovery phrase brings your identity back.',
      onSubmit: (_, next) async {
        // Silent start: the keystore holds the key where the platform has one,
        // and the secure-storage copy covers the rest, so the app lock is the
        // only prompt and a duress code typed there signs the wide scopes.
        await identity_api.enablePasswordProtection(
            password: next, requireOnLaunch: false);
        final appLock = AppLockService();
        appLock.sessionSecret = next;
        await appLock.storeLaunchSecret(next);
      },
    );
    if (passphrase == null || !mounted) return;
    await _loadProtectionStatus();
    if (!mounted) return;
    HollowToast.show(context, 'App lock enabled',
        type: HollowToastType.success);
  }

  Future<void> _toggleRequireOnLaunch(bool require) async {
    final appLock = AppLockService();
    try {
      if (require) {
        await identity_api.setRequirePasswordOnLaunch(require: true);
        await appLock.clearLaunchSecret();
      } else {
        // Turning the silent start back on needs the password itself, which
        // may not be in memory if this session was unlocked by the keystore.
        var secret = appLock.sessionSecret;
        if (secret == null) {
          secret = await askSecretDialog(
            context,
            title: 'Confirm your $_secretWord',
            ask: SecretAsk.current,
            isPin: _phone && _isPin,
            confirmLabel: 'Continue',
            onSubmit: (current, _) async {
              await identity_api.unlockIdentity(password: current);
              appLock.sessionSecret = current;
            },
          );
          if (secret == null || !mounted) return;
        }
        await identity_api.setRequirePasswordOnLaunch(require: false);
        await appLock.storeLaunchSecret(secret);
      }
      if (!mounted) return;
      await _loadProtectionStatus();
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(context,
          friendlyError(e, fallback: "Couldn't change the setting. Try again."),
          type: HollowToastType.error);
    }
  }

  Future<void> _changePassword() async {
    final newPass = await askSecretDialog(
      context,
      title: 'Change password',
      ask: SecretAsk.change,
      confirmLabel: 'Change password',
      onSubmit: (current, next) async {
        await identity_api.changePassword(
            oldPassword: current, newPassword: next);
        final appLock = AppLockService();
        appLock.sessionSecret = next;
        if (await appLock.hasLaunchSecret()) {
          await appLock.storeLaunchSecret(next);
        }
      },
    );
    if (newPass == null || !mounted) return;
    HollowToast.show(context, 'Password changed',
        type: HollowToastType.success);
  }

  Future<void> _removePassword() async {
    final pass = await askSecretDialog(
      context,
      title: 'Turn off the password',
      ask: SecretAsk.current,
      confirmLabel: 'Turn off',
      message: 'Your identity file stays on this computer unencrypted, so '
          'anyone using it can copy your identity.',
      onSubmit: (current, _) async {
        await identity_api.removePasswordProtection(password: current);
        await AppLockService().clearAll();
      },
    );
    if (pass == null || !mounted) return;
    await _loadProtectionStatus();
    if (!mounted) return;
    HollowToast.show(context, 'Password turned off',
        type: HollowToastType.success);
  }

  /// Phone: a PIN or a password, chosen first. The calls are the desktop's;
  /// `requireOnLaunch` changes nothing where Rust has no platform keystore,
  /// and the stored launch secret gives the silent start.
  Future<void> _enablePhoneLock() async {
    final type = await _chooseLockType(context);
    if (type == null || !mounted) return;
    final isPin = type == 'pin';
    final secret = await askSecretDialog(
      context,
      title: isPin ? 'Set a PIN' : 'Set a password',
      ask: SecretAsk.create,
      isPin: isPin,
      confirmLabel: 'Turn on',
      message: 'Hollow asks for it whenever it locks. If you forget it, only '
          'your recovery phrase brings your identity back.',
      onSubmit: (_, next) async {
        await identity_api.enablePasswordProtection(
            password: next, requireOnLaunch: true);
        final appLock = AppLockService();
        await appLock.setLockType(type);
        // Any biometric secret stored before is stale now.
        await appLock.disableBiometric();
        appLock.sessionSecret = next;
        // Hollow starts on its own and the app lock is the prompt, so a duress
        // code typed there reaches the other devices even after a full close.
        await appLock.storeLaunchSecret(next);
      },
    );
    if (secret == null || !mounted) return;
    await _loadProtectionStatus();
    if (!mounted) return;
    HollowToast.show(context, isPin ? 'PIN set' : 'Password set',
        type: HollowToastType.success);
  }

  Future<void> _changePhoneSecret() async {
    final isPin = _isPin;
    final newSecret = await askSecretDialog(
      context,
      title: 'Change $_secretWord',
      ask: SecretAsk.change,
      isPin: isPin,
      confirmLabel: 'Change',
      onSubmit: (current, next) async {
        await identity_api.changePassword(
            oldPassword: current, newPassword: next);
        final appLock = AppLockService();
        appLock.sessionSecret = next;
        if (await appLock.hasLaunchSecret()) {
          await appLock.storeLaunchSecret(next);
        }
        // The biometric releases the secret it holds, so it follows the change.
        if (await appLock.isBiometricEnabled()) {
          await appLock.enableBiometric(next);
        }
      },
    );
    if (newSecret == null || !mounted) return;
    HollowToast.show(context, isPin ? 'PIN changed' : 'Password changed',
        type: HollowToastType.success);
  }

  Future<void> _removePhoneLock() async {
    final secret = await askSecretDialog(
      context,
      title: 'Turn off the app lock',
      ask: SecretAsk.current,
      isPin: _isPin,
      confirmLabel: 'Turn off',
      onSubmit: (current, _) async {
        await identity_api.removePasswordProtection(password: current);
        await AppLockService().clearAll();
      },
    );
    if (secret == null || !mounted) return;
    await _loadProtectionStatus();
    if (!mounted) return;
    HollowToast.show(context, 'App lock removed',
        type: HollowToastType.success);
  }

  Future<void> _toggleBiometric(bool enable) async {
    final appLock = AppLockService();
    if (!enable) {
      await appLock.disableBiometric();
      await _loadProtectionStatus();
      return;
    }
    // The secret is stored behind the biometric gate, so it comes from this
    // session's capture or from the user, checked against the identity first.
    var secret = appLock.sessionSecret;
    if (secret == null) {
      if (!mounted) return;
      secret = await askSecretDialog(
        context,
        title: 'Enter your $_secretWord',
        ask: SecretAsk.current,
        isPin: _isPin,
        confirmLabel: 'Continue',
        onSubmit: (current, _) =>
            identity_api.unlockIdentity(password: current),
      );
    }
    if (secret == null || secret.isEmpty) return;
    // One live prompt, so a broken or cancelled sensor is never trusted.
    final ok = await appLock.promptBiometric();
    if (!ok) {
      if (mounted) {
        HollowToast.show(context, 'Biometric check failed',
            type: HollowToastType.error);
      }
      return;
    }
    await appLock.enableBiometric(secret);
    appLock.sessionSecret = secret;
    await _loadProtectionStatus();
    if (mounted) {
      HollowToast.show(context, 'Biometric unlock enabled',
          type: HollowToastType.success);
    }
  }

  List<Widget> _phoneLockRows() {
    final hollow = HollowTheme.of(context);
    if (!_hasPassword) {
      return [
        SettingsRow(
          title: 'App lock',
          subtitle: 'A PIN or password locks Hollow and encrypts your '
              'identity on this phone',
          trailing: HollowButton.filled(
            compact: true,
            onPressed: _enablePhoneLock,
            child: const Text('Turn on'),
          ),
        ),
      ];
    }
    return [
      SettingsRow(
        title: 'App lock',
        subtitleWidget: Text.rich(
          TextSpan(children: [
            TextSpan(text: 'On. ', style: TextStyle(color: hollow.success)),
            TextSpan(text: 'Opens with your $_secretWord.'),
          ]),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            HollowButton.ghost(
              compact: true,
              onPressed: _changePhoneSecret,
              child: const Text('Change'),
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.ghost(
              compact: true,
              onPressed: _removePhoneLock,
              child: const Text('Turn off'),
            ),
          ],
        ),
      ),
      if (_canBiometric)
        SettingsSwitchRow(
          title: _biometricName,
          subtitle: 'Unlock without typing your $_secretWord',
          value: _biometricEnabled,
          onChanged: _toggleBiometric,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_phone) {
      return SettingsSection(
        title: 'App lock',
        children: [
          if (_protectionLoading)
            const SettingsRow(
                title: 'App lock', trailing: HollowSpinner(delayed: true))
          else if (_protectionFailed)
            _protectionFailedRow('App lock')
          else ...[
            ..._phoneLockRows(),
            if (_hasPassword) ..._launchRows(),
          ],
          const DuressCodeCard(wideScopes: true),
          const SettingsNote(
            'Forgot it? Your recovery phrase brings your identity back.',
          ),
        ],
      );
    }
    return SettingsSection(
      title: 'App lock',
      children: [
        if (_protectionLoading)
          const SettingsRow(
              title: 'Password', trailing: HollowSpinner(delayed: true))
        else if (_protectionFailed)
          _protectionFailedRow('Password')
        else if (!_hasPassword)
          SettingsRow(
            title: 'Password',
            subtitle: 'Locks Hollow and encrypts your identity file. Without '
                'one, anyone using this computer can copy your identity.',
            trailing: HollowButton.filled(
              compact: true,
              onPressed: _enablePassword,
              child: const Text('Set password'),
            ),
          )
        else
          ..._passwordOnRows(),
        const DuressCodeCard(wideScopes: true),
        const SettingsNote(
          'Forgot the password? Your recovery phrase brings your identity '
          'back. Your files on disk are protected with the same key as your '
          'messages.',
        ),
      ],
    );
  }

  List<Widget> _passwordOnRows() {
    final hollow = HollowTheme.of(context);
    final duress = ref.watch(duressStatusProvider).valueOrNull;
    // A code set for the wider scopes cannot sign them at a cold start, and
    // that has to be said where the cold start is switched on.
    final duressGoesLocal = _askBeforeStart &&
        !(Platform.isAndroid || Platform.isIOS) &&
        (duress?.enabled ?? false) &&
        duress?.scope != kDuressScopeDevice;
    return [
      SettingsRow(
        title: 'Password',
        subtitleWidget: Text.rich(
          TextSpan(children: [
            TextSpan(text: 'On. ', style: TextStyle(color: hollow.success)),
            const TextSpan(
              text: 'Locks Hollow and encrypts your identity file on this '
                  'computer.',
            ),
          ]),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            HollowButton.ghost(
              compact: true,
              onPressed: _changePassword,
              child: const Text('Change'),
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.ghost(
              compact: true,
              onPressed: _removePassword,
              child: const Text('Turn off'),
            ),
          ],
        ),
      ),
      ..._launchRows(),
      if (duressGoesLocal)
        const SettingsNote(
            'A duress code typed at that prompt destroys this computer only.'),
    ];
  }

  /// The idle lock and the cold-start prompt, once a lock exists.
  List<Widget> _launchRows() => [
        AppLockCard(hasPassword: _hasPassword),
        SettingsSwitchRow(
          title: 'Ask before Hollow starts',
          subtitle: 'Hollow stays offline until you type the $_secretWord',
          value: _askBeforeStart,
          onChanged: _toggleRequireOnLaunch,
        ),
      ];
}

/// The "Recovery" section: the 24 words and the backup file.
class SecurityRecoverySection extends StatefulWidget {
  const SecurityRecoverySection({super.key});
  @override
  State<SecurityRecoverySection> createState() =>
      _SecurityRecoverySectionState();
}

class _SecurityRecoverySectionState extends State<SecurityRecoverySection> {
  static const _title = 'Recovery phrase';

  final _entry = TextEditingController();
  bool _revealed = false;
  bool _loading = true;
  bool _saving = false;
  String? _mnemonic;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMnemonic();
  }

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  Future<void> _loadMnemonic() async {
    try {
      final mnemonic = await storage_api.getMnemonic();
      if (!mounted) return;
      setState(() {
        _mnemonic = mnemonic;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  Future<void> _onMnemonicSubmitted(String val) async {
    if (_saving) return;
    final words = val.trim().split(RegExp(r'\s+'));
    if (words.length != 24) {
      HollowToast.show(context, 'Must be exactly 24 words',
          type: HollowToastType.error);
      return;
    }
    setState(() => _saving = true);
    try {
      await storage_api.saveMnemonic(mnemonic: val.trim());
      if (mounted) {
        setState(() => _mnemonic = val.trim());
        HollowToast.show(context, 'Recovery phrase saved',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, friendlyError(e),
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _mnemonic!));
    if (!mounted) return;
    HollowToast.show(context, 'Copied to clipboard',
        type: HollowToastType.success);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSection(
      title: 'Recovery',
      children: [
        ..._phraseRows(HollowTheme.of(context)),
        const BackupFileRow(),
      ],
    );
  }

  List<Widget> _phraseRows(HollowTheme hollow) {
    if (_loading) {
      return const [SettingsRow(title: _title, trailing: HollowSpinner())];
    }
    if (_error != null) {
      return [
        SettingsRow(
          title: _title,
          subtitleWidget: Text(
            "Couldn't load the recovery phrase. $_error",
            style: HollowTypography.bodySmall.copyWith(color: hollow.error),
          ),
        ),
      ];
    }
    if (_mnemonic == null) {
      return [
        SettingsRow(
          title: _title,
          subtitle: 'None stored on this device. If you have your 24 words, '
              'enter them below.',
          trailing: HollowButton.outline(
            compact: true,
            onPressed: _saving ? null : () => _onMnemonicSubmitted(_entry.text),
            loading: _saving,
            child: const Text('Save'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
          child: HollowTextField(
            controller: _entry,
            hintText: 'Enter the 24 words',
            isDense: true,
            onSubmitted: _onMnemonicSubmitted,
          ),
        ),
      ];
    }
    return [
      SettingsRow(
        title: _title,
        subtitle: '24 words that bring your identity back on any device. '
            'Anyone who has them owns it.',
        trailing: HollowButton.ghost(
          compact: true,
          onPressed: () => setState(() => _revealed = !_revealed),
          child: Text(_revealed ? 'Hide' : 'Reveal'),
        ),
      ),
      if (_revealed) ...[
        Container(
          padding: const EdgeInsets.all(HollowSpacing.md),
          decoration: BoxDecoration(
            color: hollow.elevated,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
          ),
          child: _buildWordGrid(hollow),
        ),
        const SizedBox(height: HollowSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: HollowButton.ghost(
            compact: true,
            onPressed: _copy,
            child: const Text('Copy'),
          ),
        ),
      ],
    ];
  }

  Widget _buildWordGrid(HollowTheme hollow) {
    final words = _mnemonic!.split(' ');
    return LayoutBuilder(builder: (context, constraints) {
      // Four columns where a word fits, three on a phone.
      final cols = constraints.maxWidth >= 480 ? 4 : 3;
      final rows = (words.length / cols).ceil();
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int row = 0; row < rows; row++)
            Padding(
              padding: EdgeInsets.only(
                bottom: row < rows - 1 ? HollowSpacing.xs : 0,
              ),
              child: Row(
                children: [
                  for (int col = 0; col < cols; col++) ...[
                    if (col > 0) const SizedBox(width: HollowSpacing.sm),
                    Expanded(child: _word(hollow, words, row * cols + col)),
                  ],
                ],
              ),
            ),
        ],
      );
    });
  }

  Widget _word(HollowTheme hollow, List<String> words, int index) {
    if (index >= words.length) return const SizedBox.shrink();
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: '${(index + 1).toString().padLeft(2)}. ',
          style: HollowTypography.monoSmall.copyWith(color: hollow.textTertiary),
        ),
        TextSpan(
          text: words[index],
          style: HollowTypography.monoSmall.copyWith(color: hollow.textPrimary),
        ),
      ]),
    );
  }
}
