import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/duress_provider.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/settings/backup_section.dart';
import 'package:hollow/src/ui/settings/device_management_shared.dart';
import 'package:hollow/src/ui/settings/duress_section.dart';
import 'package:hollow/src/ui/settings/security_section.dart';
import 'package:hollow/src/ui/settings/verify_proof_section.dart';

import '../helpers/test_app.dart';

/// Dialogs pass, agent 3 part B: the security, device and backup prompts of
/// Settings after the fixes. Invented content only; FFI mocked.
///
/// Output: build/ui_screenshots/dialogs_after/3/b_*.png
final _desktop = TargetPlatformVariant.only(TargetPlatform.windows);
final _phone = TargetPlatformVariant.only(TargetPlatform.android);

class _Api implements RustLibApi {
  @override
  Future<void> crateApiIdentitySetDuressCode({
    required String password,
    required String duressCode,
    required String scope,
    required bool notifyFriends,
  }) async =>
      throw 'Wrong password or corrupted identity file';

  @override
  Future<void> crateApiIdentityClearDuressCode(
          {required String password}) async =>
      throw 'Wrong password or corrupted identity file';

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _laptop = MyDevice(
    peerId: 'dev-laptop', isThisDevice: false, online: true, label: 'Laptop');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final sep = Platform.pathSeparator;
  final outDir =
      '${Directory.current.path}${sep}build${sep}ui_screenshots${sep}dialogs_after${sep}3';

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
      final file = File('$outDir${Platform.pathSeparator}b_$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data.buffer.asUint8List());
      debugPrint('[screenshot] wrote ${file.path}');
    });
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  late BuildContext host;
  late WidgetRef hostRef;

  Future<void> pumpHost(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: hollowTestOverrides(extra: [
        duressStatusProvider.overrideWith((ref) async =>
            const identity_api.DuressStatus(
              enabled: true,
              scope: 'device',
              notifyFriends: false,
              available: true,
            )),
      ]),
      child: RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Consumer(builder: (context, ref, _) {
              host = context;
              hostRef = ref;
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  children: [
                    DuressCodeCard(wideScopes: true),
                    AccountDangerZoneCard(),
                    BackupFileRow(),
                  ],
                ),
              );
            }),
          ),
        ),
      ),
    ));
    await settle(tester);
  }

  Future<void> fill(WidgetTester tester, List<String> values) async {
    final fields = find.byType(TextField);
    for (var i = 0; i < values.length; i++) {
      await tester.enterText(fields.at(i), values[i]);
    }
    await tester.pump();
  }

  final scenarios = <String, Future<void> Function(WidgetTester)>{
    'duress_wrong_password': (tester) async {
      await tester.tap(find.text('Change'));
      await settle(tester);
      await tester.tap(find.text('My whole identity'));
      await tester.pump();
      await fill(tester, ['not my password', 'blue heron', 'blue heron']);
      await tester.tap(find.widgetWithText(HollowButton, 'Change code'));
      await settle(tester);
    },
    'remove_duress_wrong_password': (tester) async {
      await tester.tap(find.text('Remove'));
      await settle(tester);
      await fill(tester, ['not it']);
      await tester.tap(find.widgetWithText(HollowButton, 'Remove').last);
      await settle(tester);
    },
    'destroy': (tester) async {
      await tester.tap(find.text('Destroy identity'));
      await settle(tester);
      await fill(tester, ['DESTROY']);
      await settle(tester);
    },
    'set_password_mismatch': (tester) async {
      unawaited(askSecretDialog(host,
          title: 'Set app password',
          ask: SecretAsk.create,
          confirmLabel: 'Set password',
          message: 'Hollow asks for it whenever it locks. If you forget it, '
              'only your recovery phrase brings your identity back.',
          onSubmit: (_, _) async {}));
      await settle(tester);
      await fill(tester, ['hunter22', 'hunter23']);
      await tester.tap(find.widgetWithText(HollowButton, 'Set password'));
      await settle(tester);
    },
    'change_password_wrong': (tester) async {
      unawaited(askSecretDialog(host,
          title: 'Change password',
          ask: SecretAsk.change,
          confirmLabel: 'Change password',
          onSubmit: (_, _) async =>
              throw 'Wrong password or corrupted identity file'));
      await settle(tester);
      await fill(tester, ['old', 'hunter22', 'hunter22']);
      await tester.tap(find.widgetWithText(HollowButton, 'Change password'));
      await settle(tester);
    },
    'export_backup': (tester) async {
      await tester.tap(find.text('Export'));
      await settle(tester);
      await fill(tester, ['correct horse']);
    },
    'rename_device': (tester) async {
      unawaited(renameDeviceFlow(host, hostRef, _laptop));
      await settle(tester);
    },
    'sync_device': (tester) async {
      unawaited(syncFromDeviceFlow(host, hostRef, _laptop));
      await settle(tester);
    },
    'remove_other_devices': (tester) async {
      unawaited(resetDeviceListsFlow(host));
      await settle(tester);
    },
    'verify_proof': (tester) async {
      unawaited(showVerifyProofDialog(host));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, '{"version": 2');
      await tester.pump();
      await tester.tap(find.widgetWithText(HollowButton, 'Verify'));
      await settle(tester);
    },
  };

  for (final entry in scenarios.entries) {
    testWidgets('${entry.key} desktop', (tester) async {
      await pumpHost(tester, const Size(1440, 900));
      await entry.value(tester);
      await capture(tester, '${entry.key}_desktop');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, variant: _desktop);
    testWidgets('${entry.key} phone', (tester) async {
      await pumpHost(tester, const Size(390, 844));
      await entry.value(tester);
      await capture(tester, '${entry.key}_phone');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, variant: _phone);
  }
}
