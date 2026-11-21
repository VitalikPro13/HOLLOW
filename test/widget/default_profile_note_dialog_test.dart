import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/shell/data_recovery.dart';

/// #155 review: the note about an identity left in the Default profile offers the
/// switch itself (the existing profile switch, restart included), closes with the
/// dialog's close control and has no lone "OK". Renders land in HOLLOW_SHOT_DIR,
/// else build/ui_screenshots/default_profile_note.
const _root = '/Users/someone/Library/Application Support/hollow';
const _shotKey = Key('screenshot-boundary');

void main() {
  final sep = Platform.pathSeparator;
  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${sep}build${sep}ui_screenshots${sep}default_profile_note';

  setUpAll(() async {
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

  Future<void> open(WidgetTester tester, Widget dialog,
      {Size size = const Size(1280, 800), bool light = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      child: RepaintBoundary(
        key: _shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () =>
                      showHollowDialog<void>(context: context, builder: (_) => dialog),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(_shotKey));
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

  testWidgets('the primary switches to Default through the profile switch',
      (tester) async {
    final switched = <String>[];
    await open(
        tester,
        DefaultProfileNoteDialog(
          defaultRoot: _root,
          switchTo: (path) async => switched.add(path),
        ));
    expect(find.text('Your other identity is still here'), findsOneWidget);
    expect(find.byType(HollowDialogCloseButton), findsOneWidget);
    expect(find.text('OK'), findsNothing);
    final primary = find.widgetWithText(HollowButton, 'Switch to Default');
    expect(primary, findsOneWidget);
    expect(tester.widget<HollowButton>(primary).variant, HollowButtonVariant.filled);
    expect(
        find.textContaining('To switch later, open Settings, then Files & storage.'),
        findsOneWidget);

    await tester.tap(primary);
    await tester.pump();
    expect(switched, [_root]);
  });

  testWidgets('a failed switch stays open and says so', (tester) async {
    await open(
        tester,
        DefaultProfileNoteDialog(
          defaultRoot: _root,
          switchTo: (_) async => throw const FileSystemException('denied'),
        ));
    await tester.tap(find.text('Switch to Default'));
    await tester.pumpAndSettle();
    expect(find.text('Your other identity is still here'), findsOneWidget);
    expect(find.textContaining("couldn't switch"), findsOneWidget);
  });

  testWidgets('the close control leaves the person on this profile',
      (tester) async {
    final switched = <String>[];
    await open(
        tester,
        DefaultProfileNoteDialog(
          defaultRoot: _root,
          switchTo: (path) async => switched.add(path),
        ));
    await tester.tap(find.byType(HollowDialogCloseButton));
    await tester.pumpAndSettle();
    expect(find.text('Your other identity is still here'), findsNothing);
    expect(switched, isEmpty);
  });

  test('by default it runs the existing profile switch', () {
    const dialog = DefaultProfileNoteDialog(defaultRoot: _root);
    expect(identical(dialog.switchTo, switchProfileAndRestart), isTrue);
  });

  for (final light in [false, true]) {
    final theme = light ? 'light' : 'dark';
    testWidgets('renders ($theme)', (tester) async {
      final after = DefaultProfileNoteDialog(defaultRoot: _root, switchTo: (_) async {});
      await open(tester, after, light: light);
      await capture(tester, 'after_desktop_$theme');
      await open(tester, after, size: const Size(375, 760), light: light);
      await capture(tester, 'after_phone_$theme');
      await open(tester, const _Before(), light: light);
      await capture(tester, 'before_desktop_$theme');
      await open(tester, const _Before(), size: const Size(375, 760), light: light);
      await capture(tester, 'before_phone_$theme');
    });
  }
}

/// The note as it was before this round (lone OK, no switch), for the before|after image.
class _Before extends StatelessWidget {
  const _Before();

  @override
  Widget build(BuildContext context) {
    return HollowDialog(
      title: 'Your other identity is still here',
      content: const HollowDialogText(
          'Hollow is using the profile in the folder next to the app. The '
          'identity you had before is still on this computer, in the Default '
          'profile. To go back to it, open Settings, then Files & storage, and '
          'switch to Default.'),
      actions: [
        HollowButton.filled(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    );
  }
}
