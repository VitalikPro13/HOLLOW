// C-LOCAL-09/10: a copied secret leaves the clipboard again, and a phrase
// screen keeps itself out of screenshots only while it is up.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/privacy_screen.dart';
import 'package:hollow/src/core/services/secret_clipboard.dart';

const _phrase = 'abandon ability able about above absent absorb abstract';
const _privacy = MethodChannel('hollow/privacy');

String? _clip;
final _privacyCalls = <MethodCall>[];

void _mockChannels({Object? Function(MethodCall call)? privacy}) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    switch (call.method) {
      case 'Clipboard.setData':
        _clip = (call.arguments as Map)['text'] as String?;
        return null;
      case 'Clipboard.getData':
        return _clip == null ? null : {'text': _clip};
    }
    return null;
  });
  messenger.setMockMethodCallHandler(_privacy, (call) async {
    _privacyCalls.add(call);
    return privacy?.call(call);
  });
}

void main() {
  setUp(() {
    _clip = null;
    _privacyCalls.clear();
  });
  tearDown(() {
    SecretClipboard.debugPlatform = null;
    PrivacyScreen.debugForceMobile = false;
  });

  group('desktop', () {
    setUp(() => SecretClipboard.debugPlatform = TargetPlatform.windows);

    testWidgets('the phrase is cleared after a minute', (tester) async {
      _mockChannels();
      await SecretClipboard.copy(_phrase);
      expect(_clip, _phrase);

      await tester.pump(const Duration(seconds: 59));
      expect(_clip, _phrase);
      await tester.pump(const Duration(seconds: 2));
      expect(_clip, isEmpty);
    });

    testWidgets('something copied since is left alone', (tester) async {
      _mockChannels();
      await SecretClipboard.copy(_phrase);
      _clip = 'a shopping list';
      await tester.pump(const Duration(seconds: 61));
      expect(_clip, 'a shopping list');
    });
  });

  testWidgets('iOS hands the phrase to an expiring, local-only pasteboard',
      (tester) async {
    SecretClipboard.debugPlatform = TargetPlatform.iOS;
    _mockChannels(privacy: (_) => true);
    await SecretClipboard.copy(_phrase);

    expect(_privacyCalls.single.method, 'copySecret');
    expect(_privacyCalls.single.arguments,
        {'text': _phrase, 'seconds': SecretClipboard.clearAfter.inSeconds});
    expect(_clip, isNull, reason: 'never through the plain clipboard');
  });

  testWidgets('Android clears its labelled clip, asking again on return',
      (tester) async {
    SecretClipboard.debugPlatform = TargetPlatform.android;
    var answer = 'unknown';
    _mockChannels(privacy: (call) {
      if (call.method == 'copySecret') return true;
      if (call.method == 'clearSecret') return answer;
      return null;
    });
    await SecretClipboard.copy(_phrase);
    expect(_privacyCalls.map((c) => c.method), ['copySecret']);

    // Backgrounded: the clipboard cannot be judged yet.
    await tester.pump(const Duration(seconds: 61));
    expect(_privacyCalls.map((c) => c.method), ['copySecret', 'clearSecret']);

    answer = 'cleared';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(_privacyCalls.map((c) => c.method),
        ['copySecret', 'clearSecret', 'clearSecret']);
  });

  testWidgets('a phrase screen blocks capture only while it is up',
      (tester) async {
    PrivacyScreen.debugForceMobile = true;
    _mockChannels();

    Widget screens({required bool outer, required bool inner}) =>
        Directionality(
          textDirection: TextDirection.ltr,
          child: outer
              ? SecretScreen(
                  child: inner
                      ? const SecretScreen(child: SizedBox())
                      : const SizedBox(),
                )
              : const SizedBox(),
        );

    await tester.pumpWidget(screens(outer: true, inner: true));
    expect(PrivacyScreen.holds, 2);
    await tester.pumpWidget(screens(outer: true, inner: false));
    expect(PrivacyScreen.holds, 1);
    await tester.pumpWidget(screens(outer: false, inner: false));
    expect(PrivacyScreen.holds, 0);

    expect(
      _privacyCalls
          .where((c) => c.method == 'setSecureScreen')
          .map((c) => c.arguments),
      [true, false],
      reason: 'one flag for the nested screens, cleared when the last goes',
    );
  });
}
