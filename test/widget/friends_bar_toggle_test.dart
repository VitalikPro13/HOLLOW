/// The friends-strip buttons that light up must also un-light.
///
/// Conferences already toggled (issue #28: "pressing the lit button again is
/// how you get back to what you were doing"), but Saved messages next to it
/// only ever selected — pressing the lit button re-selected the same peer, so
/// it read as a dead press. The two need different machinery for the same
/// feel: Conferences is a centre TAB layered over the selection, so closing
/// it reveals what was underneath; Saved messages IS the selection, so there
/// is nothing underneath and "away" means Home.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/saved_messages_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/core/providers/shop_tab_provider.dart';
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/shell/friends_bar.dart';

import '../helpers/test_app.dart';

Future<ProviderContainer> _pumpBar(
  WidgetTester tester, {
  bool shopAvailable = true,
}) async {
  tester.view.physicalSize = const Size(1280, 200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final container = ProviderContainer(
    overrides: hollowTestOverrides(
      extra: [shopAvailableProvider.overrideWithValue(shopAvailable)],
    ),
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(body: Align(
          alignment: Alignment.topCenter,
          child: FriendsBar(),
        )),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  return container;
}

Future<void> _tap(WidgetTester tester, String label) async {
  final button = find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.label == label,
  );
  expect(button, findsWidgets, reason: '"$label" button should be on the bar');
  await tester.tap(button.first, warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('Saved messages opens on the first press and closes on the second',
      (tester) async {
    final c = await _pumpBar(tester);

    final savedId = c.read(savedMessagesPeerIdProvider);
    expect(savedId, isNotNull,
        reason: 'the mocked identity should yield a saved-messages peer id');
    expect(c.read(selectedPeerProvider), isNull);

    await _tap(tester, 'Saved messages');
    expect(c.read(selectedPeerProvider), savedId,
        reason: 'first press should open the saved-messages DM');

    // The regression: this press used to re-select the same peer and do
    // nothing visible.
    await _tap(tester, 'Saved messages');
    expect(c.read(selectedPeerProvider), isNull,
        reason: 'second press should put the centre pane back to Home');
  });

  testWidgets('closing Saved messages leaves no stale server selection',
      (tester) async {
    final c = await _pumpBar(tester);

    await _tap(tester, 'Saved messages');
    await _tap(tester, 'Saved messages');

    // Home means Home — a leftover server or channel would render something
    // else entirely under the cleared peer.
    expect(c.read(selectedPeerProvider), isNull);
    expect(c.read(selectedServerProvider), isNull);
    expect(c.read(selectedChannelProvider), isNull);
    expect(c.read(anyShellTabOpenProvider), isFalse);
  });

  testWidgets('Hollow Shop toggles', (tester) async {
    final c = await _pumpBar(tester);

    await _tap(tester, 'Hollow Shop');
    expect(c.read(shopTabOpenProvider), isTrue);
    expect(c.read(anyShellTabOpenProvider), isTrue);

    await _tap(tester, 'Hollow Shop');
    expect(c.read(shopTabOpenProvider), isFalse,
        reason: 'a lit button un-lights (issue #28)');
    expect(c.read(anyShellTabOpenProvider), isFalse);
  });

  /// Apple 3.1.1 and Play policy: a store build carries no shop surface at
  /// all, so the button is ABSENT rather than disabled.
  testWidgets('Hollow Shop is absent on store builds', (tester) async {
    await _pumpBar(tester, shopAvailable: false);
    expect(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Hollow Shop',
      ),
      findsNothing,
    );
  });

  testWidgets('Conferences still toggles, and the two are mutually exclusive',
      (tester) async {
    final c = await _pumpBar(tester);
    final savedId = c.read(savedMessagesPeerIdProvider);

    await _tap(tester, 'Conferences');
    expect(c.read(conferenceTabOpenProvider), isTrue);

    await _tap(tester, 'Conferences');
    expect(c.read(conferenceTabOpenProvider), isFalse,
        reason: 'the behaviour Saved messages was matched against');

    // Opening one must not leave the other lit: Conferences clears the peer
    // selection, and selecting the saved DM closes every centre tab.
    await _tap(tester, 'Saved messages');
    await _tap(tester, 'Conferences');
    expect(c.read(conferenceTabOpenProvider), isTrue);
    expect(c.read(selectedPeerProvider), isNull);

    await _tap(tester, 'Saved messages');
    expect(c.read(selectedPeerProvider), savedId);
    expect(c.read(anyShellTabOpenProvider), isFalse);
  });
}
