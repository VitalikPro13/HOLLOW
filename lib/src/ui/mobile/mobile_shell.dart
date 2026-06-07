import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/mobile/mobile_active_call_pill.dart';
import 'package:hollow/src/ui/mobile/mobile_nav_bar.dart';
import 'package:hollow/src/ui/mobile/mobile_notification_banner.dart';
import 'package:hollow/src/ui/mobile/mobile_voice_channel_pill.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_archive_tab.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_chats_tab.dart'
    show MobileChatsTab, showNewConversationDialog;
import 'package:hollow/src/ui/mobile/tabs/mobile_friends_tab.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart';
import 'package:hollow/src/ui/shell/mobile_nav.dart';

class MobileShell extends ConsumerWidget {
  const MobileShell({super.key});

  static const _tabs = [
    MobileChatsTab(),
    MobileFriendsTab(),
    MobileArchiveTab(),
    MobileSettingsTab(),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
