import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/services/push_notification_service.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/mobile/mobile_active_call_pill.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_nav_bar.dart';
import 'package:hollow/src/ui/mobile/mobile_notification_banner.dart';
import 'package:hollow/src/ui/mobile/mobile_voice_channel_pill.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_archive_tab.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_chats_tab.dart'
    show MobileChatsTab, showNewConversationDialog;
import 'package:hollow/src/ui/mobile/tabs/mobile_friends_tab.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart';
import 'package:hollow/src/ui/shell/mobile_nav.dart';

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

  void _openChatFromPush(String peerId) {
    if (!mounted) return;
    // Already viewing this chat — nothing to do.
    if (ref.read(selectedPeerProvider) == peerId) return;
    ref.read(selectedPeerProvider.notifier).state = peerId;
    ref.read(selectedServerProvider.notifier).state = null;
    ref.read(unreadProvider.notifier).markDmSeen(peerId, null);
    Navigator.of(context, rootNavigator: true)
        .push(MaterialPageRoute(
      builder: (_) => MobileChatRoute(peerId: peerId),
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
    Navigator.of(context, rootNavigator: true)
        .push(MaterialPageRoute(
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
      bottomNavigationBar: MobileNavBar(
        onAdd: () => showNewConversationDialog(context),
      ),
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
        const MobileNotificationBanner(),
        const MobileActiveCallPill(),
        const MobileVoiceChannelPill(),
      ],
    );
  }
}
