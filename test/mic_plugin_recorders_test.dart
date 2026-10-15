import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/mic_level_capture.dart';
import 'package:record/record.dart' as rec;

/// record_windows 1.0.7 frees a disposed native recorder while Media
/// Foundation still holds it as the source reader's callback; the late release
/// lands on freed memory (OLEAUT32!VariantClear) and kills the app. These pin
/// that the overlay's and the mic test's capture never dispose one.
class _FakeRecorder implements rec.AudioRecorder {
  _FakeRecorder(this.id, this.events);

  final int id;
  final List<String> events;
  StreamController<Uint8List>? _chunks;

  @override
  Future<Stream<Uint8List>> startStream(rec.RecordConfig config) async {
    events.add('start#$id');
    final chunks = StreamController<Uint8List>();
    _chunks = chunks;
    return chunks.stream;
  }

  @override
  Future<String?> stop() async {
    events.add('stop#$id');
    await _chunks?.close();
    _chunks = null;
    return null;
  }

  @override
  Future<void> dispose() async {
    events.add('dispose#$id');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late List<String> events;
  late int created;
  late PluginRecorders saved;

  PluginRecorders pool({required bool keepAlive}) => PluginRecorders(
        create: () => _FakeRecorder(++created, events),
        keepAlive: keepAlive,
      );

  MicLevelCapture capture() =>
      MicLevelCapture(backend: () => RecordPcmBackend());

  setUp(() {
    events = [];
    created = 0;
    saved = pluginRecorders;
  });

  tearDown(() => pluginRecorders = saved);

  group('where disposing crashes (Windows)', () {
    setUp(() => pluginRecorders = pool(keepAlive: true));

    test('a capture stops the recorder and never disposes it', () async {
      final c = capture();
      await c.start(onChunk: (_, _) {});
      await c.stop();
      expect(events, ['start#1', 'stop#1']);
    });

    test('the next capture reuses the stopped recorder', () async {
      for (var i = 0; i < 3; i++) {
        final c = capture();
        await c.start(onChunk: (_, _) {});
        await c.stop();
      }
      expect(created, 1);
      expect(events.where((e) => e.startsWith('dispose')), isEmpty);
    });

    test('two captures at once take two recorders, both kept', () async {
      final a = capture();
      final b = capture();
      await a.start(onChunk: (_, _) {});
      await b.start(onChunk: (_, _) {});
      await a.stop();
      await b.stop();
      expect(events, ['start#1', 'start#2', 'stop#1', 'stop#2']);

      final c = capture();
      await c.start(onChunk: (_, _) {});
      await c.stop();
      expect(created, 2);
    });

    test('a recorder that failed to start is still stopped and kept', () async {
      pluginRecorders = PluginRecorders(
        create: () => _FailingRecorder(++created, events),
        keepAlive: true,
      );
      await expectLater(
          capture().start(onChunk: (_, _) {}), throwsA(isA<StateError>()));
      expect(events, ['start#1', 'stop#1']);
      expect(pluginRecorders.idleCount, 1);
    });
  });

  test('elsewhere a released recorder is stopped, then disposed', () async {
    pluginRecorders = pool(keepAlive: false);
    final c = capture();
    await c.start(onChunk: (_, _) {});
    await c.stop();
    expect(events, ['start#1', 'stop#1', 'dispose#1']);
    expect(pluginRecorders.idleCount, 0);
  });
}

class _FailingRecorder extends _FakeRecorder {
  _FailingRecorder(super.id, super.events);

  @override
  Future<Stream<Uint8List>> startStream(rec.RecordConfig config) async {
    events.add('start#$id');
    throw StateError('no microphone');
  }
}
