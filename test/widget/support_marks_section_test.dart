/// Support marks in Settings > Profile: the two choices a holder makes, and
/// the one irreversible thing they can do.
///
/// What this pins: both toggles are on the panel, "Hide my support marks"
/// asks Rust for exactly `true`, Remove asks first with a `.danger` confirm
/// and only then forgets the credential, and an identity with no marks is
/// told how to earn one rather than shown an empty space.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/owned_art_provider.dart';
import 'package:hollow/src/core/providers/shop_provider.dart' as shop;
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/shop/owned_art_panel.dart';

import '../helpers/test_app.dart';

final _redeemedAt = DateTime(2026, 9, 2, 12);
final int _redeemedMs = _redeemedAt.millisecondsSinceEpoch;

const String _item =
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

final _cred = shop.OwnSupportCred(
  item: _item,
  parts: const ['eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'],
  slug: 'gilded-frame',
  title: 'Gilded frame',
  artistName: 'Nadia',
  // Noon local on the redeem day, so the row's date reads the same wherever
  // the test runs.
  redeemedAt: _redeemedMs,
  badge: true,
);

/// Records what the section asked Rust for, without a Rust library.
class _FakeSupportMarksFfi implements shop.SupportMarksFfi {
  bool? badge;
  bool? hidden;
  final removed = <String>[];

  @override
  Future<void> setBadge(bool show) async => badge = show;

  @override
  Future<void> setHidden(bool value) async => hidden = value;

  @override
  Future<void> remove(String item) async => removed.add(item);
}

class _FakeOwnedArt extends OwnedArtNotifier {
  @override
  List<OwnedItem> build() => const [];

  @override
  Future<void> reload() async {}

  @override
  Future<void> wear(OwnedItem item, Set<String> kinds) async {}
}

Future<_FakeSupportMarksFfi> _pump(
  WidgetTester tester, {
  List<shop.OwnSupportCred> creds = const [],
  bool hidden = false,
}) async {
  tester.view.physicalSize = const Size(900, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final ffi = _FakeSupportMarksFfi();

  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(extra: [
        shopAvailableProvider.overrideWithValue(true),
        ownedArtProvider.overrideWith(_FakeOwnedArt.new),
        railBytesProvider.overrideWith((ref, hash) async => null as Uint8List?),
        myWornHashesProvider.overrideWithValue(const <String>{}),
        shop.keptRedeemCodesProvider
            .overrideWith((ref) async => <shop.KeptRedeemCode>[]),
        shop.ownSupportCredsProvider.overrideWith((ref) async => creds),
        shop.supportBadgeProvider.overrideWith((ref) async => true),
        shop.supportMarksHiddenProvider.overrideWith((ref) async => hidden),
        shop.supportMarksFfiProvider.overrideWithValue(ffi),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(
          body: SingleChildScrollView(child: OwnedArtPanel()),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  return ffi;
}

Finder _toggle(String label) => find.byWidgetPredicate(
    (w) => w is HollowToggle && w.semanticLabel == label);

/// Lets a success toast run its course: it schedules a Timer, and the
/// framework fails any test that leaves one pending.
Future<void> _drainToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('both toggles are there, and Hide asks Rust for true',
      (tester) async {
    final ffi = await _pump(tester, creds: [_cred]);

    expect(find.text('SUPPORT MARKS'), findsOneWidget);
    expect(find.text('Hide my support marks'), findsOneWidget);
    expect(
      find.text(
          'Show the mark next to my name in chats and member lists'),
      findsOneWidget,
    );
    expect(_toggle('Hide my support marks'), findsOneWidget);
    expect(_toggle('Show the support mark next to my name'), findsOneWidget);

    await tester.tap(_toggle('Hide my support marks'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));

    expect(ffi.hidden, isTrue);
    expect(ffi.badge, isNull, reason: 'hiding must not touch the glyph setting');
  });

  testWidgets('a held mark lists its title, artist and date', (tester) async {
    await _pump(tester, creds: [_cred]);

    expect(find.text('Gilded frame by Nadia'), findsOneWidget);
    expect(find.text('Redeemed 2026-09-02'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
  });

  testWidgets('Remove asks first, with a danger confirm, then forgets it',
      (tester) async {
    final ffi = await _pump(tester, creds: [_cred]);

    await tester.tap(find.text('Remove'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Remove this mark?'), findsOneWidget);
    expect(
      find.textContaining('The mark for Gilded frame by Nadia leaves your '
          'profile on every device'),
      findsOneWidget,
    );
    final cancel = find.byWidgetPredicate(
        (w) => w is HollowButton && w.variant == HollowButtonVariant.ghost);
    expect(cancel, findsWidgets);

    // The confirm is destructive, so it is the one danger button on screen;
    // the row's own Remove stays a ghost.
    final confirm = find.byWidgetPredicate(
        (w) => w is HollowButton && w.variant == HollowButtonVariant.danger);
    expect(confirm, findsOneWidget);
    expect(ffi.removed, isEmpty,
        reason: 'nothing goes until the dialog is answered');

    await tester.tap(confirm);
    await tester.pump(const Duration(milliseconds: 300));

    expect(ffi.removed, [_item]);
    expect(find.text('Mark removed'), findsOneWidget);
    await _drainToast(tester);
  });

  testWidgets('Cancel leaves the mark alone', (tester) async {
    final ffi = await _pump(tester, creds: [_cred]);

    await tester.tap(find.text('Remove'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(ffi.removed, isEmpty);
    expect(find.text('Remove this mark?'), findsNothing);
  });

  testWidgets('no marks says how to earn one', (tester) async {
    await _pump(tester);

    expect(
      find.text('No marks yet. Redeem a code on the Shop tab to earn one.'),
      findsOneWidget,
    );
    expect(find.text('Remove'), findsNothing);
  });
}
