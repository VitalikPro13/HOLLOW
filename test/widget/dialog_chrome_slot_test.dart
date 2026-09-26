import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/window_chrome_provider.dart';
import 'package:hollow/src/core/services/window_fullscreen.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';

class _Windowed extends FullscreenNotifier {
  @override
  bool build() => false;
}

class _Fullscreen extends FullscreenNotifier {
  @override
  bool build() => true;
}

const _body = Key('dialog-body');

/// Opens a dialog far taller than the window, the case that used to run up
/// into the Dock header.
Future<Rect> _openTallDialog(
  WidgetTester tester, {
  required bool dockOwnsChrome,
  bool fullscreen = false,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      dockOwnsWindowChromeProvider.overrideWith((_) => dockOwnsChrome),
      fullscreenProvider
          .overrideWith(fullscreen ? _Fullscreen.new : _Windowed.new),
    ],
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showHollowDialog<void>(
              context: context,
              builder: (_) => const HollowDialogSurface(
                padded: false,
                child: SingleChildScrollView(
                  child: SizedBox(key: _body, width: 400, height: 3000),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return tester.getRect(find.byType(SingleChildScrollView));
}

void main() {
  testWidgets('in the Dock a dialog never reaches the header band',
      (tester) async {
    final rect = await _openTallDialog(tester, dockOwnsChrome: true);
    expect(rect.top, greaterThanOrEqualTo(kDockHeaderHeight));
    expect(rect.bottom, lessThanOrEqualTo(720));
  });

  testWidgets('without the Dock header a dialog uses the whole window',
      (tester) async {
    final rect = await _openTallDialog(tester, dockOwnsChrome: false);
    expect(rect.top, lessThan(kDockHeaderHeight));
  });

  testWidgets('in fullscreen the hidden header takes no band', (tester) async {
    final rect =
        await _openTallDialog(tester, dockOwnsChrome: true, fullscreen: true);
    expect(rect.top, lessThan(kDockHeaderHeight));
  });

  testWidgets('the dialog reads the slot, not the window, as its screen',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Size? seen;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dockOwnsWindowChromeProvider.overrideWith((_) => true),
        fullscreenProvider.overrideWith(_Windowed.new),
      ],
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showHollowDialog<void>(
              context: context,
              builder: (context) {
                seen = MediaQuery.sizeOf(context);
                return const SizedBox.shrink();
              },
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(seen, const Size(1280, 720 - kDockHeaderHeight));
  });
}
