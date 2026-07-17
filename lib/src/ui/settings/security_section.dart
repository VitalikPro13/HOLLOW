import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/settings/blocked_users_shared.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:hollow/src/ui/settings/verify_proof_section.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'dart:io' show Platform;

/// Passphrase prompt shared by App Lock (Security category) and Identity
/// Backup (Backup category). Returns the entered passphrase, or null if
/// cancelled. When [confirm] is true a second field must match.
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
              color: hollow.elevated,
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

/// Security category — App Lock + Device Protection + Recovery Phrase,
/// plus proof verification and the blocked users list.
class SecurityTab extends StatefulWidget {
  const SecurityTab({super.key});
  @override
  State<SecurityTab> createState() => _SecurityTabState();
}

class _SecurityTabState extends State<SecurityTab> {
  bool _revealed = false;
  bool _loading = true;
  String? _mnemonic;
  String? _error;
  bool _hasPassword = false;
  bool _hasOsKeychain = false;
  bool _osKeychainAvailable = false;
  bool _protectionLoading = true;

  @override
  void initState() {
    super.initState();
    _loadMnemonic();
    _loadProtectionStatus();
  }

  Future<void> _loadProtectionStatus() async {
    try {
      final status = await identity_api.getIdentityProtectionStatus();
      if (!mounted) return;
      setState(() {
        _hasPassword = status.hasPassword;
        _hasOsKeychain = status.hasOsKeychain;
        _osKeychainAvailable = status.osKeychainAvailable;
        _protectionLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _protectionLoading = false);
    }
  }

  /// Which protection action is running an Argon2id/keychain FFI right now
  /// (null = idle). One field for all five buttons — they mutate the same
  /// identity file and must not overlap; the active button shows a spinner.
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
    final passphrase = await _askPassphrase(context, 'Set App Password', confirm: true, buttonLabel: 'Set Password');
    if (passphrase == null || !mounted) return;

    await _runProtectionAction('enablePassword', () async {
      try {
        await identity_api.enablePasswordProtection(password: passphrase, requireOnLaunch: true);
        if (!mounted) return;
        await _loadProtectionStatus();
        if (!mounted) return;
        HollowToast.show(context, 'Password protection enabled', type: HollowToastType.success);
      } catch (e) {
        if (!mounted) return;
        HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
      }
    });
  }

  Future<void> _toggleRequireOnLaunch(bool require) async {
    try {
      await identity_api.setRequirePasswordOnLaunch(require: require);
      if (!mounted) return;
      await _loadProtectionStatus();
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
    }
  }

  Future<void> _changePassword() async {
    final oldPass = await _askPassphrase(context, 'Current Password', buttonLabel: 'Next');
    if (oldPass == null || !mounted) return;

    final newPass = await _askPassphrase(context, 'New Password', confirm: true, buttonLabel: 'Change Password');
    if (newPass == null || !mounted) return;

    await _runProtectionAction('changePassword', () async {
      try {
        await identity_api.changePassword(oldPassword: oldPass, newPassword: newPass);
        if (!mounted) return;
        HollowToast.show(context, 'Password changed', type: HollowToastType.success);
      } catch (e) {
        if (!mounted) return;
        HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
      }
    });
  }

  Future<void> _removePassword() async {
    final pass = await _askPassphrase(context, 'Enter Current Password', buttonLabel: 'Remove Password');
    if (pass == null || !mounted) return;

    await _runProtectionAction('removePassword', () async {
      try {
        await identity_api.removePasswordProtection(password: pass);
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

  Future<void> _enableOsKeychain() async {
    await _runProtectionAction('enableKeychain', () async {
      try {
        await identity_api.enableOsKeychainProtection();
        if (!mounted) return;
        await _loadProtectionStatus();
        if (!mounted) return;
        HollowToast.show(context, 'Device protection enabled', type: HollowToastType.success);
      } catch (e) {
        if (!mounted) return;
        HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
      }
    });
  }

  Future<void> _disableOsKeychain() async {
    await _runProtectionAction('disableKeychain', () async {
      try {
        await identity_api.disableOsKeychainProtection();
        if (!mounted) return;
        await _loadProtectionStatus();
        if (!mounted) return;
        HollowToast.show(context, 'Device protection removed', type: HollowToastType.success);
      } catch (e) {
        if (!mounted) return;
        HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
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
          // ── App Lock ──
          const SettingsSectionLabel(label: 'APP LOCK'),
          const SizedBox(height: HollowSpacing.sm),

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

          // ── Recovery Phrase ──
          const SettingsSectionLabel(label: 'RECOVERY PHRASE'),
          const SizedBox(height: HollowSpacing.sm),

          ..._recoveryChildren(hollow),

          const SizedBox(height: HollowSpacing.xl),

          // ── Verify a Proof ──
          const SettingsSectionLabel(label: 'VERIFY A PROOF'),
          const SizedBox(height: HollowSpacing.sm),
          const VerifyProofSection(),

          const SizedBox(height: HollowSpacing.xl),

          // ── Blocked Users ──
          const BlockedUsersCard(),
        ],
      ),
    );
  }

  List<Widget> _appLockChildren(HollowTheme hollow) {
    return [
      Text(
        _hasPassword
            ? 'Your identity is encrypted with a password.'
            : 'Set a password to encrypt your identity file. Without it, anyone with access to your computer can copy your identity.',
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
          child: const Text('Set Password'),
        ),

      if (!_hasPassword && _osKeychainAvailable)
        ..._deviceProtectionChildren(hollow),

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
    ];
  }

  List<Widget> _passwordActiveChildren(HollowTheme hollow) {
    return [
      Row(
        children: [
          Icon(LucideIcons.shieldCheck, size: 16, color: hollow.success),
          const SizedBox(width: HollowSpacing.xs),
          Text(
            'Password protection active',
            style: HollowTypography.body.copyWith(
              color: hollow.success, fontSize: 13,
            ),
          ),
        ],
      ),
      const SizedBox(height: HollowSpacing.md),
      if (_osKeychainAvailable) ...[
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ask for password on launch',
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary, fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _hasOsKeychain
                        ? 'Off — the app opens silently on this device, but your identity file is still encrypted.'
                        : 'On — password is required every time you open Hollow.',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary, fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: HollowSpacing.md),
            HollowToggle(
              value: !_hasOsKeychain,
              onChanged: (val) => _toggleRequireOnLaunch(val),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.md),
      ],
      Row(
        children: [
          HollowButton.ghost(
            onPressed: _busyAction == null ? _changePassword : null,
            icon: _busyAction == 'changePassword'
                ? _busySpinner(hollow.accent)
                : const Icon(LucideIcons.keyRound, size: 16),
            child: const Text('Change Password'),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.ghost(
            onPressed: _busyAction == null ? _removePassword : null,
            icon: _busyAction == 'removePassword'
                ? _busySpinner(hollow.accent)
                : const Icon(LucideIcons.shieldOff, size: 16),
            child: const Text('Remove Password'),
          ),
        ],
      ),
    ];
  }

  List<Widget> _deviceProtectionChildren(HollowTheme hollow) {
    return [
      const SizedBox(height: HollowSpacing.xl),
      const SettingsSectionLabel(label: 'DEVICE PROTECTION'),
      const SizedBox(height: HollowSpacing.sm),
      Text(
        _hasOsKeychain
            ? 'Your identity is encrypted with this device\'s credentials. If Windows loses these credentials (OS reinstall, password reset), you\'ll need your 24-word recovery phrase.'
            : 'Encrypt your identity with this device\'s credentials. The app unlocks silently on this device, but the identity cannot be moved to another computer without the recovery phrase.',
        style: HollowTypography.body.copyWith(
          color: hollow.textSecondary, fontSize: 12,
        ),
      ),
      const SizedBox(height: HollowSpacing.md),
      if (_hasOsKeychain) ...[
        Row(
          children: [
            Icon(LucideIcons.monitor, size: 16, color: hollow.success),
            const SizedBox(width: HollowSpacing.xs),
            Text(
              'Device protection active',
              style: HollowTypography.body.copyWith(
                color: hollow.success, fontSize: 13,
              ),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.md),
        HollowButton.ghost(
          onPressed: _busyAction == null ? _disableOsKeychain : null,
          icon: _busyAction == 'disableKeychain'
              ? _busySpinner(hollow.accent)
              : const Icon(LucideIcons.shieldOff, size: 16),
          child: const Text('Remove Device Protection'),
        ),
      ] else ...[
        HollowButton.outline(
          onPressed: _busyAction == null ? _enableOsKeychain : null,
          icon: _busyAction == 'enableKeychain'
              ? _busySpinner(hollow.accent)
              : const Icon(LucideIcons.monitor, size: 16),
          child: const Text('Enable Device Protection'),
        ),
      ],
      if (Platform.isWindows) ...[
        const SizedBox(height: HollowSpacing.sm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(LucideIcons.alertTriangle, size: 14, color: hollow.warning),
            ),
            const SizedBox(width: HollowSpacing.xs),
            Expanded(
              child: Text(
                'Windows may lose device credentials after OS reinstalls or admin password resets. Always keep your 24-word recovery phrase backed up.',
                style: HollowTypography.caption.copyWith(
                  color: hollow.warning, fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      ],
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
            borderRadius: hollow.radiusSm,
            onSubmitted: _onMnemonicSubmitted,
          ),
        ),
      ],
    );
  }

  List<Widget> _mnemonicPresentChildren(HollowTheme hollow) {
    return [
      // Mnemonic container
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(HollowSpacing.md),
        decoration: BoxDecoration(
          color: hollow.background,
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

      // Reveal / Hide button + Copy button
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

      // Warning text
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
    // 6 rows x 4 columns (easier to read, less cramped)
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
