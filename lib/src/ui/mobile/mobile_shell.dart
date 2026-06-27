import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/services/push_notification_service.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/mobile/mobile_active_call_pill.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_nav_bar.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/mobile_voice_channel_pill.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_archive_tab.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_chats_tab.dart'
    show MobileChatsTab, showNewConversationDialog;
import 'package:hollow/src/ui/mobile/tabs/mobile_friends_tab.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart';
import 'package:hollow/src/ui/shell/mobile_nav.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';

class MobileShell extends ConsumerStatefulWidget {
  const MobileShell({super.key});

  @override
  ConsumerState<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends ConsumerState<MobileShell> {
  static const _tabs = [
    MobileChatsTab(),
    MobileFriendsTab(),
    MobileArchiveTab(),
    MobileSettingsTab(),
  ];

  /// Subscribe the node to a channel's relay topic so live MLS topic-broadcasts
  /// are delivered (the relay only routes a topic message to subscribed sockets).
  /// Includes unread channels of the same server so @mentions still arrive.
  void _subscribeActiveChannel(String serverId, String channelId) {
    final unread = ref.read(unreadProvider);
    final prefix = '$serverId:';
    final unreadChannels = unread.channelUnreadCounts.entries
        .where((e) => e.key.startsWith(prefix) && e.value > 0)
        .map((e) => e.key.substring(prefix.length))
        .toList();
    final topics = <String>{channelId, ...unreadChannels}.toList();
    network_api.subscribeChannels(serverId: serverId, channelIds: topics);
  }

  @override
  void initState() {
    super.initState();
    // Push notification taps land here: open the sender's DM chat or the
    // tapped channel. Buffered taps from cold start are delivered immediately
    // on registration.
    if (Platform.isAndroid || Platform.isIOS) {
      PushNotificationService.registerOpenChatHandler(_openChatFromPush);
      PushNotificationService.registerOpenChannelHandler(_openChannelFromPush);
    }
  }

  Future<void> _openChatFromPush(String peerId) async {
    if (!mounted) return;
    // Resolve device→master. A DM push `sender` is the friend's DEVICE id, but
    // every DM thread / provider keys on the friend's MASTER id. On iOS a
    // force-killed tap arrives via FCM `data['sender']` (the raw device id,
    // bypassing the Dart handler's master resolution), so without this the chat
    // opens a separate empty thread keyed on the device id. (Covers all 3 tap
    // entry points; a single-device / unknown peer resolves to itself.)
    //
    // Resolve via the Rust FFI (the live node resolver is warmed at startup) —
    // more reliable on a COLD-START tap than the `deviceLinkProvider` mirror,
    // which warms async and could still be empty when a buffered tap fires. Fall
    // back to the provider mirror if the FFI call fails.
    String masterId;
    try {
      masterId = await network_api.identityFor(peerId: peerId);
    } catch (_) {
      masterId = ref.read(deviceLinkProvider).identityOf(peerId);
    }
    if (masterId.isEmpty) masterId = peerId;
    if (!mounted) return;
    // Already viewing this chat — nothing to do.
    if (ref.read(selectedPeerProvider) == masterId) return;
    ref.read(selectedPeerProvider.notifier).state = masterId;
    ref.read(selectedServerProvider.notifier).state = null;
    ref.read(unreadProvider.notifier).markDmSeen(masterId, null);
    Navigator.of(context, rootNavigator: true)
        .push(hollowMobileRoute(
      builder: (_) => MobileChatRoute(peerId: masterId),
    ))
        .then((_) {
      if (mounted) {
        ref.read(selectedPeerProvider.notifier).state = null;
      }
    });
  }

  Future<void> _openChannelFromPush(String serverId, String channelId) async {
    if (!mounted) return;
    // Already viewing this channel — nothing to do.
    if (ref.read(selectedServerProvider) == serverId &&
        ref.read(selectedChannelProvider) == channelId) {
      return;
    }
    // Resolve the channel name from the local DB for the route header.
    var channelName = '';
    try {
      final channels = await ChannelListNotifier.fetchChannels(serverId);
      channelName = channels[channelId]?.name ?? '';
    } catch (_) {}
    if (!mounted) return;
    ref.read(selectedServerProvider.notifier).state = serverId;
    ref.read(selectedChannelProvider.notifier).state = channelId;
    // Subscribe to the channel's relay topic so live MLS topic-broadcasts arrive
    // (without this the channel only fetched messages on open, never real-time).
    _subscribeActiveChannel(serverId, channelId);
    Navigator.of(context, rootNavigator: true)
        .push(hollowMobileRoute(
      builder: (_) => MobileChatRoute(
        serverId: serverId,
        channelId: channelId,
        channelName: channelName.isNotEmpty ? channelName : 'channel',
      ),
    ))
        .then((_) {
      if (mounted) {
        ref.read(selectedServerProvider.notifier).state = null;
        ref.read(selectedChannelProvider.notifier).state = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final currentTab = ref.watch(mobileTabProvider);
    final bg = ref.watch(backgroundProvider);

    // Refresh archive data whenever the user switches TO the Archive tab (index 2).
    // The list providers are non-autoDispose FutureProviders that cache their first
    // result for the app lifetime, so without this the Archive tab shows stale
    // conversation/message counts until the next app launch. This mirrors desktop,
    // which invalidates these providers in its archive-open handlers (bottom_bar /
    // server_strip). Applies to both Android and iOS — single mobile codebase.
    ref.listen<int>(mobileTabProvider, (prev, next) {
      if (next == 2 && prev != 2) {
        ref.invalidate(archiveDmListProvider);
        ref.invalidate(archiveChannelListProvider);
      }
    });

    Widget scaffold = Scaffold(
      backgroundColor: bg.hasBackground ? Colors.transparent : hollow.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  for (int i = 0; i < _tabs.length; i++)
                    AnimatedOpacity(
                      opacity: i == currentTab ? 1.0 : 0.0,
                      duration: HollowDurations.fast,
                      curve: HollowCurves.subtle,
                      child: IgnorePointer(
                        ignoring: i != currentTab,
                        child: _tabs[i],
                      ),
                    ),
                ],
              ),
            ),
            // System-status notice pinned just above the bottom nav bar — the
            // mobile "tab screens" surface. Self-hides when nothing to announce.
            const SystemStatusBanner(anchor: StatusBannerAnchor.bottom),
          ],
        ),
      ),
      bottomNavigationBar: MobileNavBar(
        onAdd: () => showNewConversationDialog(context),
      ),
    );

    // Reading-order Tab/traversal for external keyboards + Switch Access on
    // mobile (a11y 2.6) — follows the visual layout instead of widget-tree
    // order. Cheap and harmless when no keyboard is attached.
    scaffold = FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: scaffold,
    );

    if (bg.hasBackground) {
      final darkenAlpha = bg.panelOpacity.clamp(0.0, 0.92);
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
          Positioned.fill(
            child: Container(
              color: hollow.background.withValues(alpha: darkenAlpha),
            ),
          ),
          scaffold,
        ],
      );
    }

    return Stack(
      children: [
        scaffold,
        // No in-app banner here: the only mobile in-app notification is the
        // compact MobileInChatBanner (with countdown) shown WHILE inside a chat
        // for other conversations. Outside a chat, we rely on OS notifications
        // (backgrounded) — no on-screen banner.
        const MobileActiveCallPill(),
        const MobileVoiceChannelPill(),
      ],
    );
  }
}
