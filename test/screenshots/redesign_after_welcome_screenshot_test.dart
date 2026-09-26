import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/device_link_sync_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/dialogs/device_link_dialog.dart';
import 'package:hollow/src/ui/dialogs/welcome_dialog.dart';

import '../helpers/test_app.dart';

/// "After" renders of Welcome and the first-run link path, beside the before
/// set in redesign_before/. The profile registry is faked through
/// `IOOverrides`, so no real profile path on this machine reaches a render.
///
/// Output: $HOLLOW_SHOT_DIR/redesign_after, else
/// build/ui_screenshots/redesign_after.
final _desktop = TargetPlatformVariant.only(TargetPlatform.windows);
final _phone = TargetPlatformVariant.only(TargetPlatform.android);

const _desk = Size(1440, 900);
const _hand = Size(390, 844);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');

  final outDir =
      '${Platform.environment['HOLLOW_SHOT_DIR'] ?? '${Directory.current.path}${Platform.pathSeparator}build${Platform.pathSeparator}ui_screenshots'}'
      '${Platform.pathSeparator}redesign_after';

  setUpAll(() async {
    RustLib.initMock(api: _Api());
    final lucide = await rootBundle.load(
      'packages/lucide_icons_flutter/assets/lucide.ttf',
    );
    await (FontLoader(
      'packages/lucide_icons_flutter/Lucide',
    )..addFont(Future.value(lucide))).load();
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
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(shotKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final file = File('$outDir${Platform.pathSeparator}$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data.buffer.asUint8List());
      debugPrint('[screenshot] wrote ${file.path}');
    });
  }

  /// Fixed pumps, never pumpAndSettle: spinners never settle.
  Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  late BuildContext hostContext;

  Future<void> pumpHost(
    WidgetTester tester, {
    required Size size,
    bool light = false,
    List<Override> extra = const [],
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
        overrides: hollowTestOverrides(extra: extra),
        child: RepaintBoundary(
          key: shotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  hostContext = context;
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

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.tap(f.first, warnIfMissed: false);
    await tester.pump();
    await settle(tester, rounds: 4);
  }

  // --------------------------------------------------------------- welcome

  Future<void> openWelcome(
    WidgetTester tester, {
    Size size = _desk,
    bool light = false,
    bool withProfiles = false,
  }) async {
    IOOverrides.global = _WelcomeIo(withProfiles: withProfiles);
    addTearDown(() => IOOverrides.global = null);
    if (withProfiles) await initHollowDataDir();
    await pumpHost(tester, size: size, light: light);
    unawaited(showWelcomeDialog(hostContext));
    await tester.pump();
    await settle(tester);
  }

  Finder relayButton() => find.bySemanticsLabel(RegExp('^Change the relay'));

  testWidgets('welcome: first run and relay, dark', (t) async {
    await openWelcome(t);
    await capture(t, 'welcome_firstrun_dark');
    await tap(t, relayButton());
    await capture(t, 'welcome_advanced_dark');
    await t.enterText(
      find.byWidgetPredicate(
        (w) =>
            w is TextField && w.decoration?.hintText == 'relay.anonlisten.com',
      ),
      'not a relay!',
    );
    await t.pump();
    await tap(t, find.text('Create an identity'));
    await capture(t, 'welcome_advanced_invalid_dark');
  }, variant: _desktop);

  testWidgets('welcome: first run, light', (t) async {
    await openWelcome(t, light: true);
    await capture(t, 'welcome_firstrun_light');
  }, variant: _desktop);

  testWidgets('welcome: other profiles', (t) async {
    await openWelcome(t, withProfiles: true);
    await tap(t, find.textContaining('Other profiles'));
    await capture(t, 'welcome_profiles_dark');
  }, variant: _desktop);

  testWidgets('welcome: other profiles, light', (t) async {
    await openWelcome(t, light: true, withProfiles: true);
    await tap(t, find.textContaining('Other profiles'));
    await capture(t, 'welcome_profiles_light');
  }, variant: _desktop);

  testWidgets('welcome: restore from a backup', (t) async {
    FilePicker.platform = _FakePicker();
    await openWelcome(t);
    await tap(t, find.text('Restore from a backup'));
    await capture(t, 'welcome_restore_dark');
    await t.enterText(find.byType(EditableText).last, 'night shift tea');
    await t.pump();
    await tap(t, find.text('Restore'));
    await capture(t, 'welcome_restoring_dark');
  }, variant: _desktop);

  testWidgets('welcome: restore, wrong passphrase', (t) async {
    FilePicker.platform = _FakePicker();
    _Api.importFails = true;
    addTearDown(() => _Api.importFails = false);
    await openWelcome(t, light: true);
    await tap(t, find.text('Restore from a backup'));
    await t.enterText(find.byType(EditableText).last, 'wrong one');
    await t.pump();
    await tap(t, find.text('Restore'));
    await capture(t, 'welcome_restore_error_light');
  }, variant: _desktop);

  testWidgets('welcome: phone first run', (t) async {
    await openWelcome(t, size: _hand);
    await capture(t, 'welcome_phone_dark');
  }, variant: _phone);

  testWidgets('welcome: phone first run, light', (t) async {
    await openWelcome(t, size: _hand, light: true);
    await capture(t, 'welcome_phone_light');
  }, variant: _phone);

  testWidgets('welcome: phone restore', (t) async {
    FilePicker.platform = _FakePicker();
    await openWelcome(t, size: _hand);
    await tap(t, find.text('Restore from a backup'));
    await capture(t, 'welcome_phone_restore_dark');
  }, variant: _phone);

  // ------------------------------------------------------------- link path

  testWidgets('link: connecting', (t) async {
    await pumpHost(t, size: _desk);
    showConnectingDialog(
      hostContext,
      message: 'Connecting to link your device…',
    );
    await t.pump();
    await settle(t, rounds: 4);
    await capture(t, 'welcome_link_1_connecting');
    dismissConnectingDialog();
  }, variant: _desktop);

  Future<void> shootLink(
    WidgetTester tester,
    String name,
    DeviceLinkState s, {
    bool online = true,
    bool light = false,
    Size size = _desk,
    String? typed,
  }) async {
    await pumpHost(
      tester,
      size: size,
      light: light,
      extra: [
        deviceLinkSyncProvider.overrideWith(() => _SeededLink(s)),
        overallConnectionProvider.overrideWithValue(
          online ? OverallConnection.connected : OverallConnection.connecting,
        ),
      ],
    );
    unawaited(
      showDeviceLinkDialog(hostContext, mode: DeviceLinkMode.enterCode),
    );
    await tester.pump();
    await settle(tester, rounds: 4);
    if (typed != null) {
      await tester.enterText(find.byType(TextField), typed);
      await tester.pump();
      await settle(tester, rounds: 2);
    }
    await capture(tester, name);
  }

  testWidgets('link: enter code', (t) async {
    await shootLink(
      t,
      'welcome_link_2_entercode_dark',
      const DeviceLinkState(),
      typed: 'K7Q',
    );
  }, variant: _desktop);
  testWidgets('link: enter code, light', (t) async {
    await shootLink(
      t,
      'welcome_link_2_entercode_light',
      const DeviceLinkState(),
      light: true,
      typed: 'K7Q2MX',
    );
  }, variant: _desktop);
  testWidgets('link: enter code, relay not up yet', (t) async {
    await shootLink(
      t,
      'welcome_link_3_entercode_offline',
      const DeviceLinkState(),
      online: false,
      typed: 'K7Q',
    );
  }, variant: _desktop);
  testWidgets('link: waiting', (t) async {
    await shootLink(
      t,
      'welcome_link_4_waiting',
      const DeviceLinkState(phase: LinkPhase.waiting),
    );
  }, variant: _desktop);
  testWidgets('link: receiving', (t) async {
    await shootLink(t, 'welcome_link_5_receiving', _receiving);
  }, variant: _desktop);
  testWidgets('link: importing', (t) async {
    await shootLink(
      t,
      'welcome_link_6_importing',
      const DeviceLinkState(phase: LinkPhase.importing),
    );
  }, variant: _desktop);
  testWidgets('link: failed', (t) async {
    await shootLink(t, 'welcome_link_7_failed', _failed);
  }, variant: _desktop);
  testWidgets('link: linked', (t) async {
    await shootLink(
      t,
      'welcome_link_8_linked',
      const DeviceLinkState(phase: LinkPhase.done),
    );
  }, variant: _desktop);

  testWidgets('link: phone code', (t) async {
    await shootLink(
      t,
      'welcome_phone_link_code_dark',
      const DeviceLinkState(),
      size: _hand,
      typed: 'K7Q',
    );
  }, variant: _phone);
  testWidgets('link: phone receiving', (t) async {
    await shootLink(
      t,
      'welcome_phone_link_receiving_dark',
      _receiving,
      size: _hand,
    );
  }, variant: _phone);
  testWidgets('link: phone failed, light', (t) async {
    await shootLink(
      t,
      'welcome_phone_link_failed_light',
      _failed,
      size: _hand,
      light: true,
    );
  }, variant: _phone);
}

const _receiving = DeviceLinkState(
  phase: LinkPhase.receiving,
  bytesReceived: 41 * 1024 * 1024,
  totalBytes: 66 * 1024 * 1024,
);

const _failed = DeviceLinkState(
  phase: LinkPhase.failed,
  error: 'The code expired. Make a new one on your other device.',
);

class _SeededLink extends DeviceLinkSyncNotifier {
  final DeviceLinkState seeded;
  _SeededLink(this.seeded);

  @override
  DeviceLinkState build() => seeded;
}

class _Api implements RustLibApi {
  static bool importFails = false;

  @override
  Future<void> crateApiStorageImportBackup({
    required String backupPath,
    required String passphrase,
  }) => importFails
      ? Future.error('Wrong passphrase or corrupted backup')
      : Completer<void>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePicker extends FilePicker {
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
  }) async => FilePickerResult([
    PlatformFile(
      name: 'hollow-backup-2026-09-20.hollow',
      path: r'D:\Backups\hollow-backup-2026-09-20.hollow',
      size: 50541363,
    ),
  ]);
}

/// Fakes only profiles.json and identity.key lookups; every other file goes
/// to the real filesystem (fonts, assets, the PNG writes).
final class _WelcomeIo extends IOOverrides {
  final bool withProfiles;
  _WelcomeIo({required this.withProfiles});

  static const _registry =
      '{"version":1,"active":"D:\\\\Hollow\\\\Mira",'
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
