import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/android_platform.dart';
import 'package:hollow/src/core/services/android_version.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/services/app_lock_service.dart';
import 'package:hollow/src/core/services/channel_topic_service.dart';
import 'package:hollow/src/core/services/deep_link_service.dart';
import 'package:hollow/src/core/services/ios_data_dir_migration.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/help_panel_provider.dart';
import 'package:hollow/src/core/providers/hotkey_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/device_link_sync_provider.dart';
import 'package:hollow/src/core/providers/node_provider.dart';
import 'package:hollow/src/core/providers/pending_join_provider.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
import 'package:hollow/src/core/providers/favourite_friends_provider.dart';
import 'package:hollow/src/core/providers/hidden_archive_dm_provider.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/security_alerts_provider.dart';
import 'package:hollow/src/core/providers/verified_peers_provider.dart';
import 'package:hollow/src/core/providers/status_provider.dart';
import 'package:hollow/src/core/providers/annotation_mode_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/recording_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/providers/theme_provider.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_anim_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'package:hollow/src/core/providers/server_banner_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/sticker_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/system_notification_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/animations/ambient_background.dart';
import 'package:hollow/src/ui/animations/startup_reveal.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/desktop_notification_service.dart';
import 'package:hollow/src/ui/chat/channel_chat_pane.dart';
import 'package:hollow/src/ui/chat/chat_pane.dart';
import 'package:hollow/src/ui/chat/voice_channel_pane.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/notification_overlay.dart';
import 'package:hollow/src/ui/components/active_call_bar.dart';
import 'package:hollow/src/ui/dialogs/incoming_call_dialog.dart';
import 'package:hollow/src/ui/dialogs/create_channel_dialog.dart';
import 'package:hollow/src/ui/dialogs/device_link_dialog.dart';
import 'package:hollow/src/ui/dialogs/mnemonic_dialog.dart';
import 'package:hollow/src/ui/dialogs/user_settings_dialog.dart';
import 'package:hollow/src/ui/dialogs/welcome_dialog.dart';
import 'package:hollow/src/ui/dialogs/license_key_dialog.dart';
import 'package:hollow/src/core/providers/license_key_provider.dart';
import 'package:hollow/src/core/providers/gif_library_provider.dart';
import 'package:hollow/src/core/providers/gif_provider.dart';
import 'package:hollow/src/core/providers/link_preview_settings_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/relay_status_provider.dart';
import 'package:hollow/src/core/providers/app_shortcuts_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_binding.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/ui/settings/server_settings_panel.dart';
import 'package:hollow/src/core/providers/display_scale_provider.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/core/providers/shop_unlock_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
import 'package:hollow/src/ui/guides/help_panel.dart';
import 'package:hollow/src/ui/shell/bottom_bar.dart';
import 'package:hollow/src/ui/shell/channel_sidebar.dart';
import 'package:hollow/src/ui/shell/friends_bar.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';
import 'package:hollow/src/core/providers/app_lifecycle_provider.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/core/providers/shop_tab_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/ui/shell/archive_dashboard.dart';
import 'package:hollow/src/ui/shell/conference_dashboard.dart';
import 'package:hollow/src/ui/shop/shop_dashboard.dart';
import 'package:hollow/src/ui/share/share_dashboard.dart';
import 'package:hollow/src/ui/shell/home_dashboard.dart';
import 'package:hollow/src/core/providers/layout_prefs_provider.dart';
import 'package:hollow/src/ui/components/panel_resize_handle.dart';
import 'package:hollow/src/ui/shell/member_panel.dart';
import 'package:hollow/src/ui/shell/mobile_nav.dart';
import 'package:hollow/src/ui/mobile/mobile_shell.dart';
import 'package:hollow/src/ui/shell/server_strip.dart';
import 'package:hollow/src/core/providers/guest_provider.dart';
import 'package:hollow/src/ui/guest/public_channel_browser.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

const _kDesktopBreakpoint = 1024.0;
const _kTabletBreakpoint = 600.0;

/// Main application shell.
///
/// Desktop is ServerStrip | ChannelSidebar | ChatPane | MemberPanel, tablet
/// drops to a toggleable member panel, mobile to one tab view plus a nav bar.
class HollowShell extends ConsumerStatefulWidget {
  const HollowShell({super.key});

  @override
  ConsumerState<HollowShell> createState() => _HollowShellState();
}

class _HollowShellState extends ConsumerState<HollowShell>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  bool _initialized = false;

  // True while the identity unlocks and the DB loads. Argon2id is deliberately
  // slow (~1.5-3s on a phone, that is the at-rest protection), so the shell
  // shows a spinner rather than looking frozen. Only set under App Lock.
  bool _unlocking = false;

  // Master startup controller, shared down the tree by an InheritedWidget.
  late final AnimationController _revealController;
  bool _revealComplete = false;

  late final Animation<double> _chatReveal;

  late final Animation<double> _friendsBarReveal;
  late final Animation<double> _bottomBarReveal;
  late final Animation<double> _dockChatReveal;

  // The member panel auto-collapses below the desktop breakpoint, which a high
  // interface scale can cross on its own. `_memberPanelWasOpen` holds what the
  // user had before, so widening never forces open a panel they closed.
  bool? _wideEnoughForMembers;
  bool _memberPanelWasOpen = true;

  /// Collapses or restores the member panel as the shell crosses the
  /// breakpoint. Only ON A CROSSING, so it never fights the header toggle.
  void _syncMemberPanelToWidth(bool wideEnough) {
    if (_wideEnoughForMembers == wideEnough) return;
    _wideEnoughForMembers = wideEnough;
    // Provider writes never happen during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!wideEnough) {
        _memberPanelWasOpen = ref.read(memberPanelProvider);
        if (_memberPanelWasOpen) {
          ref.read(memberPanelProvider.notifier).state = false;
        }
      } else if (_memberPanelWasOpen && !ref.read(memberPanelProvider)) {
        ref.read(memberPanelProvider.notifier).state = true;
      }
    });
  }

  /// Subscribes the node to a channel's relay topic, without which the relay
  /// routes no topic message to this socket. Unread channels of the same server
  /// come along so @mentions still arrive. Idempotent.
  void _subscribeActiveChannel(String serverId, String channelId) {
    final unread = ref.read(unreadProvider);
    final prefix = '$serverId:';
    final unreadChannels = unread.channelUnreadCounts.entries
        .where((e) => e.key.startsWith(prefix) && e.value > 0)
        .map((e) => e.key.substring(prefix.length))
        .toList();
    final topics = <String>{channelId, ...unreadChannels}.toList();
    // Never throws and retries if the node is not running yet, which startup
    // auto-select can race.
    subscribeChannelTopics(serverId: serverId, channelIds: topics);
  }

  /// Wires the desktop OS-toast callbacks once at startup; the handlers reuse
  /// the same navigation the in-app notification card uses.
  void _registerDesktopNotificationHandlers() {
    if (!DesktopNotificationService.isSupported) return;

    DesktopNotificationService.registerOpenHandler((payload) async {
      // A toast can be tapped while we are in the background or the tray.
      await ref.read(systemNotificationProvider.notifier).bringWindowToFront();
      if (!mounted) return;
      if (payload.startsWith('channel:')) {
        final rest = payload.substring('channel:'.length);
        final sep = rest.indexOf(':');
        if (sep <= 0 || sep >= rest.length - 1) return;
        await _openChannelFromNotification(
            rest.substring(0, sep), rest.substring(sep + 1));
      } else {
        _openDmFromNotification(payload);
      }
    });

    DesktopNotificationService.registerReplyHandler((peerId, text) {
      // Inline Reply sends straight away, with no window focus needed.
      ref.read(chatProvider.notifier).sendMessage(peerId, text);
    });
  }

  void _openDmFromNotification(String peerId) {
    setShellTab(ref.read, null);
    ref.read(selectedPeerProvider.notifier).state = peerId;
    ref.read(selectedServerProvider.notifier).state = null;
    ref.read(channelListProvider.notifier).clear();
    ref.read(selectedChannelProvider.notifier).state = null;
    ref.read(serverSettingsOpenProvider.notifier).state = false;
    ref.read(unreadProvider.notifier).markDmSeen(peerId, null);
  }

  Future<void> _openChannelFromNotification(
      String serverId, String channelId) async {
    final channels = await ChannelListNotifier.fetchChannels(serverId);
    final layout = await ChannelLayoutNotifier.fetchLayout(serverId);
    if (!mounted) return;
    setShellTab(ref.read, null);
    ref.read(selectedPeerProvider.notifier).state = null;
    ref.read(serverSettingsOpenProvider.notifier).state = false;
    ref.read(channelListProvider.notifier).setChannels(channels);
    ref.read(channelLayoutProvider.notifier)
        .setLayout(layout, serverId: serverId);
    ref.read(selectedChannelProvider.notifier).state = channelId;
    ref.read(selectedServerProvider.notifier).state = serverId;
    final map =
        Map<String, String>.from(ref.read(lastChannelPerServerProvider));
    map[serverId] = channelId;
    ref.read(lastChannelPerServerProvider.notifier).state = map;
  }

  @override
  void initState() {
    super.initState();

    _revealController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );

    _chatReveal = CurvedAnimation(
      parent: _revealController,
      curve: const Interval(0.30, 0.70, curve: Curves.easeOutCubic),
    );

    _friendsBarReveal = CurvedAnimation(
      parent: _revealController,
      curve: const Interval(0.0, 0.25, curve: Curves.easeOutCubic),
    );
    _bottomBarReveal = CurvedAnimation(
      parent: _revealController,
      curve: const Interval(0.05, 0.30, curve: Curves.easeOutCubic),
    );
    _dockChatReveal = CurvedAnimation(
      parent: _revealController,
      curve: const Interval(0.20, 0.60, curve: Curves.easeOutCubic),
    );

    _revealController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() => _revealComplete = true);
      }
    });

    HardwareKeyboard.instance.addHandler(_handleGlobalKey);

    // Mobile lifecycle observer for WS reconnection on app resume.
    if (Platform.isAndroid || Platform.isIOS) {
      WidgetsBinding.instance.addObserver(this);
    }

    // After the first frame, so the window is visible before anything moves.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealController.forward();
      // A cold-start protocol launch buffers in the service until the shell is
      // mounted.
      DeepLinkService.instance.notifyShellReady();
    });
    _bootstrap();
    _listenForLicenseErrors();
    _listenForNicknameChanges();
    _listenForRecordingEvents();
  }

  void _listenForNicknameChanges() {
    ref.listenManual(localNicknameProvider, (_, next) {
      setLocalNicknamesRef(next);
    });
  }

  void _listenForRecordingEvents() {
    ref.listenManual<RecordingState>(recordingProvider, (prev, next) {
      if (!mounted) return;
      final profiles = ref.read(profileProvider);
      final prevSet = prev?.remoteRecorders ?? const <String>{};
      final added = next.remoteRecorders.difference(prevSet);
      final removed = prevSet.difference(next.remoteRecorders);
      for (final peerId in added) {
        final name = displayNameForPeer(profiles[peerId], peerId);
        HollowToast.show(
          context,
          '$name started recording the call',
          type: HollowToastType.info,
          duration: const Duration(seconds: 4),
        );
      }
      for (final peerId in removed) {
        final name = displayNameForPeer(profiles[peerId], peerId);
        HollowToast.show(
          context,
          '$name stopped recording',
          type: HollowToastType.info,
        );
      }
    });
  }

  void _listenForLicenseErrors() {
    ref.listenManual(licenseErrorProvider, (prev, next) {
      if (next != null && mounted) {
        _handleLicenseError(next);
      }
    });
  }

  Future<void> _handleLicenseError(String reason) async {
    ref.read(nodeProvider.notifier).stop();
    await ref.read(licenseKeyProvider.notifier).clearKey();
    ref.read(licenseErrorProvider.notifier).state = null;

    final friendlyMessage = switch (reason) {
      'invalid_license_key' => 'Invalid license key',
      'license_key_in_use' =>
        'This key is already in use on another device',
      'license_key_required' => 'A license key is required to connect',
      _ => 'License error: $reason',
    };

    if (!mounted) return;
    final newKey =
        await showLicenseKeyDialog(context, error: friendlyMessage);
    if (!mounted) return;
    if (newKey != null) {
      await ref.read(licenseKeyProvider.notifier).setKey(newKey);
      await network_api.setLicenseKey(key: newKey);
      await ref.read(nodeProvider.notifier).start();
    }
  }

  /// Unlocks the identity, showing a blocking dialog when one is needed.
  /// Returns false when the user cancelled.
  Future<bool> _unlockIdentity() async {
    try {
      // Without a password first: DPAPI, Keychain or plaintext.
      await identity_api.unlockIdentity();
      return true;
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('password') || msg.contains('Password')) {
        return _showPasswordUnlockDialog();
      }
      // A DPAPI or Keychain failure means a different machine.
      if (msg.contains('credentials') || msg.contains('device') || msg.contains('keychain')) {
        return _showDeviceBoundRecoveryDialog();
      }
      // Anything else (a corrupted file) falls back to recovery.
      if (mounted) {
        return _showDeviceBoundRecoveryDialog(
          errorMessage: 'Failed to unlock identity: $msg',
        );
      }
      return false;
    }
  }

  /// Full-screen blocking dialog for an identity copied to another machine. The
  /// 24-word mnemonic is the only way out.
  Future<bool> _showDeviceBoundRecoveryDialog({String? errorMessage}) async {
    final controller = TextEditingController();
    final result = await showHollowDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final hollow = HollowTheme.of(ctx);
        final screenWidth = MediaQuery.sizeOf(ctx).width;
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(HollowSpacing.lg),
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              width: (screenWidth - HollowSpacing.lg * 2).clamp(0.0, 420.0),
              padding: const EdgeInsets.all(HollowSpacing.xl),
              decoration: BoxDecoration(
                color: hollow.elevated,
                borderRadius: BorderRadius.circular(hollow.radiusLg),
                border: Border.all(color: hollow.error.withValues(alpha: 0.3)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(LucideIcons.shieldAlert, size: 20, color: hollow.error),
                      const SizedBox(width: HollowSpacing.sm),
                      Text('Identity Locked', style: HollowTypography.heading.copyWith(
                        color: hollow.textPrimary, fontSize: 16,
                      )),
                    ],
                  ),
                  const SizedBox(height: HollowSpacing.md),
                  Text(
                    errorMessage ?? 'This identity was bound to another device and cannot be used here. Enter your 24-word recovery phrase to unlock your identity on this device.',
                    style: HollowTypography.body.copyWith(
                      color: hollow.textSecondary, fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: HollowSpacing.lg),
                  HollowTextField(
                    controller: controller,
                    autofocus: true,
                    hintText: 'Enter 24-word recovery phrase',
                  ),
                  const SizedBox(height: HollowSpacing.lg),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      HollowButton.filled(
                        onPressed: () async {
                          final phrase = controller.text.trim();
                          final words = phrase.split(RegExp(r'\s+'));
                          if (words.length != 24) {
                            HollowToast.show(ctx, 'Must be exactly 24 words', type: HollowToastType.error);
                            return;
                          }
                          try {
                            await identity_api.restoreIdentityFromMnemonic(phrase: phrase);
                            await identity_api.unlockIdentity();
                            // Reset to plaintext, so the App Lock marker and
                            // biometric secret are stale.
                            await AppLockService().clearAll();
                            if (ctx.mounted) Navigator.of(ctx).pop(true);
                          } catch (e) {
                            if (ctx.mounted) {
                              HollowToast.show(ctx, 'Recovery failed: $e', type: HollowToastType.error);
                            }
                          }
                        },
                        child: const Text('Recover Identity'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          ),
        );
      },
    );
    return result == true;
  }

  Future<bool> _showPasswordUnlockDialog() async {
    final appLock = AppLockService();
    final lockType = await appLock.getLockType();
    final isPin = lockType == 'pin';
    final hasBiometric = await appLock.isBiometricEnabled();

    /// One biometric round: OS prompt → stored secret → Rust unlock.
    Future<bool> tryBiometric() async {
      final secret = await appLock.authenticateAndGetSecret();
      if (secret == null) return false;
      // The slow Argon2id derivation runs next and the OS sheet has dismissed,
      // so the spinner belongs here.
      if (mounted) setState(() => _unlocking = true);
      try {
        await identity_api.unlockIdentity(password: secret);
        appLock.sessionSecret = secret;
        return true;
      } catch (_) {
        if (mounted) setState(() => _unlocking = false);
        // A stale stored secret (changed via recovery) would leave the user in
        // a failing biometric loop.
        await appLock.disableBiometric();
        return false;
      }
    }

    // Most unlocks end right here.
    if (hasBiometric && await tryBiometric()) return true;
    if (!mounted) return false;

    final secretLabel = isPin ? 'PIN' : 'password';
    final controller = TextEditingController();
    var attempts = 0;
    while (true) {
      // Statement-level, not just the loop condition, so the gap after the
      // previous iteration's awaits is covered.
      if (!mounted) return false;
      final result = await showHollowDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          final hollow = HollowTheme.of(ctx);
          final screenWidth = MediaQuery.sizeOf(ctx).width;
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(HollowSpacing.lg),
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  width: (screenWidth - HollowSpacing.lg * 2).clamp(0.0, 380.0),
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
                      Row(
                        children: [
                          Icon(LucideIcons.lock, size: 20, color: hollow.accent),
                          const SizedBox(width: HollowSpacing.sm),
                          Text('Unlock Hollow', style: HollowTypography.heading.copyWith(
                            color: hollow.textPrimary, fontSize: 16,
                          )),
                        ],
                      ),
                      const SizedBox(height: HollowSpacing.sm),
                      Text(
                        'Enter your app $secretLabel to unlock your identity.',
                        style: HollowTypography.body.copyWith(
                          color: hollow.textSecondary, fontSize: 12,
                        ),
                      ),
                      if (attempts > 0) ...[
                        const SizedBox(height: HollowSpacing.xs),
                        Text(
                          'Wrong ${isPin ? 'PIN' : 'password'}. Try again.',
                          style: HollowTypography.body.copyWith(
                            color: hollow.error, fontSize: 12,
                          ),
                        ),
                      ],
                      const SizedBox(height: HollowSpacing.lg),
                      HollowTextField(
                        controller: controller,
                        obscureText: true,
                        autofocus: true,
                        hintText: isPin ? 'PIN' : 'Password',
                        keyboardType: isPin ? TextInputType.number : null,
                        onSubmitted: (val) {
                          if (val.isNotEmpty) Navigator.of(ctx).pop(val);
                        },
                      ),
                      const SizedBox(height: HollowSpacing.lg),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          HollowButton.ghost(
                            onPressed: () => Navigator.of(ctx).pop('__recover__'),
                            child: Text('Recover with phrase',
                              style: TextStyle(fontSize: 12, color: hollow.textSecondary),
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (hasBiometric) ...[
                                HollowPressable(
                                  semanticLabel: 'Unlock with biometrics',
                                  onTap: () =>
                                      Navigator.of(ctx).pop('__biometric__'),
                                  borderRadius:
                                      BorderRadius.circular(hollow.radiusSm),
                                  padding:
                                      const EdgeInsets.all(HollowSpacing.sm),
                                  child: Icon(LucideIcons.fingerprint,
                                      size: 18, color: hollow.accent),
                                ),
                                const SizedBox(width: HollowSpacing.xs),
                              ],
                              HollowButton.filled(
                                onPressed: () {
                                  final pass = controller.text.trim();
                                  if (pass.isNotEmpty) Navigator.of(ctx).pop(pass);
                                },
                                child: const Text('Unlock'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );

      if (result == null || !mounted) return false;

      if (result == '__recover__') {
        final recovered = await _recoverWithMnemonic();
        if (recovered) {
          // Reset to plaintext, so the lock state is stale.
          await AppLockService().clearAll();
          return true;
        }
        controller.clear();
        continue;
      }

      if (result == '__biometric__') {
        if (await tryBiometric()) return true;
        continue;
      }

      // Argon2id runs next, so the spinner covers it.
      if (mounted) setState(() => _unlocking = true);
      try {
        await identity_api.unlockIdentity(password: result);
        appLock.sessionSecret = result;
        return true;
      } catch (_) {
        // Wrong secret: let the dialog re-prompt.
        if (mounted) setState(() => _unlocking = false);
        attempts++;
        controller.clear();
        continue;
      }
    }
    return false;
  }

  Future<bool> _recoverWithMnemonic() async {
    final controller = TextEditingController();
    final result = await showHollowDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final hollow = HollowTheme.of(ctx);
        final screenWidth = MediaQuery.sizeOf(ctx).width;
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(HollowSpacing.lg),
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              width: (screenWidth - HollowSpacing.lg * 2).clamp(0.0, 420.0),
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
                  Text('Recover Identity', style: HollowTypography.heading.copyWith(
                    color: hollow.textPrimary, fontSize: 16,
                  )),
                  const SizedBox(height: HollowSpacing.sm),
                  Text(
                    'Enter your 24-word recovery phrase to reset your identity. This will remove the existing password.',
                    style: HollowTypography.body.copyWith(
                      color: hollow.textSecondary, fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: HollowSpacing.lg),
                  HollowTextField(
                    controller: controller,
                    autofocus: true,
                    hintText: 'Enter 24-word recovery phrase',
                  ),
                  const SizedBox(height: HollowSpacing.lg),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      HollowButton.ghost(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      HollowButton.filled(
                        onPressed: () async {
                          final phrase = controller.text.trim();
                          final words = phrase.split(RegExp(r'\s+'));
                          if (words.length != 24) {
                            HollowToast.show(ctx, 'Must be exactly 24 words', type: HollowToastType.error);
                            return;
                          }
                          try {
                            await identity_api.restoreIdentityFromMnemonic(phrase: phrase);
                            await identity_api.unlockIdentity();
                            if (ctx.mounted) Navigator.of(ctx).pop(true);
                          } catch (e) {
                            if (ctx.mounted) {
                              HollowToast.show(ctx, 'Recovery failed: $e', type: HollowToastType.error);
                            }
                          }
                        },
                        child: const Text('Recover'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          ),
        );
      },
    );
    return result == true;
  }

  Future<void> _bootstrap() async {
    if (_initialized) return;
    _initialized = true;

    // Backing out of "Link a device" leaves a throwaway identity. Wipe the data
    // dir HERE, before the node starts and before the pending link import: with
    // SQLCipher handles open, Windows keeps messages.db and the next identity
    // loads forever.
    try {
      if (await storage_api.hasPendingWipe()) {
        await storage_api.performPendingWipe();
      }
    } catch (e) {
      debugPrint('[HOLLOW] Pending data-dir wipe failed: $e');
    }

    // A link transfer stashed an encrypted .hollow blob. Import it FIRST, in the
    // same pre-node-start window a manual restore uses, then fall through as a
    // normal restored launch.
    try {
      if (await storage_api.hasPendingLink()) {
        await storage_api.importPendingLink();
      }
    } catch (e) {
      debugPrint('[HOLLOW] Pending link import failed: $e');
    }

    final hasExisting = await storage_api.hasIdentity();

    WelcomeResult? welcomeResult;
    if (!hasExisting && mounted) {
      welcomeResult = await showWelcomeDialog(context);
      if (!mounted) return;

      // 'restored_mnemonic' and 'restored_backup' leave an identity on disk;
      // 'create_new' and null fall through to a normal load, which generates.
    }

    if (hasExisting && mounted) {
      final unlocked = await _unlockIdentity();
      if (!unlocked || !mounted) return;
    } else {
      // New or just restored: no password to ask for.
      try {
        await identity_api.unlockIdentity();
      } catch (_) {
        // First launch: load() creates the identity.
      }
    }

    await ref.read(identityProvider.notifier).load();

    final identity = ref.read(identityProvider);
    if (identity.error != null) {
      if (_unlocking && mounted) setState(() => _unlocking = false);
      return;
    }

    // Must follow the identity load, which opens the DB. Building the provider
    // self-applies the persisted mode to ReduceMotionController, refining the OS
    // flag main() seeded.
    try {
      await ref.read(reduceMotionProvider.future);
      if (ReduceMotionController.instance.isReduced) {
        if (!_revealController.isCompleted) {
          _revealController.value = 1.0;
        }
      }
    } catch (_) {}

    // Engine create is a one-time per-process cost: instant for RNNoise, but
    // DFN3's model load measured 15 SECONDS on a Pixel, and kicked at first call
    // it eats the start of the call with undenoised frames.
    try {
      final aiNs = await ref.read(noiseSuppressAiProvider.future);
      if (aiNs) {
        final engine = noiseSuppressEngineToNative(
            await ref.read(noiseSuppressEngineProvider.future));
        unawaited(Helper.setNoiseSuppressAi(true, engine: engine)
            .catchError((_) {}));
      }
    } catch (_) {}

    // 'link_device' creates a THROWAWAY identity that the snapshot pull
    // replaces, so there is no mnemonic worth backing up.
    final isLinkDevice = welcomeResult?.action == 'link_device';

    // Node startup and relay connect take a few seconds, and without this the
    // welcome dialog just vanishes until the link prompt appears.
    if (isLinkDevice && mounted) {
      showConnectingDialog(context, message: 'Connecting to link your device…');
    }

    if (identity.mnemonic != null && mounted && !isLinkDevice) {
      await storage_api.saveMnemonic(mnemonic: identity.mnemonic!);
      if (!mounted) return;
      showMnemonicDialog(context, identity.mnemonic!);
    }

    await ref.read(relayDomainProvider.notifier).loadCached();
    await ref.read(savedRelayListProvider.notifier).loadCached();
    if (welcomeResult != null && welcomeResult.relayDomain != kDefaultRelayDomain) {
      await ref.read(relayDomainProvider.notifier).setDomain(welcomeResult.relayDomain);
      await ref.read(savedRelayListProvider.notifier).addRelay(welcomeResult.relayDomain);
    }
    final relayDomain = ref.read(relayDomainProvider);
    await network_api.setRelayUrl(domain: relayDomain);
    await ref.read(licenseKeyProvider.notifier).loadCached();

    // Pushed explicitly, like the relay URL: the Rust-side gate defaults
    // permissive until this lands (issue #41).
    await pushAutoDownloadConfig(
      thresholdMb: await ref
          .read(autoDownloadThresholdProvider.future)
          .catchError((_) => 169),
      overrides: await ref
          .read(autoDownloadOverridesProvider.future)
          .catchError((_) => const <String, bool>{}),
    );

    // GIF source settings, pushed explicitly for the same reason: proxy
    // override, the user's own key, its allowlist and the content rating.
    await ref.read(gifProxyUrlProvider.notifier).loadCached();
    await ref.read(gifApiKeyProvider.notifier).loadCached();
    await ref.read(gifMediaHostsProvider.notifier).loadCached();
    await ref.read(gifRatingProvider.notifier).loadCached();
    await ref.read(gifAutoplayProvider.notifier).loadCached();
    // Link previews (issue #45), pushed here rather than read lazily so the
    // first URL typed already honours them.
    await ref.read(linkPreviewsEnabledProvider.notifier).loadCached();
    await ref.read(embedProxyUrlProvider.notifier).loadCached();
    // AFTER the source settings: saved GIFs store proxy-RELATIVE paths and
    // resolve against whatever source is active.
    await ref.read(gifLibraryProvider.notifier).loadCached();
    // No source coupling: a sticker's bytes are already a local
    // content-addressed blob, so there is no proxy base to resolve against.
    await ref.read(stickerRecentsProvider.notifier).loadCached();
    await ref.read(stickerLastTabProvider.notifier).loadCached();
    await ref.read(stickerPacksProvider.notifier).loadCached();
    // Warmed late so the GIF picker opens without a spinner.
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) {
        ref.read(gifCatalogProvider).prefetchTrending(ref.read(gifRatingProvider));
      }
    });

    // Anti-censorship proxy: force the (lazy) proxy-config provider to build so
    // its `_push` seeds the Rust global BEFORE start_node() (line ~903) reads it.
    // Without this the provider only builds when the Settings dialog is opened,
    // so the tunnel silently never launches on a normal launch — the node
    // connects directly (which is exactly what we're trying to avoid). Mirrors
    // how setRelayUrl is pushed explicitly here rather than relied on lazily.
    await ref.read(proxyConfigProvider.future);

    // LOCAL-FIRST RENDER: everything the conversation and server lists need is
    // a pure SQLCipher read, so it all loads before the network phase and the
    // shell shows real content instead of "connecting" behind a 5s HTTP call.

    // Before unread, which is computed from it.
    await ref.read(serverListProvider.notifier).loadFromDb();

    // Before the node starts, so sync events do not race loadAll.
    try {
      final servers = ref.read(serverListProvider);
      final serverChannels = <String, List<String>>{};
      for (final sid in servers.keys) {
        final channels = await crdt_api.getServerChannels(serverId: sid);
        serverChannels[sid] = channels.map((c) => c.channelId).toList();
      }
      final dmPeerIds = await storage_api.getDmPeerIds();
      // Before unread, which depends on the notification levels.
      await ref.read(notificationSettingsProvider.notifier)
          .loadAll(servers.keys.toList(), serverChannels, dmPeerIds);
      await ref.read(unreadProvider.notifier).loadAll(serverChannels, dmPeerIds);
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load unread state: $e');
    }

    // The DM list's source, and a pure local read, so it precedes the network.
    await ref.read(profileProvider.notifier).loadAll();
    await ref.read(friendsProvider.notifier).loadAll();

    // Pure DB reads: behind fetchRelayStatus a slow relay means seconds of the
    // wrong theme on a fully local render.
    await ref.read(themeModeProvider.notifier).load();
    await ref.read(accentHueProvider.notifier).load();
    // Dock vs Classic shell (#58): read from a provider's build() this races the
    // store open, and Classic never survives a restart.
    await ref.read(layoutModeProvider.notifier).load();
    // Whether the shop has been woken up here. The dock bar watches the gate on
    // the first frame, so it loads here, never in build().
    await ref.read(shopUnlockedProvider.notifier).load();
    // Display size (issue #20): loadSetting throws until the store is open.
    await ref.read(uiScaleProvider.notifier).load();
    await ref.read(chatTextScaleProvider.notifier).load();
    // Panel widths, panel zoom, profile-card style and the folded member-list
    // sections (issue #54): all watched by the first frame.
    await loadLayoutPrefs(ref);
    await ref.read(backgroundProvider.notifier).load();
    await ref.read(accentPresetsProvider.notifier).load();
    // UI sound pack (#55): the notifiers mirror their value into SoundService's
    // statics, because the sounds fire from notifiers with no `ref` of their own.
    await ref.read(soundEffectsEnabledProvider.notifier).load();
    await ref.read(soundEffectsVolumeProvider.notifier).load();
    // Building the provider is what publishes the volume to SoundService, so
    // without this the first outgoing call of a session rings at the default.
    try {
      await ref.read(ringtoneVolumeProvider.future);
    } catch (e) {
      debugPrint('[HOLLOW] ringtone volume preload failed: $e');
    }
    await ref.read(localNicknameProvider.notifier).loadAll();
    setLocalNicknamesRef(ref.read(localNicknameProvider));
    await ref.read(serverStripLayoutProvider.notifier).loadLayout();
    // Must be known BEFORE the node starts: the first TURN credentials land
    // moments after and IceConfigNotifier composes the ICE map from this flag,
    // so loading it later leaves a window with direct candidates.
    await ref.read(alwaysRelayCallsProvider.notifier).load();
    // Peer media forwarding, on the same timing and pushed into the node right
    // after it starts.
    await ref.read(peerForwardingProvider.notifier).load();

    // The lists are populated from the local DB, so the network phase can run
    // behind an already-visible shell.
    if (_unlocking && mounted) setState(() => _unlocking = false);

    final earlyAcceptedPeerIds = ref
        .read(friendsProvider)
        .values
        .where((f) => f.status == 'accepted')
        .map((f) => f.peerId)
        .toList();
    if (earlyAcceptedPeerIds.isNotEmpty) {
      ref.read(chatProvider.notifier).loadLastMessagePreviews(earlyAcceptedPeerIds);
    }

    // NETWORK PHASE, once the local UI is populated. This is the blocking 5s
    // HTTP call, and it is non-fatal: fetchRelayStatus swallows errors and
    // answers license-not-required.
    final relayStatus = await fetchRelayStatus(domain: relayDomain);
    if (relayStatus.licenseRequired) {
      var cachedKey = ref.read(licenseKeyProvider);
      if (cachedKey == null && mounted) {
        final enteredKey = await showLicenseKeyDialog(context);
        if (!mounted) return;
        if (enteredKey != null) {
          await ref.read(licenseKeyProvider.notifier).setKey(enteredKey);
          cachedKey = enteredKey;
        } else {
          return;
        }
      }
      if (cachedKey != null) {
        await network_api.setLicenseKey(key: cachedKey);
      }
    }

    await ref.read(nodeProvider.notifier).start();

    // The node starts with forwarding OFF, so the loaded setting is mirrored in.
    ref.read(peerForwardingProvider.notifier).pushToNode();

    // Rust already loaded this at node startup; this is only for the Dart UI's
    // toggle.
    ref.read(invisibleModeProvider.notifier).load();

    // AFTER the node starts, which is what restores the in-memory entries and
    // rejoins their rooms; the strip watches this map on the first frame (#58).
    await ref.read(pendingJoinsProvider.notifier).load();

    // The relay's availability registry is RAM-only, so this re-registers on
    // every start. Retention loads FIRST, or the enable re-apply reads the wrong
    // window.
    ref.read(offlineInboxRetentionProvider.notifier).load().then((_) {
      ref.read(offlineInboxProvider.notifier).load();
    }).catchError((_) {});

    // A credential verifies for its 90-day window and the one after, so there is
    // a whole window in which to renew it silently from the persisted refresh
    // token. Fire-and-forget needs the explicit catchError
    // (`feedback_ffi_fire_and_forget_catcherror`).
    twitch_api.twitchMaintainOwnerCredential().then((minted) {
      if (minted) ref.read(profileProvider.notifier).loadAll();
    }).catchError((e) {
      debugPrint('[HOLLOW] Twitch re-verify skipped: $e');
    });

    // One-shot: move animated avatars authored before the asset-rail split off
    // the pushed profile blob. An un-awaited FFI rejection reaches the zone
    // crash handler, and a migration that cannot run is not worth a crash.
    network_api.migrateProfileMediaOnce().then((moved) {
      if (moved) ref.read(profileProvider.notifier).loadAll();
    }).catchError((e) {
      debugPrint('[HOLLOW] Profile media migration skipped: $e');
      return false;
    });

    final serverIds = ref.read(serverListProvider).keys.toList();
    ref.read(serverAvatarProvider.notifier).loadAll(serverIds);
    ref.read(serverAvatarAnimProvider.notifier).loadAll(serverIds);
    ref.read(serverBannerProvider.notifier).loadAll(serverIds);

    // So hollow://share cards in chat show the right state.
    ref.read(shareTabProvider.notifier).loadAll();

    await ref.read(favouriteFriendsProvider.notifier).load();

    await ref.read(hiddenArchiveDmsProvider.notifier).load();

    // Master-keyed, mirroring Rust's ingest guard set, so the Block UI and
    // channel hiding are correct at boot.
    await ref.read(blockedUsersProvider.notifier).load();

    await ref.read(verifiedPeersProvider.notifier).load();

    // Loaded, not only streamed: an alert raised while the app was closed has to
    // be waiting in the conversation on the next launch, or it is missable.
    await ref.read(securityAlertsProvider.notifier).load();

    // After the DB is open, or the dismissed banner re-appears on every restart.
    await ref.read(statusProvider.notifier).loadDismissed();

    await ref.read(systemNotificationProvider.notifier).init();
    _registerDesktopNotificationHandlers();

    // The node is connected on a throwaway identity, so the enter-code flow can
    // pull the real data; a successful import replaces identity and DB.
    if (isLinkDevice && mounted) {
      dismissConnectingDialog();
      final wentBack = await showDeviceLinkDialog(context, mode: DeviceLinkMode.enterCode);
      // Back means "go back to Welcome", and the running node still holds the DB
      // handle, so the throwaway identity is discarded by RELAUNCHING rather than
      // by re-showing Welcome in place.
      //
      // The wipe is MARKED, not done now: with SQLCipher handles open, deleting
      // messages.db fails silently on Windows and it survives encrypted with the
      // throwaway passphrase, so the next identity loads forever. The next
      // launch's _bootstrap wipes before the node starts.
      if (wentBack == true) {
        await storage_api.stashPendingWipe();
        try {
          await network_api.notifyShutdown();
          await Future.delayed(const Duration(milliseconds: 200));
        } catch (_) {}
        try {
          if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
            await Process.start(Platform.resolvedExecutable, const [],
                mode: ProcessStartMode.detached);
            await Future.delayed(const Duration(milliseconds: 100));
          }
        } catch (_) {}
        exit(0);
      }
    }

    // The WiFi lock is what stops Android throttling the socket.
    if (Platform.isAndroid) {
      await acquireWifiLock();
      // Primed so the screen-share sheet can lock the audio toggle on
      // Android < 10 without a first-frame flash.
      await AndroidScreenAudioSupport.prime();
      final optimized = await isBatteryOptimized();
      if (optimized && mounted) {
        await requestBatteryExemption();
      }
    }
  }

  @override
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    // Event routing picks an OS notification or an in-app banner from this, so
    // it is set BEFORE the _initialized guard and is always current.
    ref.read(appLifecycleProvider.notifier).state = state;
    if (!_initialized) return;
    if (state == AppLifecycleState.resumed) {
      debugPrint('[HOLLOW] App resumed — rejoining rooms + WiFi lock');
      acquireWifiLock();
      _rejoinRoomsOnResume();
      _updateIosPushHeartbeat(active: true);
    } else if (state == AppLifecycleState.paused) {
      debugPrint('[HOLLOW] App paused — releasing WiFi lock');
      releaseWifiLock();
      // A live node only receives while resumed, so the NSE has to run its own
      // fetch while we are gone.
      _updateIosPushHeartbeat(active: false);
    }
  }

  /// iOS push heartbeat: the NSE skips its own fetch while the app has reported
  /// itself active recently, because the live node already has the message. The
  /// file lives in the App Group container, the PARENT of the data dir.
  void _updateIosPushHeartbeat({required bool active}) {
    if (!Platform.isIOS) return;
    final dataDir = hollowDataDir; // <AppGroupContainer>/hollow_data
    final container = Directory(dataDir).parent.path;
    if (active) {
      IosDataDirMigration.touchHeartbeat(container);
    } else {
      IosDataDirMigration.clearHeartbeat(container);
    }
  }

  void _rejoinRoomsOnResume() {
    final servers = ref.read(serverListProvider);
    final peerId = ref.read(identityProvider).peerId;
    if (peerId == null) return;
    // .catchError, not try/catch: an async rejection ("Node is not running" when
    // a resume fires during startup) escapes a sync try/catch. The node's own
    // start path joins rooms, so a swallowed early failure self-heals.
    network_api.joinRoom(roomCode: peerId).catchError((_) {});
    for (final serverId in servers.keys) {
      network_api.joinRoom(roomCode: serverId).catchError((_) {});
    }
  }

  @override
  void dispose() {
    if (Platform.isAndroid || Platform.isIOS) {
      WidgetsBinding.instance.removeObserver(this);
    }
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    _revealController.dispose();
    super.dispose();
  }

  /// Global keyboard shortcut handler, on HardwareKeyboard so it works whatever
  /// has focus. Bindings come from [appShortcutsProvider], and `matchesEvent`
  /// carries the AltGr guard: a held Alt is the user typing a layout character
  /// (AZERTY @ is AltGr+à, issue #43), never a shortcut.
  bool _handleGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    // A keybind capture field is armed: the user is TYPING a binding, and acting
    // here would fire the shortcut being rebound.
    if (ref.read(keybindCaptureActiveProvider)) return false;

    final hk = HardwareKeyboard.instance;
    final binds =
        ref.read(appShortcutsProvider).valueOrNull ?? kAppShortcutDefaults;
    bool match(AppShortcut s) => binds[s]!.matchesEvent(event, hk);

    if (match(AppShortcut.openSettings)) {
      showUserSettingsDialog(context);
      return true;
    }

    if (match(AppShortcut.toggleMemberPanel)) {
      final current = ref.read(memberPanelProvider);
      ref.read(memberPanelProvider.notifier).state = !current;
      return true;
    }

    if (match(AppShortcut.quickSearch)) {
      final current = ref.read(chatSearchOpenProvider);
      ref.read(chatSearchOpenProvider.notifier).state = !current;
      return true;
    }

    // Interface zoom (issue #20). The DEFAULT bindings keep their aliases: "+"
    // is Shift+= on most layouts and the numpad variants count. A custom binding
    // matches exactly.
    if (_matchZoom(event, hk, binds[AppShortcut.zoomIn]!, AppShortcut.zoomIn,
        const [LogicalKeyboardKey.equal, LogicalKeyboardKey.add,
            LogicalKeyboardKey.numpadAdd],
        shiftTolerant: true)) {
      ref.read(uiScaleProvider.notifier).nudge(1);
      return true;
    }
    if (_matchZoom(event, hk, binds[AppShortcut.zoomOut]!, AppShortcut.zoomOut,
        const [LogicalKeyboardKey.minus, LogicalKeyboardKey.numpadSubtract],
        shiftTolerant: true)) {
      ref.read(uiScaleProvider.notifier).nudge(-1);
      return true;
    }
    if (_matchZoom(event, hk, binds[AppShortcut.zoomReset]!,
        AppShortcut.zoomReset,
        const [LogicalKeyboardKey.digit0, LogicalKeyboardKey.numpad0])) {
      ref.read(uiScaleProvider.notifier).reset();
      return true;
    }

    if (match(AppShortcut.toggleSplitView)) {
      if (ref.read(layoutModeProvider) == LayoutMode.dock) {
        final split = ref.read(splitViewProvider);
        if (split.isSplit) {
          ref.read(splitViewProvider.notifier).closeSplit();
        } else {
          ref.read(splitViewProvider.notifier).openSplit();
        }
        return true;
      }
    }

    if (match(AppShortcut.focusLeftPane)) {
      final split = ref.read(splitViewProvider);
      if (split.isSplit) {
        ref.read(splitViewProvider.notifier).setFocus(0);
        return true;
      }
    }

    if (match(AppShortcut.focusRightPane)) {
      final split = ref.read(splitViewProvider);
      if (split.isSplit) {
        ref.read(splitViewProvider.notifier).setFocus(1);
        return true;
      }
    }

    return false;
  }

  /// Zoom keeps its aliases while on the default binding: every key in
  /// [aliasKeys] triggers, and [shiftTolerant] ignores shift (Ctrl+Shift+= IS
  /// Ctrl++). A custom binding goes through [HotkeyBinding.matchesEvent].
  bool _matchZoom(KeyEvent event, HardwareKeyboard hk, HotkeyBinding binding,
      AppShortcut shortcut, List<LogicalKeyboardKey> aliasKeys,
      {bool shiftTolerant = false}) {
    if (binding != shortcut.defaultBinding) {
      return binding.matchesEvent(event, hk);
    }
    final isCtrl = hk.isControlPressed && !hk.isAltPressed; // AltGr guard
    if (!isCtrl) return false;
    if (!shiftTolerant && hk.isShiftPressed) return false;
    return aliasKeys.contains(event.logicalKey);
  }

  ChatMessage? _lastMessage(
      String peerId, Map<String, ChatMessage> lastMessages) {
    return lastMessages[peerId];
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day}';
  }

  Widget _buildChannelSidebar({
    required Map<String, dynamic> peers,
    required Map<String, ChatMessage> lastMessages,
    required String? selectedPeerId,
    required NodeStatus nodeStatus,
    required ServerInfo? selectedServer,
    required Map<String, ChannelInfo> channels,
    required String? selectedChannelId,
    required String channelLayoutJson,
    double? width,
    bool dockMode = false,
  }) {
    return ChannelSidebar(
      // A _ChannelSidebarSeam always follows this one and paints the divider.
      edgeBorder: false,
      peers: Map.from(peers),
      lastMessages: lastMessages,
      selectedPeerId: selectedPeerId,
      nodeStatus: nodeStatus,
      // The user's dragged width (issue #54) unless a caller overrides it.
      width: width ?? ref.watch(channelSidebarWidthProvider),
      dockMode: dockMode,
      showUserBar: !dockMode,
      onPeerSelected: (peerId) {
        setShellTab(ref.read, null);
        ref.read(selectedPeerProvider.notifier).state = peerId;
        final lastMsg = ref.read(lastDmMessageProvider)[peerId];
        ref.read(unreadProvider.notifier).markDmSeen(peerId, lastMsg?.messageId);
        ref.read(mobileTabProvider.notifier).state = 1;
      },
      lastMessage: (peerId) => _lastMessage(peerId, lastMessages),
      formatTime: _formatTime,
      selectedServer: selectedServer,
      channels: channels,
      selectedChannelId: selectedChannelId,
      onChannelSelected: (channelId) {
        ref.read(selectedChannelProvider.notifier).state = channelId;
        final serverId = ref.read(selectedServerProvider);
        if (serverId != null) {
          final map = Map<String, String>.from(
              ref.read(lastChannelPerServerProvider));
          map[serverId] = channelId;
          ref.read(lastChannelPerServerProvider.notifier).state = map;
          final chState = ref.read(channelChatProvider);
          final msgs = chState['$serverId:$channelId'];
          final latestId = msgs != null && msgs.isNotEmpty
              ? msgs.last.messageId
              : null;
          ref.read(unreadProvider.notifier)
              .markChannelSeen(serverId, channelId, latestId);
          _subscribeActiveChannel(serverId, channelId);
        }
        ref.read(mobileTabProvider.notifier).state = 1;
      },
      onCreateChannel: () {
        if (selectedServer != null) {
          showCreateChannelDialog(context, selectedServer.serverId);
        }
      },
      onOpenSettings: () {
        final split = ref.read(splitViewProvider);
        if (split.isSplit && selectedServer != null) {
          _showServerSettingsDialog(context, selectedServer);
        } else {
          ref.read(serverSettingsOpenProvider.notifier).state =
              !ref.read(serverSettingsOpenProvider);
        }
      },
      canManageChannels: selectedServer != null &&
          (ref.watch(myPermissionsProvider(selectedServer.serverId)).whenOrNull(
              data: (perms) => (perms & Permission.manageChannels) != 0) ?? false),
      channelLayoutJson: channelLayoutJson,
    );
  }

  /// Classic's resting state: nothing selected in the left panels, so the
  /// centre pane stays empty.
  Widget _buildEmptyChat(HollowTheme hollow) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.messageSquare,
            size: 64,
            color: hollow.textSecondary.withValues(alpha: 0.3),
          ),
          const SizedBox(height: HollowSpacing.lg),
          Text(
            'Select a peer to start chatting',
            style: HollowTypography.body.copyWith(
              color: hollow.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelPlaceholder(HollowTheme hollow, ChannelInfo? channel) {
    return Column(
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm),
          decoration: BoxDecoration(
            color: hollow.surface,
            border: Border(bottom: BorderSide(color: hollow.border)),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.hash, size: 20, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              // Larger Text: the name yields to the trailing action and
              // ellipsizes rather than pushing it off.
              Expanded(
                child: Text(
                  channel?.name ?? 'Unknown Channel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HollowTypography.subheading.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowTooltip(
                message: 'Toggle member panel',
                child: HollowPressable(
                  semanticLabel: 'Toggle member panel',
                  onTap: () => ref
                      .read(memberPanelProvider.notifier)
                      .state = !ref.read(memberPanelProvider),
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Icon(LucideIcons.users,
                      size: 20, color: hollow.textSecondary),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.hash,
                    size: 64,
                    color: hollow.textSecondary.withValues(alpha: 0.3)),
                const SizedBox(height: HollowSpacing.lg),
                Text(
                  'Welcome to #${channel?.name ?? "general"}',
                  style: HollowTypography.heading
                      .copyWith(color: hollow.textPrimary),
                ),
                const SizedBox(height: HollowSpacing.sm),
                Text(
                  'Channel messages coming soon.',
                  style: HollowTypography.body
                      .copyWith(color: hollow.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChatOrEmpty({
    required HollowTheme hollow,
    required String? selectedPeerId,
    required Map<String, dynamic> peers,
    required String? selectedChannelId,
    required Map<String, ChannelInfo> channels,
  }) {
    final guestOpen = ref.watch(guestTabOpenProvider);
    if (guestOpen) {
      return const PublicChannelBrowser();
    }

    final shareOpen = ref.watch(shareTabOpenProvider);
    if (shareOpen) {
      return const ShareDashboard();
    }

    final archiveOpen = ref.watch(archiveTabOpenProvider);
    if (archiveOpen) {
      return const ArchiveDashboard();
    }

    final conferenceOpen = ref.watch(conferenceTabOpenProvider);
    if (conferenceOpen) {
      return const ConferenceDashboard();
    }

    if (ref.watch(shopTabOpenProvider)) {
      return const ShopDashboard();
    }

    if (selectedChannelId != null) {
      final channel = channels[selectedChannelId];
      final serverId = ref.read(selectedServerProvider);
      if (serverId != null && channel != null) {
        // Voice channels get a dedicated pane with lounge + screen sharing.
        if (channel.channelType == ChannelType.voice) {
          return VoiceChannelPane(
            key: ValueKey('vc:$selectedChannelId'),
            serverId: serverId,
            channelId: selectedChannelId,
            channelName: channel.name,
          );
        }
        return ChannelChatPane(
          key: ValueKey('ch:$selectedChannelId'),
          serverId: serverId,
          channelId: selectedChannelId,
          channelName: channel.name,
        );
      }
      return _buildChannelPlaceholder(hollow, channel);
    }
    // The Home dashboard is a DOCK surface and stays one: Classic's centre pane
    // only ever shows what the left panels select, so putting the dock's Home
    // tab there makes the two layouts bleed into each other (#58).
    if (selectedPeerId == null) {
      return ref.watch(layoutModeProvider) == LayoutMode.dock
          ? const HomeDashboard()
          : _buildEmptyChat(hollow);
    }
    return ChatPane(
      key: ValueKey(selectedPeerId),
      peerId: selectedPeerId,
    );
  }

  /// Wraps the chat pane with a fade for the startup reveal. The FadeTransition
  /// stays in the tree so the child's State survives the reveal completing,
  /// which would otherwise reset the ambient blob positions.
  Widget _chatRevealWrap(Widget child) {
    return FadeTransition(
      opacity: _chatReveal,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Desktop only: the controller self-activates in a call and idles otherwise
    // (issue #38).
    if (!Platform.isAndroid && !Platform.isIOS) {
      ref.watch(hotkeyControllerProvider);
    }

    // Annotation mode hides the shell so the apps underneath show through the
    // transparent window; the drawing surface is an OverlayEntry in the root
    // Navigator and stays above this empty route.
    if (ref.watch(annotationModeProvider)) {
      return const SizedBox.shrink();
    }

    // Pops the confirm flow globally, unless a link dialog is already showing:
    // that one re-renders into the confirm view, while a second dialog would
    // re-run initState and mint a fresh code.
    ref.listen<DeviceLinkState>(deviceLinkSyncProvider, (prev, next) {
      if (next.phase == LinkPhase.confirmPush &&
          prev?.phase != LinkPhase.confirmPush &&
          !deviceLinkDialogIsOpen &&
          mounted) {
        showDeviceLinkDialog(context, mode: DeviceLinkMode.showCode);
      }
    });

    // On every change, NOT only an explicit sidebar click: a server's first
    // channel is auto-selected, and without a subscription live MLS
    // topic-broadcasts never arrive until the next sync request.
    ref.listen<String?>(selectedChannelProvider, (prev, next) {
      if (next == null || next == prev) return;
      // The selection batch writes selectedChannel BEFORE selectedServer and
      // this fires on the channel write, so reading the server now returns the
      // OLD one and subscribes the new channel under the WRONG relay room. One
      // microtask lets the batch settle.
      Future.microtask(() {
        if (!mounted) return;
        final serverId = ref.read(selectedServerProvider);
        final channelId = ref.read(selectedChannelProvider);
        if (serverId != null && channelId != null) {
          _subscribeActiveChannel(serverId, channelId);
        }
      });
    });

    // The channel being viewed can stop being visible in real time (tier raised,
    // or a demotion); the CRDT already propagated, so this only moves the UI to
    // the next visible text channel, else to the server's home.
    ref.listen<Map<String, ChannelInfo>>(visibleChannelsProvider, (prev, next) {
      final selectedChannel = ref.read(selectedChannelProvider);
      final serverId = ref.read(selectedServerProvider);
      if (selectedChannel == null || serverId == null) return;
      // Do not yank the user out of the settings panel; it owns its own state.
      if (ref.read(serverSettingsOpenProvider)) return;
      if (next.containsKey(selectedChannel)) return;
      final layout = ref.read(channelLayoutProvider);
      final fallback = firstTextChannelInLayout(next, layout);
      ref.read(selectedChannelProvider.notifier).state = fallback;
      if (fallback != null) {
        final map = Map<String, String>.from(
            ref.read(lastChannelPerServerProvider));
        map[serverId] = fallback;
        ref.read(lastChannelPerServerProvider.notifier).state = map;
      }
    });

    final hollow = HollowTheme.of(context);

    final nodeState = ref.watch(nodeProvider);
    final peers = ref.watch(peersProvider);
    final selectedPeerId = ref.watch(selectedPeerProvider);
    final lastMessages = ref.watch(lastDmMessageProvider);

    final memberPanelOpen = ref.watch(memberPanelProvider);
    final helpPanelOpen = ref.watch(helpPanelOpenProvider);

    final servers = ref.watch(serverListProvider);
    final selectedServerId = ref.watch(selectedServerProvider);
    final channels = ref.watch(visibleChannelsProvider);
    final selectedChannelId = ref.watch(selectedChannelProvider);
    final selectedServer =
        selectedServerId != null ? servers[selectedServerId] : null;
    final channelLayout = ref.watch(channelLayoutProvider);
    final settingsOpen = ref.watch(serverSettingsOpenProvider);

    final layoutMode = ref.watch(layoutModeProvider);

    final shellBody = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isDesktop = width >= _kDesktopBreakpoint;
        // Android and iOS ALWAYS get the mobile shell: a tablet or a landscape
        // phone crosses the breakpoint and would fall into the desktop layout.
        final isMobile = width < _kTabletBreakpoint ||
            Platform.isAndroid ||
            Platform.isIOS;

        if (isMobile) {
          return const MobileShell();
        }

        _syncMemberPanelToWidth(isDesktop);

        final isDesktopPlatform =
            Platform.isWindows || Platform.isLinux || Platform.isMacOS;

        Widget body;

        if (layoutMode == LayoutMode.dock) {
          body = _buildDockLayout(
            hollow: hollow,
            isDesktopPlatform: isDesktopPlatform,
            isDesktop: isDesktop,
            peers: peers,
            lastMessages: lastMessages,
            selectedPeerId: selectedPeerId,
            nodeStatus: nodeState.status,
            selectedServer: selectedServer,
            selectedServerId: selectedServerId,
            channels: channels,
            selectedChannelId: selectedChannelId,
            channelLayout: channelLayout,
            settingsOpen: settingsOpen,
            memberPanelOpen: memberPanelOpen,
            helpPanelOpen: helpPanelOpen,
          );
        } else {
          body = _buildClassicLayout(
            hollow: hollow,
            isDesktopPlatform: isDesktopPlatform,
            isDesktop: isDesktop,
            peers: peers,
            lastMessages: lastMessages,
            selectedPeerId: selectedPeerId,
            nodeStatus: nodeState.status,
            selectedServer: selectedServer,
            selectedServerId: selectedServerId,
            channels: channels,
            selectedChannelId: selectedChannelId,
            channelLayout: channelLayout,
            settingsOpen: settingsOpen,
            memberPanelOpen: memberPanelOpen,
            helpPanelOpen: helpPanelOpen,
          );
        }

        // setAsFrameless() removed the edge and corner resize handles; this
        // puts them back.
        if (isDesktopPlatform) {
          body = DragToResizeArea(child: body);
        }

        // Tab order follows the visual layout without any manual ordering
        // (a11y 2.6); dialogs pushed above this trap their own focus.
        body = FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: body,
        );

        return _ShellScaffold(body: body);
      },
    );

    // Without the spinner the shell looks frozen through the Argon2id wait.
    if (!_unlocking) return shellBody;
    return Stack(
      children: [shellBody, _UnlockingOverlay(hollow: hollow)],
    );
  }

  /// Classic layout: ServerStrip | ChannelSidebar | ChatPane | MemberPanel.
  Widget _buildClassicLayout({
    required HollowTheme hollow,
    required bool isDesktopPlatform,
    required bool isDesktop,
    required Map<String, dynamic> peers,
    required Map<String, ChatMessage> lastMessages,
    required String? selectedPeerId,
    required NodeStatus nodeStatus,
    required ServerInfo? selectedServer,
    required String? selectedServerId,
    required Map<String, ChannelInfo> channels,
    required String? selectedChannelId,
    required String channelLayout,
    required bool settingsOpen,
    required bool memberPanelOpen,
    required bool helpPanelOpen,
  }) {
    // Field-tuple select: without it the whole SHELL rebuilds on ANY
    // voice-channel state change, down to a per-peer audio map.
    final vc = ref.watch(voiceChannelProvider.select((s) => (
          s.currentChannelId,
          s.isInVoiceChannel,
          s.showsShareSurface || s.isCameraActive,
        )));
    final selectedChannel = selectedChannelId != null ? channels[selectedChannelId] : null;
    final vcScreenShareFullBleed = selectedChannel?.channelType == ChannelType.voice
        && vc.$2
        && vc.$1 == selectedChannelId
        && vc.$3;

    return StartupRevealScope(
      controller: _revealController,
      isComplete: _revealComplete,
      child: Column(
        children: [
          // Full-width strip at the very top, self-hiding when there is nothing
          // to announce.
          const SystemStatusBanner(),
          Expanded(
            child: Row(
              children: [
                const RepaintBoundary(child: ServerStrip()),
                _buildChannelSidebar(
                  peers: peers,
                  lastMessages: lastMessages,
                  selectedPeerId: selectedPeerId,
                  nodeStatus: nodeStatus,
                  selectedServer: selectedServer,
                  channels: channels,
                  selectedChannelId: selectedChannelId,
                  channelLayoutJson: channelLayout,
                ),
                const _ChannelSidebarSeam(),
                Expanded(
                  child: _chatRevealWrap(
                    RepaintBoundary(
                      child: AmbientBackground(
                        color1: hollow.accent,
                        color2: const Color(0xFF6366F1),
                        child: AnimatedSwitcher(
                          duration: HollowDurations.normal,
                          switchInCurve: HollowCurves.enter,
                          switchOutCurve: HollowCurves.exit,
                          layoutBuilder: (currentChild, previousChildren) {
                            return Stack(
                              alignment: Alignment.topCenter,
                              children: [
                                ...previousChildren,
                                ?currentChild,
                              ],
                            );
                          },
                          child: Container(
                            key: ValueKey(
                                ref.watch(guestTabOpenProvider) ? 'guest'
                                    : ref.watch(shareTabOpenProvider) ? 'share'
                                    : ref.watch(archiveTabOpenProvider) ? 'archive'
                                    : ref.watch(conferenceTabOpenProvider) ? 'conference'
                                    : ref.watch(shopTabOpenProvider) ? 'shop'
                                    : settingsOpen && selectedServer != null
                                    ? 'settings-${selectedServer.serverId}'
                                    : selectedChannelId ?? selectedPeerId ?? 'empty'),
                            color: hollow.background,
                            child: settingsOpen && selectedServer != null
                                ? ServerSettingsPanel(server: selectedServer)
                                : _buildChatOrEmpty(
                                    hollow: hollow,
                                    selectedPeerId: selectedPeerId,
                                    peers: peers,
                                    selectedChannelId: selectedChannelId,
                                    channels: channels,
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Docked at every width: re-opening it has to PUSH the chat
                // over, because an overlay would cover the header's own toggle.
                _MemberPanelSlider(
                  visible: selectedServerId != null && memberPanelOpen && !vcScreenShareFullBleed,
                  serverId: selectedServerId,
                ),
                HelpPanelSlider(visible: helpPanelOpen),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Dock layout: FriendsBar, then ChannelSidebar + ChatPane + MemberPanel,
  /// then BottomBar.
  Widget _buildDockLayout({
    required HollowTheme hollow,
    required bool isDesktopPlatform,
    required bool isDesktop,
    required Map<String, dynamic> peers,
    required Map<String, ChatMessage> lastMessages,
    required String? selectedPeerId,
    required NodeStatus nodeStatus,
    required ServerInfo? selectedServer,
    required String? selectedServerId,
    required Map<String, ChannelInfo> channels,
    required String? selectedChannelId,
    required String channelLayout,
    required bool settingsOpen,
    required bool memberPanelOpen,
    required bool helpPanelOpen,
  }) {
    final splitState = ref.watch(splitViewProvider);

    // Field-tuple select: without it the whole SHELL rebuilds on ANY
    // voice-channel state change, down to a per-peer audio map.
    final vc = ref.watch(voiceChannelProvider.select((s) => (
          s.currentChannelId,
          s.isInVoiceChannel,
          s.showsShareSurface || s.isCameraActive,
        )));
    final selectedChannel = selectedChannelId != null ? channels[selectedChannelId] : null;
    final vcScreenShareFullBleed = selectedChannel?.channelType == ChannelType.voice
        && vc.$2
        && vc.$1 == selectedChannelId
        && vc.$3;

    // Closing the left pane in split mode leaves the right pane's context to be
    // applied to the global providers.
    if (splitState.pendingMigration != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final migration = ref.read(splitViewProvider).pendingMigration;
        if (migration == null) return;
        if (migration.serverId != null) {
          // Fetch first, then batch the writes, so there are no intermediate
          // rebuilds.
          final channels = await ChannelListNotifier.fetchChannels(
              migration.serverId!);
          final layout = await ChannelLayoutNotifier.fetchLayout(
              migration.serverId!);
          ref.read(selectedPeerProvider.notifier).state = null;
          ref.read(channelListProvider.notifier).setChannels(channels);
          ref.read(channelLayoutProvider.notifier)
              .setLayout(layout, serverId: migration.serverId);
          ref.read(selectedServerProvider.notifier).state =
              migration.serverId;
          ref.read(selectedChannelProvider.notifier).state =
              migration.channelId;
        } else if (migration.peerId != null) {
          ref.read(selectedPeerProvider.notifier).state =
              migration.peerId;
          ref.read(selectedServerProvider.notifier).state = null;
          ref.read(selectedChannelProvider.notifier).state = null;
        }
        ref.read(splitViewProvider.notifier).clearPendingMigration();
      });
    }

    final effectiveServerId = splitState.isSplit && splitState.focusedPane == 1
        ? splitState.rightPane?.serverId
        : selectedServerId;

    return StartupRevealScope(
      controller: _revealController,
      isComplete: _revealComplete,
      child: Column(
        children: [

          ClipRect(
            child: AnimatedBuilder(
              animation: _friendsBarReveal,
              builder: (context, child) => Align(
                alignment: Alignment.bottomCenter,
                heightFactor: _friendsBarReveal.value.clamp(0.0, 1.0),
                child: child,
              ),
              child: FadeTransition(
                opacity: _friendsBarReveal,
                child: const RepaintBoundary(child: FriendsBar()),
              ),
            ),
          ),

          // Self-hides unless there is a banner-worthy notice, so it reaches
          // users whatever they are viewing.
          const SystemStatusBanner(),

          Expanded(
            child: ClipRect(child: Row(
              children: [
                _DockSidebarSlider(
                  visible: selectedServerId != null,
                  // The seam rides INSIDE the slider so it slides away with the
                  // panel it sizes.
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildChannelSidebar(
                        peers: peers,
                        lastMessages: lastMessages,
                        selectedPeerId: selectedPeerId,
                        nodeStatus: nodeStatus,
                        selectedServer: selectedServer,
                        channels: channels,
                        selectedChannelId: selectedChannelId,
                        channelLayoutJson: channelLayout,
                        dockMode: true,
                      ),
                      const _ChannelSidebarSeam(),
                    ],
                  ),
                ),

                Expanded(
                  child: FadeTransition(
                    opacity: _dockChatReveal,
                    child: AnimatedSwitcher(
                      duration: HollowDurations.normal,
                      switchInCurve: HollowCurves.enter,
                      switchOutCurve: HollowCurves.exit,
                      layoutBuilder: (currentChild, previousChildren) {
                        return Stack(
                          alignment: Alignment.topCenter,
                          children: [
                            ...previousChildren,
                            ?currentChild,
                          ],
                        );
                      },
                      child: splitState.isSplit
                          ? _SplitChatArea(
                              key: const ValueKey('split'),
                              hollow: hollow,
                              selectedPeerId: selectedPeerId,
                              selectedChannelId: selectedChannelId,
                              channels: channels,
                              settingsOpen: settingsOpen,
                              selectedServer: selectedServer,
                            )
                          : RepaintBoundary(
                              key: ValueKey(
                                  'single-${settingsOpen && selectedServer != null ? 'settings-${selectedServer.serverId}' : selectedChannelId ?? selectedPeerId ?? 'empty'}'),
                              child: AmbientBackground(
                                color1: hollow.accent,
                                color2: const Color(0xFF6366F1),
                                child: AnimatedSwitcher(
                                  duration: HollowDurations.normal,
                                  switchInCurve: HollowCurves.enter,
                                  switchOutCurve: HollowCurves.exit,
                                  layoutBuilder: (currentChild,
                                      previousChildren) {
                                    return Stack(
                                      alignment: Alignment.topCenter,
                                      children: [
                                        ...previousChildren,
                                        ?currentChild,
                                      ],
                                    );
                                  },
                                  child: Container(
                                    key: ValueKey(ref.watch(guestTabOpenProvider)
                                        ? 'guest'
                                        : ref.watch(shareTabOpenProvider)
                                        ? 'share'
                                        : ref.watch(archiveTabOpenProvider)
                                        ? 'archive'
                                        : ref.watch(conferenceTabOpenProvider)
                                        ? 'conference'
                                        : ref.watch(shopTabOpenProvider)
                                        ? 'shop'
                                        : settingsOpen &&
                                            selectedServer != null
                                        ? 'settings-${selectedServer.serverId}'
                                        : selectedChannelId ??
                                            selectedPeerId ??
                                            'empty'),
                                    color: settingsOpen ? hollow.surface : hollow.background,
                                    child: settingsOpen &&
                                            selectedServer != null
                                        ? ServerSettingsPanel(
                                            server: selectedServer)
                                        : _buildChatOrEmpty(
                                            hollow: hollow,
                                            selectedPeerId:
                                                selectedPeerId,
                                            peers: peers,
                                            selectedChannelId:
                                                selectedChannelId,
                                            channels: channels,
                                          ),
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
                ),

                // Hidden during split view and VC screen share. Width is not
                // gated: below the breakpoint it starts collapsed and re-opening
                // pushes the chat over, keeping the header's toggle reachable.
                if (!splitState.isSplit)
                  _MemberPanelSlider(
                    visible:
                        effectiveServerId != null && memberPanelOpen && !vcScreenShareFullBleed,
                    serverId: effectiveServerId,
                  ),
                HelpPanelSlider(visible: helpPanelOpen),
              ],
            )),
          ),

          ClipRect(
            child: AnimatedBuilder(
              animation: _bottomBarReveal,
              builder: (context, child) => Align(
                alignment: Alignment.topCenter,
                heightFactor: _bottomBarReveal.value.clamp(0.0, 1.0),
                child: child,
              ),
              child: FadeTransition(
                opacity: _bottomBarReveal,
                child: const RepaintBoundary(child: BottomBar()),
              ),
            ),
          ),
        ],
      ),
    );
  }

}

/// Animates the member panel sliding in and out from the right edge.
///
/// While closing, [selectedServerProvider] is overridden with the last known
/// server id so the content cannot flash "No peers online" on the way out.
class _MemberPanelSlider extends StatefulWidget {
  final bool visible;
  final String? serverId;

  const _MemberPanelSlider({
    required this.visible,
    this.serverId,
  });

  @override
  State<_MemberPanelSlider> createState() => _MemberPanelSliderState();
}

class _MemberPanelSliderState extends State<_MemberPanelSlider>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curved;

  /// Kept while closing so the panel cannot flash.
  String? _frozenServerId;

  @override
  void initState() {
    super.initState();
    _frozenServerId = widget.serverId;
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.normal,
      value: widget.visible ? 1.0 : 0.0,
    );
    _curved = CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.enter,
      reverseCurve: HollowCurves.exit,
    );
  }

  /// True while the panel animates closed, which freezes its content.
  bool _isClosing = false;

  @override
  void didUpdateWidget(_MemberPanelSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible != oldWidget.visible) {
      _controller.duration = HollowDurations.normal;
      if (widget.visible) {
        _isClosing = false;
        _frozenServerId = widget.serverId;
        _controller.forward();
      } else {
        // Freeze the content so it cannot flash "No peers online".
        _isClosing = true;
        _controller.reverse();
      }
    } else if (widget.visible && widget.serverId != oldWidget.serverId) {
      _frozenServerId = widget.serverId;
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curved,
      builder: (context, child) {
        if (_curved.value == 0.0) return const SizedBox.shrink();

        return ClipRect(
          child: Align(
            alignment: Alignment.centerRight,
            widthFactor: _curved.value,
            child: FadeTransition(
              opacity: _curved,
              child: child,
            ),
          ),
        );
      },
      // Overridden only while closing; otherwise the real provider wins.
      child: _isClosing && _frozenServerId != null
          ? ProviderScope(
              overrides: [
                selectedServerProvider.overrideWith(
                  (ref) => _frozenServerId,
                ),
              ],
              child: const _MemberPanelWithSeam(),
            )
          : const _MemberPanelWithSeam(),
    );
  }
}

/// The draggable seam on the channel sidebar's right edge (issue #54).
///
/// A strip of its own rather than an overlay on the panel edge: that edge is
/// the channel list's scrollbar gutter now, and a handle sitting on it would
/// eat the thumb.
class _ChannelSidebarSeam extends ConsumerWidget {
  const _ChannelSidebarSeam();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PanelResizeHandle(
      label: 'Resize the channel list',
      width: ref.watch(channelSidebarWidthProvider),
      onResize: (w) =>
          ref.read(channelSidebarWidthProvider.notifier).setWidth(w),
      onReset: () => ref.read(channelSidebarWidthProvider.notifier).reset(),
    );
  }
}

/// The member panel plus the seam on its LEFT edge, so dragging left widens
/// it (issue #54).
class _MemberPanelWithSeam extends ConsumerWidget {
  const _MemberPanelWithSeam();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PanelResizeHandle(
          label: 'Resize the member list',
          panelOnRight: true,
          width: ref.watch(memberPanelWidthProvider),
          onResize: (w) =>
              ref.read(memberPanelWidthProvider.notifier).setWidth(w),
          onReset: () => ref.read(memberPanelWidthProvider.notifier).reset(),
        ),
        // The seam paints the divider on this panel's left edge.
        const RepaintBoundary(child: MemberPanel(edgeBorder: false)),
      ],
    );
  }
}

/// Animates the channel sidebar sliding in/out from the left in dock mode.
class _DockSidebarSlider extends StatefulWidget {
  final bool visible;
  final Widget child;

  const _DockSidebarSlider({
    required this.visible,
    required this.child,
  });

  @override
  State<_DockSidebarSlider> createState() => _DockSidebarSliderState();
}

class _DockSidebarSliderState extends State<_DockSidebarSlider>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curved;

  /// Kept while closing so the content cannot collapse before the slide-out
  /// finishes.
  Widget? _frozenChild;
  bool _isClosing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.normal,
      value: widget.visible ? 1.0 : 0.0,
    );
    _curved = CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.enter,
      reverseCurve: HollowCurves.exit,
    );
    if (widget.visible) _frozenChild = widget.child;
  }

  @override
  void didUpdateWidget(_DockSidebarSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible != oldWidget.visible) {
      _controller.duration = HollowDurations.normal;
      if (widget.visible) {
        _isClosing = false;
        _frozenChild = widget.child;
        _controller.forward();
      } else {
        _isClosing = true;
        _controller.reverse();
      }
    } else if (widget.visible) {
      _frozenChild = widget.child;
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curved,
      builder: (context, child) {
        if (_curved.value == 0.0) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: _curved.value,
            child: FadeTransition(
              opacity: _curved,
              child: child,
            ),
          ),
        );
      },
      child: _isClosing ? _frozenChild : widget.child,
    );
  }
}

/// Two chat panes side by side with a draggable divider.
class _SplitChatArea extends ConsumerStatefulWidget {
  final HollowTheme hollow;
  final String? selectedPeerId;
  final String? selectedChannelId;
  final Map<String, ChannelInfo> channels;
  final bool settingsOpen;
  final ServerInfo? selectedServer;

  const _SplitChatArea({
    super.key,
    required this.hollow,
    required this.selectedPeerId,
    required this.selectedChannelId,
    required this.channels,
    required this.settingsOpen,
    required this.selectedServer,
  });

  @override
  ConsumerState<_SplitChatArea> createState() => _SplitChatAreaState();
}

class _SplitChatAreaState extends ConsumerState<_SplitChatArea> {
  @override
  Widget build(BuildContext context) {
    final hollow = widget.hollow;
    final splitState = ref.watch(splitViewProvider);
    final rightPane = splitState.rightPane ?? const PaneContext();
    final dividerPos = splitState.dividerPosition;
    final focusedPane = splitState.focusedPane;

    final leftFlex = (dividerPos * 1000).round();
    final rightFlex = ((1 - dividerPos) * 1000).round();

    // One scope for the whole right section, sidebar and chat.
    return ProviderScope(
      key: ValueKey('split-${rightPane.serverId}:${rightPane.channelId}:${rightPane.peerId}'),
      overrides: [
        selectedServerProvider
            .overrideWith((ref) => rightPane.serverId),
        selectedChannelProvider
            .overrideWith((ref) => rightPane.channelId),
        selectedPeerProvider
            .overrideWith((ref) => rightPane.peerId),
      ],
      child: Row(
        children: [
          // The left pane uses the global providers.
          Flexible(
            flex: leftFlex,
            child: GestureDetector(
              onTap: () =>
                  ref.read(splitViewProvider.notifier).setFocus(0),
              child: AnimatedContainer(
                duration: HollowDurations.fast,
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: focusedPane == 0
                          ? hollow.accent
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: RepaintBoundary(
                  child: AmbientBackground(
                    color1: hollow.accent,
                    color2: const Color(0xFF6366F1),
                    child: AnimatedSwitcher(
                      duration: HollowDurations.normal,
                      switchInCurve: HollowCurves.enter,
                      switchOutCurve: HollowCurves.exit,
                      layoutBuilder: (currentChild, previousChildren) {
                        return Stack(
                          alignment: Alignment.topCenter,
                          children: [
                            ...previousChildren,
                            ?currentChild,
                          ],
                        );
                      },
                      child: Container(
                        key: ValueKey(widget.settingsOpen &&
                                widget.selectedServer != null
                            ? 'settings-${widget.selectedServer!.serverId}'
                            : widget.selectedChannelId ??
                                widget.selectedPeerId ??
                                'empty-left'),
                        color: hollow.background,
                        child: widget.settingsOpen &&
                                widget.selectedServer != null
                            ? ServerSettingsPanel(
                                server: widget.selectedServer!)
                            : _buildLeftChatOrEmpty(hollow),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          _SplitDivider(
            onDrag: (details) {
              // Delta-based, or the divider snaps to centre.
              final renderBox = context.findRenderObject() as RenderBox;
              final totalWidth = renderBox.size.width;
              if (totalWidth > 0) {
                final delta = details.delta.dx / totalWidth;
                final current = ref.read(splitViewProvider).dividerPosition;
                ref
                    .read(splitViewProvider.notifier)
                    .setDividerPosition(current + delta);
              }
            },
          ),

          _RightPaneSidebar(hollow: hollow),

          Flexible(
            flex: rightFlex,
            child: GestureDetector(
              onTap: () =>
                  ref.read(splitViewProvider.notifier).setFocus(1),
              child: AnimatedContainer(
                duration: HollowDurations.fast,
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: focusedPane == 1
                          ? hollow.accent
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: RepaintBoundary(
                  child: AmbientBackground(
                    color1: hollow.accent,
                    color2: const Color(0xFF6366F1),
                    child: _RightPaneChatContent(hollow: hollow),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftChatOrEmpty(HollowTheme hollow) {
    if (widget.selectedChannelId != null) {
      final channel = widget.channels[widget.selectedChannelId];
      final serverId = ref.read(selectedServerProvider);
      if (serverId != null && channel != null) {
        return ChannelChatPane(
          key: ValueKey('ch:${widget.selectedChannelId}'),
          serverId: serverId,
          channelId: widget.selectedChannelId!,
          channelName: channel.name,
          splitPaneIndex: 0,
        );
      }
    }
    if (widget.selectedPeerId != null) {
      return ChatPane(
        key: ValueKey(widget.selectedPeerId),
        peerId: widget.selectedPeerId!,
        splitPaneIndex: 0,
      );
    }
    return _buildSplitEmptyChat(hollow);
  }

  Widget _buildSplitEmptyChat(HollowTheme hollow) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.messageSquare,
            size: 48,
            color: hollow.textSecondary.withValues(alpha: 0.3),
          ),
          const SizedBox(height: HollowSpacing.md),
          Text(
            'Select a conversation',
            style: HollowTypography.body.copyWith(
              color: hollow.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Channel sidebar for the right pane in split view, loading channels from FFI
/// independently of the global channelListProvider.
class _RightPaneSidebar extends ConsumerStatefulWidget {
  final HollowTheme hollow;
  const _RightPaneSidebar({required this.hollow});

  @override
  ConsumerState<_RightPaneSidebar> createState() =>
      _RightPaneSidebarState();
}

class _RightPaneSidebarState extends ConsumerState<_RightPaneSidebar> {
  Map<String, ChannelInfo> _channels = {};
  String _channelLayoutJson = '[]';
  String? _loadedServerId;

  @override
  Widget build(BuildContext context) {
    final selectedServerId = ref.watch(selectedServerProvider);

    if (selectedServerId == null) return const SizedBox.shrink();

    if (selectedServerId != _loadedServerId) {
      _loadChannels(selectedServerId);
    }

    final selectedChannelId = ref.watch(selectedChannelProvider);
    final servers = ref.watch(serverListProvider);
    final selectedServer = servers[selectedServerId];

    return ChannelSidebar(
      peers: const {},
      lastMessages: const {},
      selectedPeerId: null,
      nodeStatus: NodeStatus.connected,
      onPeerSelected: (_) {},
      lastMessage: (_) => null,
      formatTime: (_) => '',
      selectedServer: selectedServer,
      channels: _channels,
      selectedChannelId: selectedChannelId,
      onChannelSelected: (channelId) {
        ref.read(splitViewProvider.notifier).setRightChannel(channelId);
      },
      onCreateChannel: () {
        if (selectedServer != null) {
          showCreateChannelDialog(context, selectedServer.serverId);
        }
      },
      onOpenSettings: () {
        if (selectedServer != null) {
          _showServerSettingsDialog(context, selectedServer);
        }
      },
      canManageChannels: selectedServer != null &&
          (ref
                  .watch(
                      myPermissionsProvider(selectedServer.serverId))
                  .whenOrNull(
                      data: (perms) =>
                          (perms & Permission.manageChannels) != 0) ??
              false),
      channelLayoutJson: _channelLayoutJson,
      width: 200,
      dockMode: true,
      showUserBar: false,
    );
  }

  Future<void> _loadChannels(String serverId) async {
    _loadedServerId = serverId;
    try {
      // A full mapping, not a name-only rebuild, so meCanSee filters here too
      // and the right pane hides restricted channels like the main sidebar.
      final all = await ChannelListNotifier.fetchChannels(serverId);
      final map = <String, ChannelInfo>{
        for (final e in all.entries)
          if (e.value.meCanSee) e.key: e.value,
      };
      final layoutJson =
          await crdt_api.getChannelLayout(serverId: serverId);
      if (mounted) {
        setState(() {
          _channels = map;
          _channelLayoutJson = layoutJson;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _channels = {};
          _channelLayoutJson = '[]';
        });
      }
    }
  }
}

/// Chat content for the right pane in split view (no sidebar).
class _RightPaneChatContent extends ConsumerWidget {
  final HollowTheme hollow;
  const _RightPaneChatContent({required this.hollow});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedChannelId = ref.watch(selectedChannelProvider);
    final selectedPeerId = ref.watch(selectedPeerProvider);
    final selectedServerId = ref.watch(selectedServerProvider);

    if (selectedChannelId != null && selectedServerId != null) {
      return _RightChannelChat(
        serverId: selectedServerId,
        channelId: selectedChannelId,
      );
    }

    if (selectedPeerId != null && selectedPeerId.isNotEmpty) {
      return Container(
        color: hollow.background,
        child: ChatPane(
          key: ValueKey('dm-r:$selectedPeerId'),
          peerId: selectedPeerId,
          splitPaneIndex: 1,
        ),
      );
    }

    return Container(
      color: hollow.background,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.columns,
              size: 48,
              color: hollow.textSecondary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: HollowSpacing.md),
            Text(
              'Select a conversation',
              style: HollowTypography.body.copyWith(
                color: hollow.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Loads the channel name from FFI, then renders ChannelChatPane.
class _RightChannelChat extends StatefulWidget {
  final String serverId;
  final String channelId;
  const _RightChannelChat({
    required this.serverId,
    required this.channelId,
  });

  @override
  State<_RightChannelChat> createState() => _RightChannelChatState();
}

class _RightChannelChatState extends State<_RightChannelChat> {
  final Map<String, String> _nameCache = {};

  @override
  Widget build(BuildContext context) {
    final cacheKey = '${widget.serverId}:${widget.channelId}';
    final name = _nameCache[cacheKey];

    if (name == null) {
      _loadName();
      return const SizedBox.shrink();
    }

    return ChannelChatPane(
      key: ValueKey('ch-r:${widget.channelId}'),
      serverId: widget.serverId,
      channelId: widget.channelId,
      channelName: name,
      splitPaneIndex: 1,
    );
  }

  Future<void> _loadName() async {
    final cacheKey = '${widget.serverId}:${widget.channelId}';
    if (_nameCache.containsKey(cacheKey)) return;
    try {
      final channels = await crdt_api.getServerChannels(
          serverId: widget.serverId);
      for (final ch in channels) {
        _nameCache['${widget.serverId}:${ch.channelId}'] = ch.name;
      }
    } catch (_) {
      _nameCache[cacheKey] = widget.channelId;
    }
    if (mounted) setState(() {});
  }
}

/// Shows server settings as a dialog popup (used during split view).
void _showServerSettingsDialog(BuildContext context, ServerInfo server) {
  showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Server Settings',
    barrierColor: Colors.black.withValues(alpha: 0.5),
    transitionDuration: HollowDurations.normal,
    pageBuilder: (context, anim1, anim2) {
      return Center(
        // The zoom shrinks the logical viewport, so this panel can be TALLER
        // than the screen it opens on. The clamp keeps it on-screen and the
        // padding keeps it reading as a dialog rather than a takeover.
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.lg),
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 800,
              height: 600,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: HollowTheme.of(context).background,
                borderRadius: BorderRadius.circular(
                  HollowTheme.of(context).radiusLg,
                ),
                border: Border.all(
                  color: HollowTheme.of(context).border,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: ServerSettingsPanel(
                server: server,
                onClose: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (context, anim1, anim2, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: anim1, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.95, end: 1.0).animate(
            CurvedAnimation(parent: anim1, curve: Curves.easeOut),
          ),
          child: child,
        ),
      );
    },
  );
}

/// Draggable vertical divider between split panes.
class _SplitDivider extends StatefulWidget {
  final void Function(DragUpdateDetails) onDrag;

  const _SplitDivider({required this.onDrag});

  @override
  State<_SplitDivider> createState() => _SplitDividerState();
}

class _SplitDividerState extends State<_SplitDivider> {
  bool _hovering = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final isActive = _hovering || _dragging;

    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: widget.onDrag,
        onHorizontalDragEnd: (_) => setState(() => _dragging = false),
        child: AnimatedContainer(
          duration: HollowDurations.fast,
          width: 6,
          color: isActive
              ? hollow.accent.withValues(alpha: 0.3)
              : Colors.transparent,
          child: Center(
            child: AnimatedContainer(
              duration: HollowDurations.fast,
              width: isActive ? 2 : 1,
              height: 40,
              decoration: BoxDecoration(
                color: isActive
                    ? hollow.accent
                    : hollow.border,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen overlay while the identity unlocks and the local DB loads:
/// Argon2id alone is ~1.5-3s on a phone, which reads as a frozen shell. It
/// dismisses once the conversation list is populated.
class _UnlockingOverlay extends StatelessWidget {
  final HollowTheme hollow;
  const _UnlockingOverlay({required this.hollow});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          color: hollow.background.withValues(alpha: 0.82),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.lockKeyholeOpen, size: 32, color: hollow.accent),
              const SizedBox(height: HollowSpacing.lg),
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: hollow.accent,
                ),
              ),
              const SizedBox(height: HollowSpacing.lg),
              Text(
                'Unlocking…',
                style: HollowTypography.body
                    .copyWith(color: hollow.textPrimary),
              ),
              const SizedBox(height: HollowSpacing.xs),
              Text(
                'Decrypting your messages',
                style: HollowTypography.caption
                    .copyWith(color: hollow.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Isolates the background image and scaffold from the main shell build, so it
/// rebuilds only when the background changes.
class _ShellScaffold extends ConsumerWidget {
  final Widget body;
  const _ShellScaffold({required this.body});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final bg = ref.watch(backgroundProvider);

    Widget scaffold = Scaffold(
      backgroundColor: bg.hasBackground ? Colors.transparent : hollow.background,
      body: Stack(
        children: [
          body,
          const NotificationOverlay(),
          const ActiveCallBar(),
          const IncomingCallOverlay(),
        ],
      ),
    );

    if (bg.hasBackground) {
      scaffold = Stack(
        children: [
          Positioned.fill(
            child: Container(
              color: Colors.black,
              child: Image.memory(
                bg.imageBytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                width: double.infinity,
                height: double.infinity,
              ),
            ),
          ),
          scaffold,
        ],
      );
    }

    return scaffold;
  }
}
