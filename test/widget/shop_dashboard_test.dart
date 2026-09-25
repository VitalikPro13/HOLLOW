/// The Hollow Shop wall.
///
/// What this pins: the catalog renders as one shelf per kind at each kind's
/// shape, art you already own says so, the kind chips actually filter, and the
/// item dialog offers Buy (on Ko-fi when the catalog names it) for a listing
/// you do not own and Wear it for one you do. Preview art is left
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
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/shop/shop_art.dart';
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

/// The credential item hashes the catalog names for each listing.
const _frameItem =
    '1111111111111111111111111111111111111111111111111111111111111111';
const _bannerItem =
    '2222222222222222222222222222222222222222222222222222222222222222';
const _setItem =
    '3333333333333333333333333333333333333333333333333333333333333333';

/// The frame was BOUGHT: a credential for its listing is in our table.
const _frameCred = shop.OwnSupportCred(
  item: _frameItem,
  parts: [_frameHash],
  slug: 'winter-frame',
  title: 'Winter Frame',
  artistName: 'Ada',
  redeemedAt: 1,
  badge: true,
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
  buyUrl: '',
  credentialItem: _frameItem,
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
  // Sold on the artist's Ko-fi: Buy goes there and says so.
  buyUrl: 'https://ko-fi.com/s/b2c3d4e5f6',
  credentialItem: _bannerItem,
);

/// A set carrying the frame AND the banner: owning the frame alone must not
/// mark it Owned (one shared file is not ownership).
final _setListing = shop.ShopListing(
  slug: 'winter-set',
  title: 'Winter Set',
  description: 'The frame and the banner together.',
  kinds: const ['frame', 'banner'],
  priceCents: 1299,
  priceLabel: r'$12.99',
  wasCents: 0,
  wasLabel: '',
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
  bundle: true,
  wide: true,
  itemUrl: 'https://shop.anonlisten.com/i/winter-set',
  buyUrl: '',
  credentialItem: _setItem,
);

final _catalog = shop.ShopCatalog(
  origin: 'https://shop.anonlisten.com',
  generatedAt: '2026-09-01T00:00:00Z',
  listings: [_frameListing, _bannerListing, _setListing],
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

/// The banner pack is in the library too, but handed over, never bought: no
/// credential, so no Owned.
const _ownedBanner = OwnedItem(
  itemId: 'item-banner',
  title: 'Second Piece',
  artistName: 'Ada',
  artistSlug: 'ada',
  artistUrl: '',
  license: 'Personal use',
  importedAt: 1,
  byRole: {
    'banner': network_api.OwnedArt(
      hash: _bannerHash,
      role: 'banner',
      itemId: 'item-banner',
      title: 'Second Piece',
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
  List<OwnedItem> build() => [_ownedFrame, _ownedBanner];

  @override
  Future<void> reload() async {}
}

Future<void> _pumpShop(WidgetTester tester) async {
  // Tall enough that every shelf is built: the page is a lazy list.
  tester.view.physicalSize = const Size(1280, 1600);
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
        ownedHashesProvider.overrideWithValue({_frameHash, _bannerHash}),
        shop.ownSupportCredsProvider.overrideWith((ref) async => [_frameCred]),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(body: ShopDashboard()),
      ),
    ),
  );
  // Two frames: the catalog lands in the first, the credentials table (a
  // second future) redraws the cards in the second.
  await tester.pump(const Duration(milliseconds: 400));
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
    // Owned follows the CREDENTIAL, not the library: the frame was bought;
    // the banner is in the library (a handed-over pack) with no credential,
    // and the set shares the frame's file with no credential of its own.
    // One badge, on the frame.
    expect(find.text('Winter Set'), findsOneWidget);
    expect(find.text('Owned'), findsOneWidget);
  });

  testWidgets('a kind pill filters the wall', (tester) async {
    await _pumpShop(tester);

    await tester.tap(find.widgetWithText(HollowChip, 'Banners'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Winter Frame'), findsNothing);
    expect(find.text('Second Piece'), findsOneWidget);
  });

  testWidgets('a handed-over pack offers Wear it AND Buy, never Owned',
      (tester) async {
    await _pumpShop(tester);

    // Second Piece is in the library (somebody could have shared the pack)
    // but no code was redeemed for it: the art can be worn, the purchase is
    // still open.
    await tester.tap(find.text('Second Piece'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Wear it'), findsOneWidget);
    expect(find.text('Buy on Ko-fi'), findsOneWidget);
  });

  testWidgets('a bought listing offers Wear it and no Buy', (tester) async {
    await _pumpShop(tester);

    await tester.tap(find.text('Winter Frame'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Wear it'), findsOneWidget);
    expect(find.text('Buy'), findsNothing);
  });

  testWidgets('a set whose files are all in the library still sells', (tester) async {
    await _pumpShop(tester);

    // The set's files are in the library only across TWO single packs; no one
    // imported pack covers the set, so it is not worn as a set from here (each
    // piece is worn from its own card), and no credential names it, so it is
    // not bought: Buy alone.
    await tester.tap(find.text('Winter Set'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Wear it'), findsNothing);
    expect(find.text('Buy'), findsOneWidget);
  });

  testWidgets('each kind sits on its own shelf, at its own shape',
      (tester) async {
    await _pumpShop(tester);

    for (final title in ['Frames', 'Banners', 'Bundles']) {
      expect(find.widgetWithText(HollowChip, title), findsOneWidget);
    }
    // Shelf headers name the kind, so no card repeats it as a badge.
    expect(find.text('frame'), findsNothing);
    expect(find.text('banner'), findsNothing);

    final frame = tester.getSize(find.byType(ShopFrameArt));
    expect(frame.width, moreOrLessEquals(frame.height, epsilon: 0.5));
    // The banner and the set are both wide, at the one banner ratio.
    for (final art in [ShopArtFill, ShopBundleArt]) {
      final size = tester.getSize(find.byType(art).first);
      expect(size.width / size.height,
          moreOrLessEquals(kShopBannerAspect, epsilon: 0.02));
    }
  });

  testWidgets('the intro says made, not drawn', (tester) async {
    await _pumpShop(tester);
    expect(find.textContaining('made by real people'), findsOneWidget);
  });
}
