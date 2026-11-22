// What iOS is told about a call lives in native files no Dart test reaches;
// these read them as text so a later edit cannot quietly undo R-AR-04 or the
// audio session rules. Text cannot tell live code from dead: the device checks
// in the #154 checklist stay the proof that the hooks run.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/os_call_provider.dart';

/// [source] without `//` comments, so a comment naming a call proves nothing.
String _code(String source) =>
    source.replaceAll('\r\n', '\n').replaceAll(RegExp(r'//[^\n]*'), '');

/// The body of the method whose declaration starts with [signature], up to
/// its closing brace at [indent].
String _body(String source, String signature, {String indent = ''}) {
  final start = source.indexOf(signature);
  expect(start, isNonNegative, reason: signature);
  final end = source.indexOf('\n$indent}\n', start);
  expect(end, isNonNegative, reason: signature);
  return source.substring(start, end);
}

void main() {
  final plist = File('ios/Runner/Info.plist').readAsStringSync();
  final swift = _code(
    File('ios/Runner/OsCallController.swift').readAsStringSync(),
  );
  final delegate = _code(
    File('ios/Runner/AppDelegate.swift').readAsStringSync(),
  );
  final utils = _code(
    File(
      'packages/flutter_webrtc/common/darwin/Classes/AudioUtils.m',
    ).readAsStringSync(),
  );
  final header = _code(
    File(
      'packages/flutter_webrtc/common/darwin/Classes/AudioUtils.h',
    ).readAsStringSync(),
  );
  const restore = 'restoreSoundsCategoryIfIdle]';

  test('CallKit is entitled: the voip background mode is declared', () {
    // Without it every CXStartCallAction fails "requesttransaction error 1"
    // on a real iPhone, and every call silently takes the fallback.
    final modes = RegExp(
      r'<key>UIBackgroundModes</key>\s*<array>([\s\S]*?)</array>',
    ).firstMatch(plist);
    expect(modes, isNotNull);
    expect(modes!.group(1), contains('<string>voip</string>'));
  });

  test('research apps collect no speech data during a call', () {
    expect(
      plist,
      matches(RegExp(r'<key>SRResearchDataGeneration</key>\s*<false/>')),
    );
  });

  test(
    'only a DM call reaches CallKit; rooms and meetings take the fallback',
    () {
      // The fallback still runs for them: it is what gives a room its audio.
      expect(
        swift,
        contains(
          'let isDm = (args["kind"] as? String) == "${OsCallKind.dm.name}"',
        ),
      );
      final begin = _body(swift, 'private func begin(', indent: '  ');
      final branch = begin.indexOf('if forceFallback || !isDm {');
      expect(branch, isNonNegative);
      final fallback = begin.substring(
        branch,
        begin.indexOf('return false', branch),
      );
      expect(fallback, contains('fallBack('));
      for (final callKitOnly in [
        'HollowCallAudio.callKitCallBegan()',
        'AudioUtils.prepare(forCall:',
        'CXStartCallAction(',
      ]) {
        expect(fallback, isNot(contains(callKitOnly)), reason: callKitOnly);
        expect(
          begin.indexOf(callKitOnly),
          greaterThan(branch),
          reason: callKitOnly,
        );
        // Nothing else in the controller starts a CallKit call.
        expect(callKitOnly.allMatches(swift).length, 1, reason: callKitOnly);
      }
    },
  );

  test("a call's handle is never a name, only the constant one", () {
    // Any construction counts: `CXHandle(`, `CXHandle.init(`, a stored type.
    for (final file in Directory(
      'ios/Runner',
    ).listSync().whereType<File>().where((f) => f.path.endsWith('.swift'))) {
      final text = _code(file.readAsStringSync());
      final handles = RegExp(r'\bCXHandle\b').allMatches(text).length;
      expect(
        handles,
        file.path.endsWith('OsCallController.swift') ? 1 : 0,
        reason: '${file.path}: one CXHandle, built once as anonymousHandle',
      );
    }
    expect(
      swift,
      contains('anonymousHandle = CXHandle(type: .generic, value: "Hollow")'),
    );
    expect(swift, contains('handle: Self.anonymousHandle'));
    expect(swift, contains('remoteHandle = Self.anonymousHandle'));
  });

  group('app sounds get their speaker category back when call audio idles', () {
    // A call leaves playAndRecord behind, whose default output is the
    // earpiece: every app sound and the ringtone played there.
    test('the restore refuses while anything holds call audio', () {
      final body = _body(utils, '+ (void)restoreSoundsCategoryIfIdle');
      final guard = RegExp(
        r'if \(([^{]*)\)\s*\{\s*return;\s*\}',
      ).firstMatch(body);
      expect(guard, isNotNull);
      for (final term in [
        // Outside CallKit mode WebRTC runs the session itself, call or not.
        '!gHollowCallKitMode',
        // A held CallKit call is still counted: its resume needs the category.
        'gHollowCallKitCalls > 0',
        'gHollowCallKitAudioActive',
        'gHollowOwnActive',
        'gHollowFallback > 0',
        'gHollowNet',
      ]) {
        expect(guard!.group(1), contains(term), reason: term);
      }
      expect(
        body.indexOf(guard!.group(0)!),
        lessThan(body.indexOf('AVAudioSessionCategoryAmbient')),
      );
    });

    test('every place call audio ends runs the restore', () {
      for (final hook in [
        '+ (void)callKitCallEnded',
        '+ (void)callKitDidDeactivate:(AVAudioSession*)session',
        '+ (void)fallbackEnded',
      ]) {
        expect(_body(utils, hook), contains(restore), reason: hook);
      }
      expect(
        delegate,
        contains('HollowCallAudio.restoreSoundsCategoryIfIdle()'),
      );
    });

    test('our own deactivation restores only after the session is down', () {
      final body = _body(utils, '+ (void)deactivateOwnIfIdle');
      final underCallKit = body.indexOf('if (gHollowCallKitAudioActive) {');
      final down = body.indexOf('setActive:NO');
      expect(underCallKit, isNonNegative);
      expect(down, greaterThan(underCallKit));
      expect(body.indexOf(restore), greaterThan(down));
    });

    test('a net turned off restores even if it never activated', () {
      // A failed activateOwn leaves gHollowOwnActive NO, and
      // deactivateOwnIfIdle returns before its own restore.
      final body = _body(utils, '+ (void)setSafetyNet:(BOOL)on');
      final off = body.lastIndexOf('if (!on) {');
      expect(off, isNonNegative);
      final branch = body.substring(off);
      expect(
        branch.indexOf(restore),
        greaterThan(branch.indexOf('[self deactivateOwnIfIdle]')),
      );
    });

    test('a speaker change leaves no call category behind', () {
      // Dart resets the route after a call ends, which can come after the
      // restore when the person hung up from the system UI.
      for (final method in [
        '+ (void)setSpeakerphoneOn:(BOOL)enable',
        '+ (void)setSpeakerphoneOnButPreferBluetooth',
      ]) {
        final body = _body(utils, method).trimRight();
        expect(body, endsWith('[HollowCallAudio $restore;'), reason: method);
      }
    });
  });

  group('the ringback', () {
    String startLoop() => _body(delegate, 'func startLoop(', indent: '  ');

    test('waits for call audio only while a CallKit call exists', () {
      // Ringing out is no OS call: waiting on callKitMode() held the ringback
      // for a call CallKit never hears of.
      expect(startLoop(), contains('if HollowCallAudio.callKitCalls() > 0 {'));
      expect(startLoop(), isNot(contains('callKitMode()')));
    });

    test('right after a call, waits for CallKit to let its session go', () {
      // A loop started under the dying CallKit session plays at the ear and
      // is cut when CallKit deactivates it.
      expect(header, contains('+ (BOOL)callKitAudioActive;'));
      expect(header, contains('HollowCallKitAudioDeactivatedNotification'));
      expect(
        _body(utils, '+ (void)callKitDidDeactivate:(AVAudioSession*)session'),
        contains('HollowCallKitAudioDeactivatedNotification'),
      );
      final loop = startLoop();
      final branch = loop.indexOf('if HollowCallAudio.callKitAudioActive() {');
      expect(branch, isNonNegative);
      final wait = loop.substring(branch);
      expect(wait, contains('.HollowCallKitAudioDeactivated'));
      expect(wait, contains('within: Self.endedCallWait'));
      expect(
        wait.indexOf('HollowCallAudio.restoreSoundsCategoryIfIdle()'),
        allOf(isNonNegative, lessThan(wait.indexOf('startLoopNow('))),
      );
      final bound = RegExp(
        r'endedCallWait: TimeInterval = ([\d.]+)',
      ).firstMatch(delegate);
      expect(bound, isNotNull);
      expect(double.parse(bound!.group(1)!), inInclusiveRange(1, 2));
    });
  });
}
