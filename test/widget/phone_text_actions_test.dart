// Two phone actions that were bare icons now say what they do (Vitalik
// 11-19): Conferences' Join and the Archive's per-server Export.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/archive_conversation.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/mobile/mobile_conferences_route.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_archive_tab.dart';
import 'package:hollow/src/ui/shell/mobile_nav.dart';

import '../helpers/test_app.dart';

class _Conference extends ConferenceNotifier {
  @override
  ConferenceState build() => const ConferenceState(roomsLoaded: true);
}

Future<void> _pump(WidgetTester tester, Widget home,
    {List<Override> extra = const []}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: extra),
    child: MaterialApp(theme: HollowThemeData.dark(), home: home),
  ));
  await tester.pump();
}

void main() {
  testWidgets('Conferences: Join is a labelled ghost button', (tester) async {
    await _pump(tester, const MobileConferencesRoute(),
        extra: [conferenceProvider.overrideWith(() => _Conference())]);

    final join = find.widgetWithText(HollowButton, 'Join');
    expect(join, findsOneWidget);
    expect(tester.widget<HollowButton>(join).variant,
        HollowButtonVariant.ghost,
        reason: 'a header toolbar with no primary is all ghost');
    expect(tester.widget<HollowButton>(join).semanticLabel, 'Join a meeting');
    expect(
        find.byWidgetPredicate(
            (w) => w is HollowIconButton && w.label == 'Join a meeting'),
        findsNothing);

    await tester.tap(join);
    await tester.pumpAndSettle();
    expect(find.text('Join a meeting'), findsOneWidget,
        reason: 'the join dialog opens');
  });

  testWidgets('Archive: each server group says Export', (tester) async {
    const group = ArchiveChannelGroup(
      serverId: 's1',
      serverName: 'Night shift',
      channels: [
        ArchiveChannelEntry(
          serverId: 's1',
          serverName: 'Night shift',
          channelId: 'c1',
          channelName: 'general',
          messageCount: 12,
        ),
      ],
    );
    await _pump(tester, const Scaffold(body: MobileArchiveTab()), extra: [
      mobileTabProvider.overrideWith((ref) => 2),
      archiveDmListProvider.overrideWith((ref) async => const []),
      archiveChannelListProvider.overrideWith((ref) async => const [group]),
    ]);
    await tester.pump();

    final export = find.widgetWithText(HollowButton, 'Export');
    expect(export, findsOneWidget);
    expect(tester.widget<HollowButton>(export).variant,
        HollowButtonVariant.ghost,
        reason: "a group header's own action is ghost");
    expect(tester.widget<HollowButton>(export).semanticLabel,
        'Export Night shift');
    expect(
        find.byWidgetPredicate((w) =>
            w is HollowIconButton && w.label == 'Export Night shift'),
        findsNothing);
  });
}
