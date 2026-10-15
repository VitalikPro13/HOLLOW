/// Toasts raised by network events come from code with no widget context, only
/// the Navigator key. They must land in the Navigator's overlay: resolving an
/// Overlay from the Navigator's own context throws, which lost every "Joined X"
/// toast and cleared whatever toast was showing.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/event_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_toast.dart';

Future<void> _pumpApp(WidgetTester tester) => tester.pumpWidget(MaterialApp(
      navigatorKey: hollowNavigatorKey,
      theme: HollowThemeData.dark(),
      home: const SizedBox.expand(),
    ));

/// Every `HollowToast.show(` call in [path] that does not pass `overlayState:`.
List<int> _callsWithoutOverlay(String path) {
  final lines = File(path).readAsLinesSync();
  final bad = <int>[];
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].contains('HollowToast.show(')) continue;
    final call = lines.skip(i).take(8).join('\n');
    final end = call.indexOf(');');
    final args = end < 0 ? call : call.substring(0, end);
    if (!args.contains('overlayState:')) bad.add(i + 1);
  }
  return bad;
}

void main() {
  testWidgets('event_toasts_reach_the_navigator_overlay', (tester) async {
    await _pumpApp(tester);

    showEventToast('Joined Lounge', kind: 'joined', type: HollowToastType.success);
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(find.text('Joined Lounge'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('Joined Lounge'), findsNothing);
  });

  testWidgets('the Navigator context alone has no overlay for a toast',
      (tester) async {
    await _pumpApp(tester);
    expect(
      () => HollowToast.show(hollowNavigatorKey.currentContext!, 'Joined Lounge'),
      throwsA(isA<FlutterError>()),
    );
  });

  test('event and provider toasts always name the overlay', () {
    for (final path in [
      'lib/src/core/providers/event_provider.dart',
      'lib/src/core/providers/pending_join_provider.dart',
      'lib/src/core/providers/webrtc_provider.dart',
    ]) {
      expect(_callsWithoutOverlay(path), isEmpty,
          reason: '$path calls HollowToast.show without overlayState:');
    }
  });
}
