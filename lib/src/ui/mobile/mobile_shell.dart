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
import 'package:hollow/src/core/services/channel_topic_service.dart';
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

  /// Subscribes the node to a channel's relay topic; the relay only routes a
  /// topic message to subscribed sockets. Unread channels of the same server
  /// are included so mentions still arrive.
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

  @override
  void initState() {
    super.initState();
    // Push taps land here, including the buffered cold-start ones, which are
    // delivered on registration.
    if (Platform.isAndroid || Platform.isIOS) {
      PushNotificationService.registerOpenChatHandler(_openChatFromPush);
      PushNotificationService.registerOpenChannelHandler(_openChannelFromPush);
    }
  }

  Future<void> _openChatFromPush(String peerId) async {
    if (!mounted) return;
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
    // Already viewing this channel.
    if (ref.read(selectedServerProvider) == serverId &&
        ref.read(selectedChannelProvider) == channelId) {
      return;
    }
    // The route header needs a name, which only the local DB has.
    var channelName = '';
    try {
      final channels = await ChannelListNotifier.fetchChannels(serverId);
      channelName = channels[channelId]?.name ?? '';
    } catch (_) {}
    if (!mounted) return;
    ref.read(selectedServerProvider.notifier).state = serverId;
    ref.read(selectedChannelProvider.notifier).state = channelId;
    _subscribeActiveChannel(serverId, channelId);
    // Pop any chat route already on the stack, as in _openChatFromPush.
    final nav = Navigator.of(context, rootNavigator: true);
    nav.popUntil(
        (r) => r.settings.name != MobileChatRoute.routeName || r.isFirst);
    nav
        .push(hollowMobileRoute(
      settings: const RouteSettings(name: MobileChatRoute.routeName),
      builder: (_) => MobileChatRoute(
        serverId: serverId,
        channelId: channelId,
        channelName: channelName.isNotEmpty ? channelName : 'channel',
      ),
    ))
        .then((_) {
      if (mounted && ref.read(selectedChannelProvider) == channelId) {
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

    // The archive list providers are non-autoDispose and cache their first
    // result for the app lifetime, so without this refresh the tab shows counts
    // from launch until the next one.
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
            // Self-hides when there is nothing to announce.
            const SystemStatusBanner(anchor: StatusBannerAnchor.bottom),
          ],
        ),
      ),
      bottomNavigationBar: MobileNavBar(
        onAdd: () => showNewConversationDialog(context),
      ),
    );

    // Traversal follows the visual layout rather than widget-tree order, for
    // external keyboards and Switch Access (a11y 2.6).
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
        // No in-app banner here: the only mobile in-app notification is
        // MobileInChatBanner, shown while inside a chat. Outside one, mobile
        // relies on OS notifications.
        const MobileActiveCallPill(),
        const MobileVoiceChannelPill(),
      ],
    );
  }
}
