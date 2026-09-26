import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/mobile/mobile_member_panel.dart';
import 'package:hollow/src/ui/shell/member_panel.dart';

import '../helpers/test_app.dart';

/// Renders of the member panel pass: the desktop panel and the phone's member
/// sheet, with roles, a status line, offline members, a folded group and the
/// offline note, dark and light. All names are invented.
///
/// Output: $HOLLOW_SHOT_DIR/member_panel, else build/ui_screenshots/member_panel.
const _me = '12D3KooWSamSamSamSamSamSamSamSamSamSamSamSamSam';
const _ada = '12D3KooWAdaAdaAdaAdaAdaAdaAdaAdaAdaAdaAdaAdaAda';
const _juno = '12D3KooWJunoJunoJunoJunoJunoJunoJunoJunoJunoJu';
const _rui = '12D3KooWRuiRuiRuiRuiRuiRuiRuiRuiRuiRuiRuiRuiRui';
const _kit = '12D3KooWKitKitKitKitKitKitKitKitKitKitKitKitKit';
const _lena = '12D3KooWLenaLenaLenaLenaLenaLenaLenaLenaLenaLe';
const _server = 's1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final sep = Platform.pathSeparator;
  final outDir =
      '${Platform.environment['HOLLOW_SHOT_DIR'] ?? '${Directory.current.path}${sep}build${sep}ui_screenshots'}'
      '${sep}member_panel';

  setUpAll(() async {
    RustLib.initMock(api: _Api());
    final lucide =
        await rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf');
    await (FontLoader('packages/lucide_icons_flutter/Lucide')
          ..addFont(Future.value(lucide)))
        .load();
    final families = <String, List<ByteData>>{};
    for (final face in Directory('assets/fonts').listSync()) {
      final name = face.uri.pathSegments.last;
      if (!name.endsWith('.ttf')) continue;
      final family = name.startsWith('Onest')
          ? 'Onest'
          : name.startsWith('GeistMono')
              ? 'GeistMono'
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
  });

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final file = File('$outDir$sep$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data.buffer.asUint8List());
    });
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  late BuildContext host;

  Future<void> pumpHost(
    WidgetTester tester,
    Size size, {
    required bool light,
    OverallConnection link = OverallConnection.connected,
    Widget? home,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: hollowTestOverrides(extra: [
        identityProvider.overrideWith(_Identity.new),
        profileProvider.overrideWith(_Profiles.new),
        avatarProvider.overrideWith(_Avatars.new),
        onlineIdentitiesProvider.overrideWith(_Online.new),
        overallConnectionProvider.overrideWithValue(link),
        selectedServerProvider.overrideWith((_) => _server),
        serverMembersProvider(_server).overrideWith((_) async => _members),
      ]),
      child: RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
          home: Scaffold(
            body: Builder(builder: (context) {
              host = context;
              return home ?? const SizedBox.expand();
            }),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  // The panel against the canvas it sits beside.
  Widget desktop() => Builder(
        builder: (context) => Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
                child:
                    ColoredBox(color: HollowTheme.of(context).background)),
            const MemberPanel(),
          ],
        ),
      );

  for (final light in [false, true]) {
    final tag = light ? 'light' : 'dark';
    testWidgets('desktop $tag', (t) async {
      await pumpHost(t, const Size(640, 560), light: light, home: desktop());
      await settle(t);
      await capture(t, 'desktop_$tag');
    });
    testWidgets('phone $tag', (t) async {
      await pumpHost(t, const Size(390, 844), light: light);
      showMobileMemberPanel(host, _server);
      await settle(t);
      await capture(t, 'phone_$tag');
    });
  }

  testWidgets('desktop folded', (t) async {
    await pumpHost(t, const Size(640, 560), light: false, home: desktop());
    await settle(t);
    await t.tap(find.bySemanticsLabel(RegExp(r'^Collapse Offline')));
    await settle(t);
    await capture(t, 'desktop_folded');
  });

  testWidgets('desktop offline link', (t) async {
    await pumpHost(t, const Size(640, 560),
        light: false, link: OverallConnection.offline, home: desktop());
    await settle(t);
    await capture(t, 'desktop_offline_link');
  });
}

crdt_api.MemberFfi _member(String peer, String name, String role) =>
    crdt_api.MemberFfi(
      peerId: peer,
      displayName: name,
      role: role,
      nickname: '',
      twitchUsername: '',
      labels: const [],
    );

final _members = [
  _member(_me, 'Sam', 'owner'),
  _member(_ada, 'Ada', 'admin'),
  _member(_rui, 'Rui', 'moderator'),
  _member(_juno, 'Juno', 'member'),
  _member(_lena, 'Lena', 'member'),
  _member(_kit, 'Kit', 'member'),
];

storage_api.UserProfile _profile(String peer, String name,
        {String status = ''}) =>
    storage_api.UserProfile(
      peerId: peer,
      displayName: name,
      status: status,
      aboutMe: '',
      updatedAt: 0,
      twitchUsername: '',
      showcaseBoard: '',
      avatarFrame: '',
      avatarAnim: '',
      bannerAnim: '',
      supportCreds: '',
    );

class _Identity extends IdentityNotifier {
  @override
  IdentityState build() => const IdentityState(peerId: _me, isLoaded: true);
}

class _Profiles extends ProfileNotifier {
  @override
  Map<String, storage_api.UserProfile> build() => {
        _me: _profile(_me, 'Sam'),
        _ada: _profile(_ada, 'Ada', status: 'Mixing the new EP'),
        _juno: _profile(_juno, 'Juno'),
        _rui: _profile(_rui, 'Rui', status: 'Back at six'),
        _kit: _profile(_kit, 'Kit'),
        _lena: _profile(_lena, 'Lena'),
      };
}

class _Online extends OnlineIdentitiesNotifier {
  @override
  Set<String> build() => {_ada, _juno, _lena};
}

class _Avatars extends AvatarNotifier {
  @override
  Map<String, Uint8List> build() => {};

  @override
  Future<void> loadAvatar(String peerId) async {}
}

class _Api implements RustLibApi {
  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async =>
      null;

  @override
  Future<void> crateApiStorageSaveSetting(
      {required String key, required String value}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
