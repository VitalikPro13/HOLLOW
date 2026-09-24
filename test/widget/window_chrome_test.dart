/// Dock mode folds the 32 px title bar into its header: the window controls
/// float over the header's end, and everything that cannot move the window on
/// its own (Classic, the welcome screens, the lock cover) keeps the title bar.
@TestOn('windows || linux')
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/annotation_mode_provider.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/window_chrome_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/app.dart';
import 'package:hollow/src/ui/shell/window_title_bar.dart';
import 'package:window_manager/window_manager.dart';

import '../helpers/test_app.dart';

class _NoIdentity extends IdentityNotifier {
  @override
  IdentityState build() => const IdentityState();
}

Future<ProviderContainer> _pumpFrame(WidgetTester tester,
    {bool dockOwns = false, bool identity = true}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final container = ProviderContainer(
    overrides: hollowTestOverrides(extra: [
      if (!identity) identityProvider.overrideWith(_NoIdentity.new),
    ]),
  );
  addTearDown(container.dispose);
  container.read(dockOwnsWindowChromeProvider.notifier).state = dockOwns;
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: const SizedBox.expand(),
      navigatorObservers: [routesAboveHome],
      builder: (context, child) => DesktopWindowFrame(child: child!),
    ),
  ));
  await tester.pump();
  return container;
}

void main() {
  testWidgets('the dock header owns the chrome: no title bar, floating controls',
      (tester) async {
    final c = await _pumpFrame(tester, dockOwns: true);
    expect(find.byType(WindowTitleBar), findsNothing);
    expect(find.byType(WindowControls), findsOneWidget);
    expect(tester.getSize(find.byType(WindowControls)).height,
        kDockHeaderHeight);
    expect(c.read(windowControlsWidthProvider), greaterThan(0),
        reason: 'the header reserves the controls width');

    // Close sits in the window's top-right corner.
    final close = find.bySemanticsLabel('Close');
    expect(tester.getTopRight(close), const Offset(1280, 0));
  });

  testWidgets('without the dock the title bar stays', (tester) async {
    await _pumpFrame(tester);
    expect(find.byType(WindowTitleBar), findsOneWidget);
  });

  testWidgets('the lock cover brings the title bar back', (tester) async {
    final c = await _pumpFrame(tester, dockOwns: true);
    c.read(appLockedProvider.notifier).setLocked(true);
    await tester.pump();
    expect(find.byType(WindowTitleBar), findsOneWidget);
    expect(find.byType(WindowControls), findsOneWidget,
        reason: 'inside the title bar now');
  });

  testWidgets('annotation mode drops the floating controls too',
      (tester) async {
    final c = await _pumpFrame(tester, dockOwns: true);
    c.read(annotationModeProvider.notifier).state = true;
    await tester.pump();
    expect(find.byType(WindowTitleBar), findsNothing);
    expect(find.byType(WindowControls), findsNothing);
  });

  testWidgets('Welcome and the password prompt keep the title bar',
      (tester) async {
    await _pumpFrame(tester, dockOwns: true, identity: false);
    expect(find.byType(WindowTitleBar), findsOneWidget,
        reason: 'no identity yet: the welcome dialog covers the dock');
  });

  testWidgets('a dialog over the dock leaves the header draggable',
      (tester) async {
    await _pumpFrame(tester, dockOwns: true);
    // The title bar has none of its own, so only the strip is one.
    expect(find.byType(DragToMoveArea), findsNothing);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(PageRouteBuilder<void>(
      opaque: false,
      pageBuilder: (_, _, _) => const SizedBox.expand(),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.byType(DragToMoveArea), findsOneWidget);

    navigator.pop();
    await tester.pump();
    await tester.pump();
    expect(find.byType(DragToMoveArea), findsNothing);
  });
}
