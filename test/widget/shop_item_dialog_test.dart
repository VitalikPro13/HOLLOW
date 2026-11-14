/// The shop's item dialog and sheet.
///
/// What this pins: Buy on Ko-fi stays disabled until the buyer ticks the
/// right-to-cancel box, the box is asked again for every piece, the Terms and
/// Refunds links go to the shop's own pages, the artist card shows what the
/// artist gave and nothing more, a store build shows no price, no Buy and no
/// way out to the shop, and long texts lay out at desktop and phone widths
/// with the phone stacking preview, buying decision, then licence and artist.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/owned_art_provider.dart';
import 'package:hollow/src/core/providers/shop_provider.dart' as shop;
import 'package:hollow/src/core/services/untrusted_link.dart';
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_card.dart';
import 'package:hollow/src/ui/components/hollow_checkbox.dart';
import 'package:hollow/src/ui/shop/shop_art.dart';
import 'package:hollow/src/ui/shop/shop_item_dialog.dart';

import '../helpers/test_app.dart';

const _origin = 'https://shop.example';
const _hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _face = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

const _fullArtist = shop.ShopArtist(
  slug: 'nian',
  displayName: 'Nian',
  bio: 'Making cute art with soft colours.',
  headerHash: '',
  avatarHash: _face,
  links: [
    shop.ShopLink(label: 'VGen', url: 'https://vgen.co/Nian11'),
    shop.ShopLink(label: 'TwitterX', url: 'https://x.com/nian_'),
  ],
  url: '$_origin/@nian',
);

const _bareArtist = shop.ShopArtist(
  slug: '',
  displayName: 'Nobody Yet',
  bio: '',
  headerHash: '',
  avatarHash: '',
  links: [],
  url: '',
);

shop.ShopListing _listing({
  String slug = 'sua',
  String title = 'Sua',
  String description = 'School uniform Sua.',
  shop.ShopArtist artist = _fullArtist,
  String buyUrl = 'https://ko-fi.com/s/796ace22d3',
}) =>
    shop.ShopListing(
      slug: slug,
      title: title,
      description: description,
      kinds: const ['avatar'],
      priceCents: 499,
      priceLabel: r'$4.99',
      wasCents: 699,
      wasLabel: r'$6.99',
      license: 'Personal licence: wear it on your profile and keep the files.',
      createdAt: '2026-11-03',
      artist: artist,
      files: [
        shop.ShopFile(
          role: 'avatar',
          sha256: _hash,
          bytes: BigInt.from(4096),
          w: 512,
          h: 512,
          animated: false,
        ),
      ],
      displayHash: _hash,
      stillHash: '',
      primaryKind: 'avatar',
      bundle: false,
      wide: false,
      credentialItem: '',
      itemUrl: '$_origin/item/$slug',
      buyUrl: buyUrl,
    );

class _NoOwnedArt extends OwnedArtNotifier {
  @override
  List<OwnedItem> build() => const [];

  @override
  Future<void> reload() async {}
}

final List<Uri> _opened = [];

Future<void> _pumpHost(
  WidgetTester tester, {
  required List<shop.ShopListing> listings,
  bool available = true,
  Size size = const Size(1280, 1000),
  bool phone = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  debugDefaultTargetPlatformOverride =
      phone ? TargetPlatform.android : TargetPlatform.windows;
  _opened.clear();
  final previous = untrustedLinkLauncher;
  untrustedLinkLauncher = (uri) async {
    _opened.add(uri);
    return true;
  };
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    untrustedLinkLauncher = previous;
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(extra: [
        shopAvailableProvider.overrideWithValue(available),
        shop.shopCatalogProvider.overrideWith((ref) async => shop.ShopCatalog(
            origin: _origin, generatedAt: '', listings: listings)),
        shop.shopOriginProvider.overrideWith((ref) async => _origin),
        // Art never arrives: the placeholders must hold the layout.
        shop.shopArtProvider
            .overrideWith((ref, hash) => Completer<Uint8List>().future),
        ownedArtProvider.overrideWith(_NoOwnedArt.new),
        ownedHashesProvider.overrideWithValue(const {}),
        shop.ownSupportCredsProvider.overrideWith((ref) async => const []),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(children: [
              for (final l in listings)
                TextButton(
                  onPressed: () => showShopItem(context, l),
                  child: Text('open ${l.slug}'),
                ),
            ]),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _open(WidgetTester tester, String slug) async {
  await tester.tap(find.text('open $slug'));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _close(WidgetTester tester) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  navigator.pop();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

HollowButton _buyButton(WidgetTester tester) => tester.widget<HollowButton>(
    find.ancestor(
        of: find.text('Buy on Ko-fi'), matching: find.byType(HollowButton)));

/// The platform override is reset inside the body: the binding checks it
/// before any tearDown runs.
void _testShop(String name, Future<void> Function(WidgetTester) body) =>
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

void main() {
  _testShop('Buy on Ko-fi waits for the right-to-cancel box', (tester) async {
    await _pumpHost(tester, listings: [_listing()]);
    await _open(tester, 'sua');

    expect(find.text(kShopConsent), findsOneWidget);
    expect(find.text(kShopKofiUpfront), findsOneWidget);
    expect(_buyButton(tester).onPressed, isNull,
        reason: 'unticked, Buy must not open Ko-fi');
    await tester.tap(find.text('Buy on Ko-fi'), warnIfMissed: false);
    await tester.pump();
    expect(_opened, isEmpty);

    await tester.tap(find.text(kShopConsent));
    await tester.pump();
    expect(_buyButton(tester).onPressed, isNotNull);
    await tester.tap(find.text('Buy on Ko-fi'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_opened, [Uri.parse('https://ko-fi.com/s/796ace22d3')]);
    await tester.pump(const Duration(seconds: 5));
  });

  _testShop('the box is asked again for every piece', (tester) async {
    await _pumpHost(tester,
        listings: [_listing(), _listing(slug: 'other', title: 'Other')]);
    await _open(tester, 'sua');
    await tester.tap(find.text(kShopConsent));
    await tester.pump();
    expect(tester.widget<HollowCheckbox>(find.byType(HollowCheckbox)).value,
        isTrue);
    await _close(tester);

    await _open(tester, 'other');
    expect(tester.widget<HollowCheckbox>(find.byType(HollowCheckbox)).value,
        isFalse);
    expect(_buyButton(tester).onPressed, isNull);
    await _close(tester);

    await _open(tester, 'sua');
    expect(tester.widget<HollowCheckbox>(find.byType(HollowCheckbox)).value,
        isFalse,
        reason: 'reopening the same piece asks again');
  });

  _testShop('Terms and Refunds open the shop pages', (tester) async {
    await _pumpHost(tester, listings: [_listing()]);
    await _open(tester, 'sua');

    await tester.tap(find.text('Terms'));
    await tester.pump();
    await tester.tap(find.text('Refunds'));
    await tester.pump();
    expect(_opened,
        [Uri.parse('$_origin/terms'), Uri.parse('$_origin/refunds')]);
    expect(tester.widget<HollowCheckbox>(find.byType(HollowCheckbox)).value,
        isFalse,
        reason: 'reading the terms is not agreeing to them');
  });

  _testShop('a piece with no Ko-fi item shows no Buy', (tester) async {
    await _pumpHost(tester, listings: [_listing(buyUrl: '')]);
    await _open(tester, 'sua');

    // Like the site: no Ko-fi item, nothing to buy and nothing to agree to.
    expect(find.byType(HollowCheckbox), findsNothing);
    expect(find.text(kShopKofiUpfront), findsNothing);
    expect(find.textContaining('Buy'), findsNothing);
    expect(find.text(kShopNotOnSale), findsOneWidget);
    expect(_opened, isEmpty);
  });

  _testShop('the disabled Buy names the box it waits for', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpHost(tester, listings: [_listing()]);
    await _open(tester, 'sua');

    final buy = find.ancestor(
        of: find.text('Buy on Ko-fi'), matching: find.byType(HollowButton));
    expect(tester.getSemantics(buy).getSemanticsData().hint, kShopBuyWaitsHint);
    await tester.tap(find.text(kShopConsent));
    await tester.pump();
    expect(tester.getSemantics(buy).getSemanticsData().hint, isEmpty,
        reason: 'ticked, Buy needs no explaining');
    handle.dispose();
  });

  _testShop('the artist card is a step up from the dialog', (tester) async {
    await _pumpHost(tester, listings: [_listing()]);
    await _open(tester, 'sua');

    final card = tester.widget<HollowCard>(find.ancestor(
        of: find.byType(ShopArtistFace), matching: find.byType(HollowCard)));
    final hollow = HollowTheme.of(tester.element(find.byType(ShopArtistFace)));
    expect(card.color, hollow.hover,
        reason: 'inside an overlay the raised step is hover, never elevated');
  });

  _testShop('the phone sheet keeps clear of the home indicator',
      (tester) async {
    tester.view.padding = const FakeViewPadding(bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(() {
      tester.view.resetPadding();
      tester.view.resetViewPadding();
    });
    await _pumpHost(tester,
        listings: [_listing()], size: const Size(375, 800), phone: true);
    await _open(tester, 'sua');

    final scroll = tester.widget<SingleChildScrollView>(find
        .ancestor(
            of: find.byType(ShopTryOnCard),
            matching: find.byType(SingleChildScrollView))
        .first);
    expect((scroll.padding! as EdgeInsets).bottom,
        greaterThanOrEqualTo(34 + HollowSpacing.lg));
  });

  _testShop('the artist card shows the face, bio and links', (tester) async {
    await _pumpHost(tester, listings: [_listing()]);
    await _open(tester, 'sua');

    final face = tester.widget<ShopArtistFace>(find.byType(ShopArtistFace));
    expect(face.hash, _face);
    expect(find.text('Making cute art with soft colours.'), findsOneWidget);
    expect(find.text('VGen'), findsOneWidget);
    expect(find.text('TwitterX'), findsOneWidget);

    await tester.tap(find.text('VGen'));
    await tester.pump();
    await tester.tap(find.text(kShopSeeAllWork));
    await tester.pump();
    expect(_opened,
        [Uri.parse('https://vgen.co/Nian11'), Uri.parse('$_origin/@nian')]);
  });

  _testShop('an artist with nothing but a name', (tester) async {
    await _pumpHost(tester, listings: [_listing(artist: _bareArtist)]);
    await _open(tester, 'sua');

    expect(find.text('Nobody Yet'), findsNWidgets(2),
        reason: 'by the title and on the card');
    expect(tester.widget<ShopArtistFace>(find.byType(ShopArtistFace)).hash, '');
    expect(find.text(kShopSeeAllWork), findsNothing,
        reason: 'no room to send anyone to');
    expect(tester.takeException(), isNull);
  });

  _testShop('a store build shows no price, no Buy and no way out',
      (tester) async {
    await _pumpHost(tester, listings: [_listing()], available: false);
    await _open(tester, 'sua');

    expect(find.text(r'$4.99'), findsNothing);
    expect(find.text('Buy on Ko-fi'), findsNothing);
    expect(find.text('Redeem a code'), findsNothing);
    expect(find.byType(HollowCheckbox), findsNothing);
    expect(find.text(kShopKofiUpfront), findsNothing);
    expect(find.text(kShopSeeAllWork), findsNothing);
    expect(find.text('VGen'), findsNothing);
    // The piece and its maker stay.
    expect(find.text('Sua'), findsOneWidget);
    expect(find.text('Making cute art with soft colours.'), findsOneWidget);
  });

  group('layout', () {
    final longBio = List.filled(40, 'soft colours and small faces').join(' ');
    final longDescription =
        List.filled(30, 'Unofficial fanart, not affiliated with anyone.')
            .join('\n');
    final long = _listing(
      title: 'A title long enough to wrap onto a second line in the dialog',
      description: longDescription,
      artist: shop.ShopArtist(
        slug: 'nian',
        displayName: 'An artist name that goes on and on and on for a while',
        bio: longBio,
        headerHash: '',
        avatarHash: _face,
        links: [
          for (var i = 0; i < 8; i++)
            shop.ShopLink(label: 'Link $i', url: 'https://e$i.example/'),
        ],
        url: '$_origin/@nian',
      ),
    );

    double lineHeightOf(WidgetTester tester, Finder text) {
      final style = tester.widget<Text>(text).style!;
      return style.fontSize! * (style.height ?? 1.2);
    }

    _testShop('desktop: two columns, the bio clamped to two lines',
        (tester) async {
      await _pumpHost(tester, listings: [long], size: const Size(1280, 800));
      await _open(tester, 'sua');
      expect(tester.takeException(), isNull);

      final bio = find.text(longBio);
      expect(tester.getSize(bio).height,
          lessThanOrEqualTo(lineHeightOf(tester, bio) * 2 + 1));
      // The licence and the artist sit under the preview, beside the buying.
      final title = tester.getTopLeft(find.text(long.title));
      final card = tester.getTopLeft(find.byType(ShopArtistFace));
      final preview = tester.getRect(find.byType(ShopTryOnCard));
      expect(card.dx, lessThan(title.dx));
      expect(card.dy, greaterThan(preview.bottom));
      expect(tester.getTopLeft(find.text(long.license)).dx, lessThan(title.dx));
      // A long description scrolls inside the dialog; the box stays reachable.
      await tester.scrollUntilVisible(find.text(kShopConsent), 200,
          scrollable: find.byType(Scrollable).last);
      expect(find.text(kShopConsent).hitTestable(), findsOneWidget);
    });

    _testShop('a narrow desktop window stacks the dialog', (tester) async {
      await _pumpHost(tester, listings: [long], size: const Size(620, 800));
      await _open(tester, 'sua');
      expect(tester.takeException(), isNull);
      final title = tester.getTopLeft(find.text(long.title));
      final preview = tester.getRect(find.byType(ShopTryOnCard));
      expect(title.dy, greaterThan(preview.bottom));
      // The close button sits above the preview, never over the art.
      final close = tester.getRect(find.bySemanticsLabel('Close'));
      expect(close.bottom, lessThanOrEqualTo(preview.top));
    });

    for (final width in [375.0, 320.0]) {
      _testShop('phone at $width: preview, buying, then licence and artist',
          (tester) async {
        await _pumpHost(tester,
            listings: [long], size: Size(width, 800), phone: true);
        await _open(tester, 'sua');
        expect(tester.takeException(), isNull);

        final preview = tester.getRect(find.byType(ShopTryOnCard));
        final title = tester.getTopLeft(find.text(long.title));
        final consent = tester.getTopLeft(find.text(kShopConsent));
        final note = tester.getTopLeft(find.text(kShopKofiUpfront));
        final licence = tester.getTopLeft(find.text(long.license));
        final card = tester.getTopLeft(find.byType(ShopArtistFace));
        expect(title.dy, greaterThan(preview.bottom));
        expect(consent.dy, greaterThan(title.dy));
        expect(note.dy, greaterThan(consent.dy));
        expect(licence.dy, greaterThan(note.dy));
        expect(card.dy, greaterThan(licence.dy));
        // Full-width touch buttons.
        expect(tester.getSize(find.byType(HollowButton).first).width,
            greaterThan(width / 2));
      });
    }
  });
}
