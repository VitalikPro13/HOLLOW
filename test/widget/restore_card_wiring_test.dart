// Home carries the "Finish restoring your identity" card on both shells: the
// desktop dashboard and the phone's Chats tab (PHRASE_RESTORE_DESIGN 6.2).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/changelog.dart';
import 'package:hollow/src/core/providers/home_setup_provider.dart';
import 'package:hollow/src/core/providers/news_provider.dart';
import 'package:hollow/src/core/providers/relay_stats_provider.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/core/services/phrase_restore.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_chats_tab.dart';
import 'package:hollow/src/ui/shell/home_dashboard.dart';
import 'package:hollow/src/ui/shell/home_restore_card.dart';

import '../helpers/test_app.dart';

class _PendingApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _StubNews extends NewsNotifier {
  @override
  NewsState build() => const NewsState(hasFetched: true, posts: []);
}

class _StubUpdater extends UpdateNotifier {
  @override
  UpdateState build() => const UpdateState(currentVersion: '0.14.3');
}

class _StubSetup extends HomeSetupNotifier {
  @override
  HomeSetupState build() => const HomeSetupState(loaded: true);
}

class _StubRelayStats extends RelayStatsNotifier {
  @override
  RelayStats build() => const RelayStats();
}

void main() {
  setUpAll(() => RustLib.initMock(api: _PendingApi()));

  for (final phone in [false, true]) {
    testWidgets(
        phone
            ? 'the phone Chats tab shows the restore card'
            : 'the desktop Home shows the restore card', (tester) async {
      tester.view.physicalSize =
          phone ? const Size(400, 1600) : const Size(1280, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(extra: [
          newsProvider.overrideWith(_StubNews.new),
          updaterProvider.overrideWith(_StubUpdater.new),
          homeSetupProvider.overrideWith(_StubSetup.new),
          relayStatsProvider.overrideWith(_StubRelayStats.new),
          changelogProvider
              .overrideWith((ref) async => const <ChangelogRelease>[]),
          restoreCardProvider.overrideWith((ref) async => (
                atMs: 1,
                branch: PhraseRestoreBranch.recover,
                noWait: false,
                maySetAside: false,
              )),
        ]),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
              body: phone ? const MobileChatsTab() : const HomeDashboard()),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Finish restoring your identity'), findsOneWidget);
      final card = tester.widget<HomeRestoreCard>(find.byType(HomeRestoreCard));
      expect(card.touch, phone);
    });
  }
}
