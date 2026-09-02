/// "Art you own" (the Hollow Shop library inside profile settings).
///
/// Three things this pins: the panel lists an ITEM rather than the rail rows
/// it is made of, a kind already on the profile reads "Worn" instead of
/// offering itself again, and pressing Wear asks for exactly that one kind.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/owned_art_provider.dart';
import 'package:hollow/src/core/providers/shop_provider.dart' as shop;
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/shop/owned_art_panel.dart';

import '../helpers/test_app.dart';

const String _frameHash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _avatarAnimHash =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const String _avatarStillHash =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

network_api.OwnedArt _art({
  required String hash,
  required String role,
  required String itemId,
  required String title,
}) =>
    network_api.OwnedArt(
      hash: hash,
      role: role,
      itemId: itemId,
      title: title,
      artistName: 'Ada',
      artistSlug: 'ada',
      artistUrl: '',
      license: 'Personal use',
      importedAt: 1,
    );

final _frameItem = OwnedItem(
  itemId: 'item-frame',
  title: 'Winter Frame',
  artistName: 'Ada',
  artistSlug: 'ada',
  artistUrl: '',
  license: 'Personal use',
  importedAt: 2,
  byRole: {
    'frame': _art(
        hash: _frameHash,
        role: 'frame',
        itemId: 'item-frame',
        title: 'Winter Frame'),
  },
);

final _avatarItem = OwnedItem(
  itemId: 'item-avatar',
  title: 'Second Piece',
  artistName: 'Ada',
  artistSlug: 'ada',
  artistUrl: '',
  license: 'Personal use',
  importedAt: 1,
  byRole: {
    'avatar_anim': _art(
        hash: _avatarAnimHash,
        role: 'avatar_anim',
        itemId: 'item-avatar',
        title: 'Second Piece'),
    'avatar_still': _art(
        hash: _avatarStillHash,
        role: 'avatar_still',
        itemId: 'item-avatar',
        title: 'Second Piece'),
  },
);

/// Records what the panel asked for instead of writing a profile.
class _FakeOwnedArt extends OwnedArtNotifier {
  _FakeOwnedArt(this.items);

  final List<OwnedItem> items;
  OwnedItem? wornItem;
  Set<String>? wornKinds;

  @override
  List<OwnedItem> build() => items;

  @override
  Future<void> reload() async {}

  @override
  Future<void> wear(OwnedItem item, Set<String> kinds) async {
    wornItem = item;
    wornKinds = kinds;
  }
}

Future<_FakeOwnedArt> _pumpPanel(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final fake = _FakeOwnedArt([_frameItem, _avatarItem]);

  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(extra: [
        shopAvailableProvider.overrideWithValue(true),
        ownedArtProvider.overrideWith(() => fake),
        // Thumbnails must survive a cold rail: null bytes take the
        // placeholder path rather than throwing.
        railBytesProvider
            .overrideWith((ref, hash) async => null as Uint8List?),
        myWornHashesProvider.overrideWithValue({_frameHash}),
        shop.keptRedeemCodesProvider
            .overrideWith((ref) async => <shop.KeptRedeemCode>[]),
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
  return fake;
}

void main() {
  testWidgets('lists owned items, and a worn kind says so', (tester) async {
    await _pumpPanel(tester);

    expect(find.text('ART YOU OWN'), findsOneWidget);
    expect(find.text('Import a pack'), findsOneWidget);

    expect(find.text('Winter Frame'), findsOneWidget);
    expect(find.text('Second Piece'), findsOneWidget);

    // The frame is already on the profile; the avatar is not.
    expect(find.text('Worn'), findsOneWidget);
    expect(find.text('Wear frame'), findsNothing);
    expect(find.text('Wear avatar'), findsOneWidget);
  });

  testWidgets('Wear avatar asks for that item and that kind only',
      (tester) async {
    final fake = await _pumpPanel(tester);

    await tester.tap(find.text('Wear avatar'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));

    expect(fake.wornItem?.itemId, 'item-avatar');
    expect(fake.wornKinds, {'avatar'});

    // Let the success toast run its course: it schedules a Timer, and the
    // framework fails any test that leaves one pending.
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 1));
  });
}
