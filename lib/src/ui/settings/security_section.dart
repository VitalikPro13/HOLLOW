import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/duress_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/services/app_lock_service.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/app_lock_card.dart';
import 'package:hollow/src/ui/settings/backup_section.dart';
import 'package:hollow/src/ui/settings/duress_section.dart';
import 'package:hollow/src/ui/settings/pages/security_page.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Passphrase prompt for the app password flows. Returns the
/// passphrase, or null if cancelled; [confirm] adds a second field that must
/// match; [destructive] makes the confirm a danger button.
Future<String?> askPassphraseDialog(BuildContext context, String title,
    {bool confirm = false,
    String buttonLabel = 'Encrypt',
    bool destructive = false}) async {
  final controller = TextEditingController();
  final confirmController = TextEditingController();
  return showHollowDialog<String>(
    context: context,
    builder: (ctx) {
      void submit() {
        final pass = controller.text.trim();
        if (pass.isEmpty) return;
        if (confirm && pass != confirmController.text.trim()) {
          HollowToast.show(ctx, "Passphrases don't match", type: HollowToastType.error);
          return;
        }
        Navigator.of(ctx).pop(pass);
      }

      return HollowDialog(
        title: title,
        width: 420,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HollowTextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              hintText: 'Enter passphrase',
              onSubmitted: confirm ? null : (val) {
                if (val.isNotEmpty) Navigator.of(ctx).pop(val);
              },
            ),
            if (confirm) ...[
              const SizedBox(height: HollowSpacing.md),
              HollowTextField(
                controller: confirmController,
                obscureText: true,
                hintText: 'Confirm passphrase',
              ),
            ],
          ],
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          destructive
              ? HollowButton.danger(onPressed: submit, child: Text(buttonLabel))
              : HollowButton.filled(onPressed: submit, child: Text(buttonLabel)),
        ],
      );
    },
  );
}

String get _biometricName =>
    Platform.isIOS ? 'Face ID or Touch ID' : 'Fingerprint or face unlock';

/// The phone's lock secret prompt: a PIN takes digits only (4 to 8), and
/// neither kind is trimmed, since what was typed at setup is what unlocks.
Future<String?> _askLockSecret(BuildContext context, String title,
    {bool confirm = false,
    bool isPin = false,
    String buttonLabel = 'OK',
    bool destructive = false}) {
  final controller = TextEditingController();
  final confirmController = TextEditingController();
  return showHollowDialog<String>(
    context: context,
    builder: (ctx) {
      void submit() {
        final secret = controller.text;
        if (secret.isEmpty) return;
        if (isPin && confirm && secret.length < 4) {
          HollowToast.show(ctx, 'A PIN needs at least 4 digits',
              type: HollowToastType.error);
          return;
        }
        if (confirm && secret != confirmController.text) {
          HollowToast.show(
              ctx, isPin ? "PINs don't match" : "Passwords don't match",
              type: HollowToastType.error);
          return;
        }
        Navigator.of(ctx).pop(secret);
      }

      Widget field(TextEditingController c, String hint,
              {bool autofocus = false}) =>
          HollowTextField(
            controller: c,
            hintText: hint,
            obscureText: true,
            autofocus: autofocus,
            keyboardType: isPin ? TextInputType.number : null,
            inputFormatters:
                isPin ? [FilteringTextInputFormatter.digitsOnly] : null,
            maxLength: isPin ? 8 : null,
            showCounter: false,
          );

      return HollowDialog(
        title: title,
        width: 420,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            field(controller, isPin ? 'PIN' : 'Password', autofocus: true),
            if (confirm) ...[
              const SizedBox(height: HollowSpacing.md),
              field(confirmController,
                  isPin ? 'Confirm PIN' : 'Confirm password'),
            ],
          ],
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          destructive
              ? HollowButton.danger(onPressed: submit, child: Text(buttonLabel))
              : HollowButton.filled(onPressed: submit, child: Text(buttonLabel)),
        ],
      );
    },
  );
}

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
          _LockTypeOption(
            icon: LucideIcons.hash,
            title: 'PIN',
            subtitle: '4 to 8 digits, quick to type',
            onTap: () => Navigator.pop(ctx, 'pin'),
          ),
          _LockTypeOption(
            icon: LucideIcons.keyRound,
            title: 'Password',
            subtitle: 'Anything you like, stronger',
            onTap: () => Navigator.pop(ctx, 'password'),
          ),
          // A biometric sits on top of a PIN or password rather than being a
          // lock of its own; it is listed so people know it exists.
          _LockTypeOption(
            icon: LucideIcons.fingerprint,
            title: _biometricName,
            subtitle: 'Available once a PIN or password is set',
            onTap: null,
          ),
          const SizedBox(height: HollowSpacing.lg),
        ],
      ),
    ),
  );
}

class _LockTypeOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  /// Null shows the row as unavailable.
  final VoidCallback? onTap;

  const _LockTypeOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final enabled = onTap != null;
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Row(
        children: [
          Icon(icon,
              size: 20,
              color: enabled ? hollow.textSecondary : hollow.textTertiary),
          const SizedBox(width: HollowSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: HollowTypography.bodyTouch.copyWith(
                        color: enabled
                            ? hollow.textPrimary
                            : hollow.textTertiary)),
                Text(subtitle,
                    style: HollowTypography.bodySmall.copyWith(
                        color: enabled
                            ? hollow.textSecondary
                            : hollow.textTertiary)),
              ],
            ),
          ),
          if (enabled)
            Icon(LucideIcons.chevronRight,
                size: 16, color: hollow.textSecondary),
        ],
      ),
    );
    const padding = EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg, vertical: HollowSpacing.xs);
    if (!enabled) return Padding(padding: padding, child: content);
    return HollowPressable(
      onTap: onTap,
      subtle: true,
      semanticButton: false,
      padding: padding,
      child: content,
    );
  }
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
        try {
          await ref.read(alwaysRelayCallsProvider.notifier).setEnabled(val);
        } catch (e) {
          if (context.mounted) {
            HollowToast.show(context, 'Could not save the setting: $e',
                type: HollowToastType.error);
          }
        }
      },
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
            HollowToast.show(context, 'Could not save the setting: $e',
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
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _protectionLoading = false);
    }
  }

  /// Which protection action is running an Argon2id or keychain FFI, or null.
  /// One field for every button, because they mutate the same identity file
  /// and must not overlap.
  String? _busyAction;

  Future<void> _runProtectionAction(
      String action, Future<void> Function() body) async {
    if (_busyAction != null) return;
    setState(() => _busyAction = action);
    try {
      await body();
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  Future<void> _enablePassword() async {
    final passphrase = await askPassphraseDialog(context, 'Set app password',
        confirm: true, buttonLabel: 'Set password');
    if (passphrase == null || !mounted) return;

    await _runProtectionAction('enablePassword', () async {
      try {
        // Silent start: the keystore holds the key where the platform has one,
        // and the secure-storage copy covers the rest, so the app lock is the
        // only prompt and a duress code typed there signs the wide scopes.
        await identity_api.enablePasswordProtection(
            password: passphrase, requireOnLaunch: false);
        final appLock = AppLockService();
        appLock.sessionSecret = passphrase;
        await appLock.storeLaunchSecret(passphrase);
        if (!mounted) return;
        await _loadProtectionStatus();
        if (!mounted) return;
        HollowToast.show(context, 'App lock enabled',
            type: HollowToastType.success);
      } catch (e) {
        if (!mounted) return;
        HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
      }
    });
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
          secret = _phone
              ? await _askLockSecret(context, 'Confirm your $_secretWord',
                  isPin: _isPin, buttonLabel: 'Continue')
              : await askPassphraseDialog(context, 'Confirm your password',
                  buttonLabel: 'Continue');
          if (secret == null || !mounted) return;
          await identity_api.unlockIdentity(password: secret);
          appLock.sessionSecret = secret;
        }
        await identity_api.setRequirePasswordOnLaunch(require: false);
        await appLock.storeLaunchSecret(secret);
      }
      if (!mounted) return;
      await _loadProtectionStatus();
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
    }
  }

  Future<void> _changePassword() async {
    final oldPass = await askPassphraseDialog(context, 'Current password',
        buttonLabel: 'Next');
    if (oldPass == null || !mounted) return;

    final newPass = await askPassphraseDialog(context, 'New password',
        confirm: true, buttonLabel: 'Change password');
    if (newPass == null || !mounted) return;

    await _runProtectionAction('changePassword', () async {
      try {
        await identity_api.changePassword(
            oldPassword: oldPass, newPassword: newPass);
        final appLock = AppLockService();
        appLock.sessionSecret = newPass;
        if (await appLock.hasLaunchSecret()) {
          await appLock.storeLaunchSecret(newPass);
        }
        if (!mounted) return;
        HollowToast.show(context, 'Password changed',
            type: HollowToastType.success);
      } catch (e) {
        if (!mounted) return;
        HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
      }
    });
  }

  Future<void> _removePassword() async {
    final pass = await askPassphraseDialog(context, 'Turn off the password',
        buttonLabel: 'Turn off', destructive: true);
    if (pass == null || !mounted) return;

    await _runProtectionAction('removePassword', () async {
      try {
        await identity_api.removePasswordProtection(password: pass);
        await AppLockService().clearAll();
        if (!mounted) return;
        await _loadProtectionStatus();
        if (!mounted) return;
        HollowToast.show(context, 'Password turned off',
            type: HollowToastType.success);
      } catch (e) {
        if (!mounted) return;
        HollowToast.show(context, 'Wrong password', type: HollowToastType.error);
      }
    });
  }

  /// Phone: a PIN or a password, chosen first. The calls are the desktop's;
  /// `requireOnLaunch` changes nothing where Rust has no platform keystore,
  /// and the stored launch secret gives the silent start.
  Future<void> _enablePhoneLock() async {
    final type = await _chooseLockType(context);
    if (type == null || !mounted) return;
    final isPin = type == 'pin';
    final secret = await _askLockSecret(
        context, isPin ? 'Set a PIN' : 'Set a password',
        confirm: true, isPin: isPin, buttonLabel: 'Turn on');
    if (secret == null || secret.isEmpty || !mounted) return;

    await _runProtectionAction('enablePassword', () async {
      try {
        await identity_api.enablePasswordProtection(
            password: secret, requireOnLaunch: true);
        final appLock = AppLockService();
        await appLock.setLockType(type);
        // Any biometric secret stored before is stale now.
        await appLock.disableBiometric();
        appLock.sessionSecret = secret;
        // Hollow starts on its own and the app lock is the prompt, so a duress
        // code typed there reaches the other devices even after a full close.
        await appLock.storeLaunchSecret(secret);
        if (!mounted) return;
        await _loadProtectionStatus();
        if (!mounted) return;
        HollowToast.show(context, isPin ? 'PIN set' : 'Password set',
            type: HollowToastType.success);
      } catch (e) {
        if (!mounted) return;
        HollowToast.show(context, 'Could not turn on the app lock: $e',
            type: HollowToastType.error);
      }
    });
  }

  Future<void> _changePhoneSecret() async {
    final isPin = _isPin;
    final oldSecret = await _askLockSecret(context, 'Current $_secretWord',
        isPin: isPin, buttonLabel: 'Next');
    if (oldSecret == null || !mounted) return;
    final newSecret = await _askLockSecret(context, 'New $_secretWord',
        confirm: true, isPin: isPin, buttonLabel: 'Change');
    if (newSecret == null || !mounted) return;

    await _runProtectionAction('changePassword', () async {
      try {
        await identity_api.changePassword(
            oldPassword: oldSecret, newPassword: newSecret);
        final appLock = AppLockService();
        appLock.sessionSecret = newSecret;
        if (await appLock.hasLaunchSecret()) {
          await appLock.storeLaunchSecret(newSecret);
        }
        // The biometric releases the secret it holds, so it follows the change.
        if (await appLock.isBiometricEnabled()) {
          await appLock.enableBiometric(newSecret);
        }
        if (!mounted) return;
        HollowToast.show(context, isPin ? 'PIN changed' : 'Password changed',
            type: HollowToastType.success);
      } catch (e) {
        if (!mounted) return;
        HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
      }
    });
  }

  Future<void> _removePhoneLock() async {
    final isPin = _isPin;
    final secret = await _askLockSecret(context, 'Turn off the app lock',
        isPin: isPin, buttonLabel: 'Turn off', destructive: true);
    if (secret == null || secret.isEmpty || !mounted) return;

    await _runProtectionAction('removePassword', () async {
      try {
        await identity_api.removePasswordProtection(password: secret);
        await AppLockService().clearAll();
        if (!mounted) return;
        await _loadProtectionStatus();
        if (!mounted) return;
        HollowToast.show(context, 'App lock removed',
            type: HollowToastType.success);
      } catch (e) {
        if (!mounted) return;
        HollowToast.show(context, isPin ? 'Wrong PIN' : 'Wrong password',
            type: HollowToastType.error);
      }
    });
  }

  Future<void> _toggleBiometric(bool enable) async {
    final appLock = AppLockService();
    if (!enable) {
      await appLock.disableBiometric();
      await _loadProtectionStatus();
      return;
    }
    // The secret is stored behind the biometric gate, so it comes from this
    // session's capture or from the user.
    var secret = appLock.sessionSecret;
    if (secret == null) {
      if (!mounted) return;
      secret = await _askLockSecret(context, 'Enter your $_secretWord',
          isPin: _isPin, buttonLabel: 'Continue');
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
            onPressed: _busyAction == null ? _enablePhoneLock : null,
            loading: _busyAction == 'enablePassword',
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
              onPressed: _busyAction == null ? _changePhoneSecret : null,
              loading: _busyAction == 'changePassword',
              child: const Text('Change'),
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.ghost(
              compact: true,
              onPressed: _busyAction == null ? _removePhoneLock : null,
              loading: _busyAction == 'removePassword',
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
            const SettingsRow(title: 'App lock', trailing: HollowSpinner())
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
          const SettingsRow(title: 'Password', trailing: HollowSpinner())
        else if (!_hasPassword)
          SettingsRow(
            title: 'Password',
            subtitle: 'Locks Hollow and encrypts your identity file. Without '
                'one, anyone using this computer can copy your identity.',
            trailing: HollowButton.filled(
              compact: true,
              onPressed: _busyAction == null ? _enablePassword : null,
              loading: _busyAction == 'enablePassword',
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
              onPressed: _busyAction == null ? _changePassword : null,
              loading: _busyAction == 'changePassword',
              child: const Text('Change'),
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.ghost(
              compact: true,
              onPressed: _busyAction == null ? _removePassword : null,
              loading: _busyAction == 'removePassword',
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
        _error = e.toString();
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
        HollowToast.show(context, 'Failed to save: $e',
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
