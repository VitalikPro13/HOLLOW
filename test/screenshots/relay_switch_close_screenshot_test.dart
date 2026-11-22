import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/relay_stats_provider.dart';
import 'package:hollow/src/core/providers/relay_status_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/dialogs/license_key_dialog.dart';
import 'package:hollow/src/ui/dialogs/relay_switch_dialog.dart';
import 'package:hollow/src/ui/settings/network_section.dart';

/// The phone relay switch surfaces per platform, at 375 px and at 320 px with
/// text at x2.0: the invite dialog's body, its iOS saved state, the access key
/// prompt's iOS states and the Settings note.
/// Output: HOLLOW_SHOT_DIR, else build/ui_screenshots/relay_switch_close.
const _running = 'hollowtest.duckdns.org';
const _other = 'switchtest.invalid';

class _Api implements RustLibApi {
  final saved = <String, String>{};

  @override
  Future<void> crateApiStorageSaveSetting(
      {required String key, required String value}) async {
    saved[key] = value;
  }

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async =>
      saved[key];

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _Relay extends RelayDomainNotifier {
  @override
  String build() => _running;
}

class _Relays extends SavedRelayListNotifier {
  @override
  List<String> build() => const [kDefaultRelayDomain, _running, _other];
}

class _Status extends RelayStatusNotifier {
  @override
  RelayStatus build() => const RelayStatus();
}

class _Stats extends RelayStatsNotifier {
  @override
  RelayStats build() => const RelayStats();
}

class _AlwaysRelay extends AlwaysRelayCallsNotifier {
  @override
  bool build() => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final sep = Platform.pathSeparator;
  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${sep}build${sep}ui_screenshots${sep}relay_switch_close';
  final api = _Api();

  setUpAll(() async {
    RustLib.initMock(api: api);
    final lucide = await rootBundle
        .load('packages/lucide_icons_flutter/assets/lucide.ttf');
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
      families
          .putIfAbsent(family, () => [])
          .add(ByteData.view(File(face.path).readAsBytesSync().buffer));
    }
    for (final e in families.entries) {
      final loader = FontLoader(e.key);
      for (final b in e.value) {
        loader.addFont(Future.value(b));
      }
      await loader.load();
    }
  });
  setUp(() {
    api.saved.clear();
    beforeAppExit = null;
  });
  tearDown(() => debugRelaySwitchEnd = null);

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

  late BuildContext ctx;
  late WidgetRef ref;

  Future<void> host(WidgetTester tester, Size size, double scale,
      {Widget? child}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(RepaintBoundary(
      key: shotKey,
      child: ProviderScope(
        overrides: [
          relayDomainProvider.overrideWith(_Relay.new),
          savedRelayListProvider.overrideWith(_Relays.new),
          relayStatusProvider.overrideWith(_Status.new),
          relayStatsProvider.overrideWith(_Stats.new),
          alwaysRelayCallsProvider.overrideWith(_AlwaysRelay.new),
          overallConnectionProvider
              .overrideWithValue(OverallConnection.connected),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Consumer(builder: (context, r, _) {
              ctx = context;
              ref = r;
              return child == null
                  ? const SizedBox.expand()
                  : SingleChildScrollView(child: child);
            }),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  const sizes = [
    ('375_x1.0', Size(375, 760), 1.0),
    ('320_x2.0', Size(320, 568), 2.0),
  ];

  final link = classifyHollowLink('hollow://join?server='
      '0123456789abcdef0123456789abcdef01234567&relay=$_other')!;

  for (final (end, label) in [
    (RelaySwitchEnd.restart, 'desktop'),
    (RelaySwitchEnd.close, 'android'),
    (RelaySwitchEnd.closeByHand, 'ios'),
  ]) {
    final shapes = end == RelaySwitchEnd.restart
        ? const [('900_x1.0', Size(900, 640), 1.0)]
        : sizes;
    for (final (tag, size, scale) in shapes) {
      testWidgets('invite dialog $label $tag', (tester) async {
        debugRelaySwitchEnd = end;
        await host(tester, size, scale);
        unawaited(ensureRelayForInvite(ctx, ref, link));
        await settle(tester);
        await capture(tester, 'invite_${label}_$tag');
        if (end != RelaySwitchEnd.closeByHand) return;
        await tester.tap(find.text('Switch relay'));
        await settle(tester);
        await capture(tester, 'invite_ios_saved_$tag');
      });
    }
  }

  for (final (tag, size, scale) in sizes) {
    testWidgets('access key prompt ios $tag', (tester) async {
      debugRelaySwitchEnd = RelaySwitchEnd.closeByHand;
      await host(tester, size, scale);
      unawaited(showLicenseKeyDialog(ctx,
          error: 'Enter an access key to connect.'));
      await settle(tester);
      await capture(tester, 'key_ios_initial_$tag');
      await tester.tap(find.textContaining('Use the default relay'));
      await settle(tester);
      await capture(tester, 'key_ios_switched_here_$tag');
    });

    testWidgets('access key prompt ios, switch from elsewhere $tag',
        (tester) async {
      debugRelaySwitchEnd = RelaySwitchEnd.closeByHand;
      await host(tester, size, scale);
      await ref.read(relayDomainProvider.notifier).saveForNextLaunch(_other);
      unawaited(showLicenseKeyDialog(ctx,
          error: 'Enter an access key to connect.'));
      await settle(tester);
      await capture(tester, 'key_ios_elsewhere_$tag');
    });

    testWidgets('settings note ios $tag', (tester) async {
      debugRelaySwitchEnd = RelaySwitchEnd.closeByHand;
      await host(tester, size, scale, child: const RelaySettingsSection());
      await tester.tap(find.text('Change'));
      await tester.pump();
      await tester.tap(find.text(_other));
      await settle(tester);
      await capture(tester, 'settings_ios_picked_$tag');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
