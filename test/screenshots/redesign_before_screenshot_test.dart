import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart'
    show OnlineIdentitiesNotifier, onlineIdentitiesProvider;
import 'package:hollow/src/core/providers/device_link_sync_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/vault_status_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/showcase.dart' as showcase_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/profile_card_popup.dart';
import 'package:hollow/src/ui/dialogs/device_link_dialog.dart';
import 'package:hollow/src/ui/dialogs/game_card_dialog.dart';
import 'package:hollow/src/ui/dialogs/profile_dialog.dart';
import 'package:hollow/src/ui/dialogs/showcase_editor.dart';
import 'package:hollow/src/ui/dialogs/storage_dashboard_dialog.dart';
import 'package:hollow/src/ui/dialogs/welcome_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_profile_sheet.dart';
import 'package:hollow/src/ui/mobile/mobile_storage_route.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../helpers/test_app.dart';

/// "Before" renders of five dialogs about to be redesigned: the full profile
/// popup (and its compact card and phone sheet), the game card, the showcase
/// editor with its sub-dialogs, the storage dashboard (desktop + phone route)
/// and Welcome with the link-a-device path. Mockups are drawn from these.
///
/// All content is invented (Mira, Juno, Sam); art is generated in-process with
/// visible edge bands so a crop shows. FFI is mocked through
/// `RustLib.initMock`; Welcome's profile registry is faked through
/// `IOOverrides`, so no real profile path on this machine is ever read into a
/// render.
///
/// Output: $HOLLOW_SHOT_DIR/redesign_before, else
/// build/ui_screenshots/redesign_before.
final _desktop = TargetPlatformVariant.only(TargetPlatform.windows);
final _phone = TargetPlatformVariant.only(TargetPlatform.android);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');

  final outDir = '${Platform.environment['HOLLOW_SHOT_DIR'] ?? '${Directory.current.path}${Platform.pathSeparator}build${Platform.pathSeparator}ui_screenshots'}'
      '${Platform.pathSeparator}redesign_before';

  final api = _Api();

  setUpAll(() async {
    RustLib.initMock(api: api);

    final lucide =
        await rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf');
    await (FontLoader('packages/lucide_icons_flutter/Lucide')
          ..addFont(Future.value(lucide)))
        .load();
    try {
      final material = rootBundle.load('fonts/MaterialIcons-Regular.otf');
      await (FontLoader('MaterialIcons')..addFont(material)).load();
    } catch (_) {/* Material glyphs fall back to boxes */}
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

  /// Lets real image decodes land, then paints them. Fixed pumps, never
  /// pumpAndSettle: spinners and indeterminate bars never settle.
  Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
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
            home: home ??
                Scaffold(
                  body: Consumer(builder: (context, ref, _) {
                    hostContext = context;
                    hostRef = ref;
                    return const SizedBox.expand();
                  }),
                ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> tapText(WidgetTester tester, String text,
      {bool last = false}) async {
    final f = find.text(text);
    await tester.tap(last ? f.last : f.first, warnIfMissed: false);
    await tester.pump();
    await settle(tester, rounds: 4);
  }

  // ------------------------------------------------ 1. full profile popup

  Future<void> shootProfile(WidgetTester tester, String name,
      {required String peer,
      Size size = const Size(1440, 900),
      bool light = false}) async {
    await pumpHost(tester, size: size, light: light);
    unawaited(showProfileDialog(
      hostContext,
      peerId: peer,
      role: peer == _juno ? 'member' : 'admin',
      labels: peer == _juno ? const [] : const [_vip, _gamer],
      serverId: _srvSmall,
    ));
    await tester.pump();
    await settle(tester, rounds: 8);
    await capture(tester, name);
  }

  testWidgets('profile: no board, banner + avatar + frame', (t) async {
    await shootProfile(t, 'profile_full_noboard_dark', peer: _miraNone);
  }, variant: _desktop);
  testWidgets('profile: no board, light', (t) async {
    await shootProfile(t, 'profile_full_noboard_light',
        peer: _miraNone, light: true);
  }, variant: _desktop);
  testWidgets('profile: left wing only', (t) async {
    await shootProfile(t, 'profile_full_leftwing_dark', peer: _miraLeft);
  }, variant: _desktop);
  testWidgets('profile: both wings', (t) async {
    await shootProfile(t, 'profile_full_bothwings_dark', peer: _miraBoth);
  }, variant: _desktop);
  testWidgets('profile: both wings, tall window (whole ensemble)', (t) async {
    await shootProfile(t, 'profile_full_bothwings_tall_dark',
        peer: _miraBoth, size: const Size(1440, 1400));
  }, variant: _desktop);
  testWidgets('profile: both wings, light', (t) async {
    await shootProfile(t, 'profile_full_bothwings_light',
        peer: _miraBoth, light: true);
  }, variant: _desktop);
  testWidgets('profile: narrow window scales the ensemble', (t) async {
    await shootProfile(t, 'profile_full_bothwings_scaled_1100',
        peer: _miraBoth, size: const Size(1100, 900));
  }, variant: _desktop);
  testWidgets('profile: very narrow window stacks the wings', (t) async {
    await shootProfile(t, 'profile_full_bothwings_stacked_800',
        peer: _miraBoth, size: const Size(800, 900));
  }, variant: _desktop);
  testWidgets('profile: stranger, no banner, no avatar (fallbacks)',
      (t) async {
    await shootProfile(t, 'profile_full_stranger_nobanner_dark', peer: _juno);
  }, variant: _desktop);
  testWidgets('profile: yourself, both wings', (t) async {
    await shootProfile(t, 'profile_full_self_dark', peer: _me);
  }, variant: _desktop);

  Future<void> shootCompact(WidgetTester tester, String name,
      {required String peer, bool light = false}) async {
    await pumpHost(tester, size: const Size(640, 680), light: light);
    showProfileCardPopup(
      context: hostContext,
      ref: hostRef,
      peerId: peer,
      role: peer == _juno ? 'member' : 'admin',
      labels: peer == _juno ? const [] : const [_vip, _gamer],
      serverId: _srvSmall,
      anchorOf: () => const Offset(170, 40),
    );
    await tester.pump();
    await settle(tester, rounds: 8);
    await capture(tester, name);
  }

  testWidgets('compact card: friend with board', (t) async {
    await shootCompact(t, 'profile_compact_friend_dark', peer: _miraBoth);
  }, variant: _desktop);
  testWidgets('compact card: friend with board, light', (t) async {
    await shootCompact(t, 'profile_compact_friend_light',
        peer: _miraBoth, light: true);
  }, variant: _desktop);
  testWidgets('compact card: stranger', (t) async {
    await shootCompact(t, 'profile_compact_stranger_dark', peer: _juno);
  }, variant: _desktop);

  testWidgets('phone profile sheet', (t) async {
    {
      await pumpHost(t, size: const Size(390, 844));
      showMobileProfileSheet(hostContext,
          peerId: _miraBoth, role: 'admin', labels: const [_vip, _gamer]);
      await t.pump();
      await settle(t, rounds: 8);
      await capture(t, 'profile_phone_sheet_top');
      await t.drag(find.byType(SingleChildScrollView).last,
          const Offset(0, -500));
      await t.pump();
      await settle(t, rounds: 4);
      await capture(t, 'profile_phone_sheet_mid');
      await t.drag(find.byType(SingleChildScrollView).last,
          const Offset(0, -2000));
      await t.pump();
      await settle(t, rounds: 4);
      await capture(t, 'profile_phone_sheet_bottom');
    }
  }, variant: _phone);

  // --------------------------------------------------------- 2. game card

  Future<void> openGameCard(WidgetTester tester,
      {required Size size, bool withArt = true, bool light = false}) async {
    await pumpHost(tester, size: size, light: light);
    showGameCardDialog(
      hostContext,
      name: 'Outer Wilds',
      year: 2019,
      blurb: 'Twenty-two minutes I will never forget.',
      coverBytes: _Art.bytes[_hCoverB],
      artBytes: withArt ? _Art.bytes[_hArtB] : null,
      details: GameDetails.resolve(_hDetB, _Art.bytes)!,
      assets: _Art.bytes,
    );
    await tester.pump();
    await settle(tester, rounds: 8);
  }

  testWidgets('game card: desktop', (t) async {
    await openGameCard(t, size: const Size(1440, 900));
    await capture(t, 'gamecard_desktop_dark');
    await tapText(t, 'System requirements');
    await capture(t, 'gamecard_desktop_requirements_min');
    await tapText(t, 'Recommended');
    await capture(t, 'gamecard_desktop_requirements_rec');
  }, variant: _desktop);
  testWidgets('game card: tall window (whole card)', (t) async {
    await openGameCard(t, size: const Size(1440, 1400));
    await capture(t, 'gamecard_desktop_tall_dark');
  }, variant: _desktop);
  testWidgets('game card: no key art (blurred cover hero)', (t) async {
    await openGameCard(t, size: const Size(1440, 900), withArt: false);
    await capture(t, 'gamecard_desktop_noart_dark');
  }, variant: _desktop);
  testWidgets('game card: narrow window stacks', (t) async {
    await openGameCard(t, size: const Size(800, 900));
    await capture(t, 'gamecard_narrow_800_dark');
  }, variant: _desktop);
  testWidgets('game card: phone', (t) async {
    await openGameCard(t, size: const Size(390, 844));
    await capture(t, 'gamecard_phone_dark');
  }, variant: _phone);

  // --------------------------------------------------- 3. showcase editor

  Future<void> openEditor(WidgetTester tester, {required bool filled}) async {
    _Profiles.meBoard = filled ? _boardFull : '';
    await pumpHost(tester, size: const Size(1440, 900));
    showShowcaseEditorDialog(hostContext, hostRef);
    await tester.pump();
    await settle(tester, rounds: 5);
  }

  testWidgets('editor: empty board', (t) async {
    await openEditor(t, filled: false);
    await capture(t, 'showcase_editor_empty');
  }, variant: _desktop);
  testWidgets('editor: filled board', (t) async {
    await openEditor(t, filled: true);
    await capture(t, 'showcase_editor_filled');
  }, variant: _desktop);
  testWidgets('editor: add block picker, then text block', (t) async {
    await openEditor(t, filled: false);
    await tapText(t, 'Add block');
    await capture(t, 'showcase_sub_block_picker');
    await tapText(t, 'Text');
    await capture(t, 'showcase_sub_text_new');
  }, variant: _desktop);
  testWidgets('editor: edit an existing text block', (t) async {
    await openEditor(t, filled: true);
    await t.tap(find.byIcon(LucideIcons.pencil).at(1));
    await t.pump();
    await settle(t, rounds: 4);
    await capture(t, 'showcase_sub_text_edit');
  }, variant: _desktop);
  testWidgets('editor: find a game, empty, results, none', (t) async {
    await openEditor(t, filled: false);
    await tapText(t, 'Add block');
    await tapText(t, 'Now Playing');
    await capture(t, 'showcase_sub_find_game_empty');
    await t.enterText(find.byType(EditableText).last, 'outer');
    await t.pump(const Duration(milliseconds: 500));
    await settle(t, rounds: 3);
    await capture(t, 'showcase_sub_find_game_results');
    await t.enterText(find.byType(EditableText).last, 'zzqx');
    await t.pump(const Duration(milliseconds: 500));
    await settle(t, rounds: 3);
    await capture(t, 'showcase_sub_find_game_none');
  }, variant: _desktop);
  testWidgets('editor: favourite game blurb prompt', (t) async {
    await openEditor(t, filled: false);
    await tapText(t, 'Add block');
    await tapText(t, 'Favorite Game');
    await t.enterText(find.byType(EditableText).last, 'outer');
    await t.pump(const Duration(milliseconds: 500));
    await settle(t, rounds: 3);
    await tapText(t, 'Outer Wilds');
    await capture(t, 'showcase_sub_why_this_game');
  }, variant: _desktop);
  testWidgets('editor: game shelf, new and existing', (t) async {
    await openEditor(t, filled: false);
    await tapText(t, 'Add block');
    await tapText(t, 'Game Shelf');
    await capture(t, 'showcase_sub_shelf_new');
  }, variant: _desktop);
  testWidgets('editor: edit an existing shelf', (t) async {
    await openEditor(t, filled: true);
    await t.tap(find.byIcon(LucideIcons.pencil).at(3));
    await t.pump();
    await settle(t, rounds: 4);
    await capture(t, 'showcase_sub_shelf_edit');
  }, variant: _desktop);
  testWidgets('editor: artwork caption prompt', (t) async {
    FilePicker.platform = _FakePicker(bytes: _Art.bytes[_hArtwork]);
    await openEditor(t, filled: false);
    await tapText(t, 'Add block');
    await tapText(t, 'Artwork / GIF');
    await settle(t, rounds: 3);
    await capture(t, 'showcase_sub_artwork_caption');
  }, variant: _desktop);

  // ---------------------------------------------------- 4. storage

  Future<void> openStorage(WidgetTester tester, String sid) async {
    await pumpHost(tester, size: const Size(1440, 900));
    showStorageDashboardDialog(hostContext, sid);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Before the load lands: the dashboard has no loading state of its own.
    if (sid == _srvSmall) await capture(tester, 'storage_desktop_loading');
    // The dashboard asks PowerShell for drive C:'s free space: a real process
    // in real time, and nothing renders until it answers.
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 1)));
      await tester.pump();
      if (find.text('0 B').evaluate().isEmpty) break;
    }
    await settle(tester, rounds: 5);
  }

  testWidgets('storage: small server (full replication)', (t) async {
    await openStorage(t, _srvSmall);
    await capture(t, 'storage_desktop_small_dark');
    await tapText(t, 'Messages:');
    await capture(t, 'storage_desktop_retention_picker');
  }, variant: _desktop);
  testWidgets('storage: large server (erasure coding)', (t) async {
    await openStorage(t, _srvBig);
    await capture(t, 'storage_desktop_large_dark');
    await t.tap(find.textContaining('Pledge:').first);
    await t.pump();
    await settle(t, rounds: 4);
    await capture(t, 'storage_desktop_pledge_dialog');
  }, variant: _desktop);

  Future<void> openPhoneStorage(WidgetTester tester, String sid) async {
    await pumpHost(tester,
        size: const Size(390, 844),
        home: MobileStorageRoute(serverId: sid));
    await settle(tester, rounds: 5);
  }

  testWidgets('storage phone: small server', (t) async {
    {
      await openPhoneStorage(t, _srvSmall);
      await capture(t, 'storage_phone_small_dark');
      await tapText(t, 'Messages:');
      await capture(t, 'storage_phone_retention_picker');
    }
  }, variant: _phone);
  testWidgets('storage phone: large server', (t) async {
    {
      await openPhoneStorage(t, _srvBig);
      await capture(t, 'storage_phone_large_dark');
      await t.tap(find.textContaining('Pledge:').first);
      await t.pump();
      await settle(t, rounds: 4);
      await capture(t, 'storage_phone_pledge_dialog');
    }
  }, variant: _phone);

  // ------------------------------------------------------ 5. welcome

  Future<void> openWelcome(WidgetTester tester,
      {bool light = false, bool withProfiles = false}) async {
    IOOverrides.global = _WelcomeIo(withProfiles: withProfiles);
    addTearDown(() => IOOverrides.global = null);
    if (withProfiles) await initHollowDataDir();
    await pumpHost(tester, size: const Size(1440, 900), light: light);
    unawaited(showWelcomeDialog(hostContext));
    await tester.pump();
    await settle(tester, rounds: 6);
  }

  testWidgets('welcome: first run, dark', (t) async {
    await openWelcome(t);
    await capture(t, 'welcome_firstrun_dark');
    await tapText(t, 'Advanced');
    await capture(t, 'welcome_advanced_dark');
  }, variant: _desktop);
  testWidgets('welcome: first run, light', (t) async {
    await openWelcome(t, light: true);
    await capture(t, 'welcome_firstrun_light');
  }, variant: _desktop);
  testWidgets('welcome: phone', (t) async {
    IOOverrides.global = _WelcomeIo(withProfiles: false);
    addTearDown(() => IOOverrides.global = null);
    await pumpHost(t, size: const Size(390, 844));
    unawaited(showWelcomeDialog(hostContext));
    await t.pump();
    await settle(t, rounds: 6);
    await capture(t, 'welcome_phone_dark');
  }, variant: _phone);
  testWidgets('welcome: restore from backup', (t) async {
    FilePicker.platform = _FakePicker(path: r'D:\Backups\mira.hollow');
    await openWelcome(t);
    await tapText(t, 'Restore from Backup');
    await capture(t, 'welcome_restore_passphrase');
    await t.enterText(find.byType(EditableText).last, 'night shift tea');
    await t.pump();
    await tapText(t, 'Decrypt');
    await capture(t, 'welcome_restoring');
  }, variant: _desktop);
  testWidgets('welcome: other profiles on this computer', (t) async {
    await openWelcome(t, withProfiles: true);
    await tapText(t, 'Use a different profile');
    await capture(t, 'welcome_profiles_dark');
  }, variant: _desktop);
  testWidgets('welcome: other profiles, light', (t) async {
    await openWelcome(t, light: true, withProfiles: true);
    await tapText(t, 'Use a different profile');
    await tapText(t, 'Advanced');
    await capture(t, 'welcome_profiles_advanced_light');
  }, variant: _desktop);

  testWidgets('link path: connecting', (t) async {
    await pumpHost(t, size: const Size(1440, 900));
    showConnectingDialog(hostContext,
        message: 'Connecting to link your device…');
    await t.pump();
    await settle(t, rounds: 4);
    await capture(t, 'welcome_link_1_connecting');
  }, variant: _desktop);

  Future<void> shootLink(WidgetTester tester, String name, DeviceLinkState s,
      {bool online = true, bool light = false}) async {
    await pumpHost(tester, size: const Size(1440, 900), light: light, extra: [
      deviceLinkSyncProvider.overrideWith(() => _SeededLink(s)),
      overallConnectionProvider.overrideWithValue(
          online ? OverallConnection.connected : OverallConnection.connecting),
    ]);
    unawaited(showDeviceLinkDialog(hostContext, mode: DeviceLinkMode.enterCode));
    await tester.pump();
    await settle(tester, rounds: 4);
    await capture(tester, name);
  }

  testWidgets('link path: enter code', (t) async {
    await shootLink(t, 'welcome_link_2_entercode_dark', const DeviceLinkState());
  }, variant: _desktop);
  testWidgets('link path: enter code, light', (t) async {
    await shootLink(t, 'welcome_link_2_entercode_light', const DeviceLinkState(),
        light: true);
  }, variant: _desktop);
  testWidgets('link path: enter code, relay not up yet', (t) async {
    await shootLink(t, 'welcome_link_3_entercode_offline',
        const DeviceLinkState(),
        online: false);
  }, variant: _desktop);
  testWidgets('link path: waiting', (t) async {
    await shootLink(t, 'welcome_link_4_waiting',
        const DeviceLinkState(phase: LinkPhase.waiting));
  }, variant: _desktop);
  testWidgets('link path: receiving', (t) async {
    await shootLink(
        t,
        'welcome_link_5_receiving',
        const DeviceLinkState(
            phase: LinkPhase.receiving,
            bytesReceived: 41 * 1024 * 1024,
            totalBytes: 66 * 1024 * 1024));
  }, variant: _desktop);
  testWidgets('link path: importing', (t) async {
    await shootLink(t, 'welcome_link_6_importing',
        const DeviceLinkState(phase: LinkPhase.importing));
  }, variant: _desktop);
  testWidgets('link path: failed', (t) async {
    await shootLink(
        t,
        'welcome_link_7_failed',
        const DeviceLinkState(
            phase: LinkPhase.failed,
            error: 'Your other device did not answer. Check that both devices '
                'are online, then try again with a fresh code.'));
  }, variant: _desktop);
}

// ===================================================================== data

const _me = 'me_peer_aaaaaaaaaaaaaaaa';
const _miraBoth = 'peer_mira_both_000000001';
const _miraLeft = 'peer_mira_left_000000002';
const _miraNone = 'peer_mira_none_000000003';
const _juno = 'peer_juno_plain_00000004';
const _srvSmall = 'srv-small';
const _srvBig = 'srv-big';

const _vip = crdt_api.LabelFfi(
    labelId: 'vip', name: 'VIP', color: '#8B5CF6', access: true);
const _gamer = crdt_api.LabelFfi(
    labelId: 'fun', name: 'Gamer', color: '#22C55E', access: false);

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
        'body': 'Painting avatar frames for the **Shop**. Ask me about '
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
  'req_min': 'OS: Windows 7\nProcessor: Intel Core i5-2300\nMemory: 6 GB RAM\n'
      'Graphics: GeForce GTX 660\nStorage: 8 GB available space',
  'req_rec': 'OS: Windows 10\nProcessor: Intel Core i5-8400\nMemory: 8 GB RAM\n'
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
  'description': 'Discover a vast haunted kingdom in the sequel to the '
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

storage_api.UserProfile _profile(String peer, String name,
        {String status = '',
        String about = '',
        String board = '',
        String frame = ''}) =>
    storage_api.UserProfile(
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
      vaultStatusProvider.overrideWith(_Vault.new),
      for (final sid in [_srvSmall, _srvBig]) ...[
        myRoleProvider(sid).overrideWith((ref) async => 'owner'),
        myPermissionsProvider(sid).overrideWith((ref) async => Permission.all),
        serverMembersProvider(sid).overrideWith((ref) async => [
              for (var i = 0; i < (sid == _srvBig ? 12 : 3); i++)
                crdt_api.MemberFfi(
                  peerId: 'peer_member_${sid}_$i',
                  displayName: 'Member $i',
                  role: i == 0 ? 'owner' : 'member',
                  nickname: '',
                  twitchUsername: '',
                  labels: const [],
                ),
            ]),
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
        _me: _profile(_me, 'Sam',
            status: 'Hosting the relay this week',
            about: 'Runs the book club server.',
            board: meBoard ?? _boardFull,
            frame: 'b:250'),
        _miraBoth: _profile(_miraBoth, 'Mira',
            status: _miraStatus,
            about: _miraAbout,
            board: _boardFull,
            frame: 'b:168'),
        _miraLeft: _profile(_miraLeft, 'Mira',
            status: _miraStatus,
            about: _miraAbout,
            board: _boardLeft,
            frame: 'b:168'),
        _miraNone: _profile(_miraNone, 'Mira',
            status: _miraStatus, about: _miraAbout, frame: 'b:168'),
        _juno: _profile(_juno, 'Juno'),
      };
}

class _Avatars extends AvatarNotifier {
  @override
  Map<String, Uint8List> build() => {
        for (final p in [_me, _miraBoth, _miraLeft, _miraNone])
          p: _Art.bytes[_hAvatar]!,
      };

  @override
  Future<void> loadAvatar(String peerId) async {}
}

class _Friends extends FriendsNotifier {
  @override
  Map<String, FriendInfo> build() => {
        for (final p in [_miraBoth, _miraLeft, _miraNone])
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
  Set<String> build() => {_miraBoth, _miraLeft, _miraNone};
}

class _Vault extends VaultStatusNotifier {
  @override
  Map<String, VaultServerStatus> build() =>
      {_srvBig: const VaultServerStatus(shardsStoredLocally: 214)};
}

class _SeededLink extends DeviceLinkSyncNotifier {
  final DeviceLinkState seeded;
  _SeededLink(this.seeded);

  @override
  DeviceLinkState build() => seeded;
}

// ====================================================================== FFI

class _Api implements RustLibApi {
  List<showcase_api.ShowcaseAsset> assets = const [];

  static final _gib = BigInt.from(1024 * 1024 * 1024);
  static final _mib = BigInt.from(1024 * 1024);

  @override
  Future<Uint8List?> crateApiStorageGetBanner({required String peerId}) async =>
      peerId == _juno ? null : _Art.bytes[_hBanner];

  @override
  Future<Uint8List?> crateApiStorageGetAvatar({required String peerId}) async =>
      peerId == _juno ? null : _Art.bytes[_hAvatar];

  @override
  Future<List<showcase_api.ShowcaseAsset>> crateApiShowcaseGetShowcaseAssets(
          {required String peerId}) async =>
      assets;

  @override
  Future<crdt_api.StorageStatsFfi> crateApiCrdtGetStorageStats(
      {required String serverId}) async {
    if (serverId == _srvBig) {
      return crdt_api.StorageStatsFfi(
        totalPledgedBytes: _gib * BigInt.from(60),
        totalUsedBytes: _gib * BigInt.from(14) + _mib * BigInt.from(210),
        myPledgeBytes: _gib * BigInt.from(5),
        myUsedBytes: _gib * BigInt.from(3) + _mib * BigInt.from(100),
        memberCount: 12,
        minPledgeMb: BigInt.from(512),
      );
    }
    return crdt_api.StorageStatsFfi(
      totalPledgedBytes: BigInt.zero,
      totalUsedBytes: _gib + _mib * BigInt.from(820),
      myPledgeBytes: BigInt.zero,
      myUsedBytes: _gib + _mib * BigInt.from(820),
      memberCount: 3,
      minPledgeMb: BigInt.from(512),
    );
  }

  @override
  Future<String> crateApiCrdtGetServerSetting(
      {required String serverId, required String key}) async {
    if (serverId == _srvBig) {
      return key == 'retention_messages' ? '180d' : '90d';
    }
    return key == 'retention_messages' ? 'permanent' : '365d';
  }

  @override
  Future<List<showcase_api.GameSearchResult>>
      crateApiShowcaseShowcaseGameSearch({required String query}) async {
    if (!query.toLowerCase().startsWith('out')) return const [];
    return const [
      showcase_api.GameSearchResult(
          id: 11737, name: 'Outer Wilds', year: 2019, gameType: 'Main Game'),
      showcase_api.GameSearchResult(
          id: 142066,
          name: 'Outer Wilds: Echoes of the Eye',
          year: 2021,
          gameType: 'DLC'),
      showcase_api.GameSearchResult(
          id: 26950, name: 'The Outer Worlds', year: 2019, gameType: 'Main Game'),
      showcase_api.GameSearchResult(
          id: 250616, name: 'The Outer Worlds 2', year: 2025),
      showcase_api.GameSearchResult(
          id: 3031, name: 'Outlast', year: 2013, gameType: 'Main Game'),
    ];
  }

  @override
  Future<showcase_api.GameCardDetails?> crateApiShowcaseShowcaseGameDetails(
          {required int gameId}) async =>
      null;

  @override
  Future<showcase_api.ShowcaseAsset> crateApiShowcaseProcessShowcaseArtwork(
          {required List<int> rawBytes}) async =>
      showcase_api.ShowcaseAsset(
          hash: _hArtwork, bytes: Uint8List.fromList(rawBytes));

  /// Held open so the Restoring state stays on screen.
  @override
  Future<void> crateApiStorageImportBackup(
          {required String backupPath, required String passphrase}) =>
      Completer<void>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePicker extends FilePicker {
  final Uint8List? bytes;
  final String? path;
  _FakePicker({this.bytes, this.path});

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      FilePickerResult([
        PlatformFile(
          name: path == null ? 'sketch.png' : 'mira.hollow',
          path: path,
          size: bytes?.length ?? 4096,
          bytes: bytes,
        ),
      ]);
}

// ============================================ Welcome's fake profile folders

/// Fakes only profiles.json and identity.key lookups; every other file goes
/// to the real filesystem (fonts, assets, the PNG writes).
final class _WelcomeIo extends IOOverrides {
  final bool withProfiles;
  _WelcomeIo({required this.withProfiles});

  static const _registry = '{"version":1,"active":"D:\\\\Hollow\\\\Mira",'
      '"profiles":[{"name":"Mira","path":"D:\\\\Hollow\\\\Mira"},'
      '{"name":"Work","path":"D:\\\\Hollow\\\\Work"},'
      '{"name":"Juno test","path":"E:\\\\hollow_data"}]}';

  static const _withIdentity = [r'd:\hollow\work', r'e:\hollow_data'];

  @override
  File createFile(String path) {
    if (path.endsWith('profiles.json')) {
      return _FakeFile(path, withProfiles, withProfiles ? _registry : '');
    }
    if (path.endsWith('identity.key')) {
      final dir = path
          .substring(0, path.length - 'identity.key'.length - 1)
          .toLowerCase();
      return _FakeFile(path, withProfiles && _withIdentity.contains(dir), '');
    }
    return super.createFile(path);
  }

  @override
  Directory createDirectory(String path) {
    if (path.toLowerCase().startsWith(r'd:\hollow')) return _FakeDir(path);
    return super.createDirectory(path);
  }
}

class _FakeFile implements File {
  @override
  final String path;
  final bool _exists;
  final String content;
  _FakeFile(this.path, this._exists, this.content);

  @override
  bool existsSync() => _exists;

  @override
  String readAsStringSync({Encoding encoding = utf8}) => content;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDir implements Directory {
  @override
  final String path;
  _FakeDir(this.path);

  @override
  bool existsSync() => true;

  @override
  void createSync({bool recursive = false}) {}

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
      c.drawCircle(Offset(s.width * 0.72, s.height * 0.34), 70,
          Paint()..color = const Color(0xFFFFC857));
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
        c.drawCircle(Offset(s.width * f, 44), 14,
            Paint()..color = const Color(0xFFFFFFFF));
      }
    });

    bytes[_hAvatar] = await _png(256, 256, (c, s) {
      _gradient(c, s, const Color(0xFF3A7BD5), const Color(0xFF00D2FF));
      c.drawCircle(Offset(s.width / 2, s.height * 0.44), 62,
          Paint()..color = const Color(0xFFF2D0A9));
      c.drawCircle(Offset(s.width / 2, s.height * 1.02), 110,
          Paint()..color = const Color(0xFF2B2D42));
      c.drawCircle(Offset(s.width * 0.42, s.height * 0.42), 7,
          Paint()..color = const Color(0xFF2B2D42));
      c.drawCircle(Offset(s.width * 0.58, s.height * 0.42), 7,
          Paint()..color = const Color(0xFF2B2D42));
      _edges(c, s, 10);
    });

    Future<Uint8List> cover(double hue) => _png(264, 352, (c, s) {
          final a = HSLColor.fromAHSL(1, hue, 0.55, 0.38).toColor();
          final b = HSLColor.fromAHSL(1, (hue + 40) % 360, 0.6, 0.18).toColor();
          _gradient(c, s, a, b);
          _stripes(c, s);
          c.drawRect(Rect.fromLTWH(0, 22, s.width, 56),
              Paint()..color = const Color(0xCC000000));
          c.drawRect(Rect.fromLTWH(24, 40, s.width * 0.6, 18),
              Paint()..color = const Color(0xFFFFFFFF));
          c.drawCircle(Offset(s.width / 2, s.height * 0.62), 64,
              Paint()..color = HSLColor.fromAHSL(1, (hue + 180) % 360, 0.7, 0.6).toColor());
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
          c.drawCircle(Offset(s.width * 0.3, s.height * 0.4), 150,
              Paint()..color = HSLColor.fromAHSL(1, (hue + 20) % 360, 0.8, 0.6).toColor());
          c.drawCircle(Offset(s.width * 0.3, s.height * 0.4), 150,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 18
                ..color = const Color(0x88FFFFFF));
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
              ..color = HSLColor.fromAHSL(0.85, i * 45.0, 0.7, 0.6).toColor());
      }
      _crosshair(c, s);
      _edges(c, s, 16);
    });

    Future<Uint8List> logo(Color color) => _png(200, 80, (c, s) {
          c.drawRRect(
              RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(12)),
              Paint()..color = color);
          c.drawCircle(const Offset(40, 40), 22,
              Paint()..color = const Color(0xFFFFFFFF));
          c.drawRect(const Rect.fromLTWH(76, 30, 104, 20),
              Paint()..color = const Color(0xFFFFFFFF));
        });
    bytes[_hLogo1] = await logo(const Color(0xFF14532D));
    bytes[_hLogo2] = await logo(const Color(0xFF7F1D1D));

    bytes[_hDetA] = Uint8List.fromList(utf8.encode(jsonEncode(_detailsA)));
    bytes[_hDetB] = Uint8List.fromList(utf8.encode(jsonEncode(_detailsB)));
  }

  static Future<Uint8List> _png(
      int w, int h, void Function(Canvas c, Size s) paint) async {
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
          ..shader = ui.Gradient.linear(
              Offset.zero, Offset(s.width, s.height), [a, b]));
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
    c.drawLine(Offset(s.width / 2, s.height / 2 - 30),
        Offset(s.width / 2, s.height / 2 + 30), p);
    c.drawLine(Offset(s.width / 2 - 30, s.height / 2),
        Offset(s.width / 2 + 30, s.height / 2), p);
  }

  static void _edges(Canvas c, Size s, double band) {
    c.drawRect(Rect.fromLTWH(0, 0, band, s.height),
        Paint()..color = const Color(0xFFFF7A1A));
    c.drawRect(Rect.fromLTWH(s.width - band, 0, band, s.height),
        Paint()..color = const Color(0xFF9BE15D));
    c.drawRect(Rect.fromLTWH(0, 0, s.width, band / 2),
        Paint()..color = const Color(0xFF22D3EE));
    c.drawRect(Rect.fromLTWH(0, s.height - band / 2, s.width, band / 2),
        Paint()..color = const Color(0xFFFF4FA3));
  }
}
