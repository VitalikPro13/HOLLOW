import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/age_gate.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/providers/channel_on_screen_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/services/channel_topic_service.dart';
import 'package:hollow/src/core/services/push_notification_service.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/dialogs/relay_denied_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_connection_indicator.dart';
import 'package:hollow/src/ui/mobile/mobile_nav_bar.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/mobile_minimised_call.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_navigation.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_chats_tab.dart'
    show MobileChatsTab;
import 'package:hollow/src/ui/mobile/tabs/mobile_friends_tab.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_servers_tab.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart';
import 'package:hollow/src/ui/shell/mobile_nav.dart';
import 'package:hollow/src/ui/shell/clock_skew_banner.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';
import 'package:hollow/src/ui/components/wallpaper_backdrop.dart';

/// Lets a widget test on a computer route push taps through the shell.
@visibleForTesting
bool debugPushTapsOnHost = false;

class MobileShell extends ConsumerStatefulWidget {
  const MobileShell({super.key});

  @override
  ConsumerState<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends ConsumerState<MobileShell> {
  static const _tabs = {
    MobileTab.chats: MobileChatsTab(),
    MobileTab.servers: MobileServersTab(),
    MobileTab.friends: MobileFriendsTab(),
    MobileTab.settings: MobileSettingsTab(),
  };

  /// Tells the node a channel was opened, so it pulls that channel's relay ring
  /// if this connection has not (unread channels of the server come along).
  void _subscribeActiveChannel(String serverId, String channelId) {
    final unread = ref.read(unreadProvider);
    final prefix = '$serverId:';
    final unreadChannels = unread.channelUnreadCounts.entries
        .where((e) => e.key.startsWith(prefix) && e.value > 0)
        .map((e) => e.key.substring(prefix.length))
        .toList();
    final topics = <String>{channelId, ...unreadChannels}.toList();
    // A buffered cold-start push tap fires before `start_node()` completes, so
    // the helper retries until the node is up and never throws.
    subscribeChannelTopics(serverId: serverId, channelIds: topics);
  }

  /// Tells the on-screen gate that the phone shell, not the desktop selection,
  /// decides which channel is shown.
  late final StateController<bool> _shellActive;

  @override
  void dispose() {
    final active = _shellActive;
    Future.microtask(() {
      if (active.mounted) active.state = false;
    });
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _shellActive = ref.read(mobileShellActiveProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _shellActive.state = true;
    });
    listenForRelayLoginDenial(ref, () => context, touch: true);
    // Push taps land here, including the buffered cold-start ones, which are
    // delivered on registration.
    if (Platform.isAndroid || Platform.isIOS || debugPushTapsOnHost) {
      ref.listenManual<bool>(appLockedProvider, (prev, locked) {
        if (!locked && prev == true) _replayHeldTap();
      });
      PushNotificationService.registerOpenChatHandler(_openChatFromPush);
      PushNotificationService.registerOpenChannelHandler(_openChannelFromPush);
    }
  }

  /// A tap that lands while the lock cover is up, held until it lifts: a route
  /// pushed now would sit ABOVE the cover and show the conversation.
  VoidCallback? _heldTap;

  /// True (and the tap held) while the lock is up. Checked again after every
  /// await, since the lock can rise while a tap resolves its target.
  bool _holdWhileLocked(VoidCallback replay) {
    if (!ref.read(appLockedProvider)) return false;
    _heldTap = replay;
    return true;
  }

  void _replayHeldTap() {
    final replay = _heldTap;
    _heldTap = null;
    if (replay != null && mounted) replay();
  }

  Future<void> _openChatFromPush(String peerId) async {
    if (!mounted) return;
    if (_holdWhileLocked(() => _openChatFromPush(peerId))) return;
    // A DM push `sender` is the friend's DEVICE id while every thread and
    // provider keys on the MASTER, so without this the tap opens a separate
    // empty thread.
    //
    // It must go through the PERSISTED-links FFI: a buffered cold-start tap
    // fires before the node's in-memory resolver is warm, and plain
    // `identityFor` then resolves the device id to itself with no error.
    // `identityForPersisted` reads `device_links` straight from SQLCipher.
    String masterId;
    try {
      masterId = await network_api.identityForPersisted(peerId: peerId);
    } catch (_) {
      masterId = ref.read(deviceLinkProvider).identityOf(peerId);
    }
    if (masterId.isEmpty) masterId = peerId;
    if (!mounted) return;
    if (_holdWhileLocked(() => _openChatFromPush(peerId))) return;
    if (ref.read(selectedPeerProvider) == masterId) return;
    ref.read(selectedPeerProvider.notifier).state = masterId;
    ref.read(selectedServerProvider.notifier).state = null;
    ref.read(unreadProvider.notifier).markDmSeen(masterId, null);
    // A tap that arrives while another conversation is open pops that route
    // rather than stacking on it. The selection is written BEFORE the pop, so
    // the popped route's guarded cleanup no-ops instead of clobbering it.
    final nav = Navigator.of(context, rootNavigator: true);
    nav.popUntil(
        (r) => r.settings.name != MobileChatRoute.routeName || r.isFirst);
    nav
        .push(hollowMobileRoute(
      settings: const RouteSettings(name: MobileChatRoute.routeName),
      builder: (_) => MobileChatRoute(peerId: masterId),
    ))
        .then((_) {
      // Another chat may have replaced this one before it popped.
      if (mounted && ref.read(selectedPeerProvider) == masterId) {
        ref.read(selectedPeerProvider.notifier).state = null;
      }
    });
  }

  Future<void> _openChannelFromPush(String serverId, String channelId) async {
    if (!mounted) return;
    void replay() => _openChannelFromPush(serverId, channelId);
    if (_holdWhileLocked(replay)) return;
    // Already viewing this channel.
    if (ref.read(selectedServerProvider) == serverId &&
        ref.read(selectedChannelProvider) == channelId) {
      return;
    }
    // A tap on a banner for a server this phone hides opens nothing: Rust's own
    // verdict, so a banner from before the gate closed cannot reopen it.
    if (ref.read(ageGateProvider.notifier).hides(serverId) ||
        await serverAgeHiddenNow(serverId)) {
      return;
    }
    if (!mounted || _holdWhileLocked(replay)) return;
    // The route header needs a name, which only the local DB has.
    var channelName = '';
    try {
      final channels = await ChannelListNotifier.fetchChannels(serverId);
      channelName = channels[channelId]?.name ?? '';
    } catch (_) {}
    if (!mounted || _holdWhileLocked(replay)) return;
    _subscribeActiveChannel(serverId, channelId);
    // Lands under that server's page, so a swipe back shows its channels.
    await openMobileChannelOn(Navigator.of(context, rootNavigator: true),
        serverId: serverId, channelId: channelId, channelName: channelName);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final currentTab = ref.watch(mobileTabProvider);
    final bg = ref.watch(backgroundProvider);

    Widget scaffold = Scaffold(
      backgroundColor: bg.hasBackground ? Colors.transparent : hollow.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  // Switching tabs is instant; every tab stays mounted so
                  // its scroll and state survive the switch.
                  for (final MapEntry(key: tab, value: body) in _tabs.entries)
                    Offstage(offstage: tab != currentTab, child: body),
                ],
              ),
            ),
            // The call you are in, docked so it covers no row or strip.
            const MobileMinimisedCall(),
            // Self-hides when there is nothing to announce.
            const SystemStatusBanner(anchor: StatusBannerAnchor.bottom),
            const ClockSkewBanner(anchor: StatusBannerAnchor.bottom),
          ],
        ),
      ),
      bottomNavigationBar: MobileNavBar(
        onAdd: () => showMobileAddServer(context),
      ),
    );

    // Traversal follows the visual layout rather than widget-tree order, for
    // external keyboards and Switch Access (a11y 2.6).
    scaffold = FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: scaffold,
    );

    scaffold = WallpaperBackdrop(child: scaffold);

    return Stack(
      children: [
        scaffold,
        // No in-app banner here: the only mobile in-app notification is
        // MobileInChatBanner, shown while inside a chat. Outside one, mobile
        // relies on OS notifications.
        // Lives in the root overlay, over every route pushed on the phone.
        const MobileConnectionIndicatorHost(),
      ],
    );
  }
}
