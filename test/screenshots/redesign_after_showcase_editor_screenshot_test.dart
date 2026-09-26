import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart'
    show OnlineIdentitiesNotifier, onlineIdentitiesProvider;
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/showcase.dart' as showcase_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/dialogs/showcase_editor.dart';

import '../helpers/test_app.dart';

/// "After" renders of the showcase editor: the profile dialog in edit mode
/// (filled, empty, adding, finding a game, editing in place, a full side, the
/// wide artwork, a narrower window) and the phone page. Fixtures and art are
/// copied from redesign_after_profile_screenshot_test.dart.
///
/// Output: $HOLLOW_SHOT_DIR/redesign_after, else
/// build/ui_screenshots/redesign_after.
final _desktop = TargetPlatformVariant.only(TargetPlatform.windows);
final _phone = TargetPlatformVariant.only(TargetPlatform.android);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');

  final outDir =
      '${Platform.environment['HOLLOW_SHOT_DIR'] ?? '${Directory.current.path}${Platform.pathSeparator}build${Platform.pathSeparator}ui_screenshots'}'
      '${Platform.pathSeparator}redesign_after';

  final api = _Api();

  setUpAll(() async {
    RustLib.initMock(api: api);

    final lucide = await rootBundle.load(
      'packages/lucide_icons_flutter/assets/lucide.ttf',
    );
    await (FontLoader(
      'packages/lucide_icons_flutter/Lucide',
    )..addFont(Future.value(lucide))).load();
    try {
      final material = rootBundle.load('fonts/MaterialIcons-Regular.otf');
      await (FontLoader('MaterialIcons')..addFont(material)).load();
    } catch (_) {
      /* Material glyphs fall back to boxes */
    }
    final families = <String, List<ByteData>>{};
    for (final face in Directory('assets/fonts').listSync()) {
      final name = face.uri.pathSegments.last;
      if (!name.endsWith('.ttf')) continue;
      final family = name.startsWith('Onest')
          ? 'Onest'
          : name.startsWith('GeistMono')
          ? 'GeistMono'
          : name.startsWith('SimpleIcons')
          ? 'SimpleIcons'
          : null;
      if (family == null) continue;
      final bytes = File(face.path).readAsBytesSync();
      families.putIfAbsent(family, () => []).add(ByteData.view(bytes.buffer));
    }
    for (final e in families.entries) {
      final loader = FontLoader(e.key);
      for (final b in e.value) {
        loader.addFont(Future.value(b));
      }
      await loader.load();
    }

    await _Art.build();
    api.assets = _Art.assetList();
  });

  // ---------------------------------------------------------------- helpers

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(shotKey),
    );
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

  /// Lets real image decodes land, then paints them. Fixed pumps, never
  /// pumpAndSettle: spinners and indeterminate bars never settle.
  Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  late BuildContext hostContext;
  late WidgetRef hostRef;

  /// An empty app shell; the dialog under test is opened from [hostContext].
  Future<void> pumpHost(
    WidgetTester tester, {
    required Size size,
    bool light = false,
    List<Override> extra = const [],
    Widget? home,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: hollowTestOverrides(extra: [..._baseOverrides(), ...extra]),
        child: RepaintBoundary(
          key: shotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
            home:
                home ??
                Scaffold(
                  body: Consumer(
                    builder: (context, ref, _) {
                      hostContext = context;
                      hostRef = ref;
                      return const SizedBox.expand();
                    },
                  ),
                ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Opens the editor from the host and lets pictures land.
  Future<void> openEditor(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    bool light = false,
    String? board,
  }) async {
    _Profiles.meBoard = board;
    await pumpHost(tester, size: size, light: light);
    showShowcaseEditorDialog(hostContext, hostRef);
    await tester.pump();
    await settle(tester, rounds: 8);
  }

  Future<void> hover(WidgetTester tester, Finder target) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 200));
    // The hover fill and toolbar fade in over the next frames.
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> search(WidgetTester tester) async {
    await tester.tap(find.text('Add block').last);
    await settle(tester, rounds: 3);
    await tester.tap(find.text('Favourite game').last);
    await settle(tester, rounds: 3);
    await tester.enterText(find.byType(EditableText).last, 'outer');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester, rounds: 4);
  }

  testWidgets('editor: filled, a block hovered', (t) async {
    await openEditor(t);
    await hover(t, find.text('Outer Wilds'));
    await capture(t, 'editor_filled_dark');
  }, variant: _desktop);

  testWidgets('editor: light', (t) async {
    await openEditor(t, light: true);
    await hover(t, find.text('Outer Wilds'));
    await capture(t, 'editor_filled_light');
  }, variant: _desktop);

  testWidgets('editor: empty boards', (t) async {
    await openEditor(t, board: '');
    await capture(t, 'editor_empty_dark');
  }, variant: _desktop);

  testWidgets('editor: Add block menu', (t) async {
    await openEditor(t, board: _boardLeft);
    await t.tap(find.text('Add block').last);
    await settle(t, rounds: 3);
    await capture(t, 'editor_add_menu_dark');
  }, variant: _desktop);

  testWidgets('editor: finding a game, one layer', (t) async {
    await openEditor(t, board: _boardLeft);
    await search(t);
    await capture(t, 'editor_search_dark');
  }, variant: _desktop);

  testWidgets('editor: a picked favourite asks why', (t) async {
    await openEditor(t, board: _boardLeft);
    await search(t);
    await t.tap(find.text('Outer Wilds: Echoes of the Eye'));
    await settle(t, rounds: 6);
    await capture(t, 'editor_picked_dark');
  }, variant: _desktop);

  testWidgets('editor: caption in place', (t) async {
    await openEditor(t);
    await t.tap(find.bySemanticsLabel('Edit caption').first);
    await settle(t, rounds: 3);
    await capture(t, 'editor_caption_dark');
  }, variant: _desktop);

  testWidgets('editor: text in place', (t) async {
    await openEditor(t);
    await t.tap(find.bySemanticsLabel('Edit text').first);
    await settle(t, rounds: 3);
    await capture(t, 'editor_text_dark');
  }, variant: _desktop);

  testWidgets('editor: shelf in place', (t) async {
    await openEditor(t);
    await t.tap(find.bySemanticsLabel('Edit shelf').first);
    await settle(t, rounds: 3);
    await capture(t, 'editor_shelf_dark');
  }, variant: _desktop);

  testWidgets('editor: a full side and the size limit', (t) async {
    await openEditor(t, board: _boardCap);
    await capture(t, 'editor_cap_dark');
  }, variant: _desktop);

  testWidgets('editor: wide artwork', (t) async {
    await openEditor(t, board: _boardWide);
    await hover(t, find.text('The whole night shift, one piece'));
    await capture(t, 'editor_wide_dark');
  }, variant: _desktop);

  testWidgets('editor: 1100 window, one column', (t) async {
    await openEditor(t, size: const Size(1100, 800));
    await capture(t, 'editor_1100_dark');
  }, variant: _desktop);

  testWidgets('editor: phone', (t) async {
    await openEditor(t, size: const Size(390, 844));
    await capture(t, 'editor_phone_dark');
    await t.tap(find.bySemanticsLabel('Favourite game options'));
    await settle(t, rounds: 4);
    await capture(t, 'editor_phone_sheet_dark');
  }, variant: _phone);

  testWidgets('editor: phone, light', (t) async {
    await openEditor(t, size: const Size(390, 844), light: true);
    await capture(t, 'editor_phone_light');
  }, variant: _phone);
}

const _me = 'me_peer_aaaaaaaaaaaaaaaa';
const _miraBoth = 'peer_mira_both_000000001';
const _miraLeft = 'peer_mira_left_000000002';
const _miraNone = 'peer_mira_none_000000003';
const _juno = 'peer_juno_plain_00000004';
const _miraWide = 'peer_mira_wide_000000005';
const _srvSmall = 'srv-small';
const _srvBig = 'srv-big';

String _h(String c) => List.filled(64, c).join();
final _hBanner = _h('0');
final _hAvatar = _h('1');
final _hCoverA = _h('2');
final _hCoverB = _h('3');
final _hCoverC = _h('4');
final _hCoverD = _h('5');
final _hCoverE = _h('6');
final _hCoverF = _h('7');
final _hArtA = _h('8');
final _hArtB = _h('9');
final _hArtwork = _h('a');
final _hLogo1 = _h('b');
final _hLogo2 = _h('c');
final _hDetA = _h('d');
final _hDetB = _h('e');

Map<String, dynamic> _nowPlaying() => {
  't': 'now_playing',
  'd': {
    'name': 'Hollow Knight: Silksong',
    'year': 2025,
    'cover': _hCoverA,
    'art': _hArtA,
    'details': _hDetA,
  },
};

Map<String, dynamic> _text() => {
  't': 'text',
  'd': {
    'title': 'Currently',
    'body':
        'Painting avatar frames for the **Shop**. Ask me about '
        '*pixel art* or `lossless WebP`. ||The tea is cold again.||',
  },
};

Map<String, dynamic> _favorite() => {
  't': 'favorite_game',
  'd': {
    'name': 'Outer Wilds',
    'year': 2019,
    'cover': _hCoverB,
    'art': _hArtB,
    'details': _hDetB,
    'blurb': 'Twenty-two minutes I will never forget.',
  },
};

Map<String, dynamic> _shelf() => {
  't': 'game_shelf',
  'd': {
    'label': 'Backlog',
    'games': [
      {'name': 'Tunic', 'cover': _hCoverC},
      {'name': 'Celeste', 'cover': _hCoverD},
      {'name': 'Hades II', 'cover': _hCoverE},
      {'name': 'Disco Elysium', 'cover': _hCoverF},
    ],
  },
};

Map<String, dynamic> _artwork() => {
  't': 'artwork',
  'd': {'image': _hArtwork, 'caption': 'Frame sketch, night shift'},
};

String get _boardFull => jsonEncode({
  'v': 1,
  'left': [_nowPlaying(), _text()],
  'right': [_favorite(), _shelf(), _artwork()],
});

String get _boardWide => jsonEncode({
  'v': 1,
  'wide': {
    't': 'artwork',
    'd': {'image': _hArtwork, 'caption': 'The whole night shift, one piece'},
  },
  'left': [_nowPlaying(), _text()],
  'right': [_favorite(), _shelf()],
});

String get _boardCap => jsonEncode({
  'v': 1,
  'left': [
    _nowPlaying(),
    {
      't': 'favorite_game',
      'd': {
        'name': 'A game with far too much baked in',
        'year': 2024,
        'details': {'summary': 'x' * 15000},
      },
    },
  ],
  'right': [_favorite(), _shelf(), _artwork(), _text()],
});

String get _boardLeft => jsonEncode({
  'v': 1,
  'left': [_nowPlaying(), _text(), _artwork()],
});

final _detailsB = {
  'description':
      'Outer Wilds is an open world mystery about a solar system trapped in '
      'an endless time loop. Explore a hand-crafted system at your own '
      'pace, and piece together what happened before the sun goes out.',
  'metacritic': 85,
  'achievements': 31,
  'genres': ['Adventure', 'Puzzle', 'Simulator'],
  'themes': ['Science fiction', 'Open world'],
  'modes': ['Single player'],
  'franchise': '',
  'steam_reviews': {
    'label': 'Overwhelmingly Positive',
    'pos': 98120,
    'total': 102740,
  },
  'ttb': {'normally': 79200, 'completely': 108000},
  'platforms': ['pc', 'playstation', 'xbox', 'nintendo'],
  'release_date': '28 May, 2019',
  'req_min':
      'OS: Windows 7\nProcessor: Intel Core i5-2300\nMemory: 6 GB RAM\n'
      'Graphics: GeForce GTX 660\nStorage: 8 GB available space',
  'req_rec':
      'OS: Windows 10\nProcessor: Intel Core i5-8400\nMemory: 8 GB RAM\n'
      'Graphics: GeForce GTX 1060\nStorage: 8 GB available space',
  'legal': 'Outer Wilds © Mobius Digital. Published by Annapurna Interactive.',
  'stores': {'steam': 'https://store.steampowered.com/app/753640'},
  'companies': [
    {
      'name': 'Mobius Digital',
      'role': 'dev',
      'logo': _hLogo1,
      'links': [
        {'kind': 'official', 'url': 'https://www.mobiusdigitalgames.com'},
        {'kind': 'twitter', 'url': 'https://twitter.com/mobiusdigital'},
      ],
    },
    {
      'name': 'Annapurna Interactive',
      'role': 'pub',
      'logo': _hLogo2,
      'links': [
        {'kind': 'official', 'url': 'https://annapurnainteractive.com'},
      ],
    },
  ],
};

final _detailsA = {
  'description':
      'Discover a vast haunted kingdom in the sequel to the '
      'award-winning action-adventure.',
  'metacritic': 91,
  'genres': ['Platform', 'Adventure'],
  'platforms': ['pc', 'playstation', 'xbox', 'nintendo'],
  'release_date': '4 Sep, 2025',
  'req_min': 'OS: Windows 10\nMemory: 4 GB RAM',
  'companies': [
    {'name': 'Team Cherry', 'role': 'devpub', 'logo': _hLogo1},
  ],
};

storage_api.UserProfile _profile(
  String peer,
  String name, {
  String status = '',
  String about = '',
  String board = '',
  String frame = '',
}) => storage_api.UserProfile(
  peerId: peer,
  displayName: name,
  status: status,
  aboutMe: about,
  updatedAt: 0,
  twitchUsername: '',
  showcaseBoard: board,
  avatarFrame: frame,
  avatarAnim: '',
  bannerAnim: '',
  supportCreds: '',
);

const _miraStatus = 'Painting frames tonight';
const _miraAbout =
    'I draw avatar frames and banners for the Shop. Mostly night shifts, '
    'lots of tea. Ask me about pixel art, lossless WebP or why every '
    'banner is 2.5 to 1.';

List<Override> _baseOverrides() => [
  identityProvider.overrideWith(_Identity.new),
  profileProvider.overrideWith(_Profiles.new),
  avatarProvider.overrideWith(_Avatars.new),
  friendsProvider.overrideWith(_Friends.new),
  onlineIdentitiesProvider.overrideWith(_Online.new),
  for (final sid in [_srvSmall, _srvBig]) ...[
    myRoleProvider(sid).overrideWith((ref) async => 'owner'),
    myPermissionsProvider(sid).overrideWith((ref) async => Permission.all),
    serverMembersProvider(sid).overrideWith(
      (ref) async => [
        for (var i = 0; i < (sid == _srvBig ? 12 : 3); i++)
          crdt_api.MemberFfi(
            peerId: 'peer_member_${sid}_$i',
            displayName: 'Member $i',
            role: i == 0 ? 'owner' : 'member',
            nickname: '',
            twitchUsername: '',
            labels: const [],
          ),
      ],
    ),
  ],
];

class _Identity extends IdentityNotifier {
  @override
  IdentityState build() => const IdentityState(peerId: _me, isLoaded: true);
}

class _Profiles extends ProfileNotifier {
  static String? meBoard;

  @override
  Map<String, storage_api.UserProfile> build() => {
    _me: _profile(
      _me,
      'Sam',
      status: 'Hosting the relay this week',
      about: 'Runs the book club server.',
      board: meBoard ?? _boardFull,
      frame: 'b:250',
    ),
    _miraBoth: _profile(
      _miraBoth,
      'Mira',
      status: _miraStatus,
      about: _miraAbout,
      board: _boardFull,
      frame: 'b:168',
    ),
    _miraLeft: _profile(
      _miraLeft,
      'Mira',
      status: _miraStatus,
      about: _miraAbout,
      board: _boardLeft,
      frame: 'b:168',
    ),
    _miraNone: _profile(
      _miraNone,
      'Mira',
      status: _miraStatus,
      about: _miraAbout,
      frame: 'b:168',
    ),
    _miraWide: _profile(
      _miraWide,
      'Mira',
      status: _miraStatus,
      about: _miraAbout,
      board: _boardWide,
      frame: 'b:168',
    ),
    _juno: _profile(_juno, 'Juno'),
  };
}

class _Avatars extends AvatarNotifier {
  @override
  Map<String, Uint8List> build() => {
    for (final p in [_me, _miraBoth, _miraLeft, _miraNone, _miraWide])
      p: _Art.bytes[_hAvatar]!,
  };

  @override
  Future<void> loadAvatar(String peerId) async {}
}

class _Friends extends FriendsNotifier {
  @override
  Map<String, FriendInfo> build() => {
    for (final p in [_miraBoth, _miraLeft, _miraNone, _miraWide])
      p: FriendInfo(
        peerId: p,
        status: 'accepted',
        direction: '',
        requestedAt: 0,
        updatedAt: 0,
      ),
  };
}

class _Online extends OnlineIdentitiesNotifier {
  @override
  Set<String> build() => {_miraBoth, _miraLeft, _miraNone, _miraWide};
}

// ====================================================================== FFI

class _Api implements RustLibApi {
  List<showcase_api.ShowcaseAsset> assets = const [];

  @override
  Future<Uint8List?> crateApiStorageGetBanner({required String peerId}) async =>
      peerId == _juno ? null : _Art.bytes[_hBanner];

  @override
  Future<Uint8List?> crateApiStorageGetAvatar({required String peerId}) async =>
      peerId == _juno ? null : _Art.bytes[_hAvatar];

  @override
  Future<List<showcase_api.ShowcaseAsset>> crateApiShowcaseGetShowcaseAssets({
    required String peerId,
  }) async => assets;

  @override
  Future<List<showcase_api.GameSearchResult>>
  crateApiShowcaseShowcaseGameSearch({required String query}) async => const [
    showcase_api.GameSearchResult(
      id: 1,
      name: 'Outer Wilds',
      year: 2019,
      gameType: 'Main Game',
    ),
    showcase_api.GameSearchResult(
      id: 2,
      name: 'Outer Wilds: Echoes of the Eye',
      year: 2021,
      gameType: 'DLC',
    ),
    showcase_api.GameSearchResult(
      id: 3,
      name: 'The Outer Worlds',
      year: 2019,
      gameType: 'Main Game',
    ),
    showcase_api.GameSearchResult(
      id: 4,
      name: 'Outer Wilds Archaeologist Edition',
      year: 2023,
      gameType: 'Main Game',
    ),
  ];

  @override
  Future<showcase_api.ShowcaseAsset> crateApiShowcaseShowcaseFetchCover({
    required String url,
  }) async => throw StateError('offline');

  @override
  Future<showcase_api.GameCardDetails?> crateApiShowcaseShowcaseGameDetails({
    required int gameId,
  }) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ======================================================================= art

/// Test art drawn in-process. Every piece carries coloured EDGE BANDS (orange
/// left, lime right, cyan top, pink bottom) and a centre crosshair, so any
/// crop, stretch or offset shows at a glance.
class _Art {
  static final Map<String, Uint8List> bytes = {};

  static List<showcase_api.ShowcaseAsset> assetList() => [
    for (final e in bytes.entries)
      if (e.key != _hBanner && e.key != _hAvatar)
        showcase_api.ShowcaseAsset(hash: e.key, bytes: e.value),
  ];

  static Future<void> build() async {
    bytes[_hBanner] = await _png(1200, 480, (c, s) {
      _gradient(c, s, const Color(0xFF1B3B5A), const Color(0xFF6B2D5C));
      _stripes(c, s);
      _grid(c, s, 100);
      // A sun and a ridge, so the top/bottom crop is legible too.
      c.drawCircle(
        Offset(s.width * 0.72, s.height * 0.34),
        70,
        Paint()..color = const Color(0xFFFFC857),
      );
      final ridge = Path()
        ..moveTo(0, s.height * 0.78)
        ..lineTo(s.width * 0.18, s.height * 0.55)
        ..lineTo(s.width * 0.36, s.height * 0.72)
        ..lineTo(s.width * 0.55, s.height * 0.48)
        ..lineTo(s.width * 0.8, s.height * 0.7)
        ..lineTo(s.width, s.height * 0.58)
        ..lineTo(s.width, s.height)
        ..lineTo(0, s.height)
        ..close();
      c.drawPath(ridge, Paint()..color = const Color(0xFF10202E));
      _crosshair(c, s);
      _edges(c, s, 28);
      // Quarter markers along the top.
      for (final f in [0.25, 0.5, 0.75]) {
        c.drawCircle(
          Offset(s.width * f, 44),
          14,
          Paint()..color = const Color(0xFFFFFFFF),
        );
      }
    });

    bytes[_hAvatar] = await _png(256, 256, (c, s) {
      _gradient(c, s, const Color(0xFF3A7BD5), const Color(0xFF00D2FF));
      c.drawCircle(
        Offset(s.width / 2, s.height * 0.44),
        62,
        Paint()..color = const Color(0xFFF2D0A9),
      );
      c.drawCircle(
        Offset(s.width / 2, s.height * 1.02),
        110,
        Paint()..color = const Color(0xFF2B2D42),
      );
      c.drawCircle(
        Offset(s.width * 0.42, s.height * 0.42),
        7,
        Paint()..color = const Color(0xFF2B2D42),
      );
      c.drawCircle(
        Offset(s.width * 0.58, s.height * 0.42),
        7,
        Paint()..color = const Color(0xFF2B2D42),
      );
      _edges(c, s, 10);
    });

    Future<Uint8List> cover(double hue) => _png(264, 352, (c, s) {
      final a = HSLColor.fromAHSL(1, hue, 0.55, 0.38).toColor();
      final b = HSLColor.fromAHSL(1, (hue + 40) % 360, 0.6, 0.18).toColor();
      _gradient(c, s, a, b);
      _stripes(c, s);
      c.drawRect(
        Rect.fromLTWH(0, 22, s.width, 56),
        Paint()..color = const Color(0xCC000000),
      );
      c.drawRect(
        Rect.fromLTWH(24, 40, s.width * 0.6, 18),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      c.drawCircle(
        Offset(s.width / 2, s.height * 0.62),
        64,
        Paint()
          ..color = HSLColor.fromAHSL(1, (hue + 180) % 360, 0.7, 0.6).toColor(),
      );
      _crosshair(c, s);
      _edges(c, s, 10);
    });

    bytes[_hCoverA] = await cover(12);
    bytes[_hCoverB] = await cover(28);
    bytes[_hCoverC] = await cover(160);
    bytes[_hCoverD] = await cover(330);
    bytes[_hCoverE] = await cover(0);
    bytes[_hCoverF] = await cover(210);

    Future<Uint8List> keyArt(double hue) => _png(1280, 720, (c, s) {
      final a = HSLColor.fromAHSL(1, hue, 0.5, 0.3).toColor();
      final b = HSLColor.fromAHSL(1, (hue + 60) % 360, 0.55, 0.12).toColor();
      _gradient(c, s, a, b);
      _grid(c, s, 160);
      c.drawCircle(
        Offset(s.width * 0.3, s.height * 0.4),
        150,
        Paint()
          ..color = HSLColor.fromAHSL(1, (hue + 20) % 360, 0.8, 0.6).toColor(),
      );
      c.drawCircle(
        Offset(s.width * 0.3, s.height * 0.4),
        150,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 18
          ..color = const Color(0x88FFFFFF),
      );
      _crosshair(c, s);
      _edges(c, s, 24);
    });
    bytes[_hArtA] = await keyArt(200);
    bytes[_hArtB] = await keyArt(25);

    bytes[_hArtwork] = await _png(800, 500, (c, s) {
      _gradient(c, s, const Color(0xFF2E1F47), const Color(0xFF7A3E65));
      for (var i = 0; i < 7; i++) {
        c.drawCircle(
          Offset(80.0 + i * 110, 250 + 90 * math.sin(i.toDouble())),
          40 + i * 6,
          Paint()
            ..color = HSLColor.fromAHSL(0.85, i * 45.0, 0.7, 0.6).toColor(),
        );
      }
      _crosshair(c, s);
      _edges(c, s, 16);
    });

    Future<Uint8List> logo(Color color) => _png(200, 80, (c, s) {
      c.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(12)),
        Paint()..color = color,
      );
      c.drawCircle(
        const Offset(40, 40),
        22,
        Paint()..color = const Color(0xFFFFFFFF),
      );
      c.drawRect(
        const Rect.fromLTWH(76, 30, 104, 20),
        Paint()..color = const Color(0xFFFFFFFF),
      );
    });
    bytes[_hLogo1] = await logo(const Color(0xFF14532D));
    bytes[_hLogo2] = await logo(const Color(0xFF7F1D1D));

    bytes[_hDetA] = Uint8List.fromList(utf8.encode(jsonEncode(_detailsA)));
    bytes[_hDetB] = Uint8List.fromList(utf8.encode(jsonEncode(_detailsB)));
  }

  static Future<Uint8List> _png(
    int w,
    int h,
    void Function(Canvas c, Size s) paint,
  ) async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    paint(canvas, Size(w.toDouble(), h.toDouble()));
    final picture = rec.endRecording();
    final image = await picture.toImage(w, h);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    return data!.buffer.asUint8List();
  }

  static void _gradient(Canvas c, Size s, Color a, Color b) {
    c.drawRect(
      Offset.zero & s,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(s.width, s.height), [
          a,
          b,
        ]),
    );
  }

  static void _stripes(Canvas c, Size s) {
    final p = Paint()
      ..color = const Color(0x14FFFFFF)
      ..strokeWidth = 18;
    for (var x = -s.height; x < s.width; x += 70) {
      c.drawLine(Offset(x, s.height), Offset(x + s.height, 0), p);
    }
  }

  static void _grid(Canvas c, Size s, double step) {
    final p = Paint()
      ..color = const Color(0x40FFFFFF)
      ..strokeWidth = 1;
    for (var x = step; x < s.width; x += step) {
      c.drawLine(Offset(x, 0), Offset(x, s.height), p);
    }
    for (var y = step; y < s.height; y += step) {
      c.drawLine(Offset(0, y), Offset(s.width, y), p);
    }
  }

  static void _crosshair(Canvas c, Size s) {
    final p = Paint()
      ..color = const Color(0xFFFF3B30)
      ..strokeWidth = 3;
    c.drawLine(
      Offset(s.width / 2, s.height / 2 - 30),
      Offset(s.width / 2, s.height / 2 + 30),
      p,
    );
    c.drawLine(
      Offset(s.width / 2 - 30, s.height / 2),
      Offset(s.width / 2 + 30, s.height / 2),
      p,
    );
  }

  static void _edges(Canvas c, Size s, double band) {
    c.drawRect(
      Rect.fromLTWH(0, 0, band, s.height),
      Paint()..color = const Color(0xFFFF7A1A),
    );
    c.drawRect(
      Rect.fromLTWH(s.width - band, 0, band, s.height),
      Paint()..color = const Color(0xFF9BE15D),
    );
    c.drawRect(
      Rect.fromLTWH(0, 0, s.width, band / 2),
      Paint()..color = const Color(0xFF22D3EE),
    );
    c.drawRect(
      Rect.fromLTWH(0, s.height - band / 2, s.width, band / 2),
      Paint()..color = const Color(0xFFFF4FA3),
    );
  }
}
