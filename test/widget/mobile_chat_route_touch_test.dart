// The phone chat page's touch behaviour: a tap on the conversation puts the
// keyboard away, the expression picker is a tall sheet, a DM can be searched,
// and the composer's bar runs down to the screen's bottom edge.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/expression_picker.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// Every FFI call stays pending, so the page sits in its loading states and
/// nothing fails or retries on a timer.
class _PendingApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _QuietTray extends FlutterLocalNotificationsPlatform {}

Future<void> _openDm(WidgetTester tester) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = const FakeViewPadding(top: 40, bottom: 34);
  addTearDown(tester.view.reset);
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(),
    child: MaterialApp(
      navigatorKey: nav,
      theme: HollowThemeData.dark(),
      home: const Scaffold(body: Text('home')),
    ),
  ));
  unawaited(nav.currentState!.push(hollowMobileRoute<void>(
    settings: const RouteSettings(name: MobileChatRoute.routeName),
    builder: (_) => const MobileChatRoute(peerId: kFriendPeerId1),
  )));
  await _settle(tester);
  expect(find.byType(MobileChatRoute), findsOneWidget);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

/// Runs out the page's open-time timers (the missing-files request).
Future<void> _drain(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 2));

EditableText _composer(WidgetTester tester) =>
    tester.widget<EditableText>(find.descendant(
      of: find.byType(MobileChatRoute),
      matching: find.byType(EditableText),
    ).last);

void main() {
  setUpAll(() {
    RustLib.initMock(api: _PendingApi());
    FlutterLocalNotificationsPlatform.instance = _QuietTray();
  });

  testWidgets('a tap on the conversation puts the keyboard away',
      (tester) async {
    await _openDm(tester);
    await tester.tap(find.byType(EditableText).last);
    await tester.pump();
    expect(_composer(tester).focusNode.hasFocus, isTrue);

    // The middle of the message area, away from the header and composer.
    await tester.tapAt(const Offset(200, 300));
    await tester.pump();
    expect(_composer(tester).focusNode.hasFocus, isFalse);
    await _drain(tester);
  });

  testWidgets('the expression picker opens as a tall sheet', (tester) async {
    await _openDm(tester);
    await tester.tap(find.bySemanticsLabel('Emoji, GIFs and stickers'));
    await _settle(tester);
    final panel = find.byType(ExpressionPanel);
    expect(panel, findsOneWidget);
    // Well past the keyboard-sized panel it replaced.
    expect(tester.getSize(panel).height, greaterThan(800 * 0.6));
    expect(tester.getTopLeft(panel).dy,
        greaterThanOrEqualTo(800 * (1 - kSheetTallHeightFactor)));
    await _drain(tester);
  });

  testWidgets('a DM has message search', (tester) async {
    await _openDm(tester);
    await tester.tap(find.bySemanticsLabel('Search messages'));
    await _settle(tester);
    expect(find.textContaining('Search in'), findsOneWidget);
    await _drain(tester);
  });

  testWidgets('the composer bar runs to the bottom edge', (tester) async {
    await _openDm(tester);
    final hollow = HollowTheme.of(tester.element(find.byType(MobileChatRoute)));
    // Something in the composer's colour fills the home indicator strip.
    final strip = find.byWidgetPredicate((w) =>
        w is ColoredBox && w.color == hollow.surface);
    final covers = strip.evaluate().any((e) {
      final box = e.renderObject as RenderBox;
      final top = box.localToGlobal(Offset.zero).dy;
      return top <= 800 - 34 && top + box.size.height >= 800;
    });
    expect(covers, isTrue);
    await _drain(tester);
  });
}
