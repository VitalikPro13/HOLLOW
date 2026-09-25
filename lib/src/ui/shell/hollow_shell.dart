import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/android_platform.dart';
import 'package:hollow/src/core/services/android_version.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/services/destroy_flow.dart';
import 'package:hollow/src/core/services/app_lock_service.dart';
import 'package:hollow/src/core/services/channel_topic_service.dart';
import 'package:hollow/src/core/services/deep_link_service.dart';
import 'package:hollow/src/core/services/ios_data_dir_migration.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/window_chrome_provider.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/channel_navigation.dart';
import 'package:hollow/src/core/providers/home_setup_provider.dart';
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
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/duress_provider.dart';
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
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/animations/ambient_background.dart';
import 'package:hollow/src/core/services/desktop_notification_service.dart';
import 'package:hollow/src/ui/chat/channel_chat_pane.dart';
import 'package:hollow/src/ui/chat/chat_pane.dart';
import 'package:hollow/src/ui/chat/voice_channel_pane.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/notification_overlay.dart';
import 'package:hollow/src/ui/call/call_recording_toasts.dart';
import 'package:hollow/src/ui/dialogs/incoming_call_dialog.dart';
import 'package:hollow/src/ui/dialogs/create_channel_dialog.dart';
import 'package:hollow/src/ui/dialogs/device_link_dialog.dart';
import 'package:hollow/src/ui/dialogs/mnemonic_dialog.dart';
import 'package:hollow/src/ui/dialogs/welcome_dialog.dart';
import 'package:hollow/src/ui/dialogs/license_key_dialog.dart';
import 'package:hollow/src/core/providers/license_key_provider.dart';
import 'package:hollow/src/core/providers/gif_library_provider.dart';
import 'package:hollow/src/core/providers/gif_provider.dart';
import 'package:hollow/src/core/providers/link_preview_settings_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/relay_status_provider.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/dialogs/relay_switch_dialog.dart';
import 'package:hollow/src/core/providers/app_shortcuts_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_binding.dart';
import 'package:hollow/src/core/services/window_fullscreen.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/ui/server_settings/server_settings_place.dart';
import 'package:hollow/src/ui/settings/settings_place.dart';
import 'package:hollow/src/core/providers/display_scale_provider.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/core/providers/shop_unlock_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
import 'package:hollow/src/ui/guides/help_panel.dart';
import 'package:hollow/src/ui/shell/identity_unlock_dialogs.dart';
import 'package:hollow/src/ui/shell/bottom_bar.dart';
import 'package:hollow/src/ui/shell/channel_sidebar.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/shell/friends_bar.dart';
import 'package:hollow/src/ui/shell/lock_cover.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';
import 'package:hollow/src/core/providers/app_lifecycle_provider.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/core/providers/shop_tab_provider.dart';
import 'package:hollow/src/core/providers/saved_messages_provider.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
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
import 'package:hollow/src/ui/components/hollow_spinner.dart';

const _kDesktopBreakpoint = 1024.0;
const _kTabletBreakpoint = 600.0;

/// A duress code was typed and Rust has already destroyed the data. Matched on
/// the exact word rather than a substring, because a mistyped password must
/// never take this branch.
bool _isDuressResult(Object error) {
  final message = error.toString().trim();
  return message == 'duress' ||
      message.endsWith('(duress)') ||
      message.endsWith(': duress');
}

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

  // Desktop app lock. The timer polls rather than watching input, so a mouse
  // move costs a field write and nothing else.
  Timer? _idleTimer;
  bool _lockFlowRunning = false;
  // The identity opened without a prompt, so the app lock is the launch prompt.
  bool _silentStart = false;
  DateTime? _pausedAt;

  // The desktop shell fades in once at startup; nothing inside it moves.
  late final AnimationController _shellFade;
  late final CurvedAnimation _shellFadeCurve;

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
    if (!mounted) return;
    await openServerChannel(
        ProviderScope.containerOf(context, listen: false), serverId, channelId);
  }

  @override
  void initState() {
    super.initState();

    _shellFade = AnimationController(
      vsync: this,
      value: HollowDurations.animationsDisabled ? 1.0 : 0.0,
    );
    _shellFadeCurve =
        CurvedAnimation(parent: _shellFade, curve: HollowCurves.enter);

    HardwareKeyboard.instance.addHandler(_handleGlobalKey);

    // Mobile lifecycle observer for WS reconnection on app resume.
    if (Platform.isAndroid || Platform.isIOS) {
      WidgetsBinding.instance.addObserver(this);
    }

    // After the first frame, so the window is visible before anything moves.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (HollowDurations.animationsDisabled) {
        _shellFade.value = 1.0;
      } else {
        _shellFade.animateTo(1.0, duration: HollowDurations.normal);
      }
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
    // The node keeps retrying a busy key on its own; the key stays stored.
    if (reason == 'license_key_in_use') {
      ref.read(licenseErrorProvider.notifier).state = null;
      if (!mounted) return;
      HollowToast.show(
        context,
        'Your access key is in use on another device. Hollow keeps retrying.',
        type: HollowToastType.info,
        duration: const Duration(seconds: 6),
      );
      return;
    }
    ref.read(nodeProvider.notifier).stop();
    await ref.read(licenseKeyProvider.notifier).clearKey();
    ref.read(licenseErrorProvider.notifier).state = null;

    final friendlyMessage = switch (reason) {
      'invalid_license_key' =>
        "The relay didn't accept that access key. Check it and try again.",
      'license_key_required' => 'Enter an access key to connect.',
      _ => "The relay turned down this access key. Enter it again, or ask "
          'whoever runs the relay.',
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

  /// The shell's own spinner sits UNDER the lock cover, so the flag is mirrored
  /// into a provider the cover reads.
  void _setUnlocking(bool value) {
    if (!mounted) return;
    setState(() => _unlocking = value);
    ref.read(appUnlockBusyProvider.notifier).state = value;
  }

  /// Desktop app lock, armed once the store is open. The node keeps running:
  /// only the UI is covered, and the same prompt a launch uses lifts it.
  void _armAppLock() {
    // Kept warm so a lock decision never waits on the FFI.
    ref.listenManual(identityProtectionProvider, (_, _) {},
        fireImmediately: true);
    ref.listenManual(windowFocusedProvider, (_, focused) {
      if (focused) IdleClock.stamp();
    });
    ref.listenManual(appLockedProvider, (prev, locked) {
      if (locked && prev != true) _runLockFlow();
    });
    _idleTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => _maybeAutoLock());
  }

  /// A silent start with a password set means the app lock IS the launch
  /// prompt: the node is up, so a duress code typed here signs the wide scopes.
  Future<void> _lockAtLaunchIfNeeded() async {
    if (!_silentStart) return;
    try {
      final status = await ref.read(identityProtectionProvider.future);
      if (!status.hasPassword || !mounted) return;
      ref.read(appLockedProvider.notifier).setLocked(true);
    } catch (e) {
      debugPrint('[HOLLOW] lock at launch skipped: $e');
    }
  }

  void _lockAfterBackground() {
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (pausedAt == null) return;
    if (DateTime.now().difference(pausedAt) < kRelockAfterBackground) return;
    final hasPassword =
        ref.read(identityProtectionProvider).valueOrNull?.hasPassword ?? false;
    if (!hasPassword || ref.read(appLockedProvider)) return;
    if (ref.read(appLockBusyProvider) != null) return;
    ref.read(appLockedProvider.notifier).setLocked(true);
  }

  void _maybeAutoLock() {
    if (!mounted) return;
    final hasPassword =
        ref.read(identityProtectionProvider).valueOrNull?.hasPassword ?? false;
    if (!hasPassword) return;
    if (!shouldAutoLock(
      lockAfterMinutes: ref.read(lockAfterMinutesProvider),
      lastInput: IdleClock.last,
      now: DateTime.now(),
      busy: ref.read(appLockBusyProvider) != null,
      locked: ref.read(appLockedProvider),
    )) {
      return;
    }
    ref.read(appLockedProvider.notifier).setLocked(true);
  }

  /// Covers the window, then re-prompts until the password opens it again. The
  /// prompt is the launch one, so a duress code typed here runs with the keys
  /// in memory and its wider scopes reach the other devices.
  Future<void> _runLockFlow() async {
    if (_lockFlowRunning) return;
    _lockFlowRunning = true;
    final nav = hollowNavigatorKey.currentState;
    final route = lockCoverRoute();
    nav?.push(route);
    try {
      while (mounted && ref.read(appLockedProvider)) {
        if (await _showPasswordUnlockDialog()) break;
        // A dismissed prompt must not spin the loop.
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    } finally {
      if (route.isActive) nav?.removeRoute(route);
      IdleClock.stamp();
      // The prompt arms the shell's "Unlocking" overlay and only the launch
      // path clears it; an app-lock unlock has to clear it here.
      _setUnlocking(false);
      if (mounted) ref.read(appLockedProvider.notifier).setLocked(false);
      _lockFlowRunning = false;
    }
  }

  /// Unlocks the identity, showing a blocking dialog when one is needed.
  /// Returns false when the user cancelled.
  Future<bool> _unlockIdentity() async {
    try {
      // Without a password first: DPAPI, Keychain or plaintext.
      await identity_api.unlockIdentity();
      _silentStart = true;
      return true;
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('password') || msg.contains('Password')) {
        // The keystore-held secret starts Hollow on its own; the app lock
        // then asks for the password with the keys already in memory.
        final appLock = AppLockService();
        final stored = await appLock.readLaunchSecret();
        if (stored != null) {
          try {
            await identity_api.unlockIdentity(password: stored);
            appLock.sessionSecret = stored;
            _silentStart = true;
            return true;
          } catch (_) {
            // Changed through recovery: the stored copy is stale.
            await appLock.clearLaunchSecret();
          }
        }
        return _showPasswordUnlockDialog();
      }
      // A DPAPI or Keychain failure means a different machine.
      if (msg.contains('credentials') || msg.contains('device') || msg.contains('keychain')) {
        return _showDeviceBoundRecoveryDialog();
      }
      // Anything else (a corrupted file) falls back to recovery.
      if (mounted) {
        return _showDeviceBoundRecoveryDialog(unreadable: true);
      }
      return false;
    }
  }

  /// Full-screen blocking dialog for an identity copied to another machine, or
  /// one whose file would not open ([unreadable]). The 24-word phrase is the
  /// only way out.
  Future<bool> _showDeviceBoundRecoveryDialog({bool unreadable = false}) async {
    final result = await showHollowDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RecoveryPhraseDialog(
        title: 'Identity locked',
        paragraphs: [
          unreadable
              ? "Hollow couldn't open your identity file on this device."
              : "This identity is tied to another device, so it can't open "
                  'here.',
          'Enter your 24-word recovery phrase to use it on this device.',
        ],
        confirmLabel: 'Recover identity',
        cancellable: false,
        onRecover: (phrase) async {
          await identity_api.restoreIdentityFromMnemonic(phrase: phrase);
          await identity_api.unlockIdentity();
          // Reset to plaintext, so the App Lock marker and biometric secret
          // are stale.
          await AppLockService().clearAll();
        },
      ),
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
      _setUnlocking(true);
      try {
        await identity_api.unlockIdentity(password: secret);
        appLock.sessionSecret = secret;
        return true;
      } catch (_) {
        _setUnlocking(false);
        // A stale stored secret (changed via recovery) would leave the user in
        // a failing biometric loop.
        await appLock.disableBiometric();
        return false;
      }
    }

    // Most unlocks end right here.
    if (hasBiometric && await tryBiometric()) return true;
    if (!mounted) return false;

    var wrong = false;
    while (true) {
      // Statement-level, not just the loop condition, so the gap after the
      // previous iteration's awaits is covered.
      if (!mounted) return false;
      final result = await showHollowDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => UnlockDialog(
          isPin: isPin,
          hasBiometric: hasBiometric,
          wrong: wrong,
        ),
      );

      if (result == null || !mounted) return false;

      if (result == kUnlockRecover) {
        final recovered = await _recoverWithMnemonic(isPin: isPin);
        if (recovered) {
          // Reset to plaintext, so the lock state is stale.
          await AppLockService().clearAll();
          return true;
        }
        wrong = false;
        continue;
      }

      if (result == kUnlockBiometric) {
        if (await tryBiometric()) return true;
        continue;
      }

      // Argon2id runs next, so the spinner covers it.
      _setUnlocking(true);
      try {
        await identity_api.unlockIdentity(password: result);
        appLock.sessionSecret = result;
        return true;
      } catch (e) {
        if (_isDuressResult(e)) {
          // A duress code was typed and Rust has already wiped. The spinner
          // stays and nothing is said: the next thing this person sees is
          // Welcome, never a hint that the code did anything.
          await clearLocalSecretsAfterDestroy();
          await relaunchApp();
        }
        // Wrong secret: let the dialog re-prompt.
        _setUnlocking(false);
        wrong = true;
        continue;
      }
    }
  }

  Future<bool> _recoverWithMnemonic({required bool isPin}) async {
    final lock = isPin ? 'PIN' : 'password';
    final result = await showHollowDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RecoveryPhraseDialog(
        title: 'Recover identity',
        paragraphs: [
          'Enter your 24-word recovery phrase to get back into this identity.',
          'This turns off your app $lock. You can set a new one in Settings.',
        ],
        confirmLabel: 'Recover',
        onRecover: (phrase) async {
          await identity_api.restoreIdentityFromMnemonic(phrase: phrase);
          await identity_api.unlockIdentity();
        },
      ),
    );
    return result == true;
  }

  /// Replays the invite a relay switch parked, now that the node is up on the
  /// new relay. Consumed exactly once: cleared BEFORE it is acted on, so a
  /// failure cannot make it reappear at every launch.
  Future<void> _resumeInviteAfterRelaySwitch() async {
    String? parked;
    try {
      parked = await storage_api.loadSetting(key: kPendingInviteAfterSwitchKey);
      if (parked == null || parked.isEmpty) return;
      await storage_api.saveSetting(
          key: kPendingInviteAfterSwitchKey, value: '');
    } catch (_) {
      return;
    }
    final link = classifyHollowLink(parked);
    // The user switched back before it could run: dropping it beats joining a
    // relay they have left.
    if (link?.relay != normalizeRelayHost(ref.read(relayDomainProvider))) return;
    DeepLinkService.instance.handleUrl(parked);
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
        if (!_shellFade.isCompleted) _shellFade.value = 1.0;
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
    // The status feed announces the OFFICIAL relay, and its eager fetch can
    // beat the domain we just loaded.
    ref.read(statusProvider.notifier).onRelayLoaded();
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
    await ref.read(messageDisplayProvider.notifier).load();
    // Home's first-run checklist flags, same reason.
    await ref
        .read(homeSetupProvider.notifier)
        .load(ref.read(updaterProvider).currentVersion);
    // App lock, same reason: the store has to be open first.
    await ref.read(lockAfterMinutesProvider.notifier).load();
    _armAppLock();
    await _lockAtLaunchIfNeeded();
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
    // Saved messages is a DM with our own master, never a friend row, so the
    // list above misses it and Home showed no preview until it was opened. Its
    // id settles on the master only once the device list loads, hence a listen.
    ref.listenManual<String?>(savedMessagesPeerIdProvider, (_, id) {
      if (id == null) return;
      ref.read(chatProvider.notifier).loadLastMessagePreviews([id]);
    }, fireImmediately: true);

    // NETWORK PHASE, once the local UI is populated. This is the blocking 5s
    // HTTP call, and it is non-fatal: fetchRelayStatus swallows errors and
    // answers license-not-required.
    final relayStatus = await fetchRelayStatus(domain: relayDomain);
    ref.read(relayStatusProvider.notifier).set(relayStatus);
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

    await _resumeInviteAfterRelaySwitch();

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
      _lockAfterBackground();
      acquireWifiLock();
      _rejoinRoomsOnResume();
      _updateIosPushHeartbeat(active: true);
    } else if (state == AppLifecycleState.paused) {
      debugPrint('[HOLLOW] App paused — releasing WiFi lock');
      _pausedAt ??= DateTime.now();
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
    _idleTimer?.cancel();
    _shellFadeCurve.dispose();
    _shellFade.dispose();
    super.dispose();
  }

  /// Global keyboard shortcut handler, on HardwareKeyboard so it works whatever
  /// has focus. Bindings come from [appShortcutsProvider], and `matchesEvent`
  /// carries the AltGr guard: a held Alt is the user typing a layout character
  /// (AZERTY @ is AltGr+à, issue #43), never a shortcut.
  bool _handleGlobalKey(KeyEvent event) {
    IdleClock.stamp();
    if (event is! KeyDownEvent) return false;
    // Locked: the unlock prompt owns the keyboard, so every binding goes quiet
    // and the key still reaches its field.
    if (ref.read(appLockedProvider)) return false;
    // A keybind capture field is armed: the user is TYPING a binding, and acting
    // here would fire the shortcut being rebound.
    if (ref.read(keybindCaptureActiveProvider)) return false;

    final hk = HardwareKeyboard.instance;
    final binds =
        ref.read(appShortcutsProvider).valueOrNull ?? kAppShortcutDefaults;
    bool match(AppShortcut s) => binds[s]!.matchesEvent(event, hk);

    if (match(AppShortcut.openSettings)) {
      toggleSettings(ref.read);
      return true;
    }

    if (match(AppShortcut.toggleMemberPanel)) {
      final current = ref.read(memberPanelProvider);
      ref.read(memberPanelProvider.notifier).state = !current;
      return true;
    }

    if (match(AppShortcut.lockNow)) {
      requestAppLock(ref, context);
      return true;
    }

    if (match(AppShortcut.quickSearch)) {
      final current = ref.read(chatSearchOpenProvider);
      ref.read(chatSearchOpenProvider.notifier).state = !current;
      return true;
    }

    if (match(AppShortcut.toggleFullscreen) && FullscreenNotifier.supported) {
      ref.read(fullscreenProvider.notifier).toggle();
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
        if (selectedServer == null) return;
        if (ref.read(serverSettingsOpenProvider)) {
          closeServerSettings(ref.read);
        } else {
          openServerSettings(ref.read, selectedServer.serverId);
        }
      },
      canManageChannels: selectedServer != null &&
          (ref.watch(myPermissionsProvider(selectedServer.serverId)).whenOrNull(
              data: (perms) => (perms & Permission.manageChannels) != 0) ?? false),
      channelLayoutJson: channelLayoutJson,
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
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Icon(LucideIcons.users,
                      size: 20, color: hollow.textSecondary),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: HollowEmptyState(
            glyph: LucideIcons.hash,
            title: 'Welcome to #${channel?.name ?? "general"}',
            description: 'Channel messages coming soon.',
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
          : const HollowEmptyState(
              glyph: LucideIcons.messageSquare,
              title: 'Select a peer to start chatting',
            );
    }
    return ChatPane(
      key: ValueKey(selectedPeerId),
      peerId: selectedPeerId,
    );
  }

  /// The server settings place when open, scoped to its own server when that
  /// is not the selected one (opened from a split's right pane).
  Widget? _serverSettingsPlace(bool open) {
    if (!open) return null;
    final target = ref.watch(serverSettingsTargetProvider);
    if (target == null) return null;
    const place = ServerSettingsPlace();
    return target == ref.watch(selectedServerProvider)
        ? place
        : ForeignServerSettingsScope(serverId: target, child: place);
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
    final fullscreen = ref.watch(fullscreenProvider);

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
        // puts them back. Fullscreen disables every edge (no frame for them to
        // drive) but keeps the widget MOUNTED: dropping it swaps the type above
        // the whole shell, which re-inflates it, and the composer's autofocus
        // then pulls focus out of an open dialog so Escape stops reaching it.
        if (isDesktopPlatform) {
          body = DragToResizeArea(
            enableResizeEdges: fullscreen ? const <ResizeEdge>[] : null,
            child: body,
          );
        }

        // Tab order follows the visual layout without any manual ordering
        // (a11y 2.6); dialogs pushed above this trap their own focus.
        body = FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: body,
        );

        return FadeTransition(
          opacity: _shellFadeCurve,
          child: _ShellScaffold(body: body),
        );
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
    // A voice room brings its own side panel (its chat), and there is only
    // ever one, so the member panel steps aside.
    final selectedChannel = selectedChannelId != null ? channels[selectedChannelId] : null;
    final voiceRoomSelected =
        selectedChannel?.channelType == ChannelType.voice;

    return Column(
      children: [
        // Full-width strip at the very top, self-hiding when there is nothing
        // to announce.
        const SystemStatusBanner(),
        Expanded(
          child: Row(
            children: [
              const RepaintBoundary(child: ServerStrip()),
              if (ref.watch(settingsTabOpenProvider))
                const Expanded(child: SettingsPlace())
              else if (_serverSettingsPlace(settingsOpen) case final place?)
                Expanded(child: place)
              else ...[
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
                child: RepaintBoundary(
                  child: AmbientBackground(
                    color1: hollow.accent,
                    color2: const Color(0xFF6366F1),
                    // Switching conversations is instant; the key resets the
                    // pane's state per conversation.
                    child: Container(
                      key: ValueKey(_mainPaneKey(
                          selectedChannelId: selectedChannelId,
                          selectedPeerId: selectedPeerId)),
                      color: hollow.background,
                      child: _buildChatOrEmpty(
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
              // Docked at every width: re-opening it has to PUSH the chat
              // over, because an overlay would cover the header's own toggle.
              _MemberPanelSlot(
                visible: selectedServerId != null && memberPanelOpen && !voiceRoomSelected,
              ),
              HelpPanelSlider(visible: helpPanelOpen),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Identifies what the main pane shows, so its state resets on a switch.
  String _mainPaneKey({
    required String? selectedChannelId,
    required String? selectedPeerId,
  }) {
    if (ref.watch(guestTabOpenProvider)) return 'guest';
    if (ref.watch(shareTabOpenProvider)) return 'share';
    if (ref.watch(archiveTabOpenProvider)) return 'archive';
    if (ref.watch(conferenceTabOpenProvider)) return 'conference';
    if (ref.watch(shopTabOpenProvider)) return 'shop';
    return selectedChannelId ?? selectedPeerId ?? 'empty';
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

    // A voice room brings its own side panel (its chat), and there is only
    // ever one, so the member panel steps aside.
    final selectedChannel = selectedChannelId != null ? channels[selectedChannelId] : null;
    final voiceRoomSelected =
        selectedChannel?.channelType == ChannelType.voice;

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

    final singleKey = selectedChannelId ?? selectedPeerId ?? 'empty';

    return Column(
      children: [
        const _DockChromeClaim(child: RepaintBoundary(child: FriendsBar())),

        // Self-hides unless there is a banner-worthy notice, so it reaches
        // users whatever they are viewing.
        const SystemStatusBanner(),

        Expanded(
          child: ref.watch(settingsTabOpenProvider)
              ? const SettingsPlace()
              : _serverSettingsPlace(settingsOpen) ?? ClipRect(child: Row(
            children: [
              if (selectedServerId != null)
                Row(
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

              // Switching conversations is instant; the keys reset the pane's
              // state per conversation while the ambient layer stays put.
              Expanded(
                child: splitState.isSplit
                    ? _SplitChatArea(
                        key: const ValueKey('split'),
                        hollow: hollow,
                        selectedPeerId: selectedPeerId,
                        selectedChannelId: selectedChannelId,
                        channels: channels,
                      )
                    : RepaintBoundary(
                        key: const ValueKey('single'),
                        child: AmbientBackground(
                          color1: hollow.accent,
                          color2: const Color(0xFF6366F1),
                          child: Container(
                            key: ValueKey((
                              singleKey,
                              _mainPaneKey(
                                  selectedChannelId: selectedChannelId,
                                  selectedPeerId: selectedPeerId),
                            )),
                            color: hollow.background,
                            child: _buildChatOrEmpty(
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

              // Hidden during split view and VC screen share. Width is not
              // gated: below the breakpoint it starts collapsed and re-opening
              // pushes the chat over, keeping the header's toggle reachable.
              if (!splitState.isSplit)
                _MemberPanelSlot(
                  visible: effectiveServerId != null &&
                      memberPanelOpen &&
                      !voiceRoomSelected,
                ),
              HelpPanelSlider(visible: helpPanelOpen),
            ],
          )),
        ),

        const RepaintBoundary(child: BottomBar()),
      ],
    );
  }

}

/// Tells the app root the dock's header carries the window chrome while it is
/// mounted, so the 32 px title bar folds away. Written after the frame and
/// cleared in a microtask, never during a build.
class _DockChromeClaim extends ConsumerStatefulWidget {
  final Widget child;
  const _DockChromeClaim({required this.child});

  @override
  ConsumerState<_DockChromeClaim> createState() => _DockChromeClaimState();
}

class _DockChromeClaimState extends ConsumerState<_DockChromeClaim> {
  late final StateController<bool> _claim =
      ref.read(dockOwnsWindowChromeProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _claim.state = true;
    });
  }

  @override
  void dispose() {
    final claim = _claim;
    Future.microtask(() => claim.state = false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The member panel's place in the row. It shows and hides instantly: a width
/// animation would re-wrap the chat text on every frame.
class _MemberPanelSlot extends StatelessWidget {
  final bool visible;

  const _MemberPanelSlot({required this.visible});

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    return const _MemberPanelWithSeam();
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

/// Two chat panes side by side with a draggable divider.
class _SplitChatArea extends ConsumerStatefulWidget {
  final HollowTheme hollow;
  final String? selectedPeerId;
  final String? selectedChannelId;
  final Map<String, ChannelInfo> channels;

  const _SplitChatArea({
    super.key,
    required this.hollow,
    required this.selectedPeerId,
    required this.selectedChannelId,
    required this.channels,
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
                          : hollow.accent.withValues(alpha: 0),
                      width: 2,
                    ),
                  ),
                ),
                child: RepaintBoundary(
                  child: AmbientBackground(
                    color1: hollow.accent,
                    color2: const Color(0xFF6366F1),
                    child: Container(
                      key: ValueKey(widget.selectedChannelId ??
                          widget.selectedPeerId ??
                          'empty-left'),
                      color: hollow.background,
                      child: _buildLeftChatOrEmpty(hollow),
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
                          : hollow.accent.withValues(alpha: 0),
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
    return const HollowEmptyState(
      glyph: LucideIcons.messageSquare,
      title: 'Select a conversation',
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
          openServerSettings(ref.read, selectedServer.serverId);
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
      child: const HollowEmptyState(
        glyph: LucideIcons.columns,
        title: 'Select a conversation',
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
          color: hollow.accent.withValues(alpha: isActive ? 0.3 : 0),
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
              const HollowSpinner.medium(),
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
          const CallRecordingToasts(),
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
