import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/crash_log.dart';
import 'package:hollow/src/core/log_redaction.dart';
import 'package:hollow/src/core/services/destroy_flow.dart';
import 'package:hollow/src/core/services/push_notification_service.dart';

/// What a wipe leaves behind and what the logs give away: a duress code at any
/// Settings prompt ends the session like the launch prompt, the push
/// registration goes without waiting on the network, the crash log goes with
/// the identity, and the support export names nobody.
void main() {
  group('a duress code at a Settings prompt', () {
    late int ended;
    final never = Completer<Never>();

    setUp(() {
      ended = 0;
      onDuressAtPrompt = () {
        ended++;
        return never.future;
      };
    });
    tearDown(() => onDuressAtPrompt = endSessionAfterDuress);

    test('recognises Rust\'s answer and nothing else', () {
      expect(isDuressResult(AnyhowException('duress')), isTrue);
      expect(isDuressResult('duress'), isTrue);
      expect(
          isDuressResult(
              AnyhowException('Wrong password or corrupted identity file')),
          isFalse);
      expect(
          isDuressResult(AnyhowException(
              'That is your duress code. Choose a different password.')),
          isFalse);
    });

    test('ends the session and never lets the dialog hear an error', () async {
      var settled = false;
      unawaited(withTypedSecret<void>(
              () => Future.error(AnyhowException('duress')))
          .then((_) => settled = true, onError: (_) => settled = true));
      await pumpEventQueue();
      expect(ended, 1);
      expect(settled, isFalse, reason: 'the spinner stays until the restart');
    });

    test('a wrong password is still an error the dialog shows', () async {
      await expectLater(
          withTypedSecret<void>(() => Future.error(
              AnyhowException('Wrong password or corrupted identity file'))),
          throwsA(isA<AnyhowException>()));
      expect(ended, 0);
      expect(await withTypedSecret(() async => 7), 7);
    });
  });

  group('forgetting the push registration', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('wipe_traces_'));
    tearDown(() {
      pushDirOverride = null;
      dir.deleteSync(recursive: true);
    });

    test('fires every provider without waiting and deletes the push files',
        () async {
      var fired = 0;
      final hung = Completer<void>();
      final saved = pushForgetSteps;
      pushForgetSteps = List.generate(4, (_) => () {
            fired++;
            return hung.future;
          });
      addTearDown(() => pushForgetSteps = saved);
      pushDirOverride = dir.path;
      for (final name in ['push_debug.log', 'push_lines.json']) {
        File('${dir.path}/$name').writeAsStringSync('names and previews');
      }

      await forgetPushRegistration(quiet: false)
          .timeout(const Duration(seconds: 2));

      expect(fired, 4, reason: 'FCM, UnifiedPush, APNs and the OS banners');
      expect(dir.listSync(), isEmpty);
    });
  });

  group('the crash log', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('crash_log_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('goes with the identity and takes no line after', () async {
      final sep = Platform.pathSeparator;
      File('${dir.path}${sep}hollow_crash.log.old')
          .writeAsStringSync('an older launch');
      CrashLog.init(dir.path);
      CrashLog.record('FLUTTER-ERROR', 'boom', null);

      await CrashLog.erase();
      CrashLog.record('FLUTTER-ERROR', 'after the wipe', null);

      expect(dir.listSync(), isEmpty);
    });

    test('a launch that finds an unfinished wipe starts it empty', () {
      final sep = Platform.pathSeparator;
      File('${dir.path}${sep}hollow_crash.log')
          .writeAsStringSync('lines of the identity that is gone');
      File('${dir.path}${sep}pending_wipe.marker').writeAsStringSync('1');
      CrashLog.init(dir.path);
      final text = File('${dir.path}${sep}hollow_crash.log').readAsStringSync();
      expect(text, isNot(contains('identity that is gone')));
      return CrashLog.erase();
    });
  });

  group('the support export', () {
    const peer = '12D3KooWQYhTNQdmr3ArTeUHRYzFg94BKyTkoWBDWez9kSCVe2Xo';
    final redactor = LogRedactor(List<int>.filled(32, 7));

    test('names no peer, id, address or home folder', () {
      final out = redactor.redact([
        'ProfileUpdate from $peer',
        'room 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08',
        'message 123e4567-e89b-12d3-a456-426614174000',
        'ICE candidate 203.0.113.7:51820, loopback 127.0.0.1',
        r'Data dir: C:\Users\Alice\AppData\Roaming\Hollow',
        'Data dir: /home/alice/.local/share/hollow',
      ].join('\n'));

      for (final secret in [
        peer,
        '9f86d081884c7d659a2feaa0c55ad015',
        '123e4567-e89b',
        '203.0.113.7',
        'Alice',
        'alice',
      ]) {
        expect(out, isNot(contains(secret)));
      }
      expect(out, contains('127.0.0.1'));
      expect(out, contains('peer#'));
    });

    test('lines up within one export, never across two', () {
      final a = redactor.redact('$peer $peer');
      final tags = RegExp(r'peer#\w+').allMatches(a).map((m) => m[0]).toSet();
      expect(tags, hasLength(1));
      expect(LogRedactor().redact(peer), isNot(LogRedactor().redact(peer)));
    });
  });

  group('source guards', () {
    String read(String path) =>
        File(path).readAsStringSync().replaceAll('\r\n', '\n');

    test('every Settings call that takes a typed password checks for duress',
        () {
      final call = RegExp(r'identity_api\.(unlockIdentity\(password:|'
          r'changePassword\(|removePasswordProtection\(|setDuressCode\(|'
          r'clearDuressCode\(|verifyIdentityPasswordAt\([^)]*password:)');
      final bare = <String>[];
      final files = Directory('lib/src/ui/settings')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));
      for (final f in files) {
        final src = read(f.path);
        for (final m in call.allMatches(src)) {
          final before = src.substring((m.start - 100).clamp(0, m.start), m.start);
          if (!before.contains('withTypedSecret(')) bare.add('${f.path}: ${m[0]}');
        }
      }
      expect(bare, isEmpty,
          reason: 'a duress code typed there would wipe and leave the app '
              'running on what it holds in memory');
    });

    test('the push log names nobody', () {
      final src = read('lib/src/core/services/push_notification_service.dart');
      final named = RegExp(r'\$\{?(sender|personKey|displayName|hollowDataDir|'
          r"server|channel|serverName|channelName|senderName)\b|data\['(?!type')");
      final bad = <String>[];
      var at = src.indexOf('_pushLog(');
      while (at >= 0) {
        final end = src.indexOf(');', at);
        final call = src.substring(at, end < 0 ? src.length : end);
        if (!call.startsWith('_pushLog(String') && named.hasMatch(call)) {
          bad.add(call);
        }
        at = src.indexOf('_pushLog(', at + 1);
      }
      expect(bad, isEmpty,
          reason: 'push_debug.log sits outside the encrypted store and goes '
              'out with the support export');
    });
  });
}
