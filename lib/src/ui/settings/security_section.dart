import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/duress_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/core/services/app_lock_service.dart';
import 'package:hollow/src/ui/settings/app_lock_card.dart';
import 'package:hollow/src/ui/settings/blocked_users_shared.dart';
import 'package:hollow/src/ui/settings/duress_section.dart';
import 'package:hollow/src/ui/settings/verified_contacts_shared.dart';
import 'package:hollow/src/ui/settings/verify_proof_section.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Passphrase prompt shared by App Lock and Identity Backup. Returns the
/// passphrase, or null if cancelled; [confirm] adds a second field that must
/// match.
Future<String?> askPassphraseDialog(BuildContext context, String title,
    {bool confirm = false, String buttonLabel = 'Encrypt'}) async {
  final controller = TextEditingController();
  final confirmController = TextEditingController();
  return showHollowDialog<String>(
    context: context,
    builder: (ctx) {
      final hollow = HollowTheme.of(ctx);
      return Center(
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            width: 360,
            padding: const EdgeInsets.all(HollowSpacing.xl),
            decoration: BoxDecoration(
              color: hollow.overlay,
              borderRadius: BorderRadius.circular(hollow.radiusLg),
              border: Border.all(color: hollow.accent.withValues(alpha: 0.15)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: HollowTypography.heading.copyWith(
                  color: hollow.textPrimary, fontSize: 16,
                )),
                const SizedBox(height: HollowSpacing.lg),
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
                  const SizedBox(height: HollowSpacing.sm),
                  HollowTextField(
                    controller: confirmController,
                    obscureText: true,
                    hintText: 'Confirm passphrase',
                  ),
                ],
                const SizedBox(height: HollowSpacing.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    HollowButton.ghost(
                      onPressed: () => Navigator.of(ctx).pop(null),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: HollowSpacing.sm),
                    HollowButton.filled(
                      onPressed: () {
                        final pass = controller.text.trim();
                        if (pass.isEmpty) return;
                        if (confirm && pass != confirmController.text.trim()) {
                          HollowToast.show(ctx, 'Passphrases don\'t match', type: HollowToastType.error);
                          return;
                        }
                        Navigator.of(ctx).pop(pass);
                      },
                      child: Text(buttonLabel),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// "Always relay calls": forces every real-time connection through the relay,
/// so co-participants never see this device's IP address.
///
/// Its own ConsumerWidget because [SecurityTab] has no `ref`.
class AlwaysRelayCallsToggle extends ConsumerWidget {
  const AlwaysRelayCallsToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final enabled = ref.watch(alwaysRelayCallsProvider);

    return Row(
      children: [
        Icon(LucideIcons.shield, size: 16, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Always relay calls',
                style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                alwaysRelayCallsDescription,
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: HollowSpacing.md),
        HollowToggle(
          value: enabled,
          onChanged: (val) async {
            try {
              await ref.read(alwaysRelayCallsProvider.notifier).setEnabled(val);
            } catch (e) {
              if (context.mounted) {
                HollowToast.show(
                  context,
                  'Could not save the setting: $e',
                  type: HollowToastType.error,
                );
              }
            }
          },
        ),
      ],
    );
  }
}

/// "Peer media forwarding": while watching a screen share, this desktop may
/// serve as a blind packet forwarder carrying the still end-to-end encrypted
/// stream to viewers who cannot connect directly. On by default, desktop only.
class PeerForwardingToggle extends ConsumerWidget {
  const PeerForwardingToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final enabled = ref.watch(peerForwardingProvider);

    return Row(
      children: [
        Icon(LucideIcons.share2, size: 16, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Peer media forwarding',
                style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                peerForwardingDescription,
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: HollowSpacing.md),
        HollowToggle(
          value: enabled,
          onChanged: (val) async {
            try {
              await ref.read(peerForwardingProvider.notifier).setEnabled(val);
            } catch (e) {
              if (context.mounted) {
                HollowToast.show(
                  context,
                  'Could not save the setting: $e',
                  type: HollowToastType.error,
                );
              }
            }
          },
        ),
      ],
    );
  }
}

/// Security category: App Lock, Device Protection, Recovery Phrase, proof
/// verification and the blocked users list.
class SecurityTab extends ConsumerStatefulWidget {
  const SecurityTab({super.key});
  @override
  ConsumerState<SecurityTab> createState() => _SecurityTabState();
}

class _SecurityTabState extends ConsumerState<SecurityTab> {
  bool _revealed = false;
  bool _loading = true;
  String? _mnemonic;
  String? _error;
  bool _hasPassword = false;
  bool _hasOsKeychain = false;
  bool _hasLaunchSecret = false;
  bool _protectionLoading = true;

  /// Hollow asks for the password before it starts: nothing holds the key for
  /// a silent start.
  bool get _askBeforeStart => !_hasOsKeychain && !_hasLaunchSecret;

  @override
  void initState() {
    super.initState();
    _loadMnemonic();
    _loadProtectionStatus();
  }

  Future<void> _loadProtectionStatus() async {
    try {
      final status = await identity_api.getIdentityProtectionStatus();
      final launchSecret = await AppLockService().hasLaunchSecret();
      if (!mounted) return;
      // The one funnel every protection change already runs through, so the
      // duress card's availability can never lag behind this tab's own state.
      // Past the first await: initState also calls this, and an invalidate
      // there asserts.
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
  /// One field for all five buttons, because they mutate the same identity file
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

  Widget _busySpinner(Color color) => SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2, color: color),
      );

  Future<void> _enablePassword() async {
    final passphrase = await _askPassphrase(context, 'Set app password', confirm: true, buttonLabel: 'Set password');
    if (passphrase == null || !mounted) return;

    await _runProtectionAction('enablePassword', () async {
      try {
        // Silent start: the keystore holds the key where the platform has one,
        // and the secure-storage copy covers the rest, so the app lock is the
        // only prompt and a duress code typed there signs the wide scopes.
        await identity_api.enablePasswordProtection(password: passphrase, requireOnLaunch: false);
        final appLock = AppLockService();
        appLock.sessionSecret = passphrase;
        await appLock.storeLaunchSecret(passphrase);
        if (!mounted) return;
        await _loadProtectionStatus();
        if (!mounted) return;
        HollowToast.show(context, 'App lock enabled', type: HollowToastType.success);
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
          secret = await _askPassphrase(context, 'Confirm your password',
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
    final oldPass = await _askPassphrase(context, 'Current password', buttonLabel: 'Next');
    if (oldPass == null || !mounted) return;

    final newPass = await _askPassphrase(context, 'New password', confirm: true, buttonLabel: 'Change password');
    if (newPass == null || !mounted) return;

    await _runProtectionAction('changePassword', () async {
      try {
        await identity_api.changePassword(oldPassword: oldPass, newPassword: newPass);
        final appLock = AppLockService();
        appLock.sessionSecret = newPass;
        if (await appLock.hasLaunchSecret()) {
          await appLock.storeLaunchSecret(newPass);
        }
        if (!mounted) return;
        HollowToast.show(context, 'Password changed', type: HollowToastType.success);
      } catch (e) {
        if (!mounted) return;
        HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
      }
    });
  }

  Future<void> _removePassword() async {
    final pass = await _askPassphrase(context, 'Enter current password', buttonLabel: 'Remove password');
    if (pass == null || !mounted) return;

    await _runProtectionAction('removePassword', () async {
      try {
        await identity_api.removePasswordProtection(password: pass);
        await AppLockService().clearAll();
        if (!mounted) return;
        await _loadProtectionStatus();
        if (!mounted) return;
        HollowToast.show(context, 'App password removed', type: HollowToastType.success);
      } catch (e) {
        if (!mounted) return;
        HollowToast.show(context, 'Wrong password', type: HollowToastType.error);
      }
    });
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

  Future<String?> _askPassphrase(BuildContext context, String title,
          {bool confirm = false, String buttonLabel = 'Encrypt'}) =>
      askPassphraseDialog(context, title,
          confirm: confirm, buttonLabel: buttonLabel);

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return SingleChildScrollView(
      key: const ValueKey('security'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HollowSectionHeader('Call Privacy'),
          const AlwaysRelayCallsToggle(),
          const SizedBox(height: HollowSpacing.md),
          const PeerForwardingToggle(),

          const SizedBox(height: HollowSpacing.xl),

          const HollowSectionHeader('App Lock'),

          if (_protectionLoading)
            Padding(
              padding: const EdgeInsets.all(HollowSpacing.md),
              child: SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: hollow.accent),
              ),
            )
          else
            ..._appLockChildren(hollow),

          const SizedBox(height: HollowSpacing.xl),

          const HollowSectionHeader('Duress Code'),
          const DuressCodeCard(wideScopes: true),

          const SizedBox(height: HollowSpacing.xl),

          const HollowSectionHeader('Recovery Phrase'),

          ..._recoveryChildren(hollow),

          const SizedBox(height: HollowSpacing.xl),

          const HollowSectionHeader('Verify a Proof'),
          const VerifyProofSection(),

          const SizedBox(height: HollowSpacing.xl),

          // Every verified badge the app shows is a claim made on the user's
          // behalf; this is where they review and withdraw them.
          const VerifiedContactsCard(),

          const SizedBox(height: HollowSpacing.xl),

          const BlockedUsersCard(),

          const SizedBox(height: HollowSpacing.xl),

          const HollowSectionHeader('Danger Zone'),
          const AccountDangerZoneCard(),
        ],
      ),
    );
  }

  List<Widget> _appLockChildren(HollowTheme hollow) {
    return [
      Text(
        _hasPassword
            ? 'Your password locks Hollow and encrypts your identity file.'
            : 'Set a password to lock Hollow and encrypt your identity file. Without one, anyone with access to this computer can copy your identity.',
        style: HollowTypography.body.copyWith(
          color: hollow.textSecondary, fontSize: 12,
        ),
      ),
      const SizedBox(height: HollowSpacing.md),

      if (_hasPassword)
        ..._passwordActiveChildren(hollow)
      else
        HollowButton.filled(
          onPressed: _busyAction == null ? _enablePassword : null,
          icon: _busyAction == 'enablePassword'
              ? _busySpinner(hollow.textOnAccent)
              : const Icon(LucideIcons.lock, size: 16),
          child: const Text('Set password'),
        ),

      const SizedBox(height: HollowSpacing.sm),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(LucideIcons.info, size: 14, color: hollow.textSecondary),
          ),
          const SizedBox(width: HollowSpacing.xs),
          Expanded(
            child: Text(
              'Forgot your password? You can recover with your 24-word recovery phrase.',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary, fontSize: 11,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: HollowSpacing.xs),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child:
                Icon(LucideIcons.shield, size: 14, color: hollow.textSecondary),
          ),
          const SizedBox(width: HollowSpacing.xs),
          Expanded(
            child: Text(
              'Your files on disk are protected with the same key as your messages.',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary, fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _passwordActiveChildren(HollowTheme hollow) {
    return [
      Row(
        children: [
          Icon(LucideIcons.shieldCheck, size: 16, color: hollow.success),
          const SizedBox(width: HollowSpacing.xs),
          Text(
            'App lock active',
            style: HollowTypography.body.copyWith(
              color: hollow.success, fontSize: 13,
            ),
          ),
        ],
      ),
      const SizedBox(height: HollowSpacing.md),
      AppLockCard(hasPassword: _hasPassword),
      const SizedBox(height: HollowSpacing.md),
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ask for the password before Hollow starts',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary, fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _askBeforeStart
                      ? 'On: Hollow stays offline until you type the password, and a duress code typed there destroys this computer only.'
                      : 'Off: Hollow starts on its own and the app lock asks for the password, so a duress code typed there reaches your other devices too.',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary, fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.md),
          HollowToggle(
            value: _askBeforeStart,
            onChanged: (val) => _toggleRequireOnLaunch(val),
          ),
        ],
      ),
      const SizedBox(height: HollowSpacing.md),
      Row(
        children: [
          HollowButton.ghost(
            onPressed: _busyAction == null ? _changePassword : null,
            icon: _busyAction == 'changePassword'
                ? _busySpinner(hollow.accent)
                : const Icon(LucideIcons.keyRound, size: 16),
            child: const Text('Change password'),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.ghost(
            onPressed: _busyAction == null ? _removePassword : null,
            icon: _busyAction == 'removePassword'
                ? _busySpinner(hollow.accent)
                : const Icon(LucideIcons.shieldOff, size: 16),
            child: const Text('Remove app lock'),
          ),
        ],
      ),
    ];
  }

  Future<void> _onMnemonicSubmitted(String val) async {
    final words = val.trim().split(RegExp(r'\s+'));
    if (words.length != 24) {
      HollowToast.show(context, 'Must be exactly 24 words', type: HollowToastType.error);
      return;
    }
    try {
      await storage_api.saveMnemonic(mnemonic: val.trim());
      if (mounted) {
        setState(() => _mnemonic = val.trim());
        HollowToast.show(context, 'Recovery phrase saved', type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) HollowToast.show(context, 'Failed to save: $e', type: HollowToastType.error);
    }
  }

  List<Widget> _recoveryChildren(HollowTheme hollow) {
    if (_loading) {
      return [
        Center(
          child: Padding(
            padding: const EdgeInsets.all(HollowSpacing.xl),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: hollow.accent,
              ),
            ),
          ),
        ),
      ];
    }
    if (_error != null) {
      return [
        Text(
          'Failed to load mnemonic: $_error',
          style: HollowTypography.body.copyWith(color: hollow.error),
        ),
      ];
    }
    if (_mnemonic == null) return [_buildMnemonicEntry(hollow)];
    return _mnemonicPresentChildren(hollow);
  }

  Widget _buildMnemonicEntry(HollowTheme hollow) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'No recovery phrase stored. If you have your 24 words, you can enter them below.',
          style: HollowTypography.body.copyWith(color: hollow.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: HollowSpacing.sm),
        SizedBox(
          width: 300,
          child: HollowTextField(
            controller: TextEditingController(),
            hintText: 'Enter 24-word recovery phrase',
            isDense: true,
            style: HollowTypography.body.copyWith(color: hollow.textPrimary, fontSize: 12),
            borderRadius: hollow.radiusMd,
            onSubmitted: _onMnemonicSubmitted,
          ),
        ),
      ],
    );
  }

  List<Widget> _mnemonicPresentChildren(HollowTheme hollow) {
    return [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(HollowSpacing.md),
        decoration: BoxDecoration(
          color: hollow.elevated,
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          border: Border.all(
            color: _revealed
                ? hollow.warning.withValues(alpha: 0.4)
                : hollow.border,
          ),
        ),
        child: _revealed
            ? _buildWordGrid(hollow)
            : Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: HollowSpacing.lg),
                  child: Text(
                    'Hidden for security',
                    style: HollowTypography.body.copyWith(
                      color: hollow.textSecondary.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
      ),

      const SizedBox(height: HollowSpacing.sm),

      Row(
        children: [
          HollowButton.ghost(
            onPressed: () => setState(() => _revealed = !_revealed),
            icon: Icon(
              _revealed ? LucideIcons.eyeOff : LucideIcons.eye,
              size: 16,
            ),
            child: Text(_revealed ? 'Hide' : 'Reveal'),
          ),
          if (_revealed) ...[
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.ghost(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _mnemonic!));
                HollowToast.show(
                  context,
                  'Copied to clipboard',
                  type: HollowToastType.success,
                );
              },
              icon: const Icon(LucideIcons.copy, size: 16),
              child: const Text('Copy'),
            ),
          ],
        ],
      ),

      const SizedBox(height: HollowSpacing.sm),

      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              LucideIcons.alertTriangle,
              size: 14,
              color: hollow.warning,
            ),
          ),
          const SizedBox(width: HollowSpacing.xs),
          Expanded(
            child: Text(
              'Anyone with these words can access your identity. Never share them.',
              style: HollowTypography.caption.copyWith(
                color: hollow.warning,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    ];
  }

  Widget _buildWordGrid(HollowTheme hollow) {
    final words = _mnemonic!.split(' ');
    const cols = 4;
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
                  Expanded(
                    child: Builder(builder: (context) {
                      final index = row * cols + col;
                      if (index >= words.length) return const SizedBox();
                      return RichText(
                        text: TextSpan(
                          children: [
                            TextSpan(
                              text: '${(index + 1).toString().padLeft(2)}. ',
                              style: HollowTypography.mono.copyWith(
                                color: hollow.textSecondary.withValues(alpha: 0.5),
                                fontSize: 10,
                              ),
                            ),
                            TextSpan(
                              text: words[index],
                              style: HollowTypography.mono.copyWith(
                                color: hollow.textPrimary,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
