import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/mobile/mobile_nav_bar.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_archive_tab.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_chats_tab.dart';
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

    return Scaffold(
      backgroundColor: hollow.background,
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
      bottomNavigationBar: const MobileNavBar(),
    );
  }
}
