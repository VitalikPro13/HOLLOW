import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/mic_level_capture.dart';
import 'package:hollow/src/core/services/overlay_mic.dart';

import 'helpers/fake_mic.dart';

/// so-crash: a disposed record_windows recorder is freed while Media
/// Foundation still holds it, and the late release kills the app
/// (OLEAUT32!VariantClear under CMFSourceReaderStream::Release). Every
/// `record` recorder therefore comes from [PluginRecorders], which keeps them.
void main() {
  test('every record recorder in lib comes from the shared pool', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.path.replaceAll('\\', '/').endsWith('services/mic_level_capture.dart')) {
        continue;
      }
      final src = f.readAsStringSync();
      final usesRecord = src.contains('package:record/');
      if (RegExp(r'AudioRecorder\s*\(\s*\)').hasMatch(src) ||
          RegExp(r'AudioRecorder\.new\b').hasMatch(src) ||
          (usesRecord &&
              RegExp(r'[Rr]ecorder\??\.dispose\(').hasMatch(src))) {
        offenders.add(f.path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'take a recorder from pluginRecorders instead; a disposed '
            'one crashes Windows');
  });

  test('turning listening off is never held forever by a capture that does '
      'not let go', () async {
    final events = <String>[];
    final mic = FakeMic(events, closeDelay: const Duration(hours: 1));
    final listen = OverlayMic(
      newCapture: () => MicLevelCapture(backend: () => mic),
      stopTimeout: const Duration(milliseconds: 50),
      log: (_) {},
    );
    await listen.turnOn();
    var off = false;
    unawaited(listen.turnOff().then((_) => off = true));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(off, isTrue);
    expect(listen.status.value, const OverlayMicStatus());
  });
}
