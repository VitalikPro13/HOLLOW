import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/banner_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/owned_art_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/shop_provider.dart' as shop;
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/shop/shop_art.dart';
import 'package:hollow/src/ui/shop/shop_dashboard.dart';

/// Screenshot harness for the Shop's shelves and its item view at phone and
/// desktop sizes. Art comes from `$HOLLOW_SHOP_ART_DIR` when set (any real
/// pictures, named as in [_files]); otherwise flat colour stands in, which is
/// enough to judge the layout. Every test still passes as "builds and
/// settles".
///
/// Output dir: $HOLLOW_SHOT_DIR, falling back to build/ui_screenshots.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  const me = 'me_peer_aaaaaaaaaaaaaaaa';

  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${Platform.pathSeparator}build'
          '${Platform.pathSeparator}ui_screenshots';
  final artDir = Platform.environment['HOLLOW_SHOP_ART_DIR'];

  final art = <String, Uint8List>{};

  setUpAll(() async {
    final lucide =
        await rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf');
    await (FontLoader('packages/lucide_icons_flutter/Lucide')
          ..addFont(Future.value(lucide)))
        .load();
    for (final face in Directory('assets/fonts').listSync()) {
      final name = face.uri.pathSegments.last;
      if (!name.endsWith('.ttf') ||
          !(name.startsWith('Onest') || name.startsWith('GeistMono'))) {
        continue;
      }
      final family = name.startsWith('Onest') ? 'Onest' : 'GeistMono';
      final bytes = File(face.path).readAsBytesSync();
      await (FontLoader(family)
            ..addFont(Future.value(ByteData.view(bytes.buffer))))
          .load();
    }

    for (final entry in _files.entries) {
      final path = artDir == null
          ? null
          : '$artDir${Platform.pathSeparator}${entry.value}';
      if (path != null && File(path).existsSync()) {
        art[entry.key] = File(path).readAsBytesSync();
      } else {
        art[entry.key] = await _flat(entry.key);
      }
    }
  });

  List<Override> overrides() => [
        shopAvailableProvider.overrideWithValue(true),
        shop.shopCatalogProvider.overrideWith((ref) async => _catalog),
        shop.shopOriginProvider
            .overrideWith((ref) async => 'https://shop.anonlisten.com'),
        shop.shopArtProvider.overrideWith((ref, hash) async =>
            art[hash] ?? Uint8List(0)),
        shop.ownSupportCredsProvider.overrideWith((ref) async => [_boughtCred]),
        ownedArtProvider.overrideWith(_NoOwnedArt.new),
        identityProvider.overrideWith(_Identity.new),
        profileProvider.overrideWith(_Profiles.new),
        avatarProvider.overrideWith(() => _Avatars(art[_hMe]!)),
        bannerProvider(me).overrideWith((ref) async => null),
      ];

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await tester.runAsync(() async {
      try {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (data == null) return;
        final file = File('$outDir${Platform.pathSeparator}$name.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(data.buffer.asUint8List());
        debugPrint('[screenshot] wrote ${file.path}');
      } catch (e) {
        debugPrint('[screenshot] skipped $name: $e');
      }
    });
  }

  Future<void> pumpShop(WidgetTester tester, Size size,
      {required bool phone}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    debugDefaultTargetPlatformOverride =
        phone ? TargetPlatform.android : TargetPlatform.windows;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.runAsync(() async {
      await tester.pumpWidget(ProviderScope(
        overrides: overrides(),
        child: RepaintBoundary(
          key: shotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: HollowThemeData.dark().copyWith(
              textTheme: HollowThemeData.dark()
                  .textTheme
                  .apply(fontFamily: 'Onest'),
            ),
            home: Scaffold(body: ShopDashboard(embedded: phone)),
          ),
        ),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> settleImages(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('desktop shelves', (tester) async {
    await pumpShop(tester, const Size(1280, 1100), phone: false);
    expect(find.byType(ShopFrameArt), findsWidgets);
    await capture(tester, 'shop-desktop-all');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('desktop item dialog', (tester) async {
    await pumpShop(tester, const Size(1280, 900), phone: false);
    await tester.scrollUntilVisible(find.text('Listening set'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pump();
    await tester.tap(find.text('Listening set'));
    await settleImages(tester);
    expect(find.text('Buy on Ko-fi'), findsOneWidget);
    await capture(tester, 'shop-desktop-item');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phone shelves', (tester) async {
    await pumpShop(tester, const Size(390, 1500), phone: true);
    await capture(tester, 'shop-phone-all');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phone item sheet', (tester) async {
    await pumpShop(tester, const Size(390, 844), phone: true);
    await tester.tap(find.text('Night shift').first);
    await settleImages(tester);
    await capture(tester, 'shop-phone-item');
    debugDefaultTargetPlatformOverride = null;
  });
}

Future<Uint8List> _flat(String seed) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final hue = (seed.codeUnitAt(0) * 37) % 360;
  canvas.drawRect(const Rect.fromLTWH(0, 0, 64, 64),
      Paint()..color = HSLColor.fromAHSL(1, hue.toDouble(), 0.4, 0.45).toColor());
  final image = await recorder.endRecording().toImage(64, 64);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

String _h(String c) => List.filled(64, c).join();
final _hMe = _h('0');
final _hHead = _h('1');
final _hNightStill = _h('2');
final _hNightAnim = _h('3');
final _hAnon = _h('4');
final _hCircuit = _h('5');
final _hLaurel = _h('6');
final _hSakura = _h('7');
final _hBanner = _h('8');

final _files = {
  _hMe: 'avatar_v13.jpg',
  _hHead: 'avatar_v13.jpg',
  _hNightStill: 'avatar_anim_still.png',
  _hNightAnim: 'avatar_anim.gif',
  _hAnon: 'avatar_anon.png',
  _hCircuit: 'frame_circuit.png',
  _hLaurel: 'frame_laurel.png',
  _hSakura: 'frame_sakura.png',
  _hBanner: 'banner_1200x480.png',
};

const _artist = shop.ShopArtist(
  slug: 'mira',
  displayName: 'Mira K.',
  bio: '',
  headerHash: '',
  url: 'https://shop.anonlisten.com/@mira',
);

shop.ShopFile _file(String role, String hash, {bool anim = false}) =>
    shop.ShopFile(
      role: role,
      sha256: hash,
      bytes: BigInt.from(1024),
      w: role.startsWith('banner') ? 1200 : 512,
      h: role.startsWith('banner') ? 480 : 512,
      animated: anim,
    );

shop.ShopListing _listing(
  String slug,
  String title,
  List<String> kinds,
  List<shop.ShopFile> files, {
  required String display,
  String still = '',
  String price = r'$4.99',
  String was = '',
  bool bundle = false,
  String credential = '',
}) =>
    shop.ShopListing(
      slug: slug,
      title: title,
      description: 'Placeholder art to judge the layout with.',
      kinds: kinds,
      priceCents: 499,
      priceLabel: price,
      wasCents: was.isEmpty ? 0 : 699,
      wasLabel: was,
      license: 'For your own profile. Not for resale.',
      createdAt: '2026-09-25',
      artist: _artist,
      files: files,
      displayHash: display,
      stillHash: still,
      primaryKind: bundle ? 'banner' : kinds.first,
      bundle: bundle,
      wide: kinds.first == 'banner' || bundle,
      credentialItem: credential,
      itemUrl: 'https://shop.anonlisten.com/item/$slug',
      buyUrl: 'https://ko-fi.com/s/a1b2c3d4e5',
    );

final _boughtItem = _h('b');
final _boughtCred = shop.OwnSupportCred(
  item: _boughtItem,
  parts: [_hHead],
  slug: 'headphones',
  title: 'Headphones',
  artistName: 'Mira K.',
  redeemedAt: 1,
  badge: true,
);

final _catalog = shop.ShopCatalog(
  origin: 'https://shop.anonlisten.com',
  generatedAt: '2026-09-25T00:00:00Z',
  listings: [
    _listing('headphones', 'Headphones', ['avatar'], [_file('avatar', _hHead)],
        display: _hHead, credential: _boughtItem),
    _listing('night-shift', 'Night shift', ['avatar'], [
      _file('avatar_anim', _hNightAnim, anim: true),
      _file('avatar_still', _hNightStill),
    ],
        display: _hNightAnim, still: _hNightStill, price: r'$6.99'),
    _listing('listening', 'Listening', ['avatar'], [_file('avatar', _hAnon)],
        display: _hAnon, price: r'$3.99', was: r'$5.99'),
    _listing('circuit', 'Circuit', ['frame'], [_file('frame', _hCircuit)],
        display: _hCircuit, price: r'$2.99'),
    _listing('laurel', 'Laurel', ['frame'], [_file('frame', _hLaurel)],
        display: _hLaurel, price: r'$3.99'),
    _listing('sakura', 'Sakura', ['frame'], [_file('frame', _hSakura)],
        display: _hSakura),
    _listing('listening-banner', 'Listening', ['banner'],
        [_file('banner', _hBanner)],
        display: _hBanner, price: r'$5.99'),
    _listing('afterglow', 'Afterglow', ['banner'], [_file('banner', _hBanner)],
        display: _hBanner, was: r'$6.99'),
    _listing('listening-set', 'Listening set', ['banner', 'avatar', 'frame'], [
      _file('banner', _hBanner),
      _file('avatar', _hAnon),
      _file('frame', _hCircuit),
    ],
        display: _hBanner, price: r'$9.99', was: r'$12.97', bundle: true),
  ],
);

class _NoOwnedArt extends OwnedArtNotifier {
  @override
  List<OwnedItem> build() => const [];

  @override
  Future<void> reload() async {}
}

class _Identity extends IdentityNotifier {
  @override
  IdentityState build() =>
      const IdentityState(peerId: 'me_peer_aaaaaaaaaaaaaaaa', isLoaded: true);
}

class _Profiles extends ProfileNotifier {
  @override
  Map<String, storage_api.UserProfile> build() => {
        'me_peer_aaaaaaaaaaaaaaaa': const storage_api.UserProfile(
          peerId: 'me_peer_aaaaaaaaaaaaaaaa',
          displayName: 'Vitalik',
          status: 'Mixing the new EP',
          aboutMe: '',
          updatedAt: 0,
          twitchUsername: '',
          showcaseBoard: '',
          avatarFrame: '',
          avatarAnim: '',
          bannerAnim: '',
          supportCreds: '',
        ),
      };
}

class _Avatars extends AvatarNotifier {
  final Uint8List bytes;
  _Avatars(this.bytes);

  @override
  Map<String, Uint8List> build() => {'me_peer_aaaaaaaaaaaaaaaa': bytes};

  @override
  Future<void> loadAvatar(String peerId) async {}
}
