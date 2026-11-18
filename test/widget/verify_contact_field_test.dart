import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/dialogs/verify_contact_dialog.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// 0.14.1: "Their number" on Verify contact holds a whole pasted safety number
/// (three lines on a phone), so its first line never scrolls out of view.
class _Api implements RustLibApi {
  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  Future<Uint8List?> crateApiStorageGetAvatar({required String peerId}) async =>
      null;

  @override
  Future<String> crateApiVerificationSafetyNumberWith(
          {required String peerId}) async =>
      '052811639472018465520937715046389120475663308217495036128874';

  @override
  String crateApiVerificationFormatSafetyNumber({required String number}) => [
        for (var i = 0; i < number.length; i += 5) number.substring(i, i + 5)
      ].join(' ');

  @override
  bool crateApiVerificationSafetyNumbersMatch(
          {required String expected, required String provided}) =>
      expected == provided.replaceAll(RegExp(r'\D'), '');

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

void main() {
  setUpAll(() => RustLib.initMock(api: _Api()));

  testWidgets('a pasted number shows whole on a phone', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const MobileVerifyContactRoute(peerId: kFriendPeerId1),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    const pasted = '05281 16394 72018 46552 09377 15046 '
        '38912 04756 63308 21749 50361 28874';
    await tester.enterText(find.byType(TextField), pasted);
    await tester.pump();

    final editable =
        tester.state<EditableTextState>(find.descendant(of: find.byType(TextField), matching: find.byType(EditableText))).renderEditable;
    final lines = editable.getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: pasted.length))
        .map((b) => b.top.round())
        .toSet()
        .length;
    expect(lines, greaterThanOrEqualTo(3), reason: 'the fixture must wrap');
    expect(editable.size.height,
        greaterThanOrEqualTo(editable.preferredLineHeight * lines - 0.5),
        reason: 'every line of the number is in view');
    expect(editable.offset.pixels, 0, reason: 'nothing scrolled away');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
