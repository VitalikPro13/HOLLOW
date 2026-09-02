/// The Hollow Shop wall.
///
/// What this pins: the catalog renders as cards, art you already own says so,
/// the kind pills actually filter, and the item dialog offers Buy for a
/// listing you do not own and Wear it for one you do. Preview art is left
/// hanging on purpose, so the placeholder path is what gets exercised.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/owned_art_provider.dart';
import 'package:hollow/src/core/providers/shop_provider.dart' as shop;
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/shop/shop_dashboard.dart';

import '../helpers/test_app.dart';

const String _frameHash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _bannerHash =
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

const _artist = shop.ShopArtist(
  slug: 'ada',
  displayName: 'Ada',
  bio: 'Draws frames.',
  headerHash: '',
  url: 'https://shop.anonlisten.com/@ada',
);

final _frameListing = shop.ShopListing(
  slug: 'winter-frame',
  title: 'Winter Frame',
  description: 'A cold ring for a cold month.',
  kinds: const ['frame'],
  priceCents: 499,
  priceLabel: r'$4.99',
  // On sale: the list price rides beside it and the card strikes it through.
  wasCents: 699,
  wasLabel: r'$6.99',
  license: 'Personal use',
  createdAt: '2026-09-01',
  artist: _artist,
  files: [
    shop.ShopFile(
      role: 'frame',
      sha256: _frameHash,
      bytes: BigInt.from(4096),
      w: 512,
      h: 512,
      animated: false,
    ),
  ],
  displayHash: _frameHash,
  stillHash: '',
  primaryKind: 'frame',
  bundle: false,
  wide: false,
  itemUrl: 'https://shop.anonlisten.com/i/winter-frame',
);

final _bannerListing = shop.ShopListing(
  slug: 'second-piece',
  title: 'Second Piece',
  description: 'A wide one.',
  kinds: const ['banner'],
  priceCents: 999,
  priceLabel: r'$9.99',
  wasCents: 0,
  wasLabel: '',
  license: 'Personal use',
  createdAt: '2026-09-01',
  artist: _artist,
  files: [
    shop.ShopFile(
      role: 'banner',
      sha256: _bannerHash,
      bytes: BigInt.from(8192),
      w: 1200,
      h: 480,
      animated: false,
    ),
  ],
  displayHash: _bannerHash,
  stillHash: '',
  primaryKind: 'banner',
  bundle: false,
  wide: true,
  itemUrl: 'https://shop.anonlisten.com/i/second-piece',
);

final _catalog = shop.ShopCatalog(
  origin: 'https://shop.anonlisten.com',
  generatedAt: '2026-09-01T00:00:00Z',
  listings: [_frameListing, _bannerListing],
);

/// The frame pack, already imported: this is what turns Buy into Wear it.
const _ownedFrame = OwnedItem(
  itemId: 'item-frame',
  title: 'Winter Frame',
  artistName: 'Ada',
  artistSlug: 'ada',
  artistUrl: '',
  license: 'Personal use',
  importedAt: 1,
  byRole: {
    'frame': network_api.OwnedArt(
      hash: _frameHash,
      role: 'frame',
      itemId: 'item-frame',
      title: 'Winter Frame',
      artistName: 'Ada',
      artistSlug: 'ada',
      artistUrl: '',
      license: 'Personal use',
      importedAt: 1,
    ),
  },
);

class _FakeOwnedArt extends OwnedArtNotifier {
  @override
  List<OwnedItem> build() => [_ownedFrame];

  @override
  Future<void> reload() async {}
}

Future<void> _pumpShop(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(extra: [
        shopAvailableProvider.overrideWithValue(true),
        shop.shopCatalogProvider.overrideWith((ref) async => _catalog),
        shop.shopOriginProvider
            .overrideWith((ref) async => 'https://shop.anonlisten.com'),
        // Preview art never arrives: the cards must render their placeholder
        // rather than wait on bytes.
        shop.shopArtProvider
            .overrideWith((ref, hash) => Completer<Uint8List>().future),
        ownedArtProvider.overrideWith(_FakeOwnedArt.new),
        ownedHashesProvider.overrideWithValue({_frameHash}),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(body: ShopDashboard()),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('renders the catalog, prices and the Owned badge',
      (tester) async {
    await _pumpShop(tester);

    expect(find.text('Winter Frame'), findsOneWidget);
    expect(find.text('Second Piece'), findsOneWidget);
    expect(find.text(r'$4.99'), findsOneWidget);
    // The frame is on sale in the fixture: its list price is on the card too.
    expect(find.text(r'$6.99'), findsOneWidget);
    expect(find.text('Owned'), findsOneWidget);
  });

  testWidgets('a kind pill filters the wall', (tester) async {
    await _pumpShop(tester);

    await tester.tap(find.text('Banners'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Winter Frame'), findsNothing);
    expect(find.text('Second Piece'), findsOneWidget);
  });

  testWidgets('an unowned listing offers Buy', (tester) async {
    await _pumpShop(tester);

    await tester.tap(find.text('Second Piece'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Buy'), findsOneWidget);
    expect(find.text('Wear it'), findsNothing);
  });

  testWidgets('an owned listing offers Wear it instead', (tester) async {
    await _pumpShop(tester);

    await tester.tap(find.text('Winter Frame'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Wear it'), findsOneWidget);
    expect(find.text('Buy'), findsNothing);
  });
}
