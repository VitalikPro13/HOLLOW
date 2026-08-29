import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/pending_join_info.dart';
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/core/providers/pending_join_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/pending_join_ui.dart';
import 'package:hollow/src/ui/shell/server_strip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../helpers/test_app.dart';

/// The parked-join tile, on the Classic strip and in the mobile chats list.
///
/// The two things worth pinning: it is NOT selectable (there is no server
/// behind it, so a click that navigated would open nothing), and it carries a
/// name a screen reader can read, because the tile is a glyph with no letter
/// and no label of its own.
void main() {
  const pendingId = 'server-pending';

  List<Override> pendingOverrides({
    bool rejected = false,
    String reason = '',
    Set<String> awaitingSetup = const {},
  }) =>
      [
        serverStripLayoutProvider
            .overrideWith(() => _SeededLayout(const [
                  PendingStripItem(serverId: pendingId),
                ])),
        pendingJoinsProvider.overrideWith(() => _SeededPendingJoins({
              pendingId: PendingJoinInfo(
                serverId: pendingId,
                requestedAt: 1,
                state: rejected
                    ? PendingJoinInfo.stateRejected
                    : PendingJoinInfo.statePending,
                reason: reason,
              ),
            })),
        awaitingSetupProvider
            .overrideWith(() => _SeededAwaitingSetup(awaitingSetup)),
      ];

  Future<ProviderContainer> pumpStrip(
    WidgetTester tester, {
    bool rejected = false,
    String reason = '',
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: hollowTestOverrides(
          extra: pendingOverrides(rejected: rejected, reason: reason),
        ),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: const Scaffold(
            body: Row(children: [ServerStrip()]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(ServerStrip)));
  }

  group('Classic server strip', () {
    testWidgets('a parked join renders as a clock tile, not a server icon',
        (tester) async {
      await pumpStrip(tester);
      expect(find.byIcon(LucideIcons.clock), findsOneWidget);
      expect(find.byIcon(LucideIcons.ban), findsNothing);
    });

    testWidgets('a rejected join swaps the clock for a ban glyph',
        (tester) async {
      await pumpStrip(tester, rejected: true, reason: 'banned');
      expect(find.byIcon(LucideIcons.ban), findsOneWidget);
      expect(find.byIcon(LucideIcons.clock), findsNothing);
    });

    testWidgets('the tile is not selectable', (tester) async {
      final container = await pumpStrip(tester);
      expect(container.read(selectedServerProvider), isNull);

      await tester.tap(find.byIcon(LucideIcons.clock));
      await tester.pumpAndSettle();

      // Clicking opens the actions menu. What it must NEVER do is navigate:
      // there is no server behind this tile yet.
      expect(container.read(selectedServerProvider), isNull);
      expect(find.text('Copy invite link'), findsOneWidget);
      expect(find.text('Discard request'), findsOneWidget);
    });

    testWidgets('a rejected tile offers Request again and Remove',
        (tester) async {
      await pumpStrip(tester, rejected: true, reason: 'banned');
      await tester.tap(find.byIcon(LucideIcons.ban));
      await tester.pumpAndSettle();

      expect(find.text('Request again'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
      expect(find.text('Discard request'), findsNothing);
      // The menu explains itself: the tile has no name to explain it.
      expect(find.text('You are banned from this server'), findsOneWidget);
    });

    testWidgets(
        'an admitted server wears the awaiting-setup flair until it is ready',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: hollowTestOverrides(extra: [
            serverStripLayoutProvider.overrideWith(() => _SeededLayout(
                  const [ServerStripItem(serverId: 'srv-1')],
                )),
            awaitingSetupProvider
                .overrideWith(() => _SeededAwaitingSetup(const {'srv-1'})),
          ]),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: HollowThemeData.dark(),
            home: const Scaffold(body: Row(children: [ServerStrip()])),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AwaitingSetupBadge), findsOneWidget);
    });

    testWidgets('the tile carries a purpose label for screen readers',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpStrip(tester);

      expect(
        find.bySemanticsLabel('Join request pending, show actions'),
        findsWidgets,
      );
      handle.dispose();
    });
  });

  group('mobile chats list', () {
    testWidgets('a pending join is a greyed row that says what it is',
        (tester) async {
      await pumpHollowMobile(tester, extraOverrides: pendingOverrides());

      expect(find.text('Join request pending'), findsOneWidget);
      expect(find.text('You will be added when a member comes online'),
          findsOneWidget);
      expect(find.byIcon(LucideIcons.clock), findsWidgets);
    });

    testWidgets('a rejected join shows the mapped reason as its subtitle',
        (tester) async {
      await pumpHollowMobile(
        tester,
        extraOverrides: pendingOverrides(
          rejected: true,
          reason: 'server_full:Night Shift:50',
        ),
      );

      expect(find.text('Join request declined'), findsOneWidget);
      expect(find.text('Night Shift is full'), findsOneWidget);
    });

    testWidgets('tapping the row opens the actions sheet', (tester) async {
      await pumpHollowMobile(tester, extraOverrides: pendingOverrides());

      await tester.tap(find.text('Join request pending'));
      await tester.pumpAndSettle();

      expect(find.text('Copy invite link'), findsOneWidget);
      expect(find.text('Discard request'), findsOneWidget);
    });
  });
}

class _SeededLayout extends ServerStripLayoutNotifier {
  final List<StripItem> items;
  _SeededLayout(this.items);

  @override
  List<StripItem> build() => items;
}

class _SeededPendingJoins extends PendingJoinsNotifier {
  final Map<String, PendingJoinInfo> seed;
  _SeededPendingJoins(this.seed);

  @override
  Map<String, PendingJoinInfo> build() => seed;
}

class _SeededAwaitingSetup extends AwaitingSetupNotifier {
  final Set<String> seed;
  _SeededAwaitingSetup(this.seed);

  @override
  Set<String> build() => seed;
}
