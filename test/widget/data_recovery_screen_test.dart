import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/profile_registry.dart';
import 'package:hollow/src/rust/api/recovery.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/dialogs/welcome_dialog.dart';
import 'package:hollow/src/ui/shell/data_recovery.dart';

class _RecoveryApi implements RustLibApi {
  StoreTrouble trouble = StoreTrouble.unreadable;
  int repairs = 0;
  int relinks = 0;
  Object? repairError;
  final reports = <bool>[];

  @override
  Future<StoreTrouble> crateApiRecoveryStoreTrouble() async => trouble;

  @override
  Future<RepairOutcome> crateApiRecoveryRepairThisDevice() async {
    repairs++;
    if (repairError != null) throw repairError!;
    return const RepairOutcome(folder: 'unreadable-2026-10-10', restored: false);
  }

  @override
  Future<String> crateApiRecoveryRelinkThisDevice() async {
    relinks++;
    return '/nowhere/hollow-old-2026-10-10';
  }

  @override
  Future<String> crateApiRecoveryDiagnosticsReport({required bool starting}) async {
    reports.add(starting);
    return starting ? '' : 'Data folder\n  messages.db 4096 bytes';
  }

  @override
  String crateApiUpdaterGetCurrentVersion() => '0.12.1';

  @override
  int crateApiUpdaterGetCurrentBuild() => 0;

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _api = _RecoveryApi();

Future<List<String>> _pump(WidgetTester tester,
    {required bool phone,
    Size size = const Size(1280, 800),
    bool bare = false}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repaired = <String>[];
  final screen = DataTroubleScreen(
    error: 'Failed to set performance PRAGMAs: file is not a database',
    phone: phone,
    onRepaired: (relay) async => repaired.add(relay),
  );
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      // The shell puts the screen straight under the app, with no Scaffold.
      home: bare ? screen : Scaffold(body: screen),
    ),
  ));
  await tester.pumpAndSettle();
  return repaired;
}

void main() {
  setUpAll(() => RustLib.initMock(api: _api));
  setUp(() {
    _api
      ..trouble = StoreTrouble.unreadable
      ..repairs = 0
      ..relinks = 0
      ..repairError = null
      ..reports.clear();
  });

  for (final phone in [false, true]) {
    final where = phone ? 'phone' : 'desktop';
    final size = phone ? const Size(375, 760) : const Size(1280, 800);

    testWidgets('$where: an unreadable database offers repair first, link again '
        'second and diagnostics', (tester) async {
      await _pump(tester, phone: phone, size: size);
      expect(find.text("Hollow can't open your data on this device"), findsOneWidget);
      expect(find.text('Repair this device'), findsOneWidget);
      expect(find.text('Link this device again'), findsOneWidget);
      expect(find.text('Copy diagnostics'), findsOneWidget);
      expect(find.text('Restart Hollow'), findsNothing);
      expect(
        find.textContaining(phone ? 'Moves everything on this phone aside' : 'into a separate profile'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('$where: a repair runs inside its dialog and hands the relay on',
        (tester) async {
      final repaired = await _pump(tester, phone: phone, size: size);
      await tester.tap(find.text('Repair this device'));
      await tester.pumpAndSettle();
      expect(find.text('Repair this device?'), findsOneWidget);
      expect(find.textContaining('unreadable-'), findsOneWidget);
      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), 'relay.example.org');
      await tester.tap(find.text('Repair'));
      await tester.pumpAndSettle();
      expect(_api.repairs, 1);
      expect(repaired, ['relay.example.org']);
    });
  }

  testWidgets('the screen brings its own text style, as the shell gives none',
      (tester) async {
    await _pump(tester, phone: true, size: const Size(375, 760), bare: true);
    for (final text in [
      "Hollow can't open your data on this device",
      'Your identity is fine.',
    ]) {
      final style = tester
          .renderObject<RenderParagraph>(find.textContaining(text))
          .text
          .style;
      expect(style?.decoration ?? TextDecoration.none, TextDecoration.none,
          reason: 'no debug underline under "$text"');
    }
  });

  testWidgets('a held repair says so inside the dialog and repairs nothing more',
      (tester) async {
    _api.repairError = "Another program is using Hollow's files. Close it and try again.";
    final repaired = await _pump(tester, phone: false);
    await tester.tap(find.text('Repair this device'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repair'));
    await tester.pumpAndSettle();
    expect(find.text("Another program is using Hollow's files. Close it and try again."), findsOneWidget);
    expect(repaired, isEmpty);
  });

  testWidgets('a cancelled repair changes nothing', (tester) async {
    final repaired = await _pump(tester, phone: false);
    await tester.tap(find.text('Repair this device'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(_api.repairs, 0);
    expect(repaired, isEmpty);
  });

  testWidgets('a held database offers only a restart and diagnostics', (tester) async {
    _api.trouble = StoreTrouble.held;
    await _pump(tester, phone: false);
    expect(find.text("Hollow can't open your data right now"), findsOneWidget);
    expect(find.text('Restart Hollow'), findsOneWidget);
    expect(find.text('Repair this device'), findsNothing);
    expect(find.text('Link this device again'), findsNothing);
  });

  testWidgets('an unfinished start-up step looks as it always did and its '
      'diagnostics carry no file list', (tester) async {
    _api.trouble = StoreTrouble.notReady;
    await _pump(tester, phone: false);
    expect(find.text("Hollow couldn't open your identity"), findsOneWidget);
    expect(find.text('Repair this device'), findsNothing);
    expect(find.text('Link this device again'), findsNothing);
    await tester.tap(find.text('Copy diagnostics'));
    await tester.pumpAndSettle();
    expect(_api.reports, [true]);
    expect(find.textContaining('messages.db'), findsNothing);
  });

  testWidgets('diagnostics show what is copied and copy it on Copy', (tester) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await _pump(tester, phone: false);
    await tester.tap(find.text('Copy diagnostics'));
    await tester.pumpAndSettle();
    expect(find.text('Diagnostics'), findsOneWidget);
    expect(find.textContaining('messages.db 4096 bytes'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(copied, contains('Hollow 0.12.1'));
    expect(copied, contains('Trouble unreadable'));
    expect(copied, contains('messages.db 4096 bytes'));
    await tester.pumpAndSettle(const Duration(seconds: 4));
  });

  testWidgets('link again tells where the old data goes before it moves anything',
      (tester) async {
    await _pump(tester, phone: true, size: const Size(375, 760));
    await tester.tap(find.text('Link this device again'));
    await tester.pumpAndSettle();
    expect(find.text('Link this device again?'), findsOneWidget);
    expect(find.textContaining("a folder Hollow keeps but can't open"), findsOneWidget);
    expect(find.textContaining('Remove the older entry'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(_api.relinks, 0);
  });

  testWidgets('desktop link again names the profile the old data becomes', (tester) async {
    await _pump(tester, phone: false);
    await tester.tap(find.text('Link this device again'));
    await tester.pumpAndSettle();
    expect(find.textContaining('a profile named Old data from '), findsOneWidget);
    expect(find.textContaining('Settings > Profile'), findsOneWidget);
  });

  group('Welcome after a relink', () {
    Future<void> openWelcome(WidgetTester tester, String relinkedTo, Size size) async {
      IOOverrides.global = _NoProfiles();
      addTearDown(() => IOOverrides.global = null);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late BuildContext host;
      await tester.pumpWidget(MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(body: Builder(builder: (c) {
          host = c;
          return const SizedBox.expand();
        })),
      ));
      showWelcomeDialog(host, relinkedTo: relinkedTo);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agree and continue'));
      await tester.pumpAndSettle();
    }

    testWidgets('desktop names the old data and leads with linking', (tester) async {
      await openWelcome(tester, 'Old data from Oct 10, 2026', const Size(1440, 900));
      expect(
        find.text('Your old data is in the Old data from Oct 10, 2026 profile. '
            'Link this device to bring your messages back.'),
        findsOneWidget,
      );
      final link = tester.getTopLeft(find.text('Link a device'));
      final create = tester.getTopLeft(find.text('Create an identity'));
      expect(link.dy, lessThan(create.dy));
      expect(find.text('Link a device'), findsOneWidget, reason: 'one way to link, not two');
    });

    testWidgets('a phone says the phone line', (tester) async {
      await openWelcome(tester, '', const Size(375, 760));
      expect(find.text('Link this phone to bring your messages back.'), findsOneWidget);
    });
  });

  group('kept profiles', () {
    test('a relink lists its old data once', () {
      const reg = ProfileRegistry();
      final once = registryWithKeptProfile(reg, '/d/hollow-old-2026-10-10', 'Old data from Oct 10, 2026');
      final twice = registryWithKeptProfile(once, '/d/hollow-old-2026-10-10', 'Other');
      expect(twice.custom.map((p) => p.name), ['Old data from Oct 10, 2026']);
    });

    test('a destroy drops the old data it erased, and only that', () {
      const reg = ProfileRegistry(custom: [
        HollowProfile(name: 'Old data from Oct 10, 2026', path: '/d/hollow-old-2026-10-10'),
        HollowProfile(name: 'Old data still there', path: '/d/hollow-old-2026-10-11-2'),
        HollowProfile(name: 'Old data gone too', path: '/d/hollow-old-2026-10-12-3'),
        HollowProfile(name: 'Another profile', path: '/d/hollow-old-friend'),
        HollowProfile(name: 'Elsewhere', path: '/e/hollow-old-2026-10-10'),
      ]);
      final next = registryAfterWipe(reg, '/d/hollow',
          runningRoot: '/d/hollow',
          profilePaths: const ['/d/hollow'],
          holdsIdentity: (_) => false,
          folderExists: (p) => p.endsWith('-11-2'));
      expect(next.custom.map((p) => p.name),
          ['Old data still there', 'Another profile', 'Elsewhere']);
    });

    test('the day comes from the kept folder name', () {
      expect(keptDayOf(r'C:\Users\x\AppData\Roaming\hollow-old-2026-10-09-3'), DateTime.utc(2026, 10, 9));
      expect(keptDayOf('/d/hollow'), isNull);
      expect(keptProfileName(DateTime.utc(2026, 10, 9)), 'Old data from Oct 9, 2026');
    });

    test('old data relinked from old data is still the root\'s', () {
      expect(isKeptAsideOf('/d/hollow-old-2026-10-10-old-2026-10-11-2', '/d/hollow'), isTrue);
      expect(isKeptAsideOf('/d/hollow-old-2026-10-10-old-friend', '/d/hollow'), isFalse);
      expect(isKeptAsideOf('/d/hollow-old-2026-10-10', '/d/hollow-old-2026-10-10'), isFalse);
    });

    test('only the install\'s own profile list takes old data', () {
      bool lists({bool phone = false, bool portable = false, bool pinned = false, bool env = false}) =>
          listsKeptProfiles(phone: phone, portable: portable, pinned: pinned, envOverride: env);
      expect(lists(), isTrue, reason: 'control: the installed default profile');
      expect(lists(pinned: true), isTrue, reason: 'a pinned profile lives in that list');
      expect(lists(portable: true), isFalse, reason: 'a portable stick never writes the host list');
      expect(lists(portable: true, pinned: true), isTrue, reason: 'a pin onto the portable folder is in the list already');
      expect(lists(env: true), isFalse, reason: 'a data folder override never writes the host list');
      expect(lists(env: true, pinned: true), isFalse);
      expect(lists(phone: true), isFalse);
    });
  });

  group('old data no profile lists', () {
    Future<BuildContext> host(WidgetTester tester) async {
      IOOverrides.global = _NoProfiles();
      addTearDown(() => IOOverrides.global = null);
      late BuildContext context;
      await tester.pumpWidget(MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(body: Builder(builder: (c) {
          context = c;
          return const SizedBox.expand();
        })),
      ));
      return context;
    }

    testWidgets('link again says the old data goes to a folder, not a profile', (tester) async {
      final context = await host(tester);
      showHollowDialog<bool>(
          context: context, builder: (_) => const RelinkDialog(phone: false, listed: false));
      await tester.pumpAndSettle();
      expect(
        find.text("Everything on this device moves into a new folder next to Hollow's data "
            'folder. Erasing this device later erases it too.'),
        findsOneWidget,
      );
      expect(find.textContaining('Settings > Profile'), findsNothing);
    });

    testWidgets('Welcome says where the folder is and leads with linking', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final context = await host(tester);
      showWelcomeDialog(context, relinkedFolder: '/media/stick/hollow_data-old-2026-10-10');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agree and continue'));
      await tester.pumpAndSettle();
      expect(
        find.text('Your old data is in this folder. Link this device to bring your '
            'messages back.'),
        findsOneWidget,
      );
      expect(find.text('/media/stick/hollow_data-old-2026-10-10'), findsOneWidget,
          reason: 'the folder on a line of its own');
      final link = tester.getTopLeft(find.text('Link a device'));
      final create = tester.getTopLeft(find.text('Create an identity'));
      expect(link.dy, lessThan(create.dy));
    });
  });
}

/// No profile registry and no identities, so no real profile on this machine
/// is ever read into the test.
final class _NoProfiles extends IOOverrides {
  @override
  File createFile(String path) =>
      path.endsWith('profiles.json') || path.endsWith('identity.key')
          ? _Missing(path)
          : super.createFile(path);
}

class _Missing implements File {
  _Missing(this.path);
  @override
  final String path;
  @override
  bool existsSync() => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
