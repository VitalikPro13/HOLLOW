/// Nothing hands an attachment's bytes to the bundled ffmpeg without the user
/// asking (audit findings DART-1 and DART-2).
///
/// An audio attachment can arrive and land on disk with no interaction at all
/// (the auto-download gate lets voice notes through the way it lets text
/// through), and the bubble used to probe every one of them on its first
/// build. Probing runs a decoder over bytes a stranger chose, and the sender
/// also chooses the file name, so a name was never evidence of anything.
///
/// Before the play tap no decoder runs at all (C-FILES-02): a genuine voice
/// note, small, still gets its duration badge, read in Dart from the Ogg page
/// headers. ffmpeg waits for the tap.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/services/at_rest.dart';
import 'package:hollow/src/core/services/audio_probe_service.dart';
import 'package:hollow/src/core/services/audio_transcode_service.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/audio_message_bubble.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// An Ogg page opens with the capture pattern "OggS".
final List<int> _oggBytes = <int>[
  0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];

/// A Windows PE image opens with "MZ". This is the payload a sender would
/// hide behind a voice-note name.
final List<int> _exeBytes = <int>[
  0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00, //
  0x04, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00,
];

/// One Ogg page carrying [packet] whole. The CRC stays zero: nothing that
/// reads the pages for a duration checks it.
List<int> _oggPage({
  required int serial,
  required int granule,
  required int sequence,
  required int headerType,
  required List<int> packet,
}) {
  final lacing = <int>[
    for (var i = 0; i < packet.length ~/ 255; i++) 255,
    packet.length % 255,
  ];
  final head = ByteData(27)
    ..setUint32(0, 0x5367674F, Endian.little) // "OggS"
    ..setUint8(4, 0)
    ..setUint8(5, headerType)
    ..setInt64(6, granule, Endian.little)
    ..setUint32(14, serial, Endian.little)
    ..setUint32(18, sequence, Endian.little)
    ..setUint32(22, 0, Endian.little)
    ..setUint8(26, lacing.length);
  return <int>[...head.buffer.asUint8List(), ...lacing, ...packet];
}

/// A voice note shaped like the recorder's: OpusHead, then audio pages whose
/// last granule position sits [seconds] past the pre-skip at 48 kHz.
Uint8List _opusVoiceNote({required int seconds}) {
  const serial = 0x1234;
  const preSkip = 312;
  final opusHead = <int>[
    ...'OpusHead'.codeUnits, 1, 1, preSkip & 0xFF, preSkip >> 8,
    0x80, 0xBB, 0x00, 0x00, 0, 0, 0, //
  ];
  final audio = List<int>.filled(300, 0x55);
  return Uint8List.fromList(<int>[
    ..._oggPage(
        serial: serial, granule: 0, sequence: 0, headerType: 2, packet: opusHead),
    ..._oggPage(
        serial: serial,
        granule: 48000,
        sequence: 1,
        headerType: 0,
        packet: audio),
    ..._oggPage(
        serial: serial,
        granule: preSkip + 48000 * seconds,
        sequence: 2,
        headerType: 4,
        packet: audio),
  ]);
}

/// A Vorbis stream at 44.1 kHz whose last page ends [seconds] in.
Uint8List _vorbisStream({required int seconds}) {
  const serial = 7;
  const rate = 44100;
  final ident = <int>[
    1, ...'vorbis'.codeUnits, 0, 0, 0, 0, 2, //
    rate & 0xFF, (rate >> 8) & 0xFF, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xB8, 1,
  ];
  return Uint8List.fromList(<int>[
    ..._oggPage(
        serial: serial, granule: 0, sequence: 0, headerType: 2, packet: ident),
    ..._oggPage(
        serial: serial,
        granule: rate * seconds,
        sequence: 1,
        headerType: 4,
        packet: List<int>.filled(40, 1)),
  ]);
}

void main() {
  late Directory tmp;
  late List<List<String>> probeCalls;
  late List<List<String>> transcodeCalls;
  // Created lazily by the runner so it is born inside the test's fake-async
  // zone: a Completer made in setUp schedules its callbacks on the real
  // microtask queue, which `pump` does not flush.
  Completer<ProcessResult>? probeGate;

  setUp(() {
    // The bubble wraps itself in a VisibilityDetector, whose default 500ms
    // debounce would be left pending when the test ends.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;

    tmp = Directory.systemTemp.createTempSync('hollow_audio_gate');
    probeCalls = <List<String>>[];
    transcodeCalls = <List<String>>[];
    probeGate = null;

    AudioProbeService.debugResetCache();
    // The probe hangs on this until the test releases it, so a test can look
    // at the widget mid-prepare.
    AudioProbeService.debugRunner = (exe, args) {
      probeCalls.add(args);
      return (probeGate ??= Completer<ProcessResult>()).future;
    };
    AudioTranscodeService.debugRunner = (exe, args) async {
      transcodeCalls.add(args);
      return ProcessResult(0, 1, '', 'stubbed, no real ffmpeg in tests');
    };
    // The page reader goes through AtRest, whose real handle would never
    // settle inside the widget binding's fake clock.
    AtRest.debugRead = (path) async => File(path).readAsBytesSync();
  });

  tearDown(() {
    AudioProbeService.debugRunner = null;
    AudioTranscodeService.debugRunner = null;
    AtRest.debugRead = null;
    AudioProbeService.debugResetCache();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String writeFile(String name, List<int> bytes, {int padTo = 0}) {
    final path = '${tmp.path}${Platform.pathSeparator}$name';
    final file = File(path)..writeAsBytesSync(bytes);
    if (padTo > bytes.length) {
      file.writeAsBytesSync(
        List<int>.filled(padTo - bytes.length, 0),
        mode: FileMode.append,
      );
    }
    return path;
  }

  FileAttachment attachment({
    required String name,
    required String ext,
    required String path,
    required int sizeBytes,
  }) =>
      FileAttachment(
        fileId: 'file-under-test',
        fileName: name,
        fileExt: ext,
        mimeType: 'audio/ogg',
        sizeBytes: sizeBytes,
        isImage: false,
        totalChunks: 1,
        chunksReceived: 1,
        isComplete: true,
        diskPath: path,
      );

  Future<void> pumpBubble(WidgetTester tester, FileAttachment att) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Center(child: AudioMessageBubble(attachment: att)),
          ),
        ),
      ),
    );
    // initState plus the post-frame retry the build schedules.
    await tester.pump();
    await tester.pump();
  }

  Future<void> tapPlay(WidgetTester tester) async {
    await tester.tap(
      find.ancestor(
        of: find.byIcon(LucideIcons.play),
        matching: find.byType(HollowPressable),
      ),
    );
    await tester.pump();
  }

  /// Tear the bubble down, then release the stubbed ffmpeg call so the 5s
  /// timeout timer wrapped around it is cancelled before the test ends.
  Future<void> drain(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final gate = probeGate;
    if (gate != null && !gate.isCompleted) {
      gate.complete(ProcessResult(0, 0, const <int>[], const <int>[]));
    }
    await tester.pump();
    await tester.pump();
  }

  group('isGenuineVoiceNote', () {
    test('accepts what the recorder actually produces', () {
      expect(
        isGenuineVoiceNote(
          voice: true,
          name: 'voice_1725_ab12.ogg',
          ext: 'ogg',
          sizeBytes: 64 * 1024,
        ),
        isTrue,
      );
      // The display name the UI shows for the same thing.
      expect(
        isGenuineVoiceNote(
          voice: true,
          name: 'Voice message.ogg',
          ext: 'OGG',
          sizeBytes: 1,
        ),
        isTrue,
      );
    });

    test('a voice name over the wrong container is not a voice note', () {
      // The whole DART-1 forgery: pick the name, keep your own bytes.
      expect(
        isGenuineVoiceNote(
          voice: true,
          name: 'voice_1725_ab12.ogg',
          ext: 'exe',
          sizeBytes: 64 * 1024,
        ),
        isFalse,
      );
    });

    test('the header flag alone is not enough', () {
      expect(
        isGenuineVoiceNote(
          voice: true,
          name: 'holiday.ogg',
          ext: 'ogg',
          sizeBytes: 64 * 1024,
        ),
        isFalse,
      );
      expect(
        isGenuineVoiceNote(
          voice: false,
          name: 'voice_1725_ab12.ogg',
          ext: 'ogg',
          sizeBytes: 64 * 1024,
        ),
        isFalse,
      );
    });

    test('holds the size ceiling exactly', () {
      expect(
        isGenuineVoiceNote(
          voice: true,
          name: 'voice_1.ogg',
          ext: 'ogg',
          sizeBytes: kVoiceNoteMaxBytes,
        ),
        isTrue,
      );
      expect(
        isGenuineVoiceNote(
          voice: true,
          name: 'voice_1.ogg',
          ext: 'ogg',
          sizeBytes: kVoiceNoteMaxBytes + 1,
        ),
        isFalse,
      );
    });
  });

  group('the bubble decides when ffmpeg runs', () {
    testWidgets('forged_voice_named_exe_bytes_are_not_probed_on_build',
        (tester) async {
      // Every field a sender controls says voice note. The bytes say PE image.
      final path = writeFile('voice_1725_evil.ogg', _exeBytes);
      await pumpBubble(
        tester,
        attachment(
          name: 'voice_1725_evil.ogg',
          ext: 'ogg',
          path: path,
          sizeBytes: _exeBytes.length,
        ),
      );

      expect(probeCalls, isEmpty,
          reason: 'a name a sender picked must not start a decode');
      expect(transcodeCalls, isEmpty);

      // The user can still choose to open it. That tap is the consent.
      await tapPlay(tester);
      expect(probeCalls, hasLength(1));

      await drain(tester);
    });

    testWidgets('a_voice_note_reaches_no_decoder_before_a_tap',
        (tester) async {
      // Voice notes skip the auto-download gate, so this one landed with no
      // interaction. Everything a sender controls says voice note; that still
      // buys no decoder run (C-FILES-02). The badge comes from the page headers.
      final bytes = _opusVoiceNote(seconds: 3);
      final path = writeFile('voice_1725_ab12.ogg', bytes);
      await pumpBubble(
        tester,
        attachment(
          name: 'voice_1725_ab12.ogg',
          ext: 'ogg',
          path: path,
          sizeBytes: bytes.length,
        ),
      );

      expect(probeCalls, isEmpty,
          reason: 'building a voice note must not run ffmpeg');
      expect(transcodeCalls, isEmpty);
      expect(find.text('0:03'), findsOneWidget,
          reason: 'the duration badge is still there, read from the pages');

      await tapPlay(tester);
      expect(probeCalls, isEmpty,
          reason: 'the duration is known, so the tap probes nothing');

      await drain(tester);
    });

    test('ogg_page_duration_reads_opus_and_vorbis_and_refuses_the_rest', () {
      expect(AudioProbeService.oggDurationFromBytes(_opusVoiceNote(seconds: 7)),
          7000);
      expect(
          AudioProbeService.oggDurationFromBytes(_vorbisStream(seconds: 2)), 2000);
      expect(AudioProbeService.oggDurationFromBytes(Uint8List.fromList(_oggBytes)),
          isNull,
          reason: 'a bare page header carries no stream');
      expect(AudioProbeService.oggDurationFromBytes(Uint8List.fromList(_exeBytes)),
          isNull);
      expect(AudioProbeService.oggDurationFromBytes(Uint8List(0)), isNull);
      // Truncated anywhere: a null, never a throw.
      final whole = _opusVoiceNote(seconds: 5);
      for (var cut = 0; cut < whole.length; cut += 7) {
        expect(() => AudioProbeService.oggDurationFromBytes(
            Uint8List.sublistView(whole, 0, cut)), returnsNormally);
      }
    });

    testWidgets('oversized_ogg_is_not_probed_until_tap', (tester) async {
      // Real Ogg header, real voice-note name, far too big to be speech.
      const bigSize = kVoiceNoteMaxBytes + 1024;
      final path = writeFile('voice_1725_big.ogg', _oggBytes, padTo: bigSize);
      await pumpBubble(
        tester,
        attachment(
          name: 'voice_1725_big.ogg',
          ext: 'ogg',
          path: path,
          sizeBytes: bigSize,
        ),
      );

      expect(probeCalls, isEmpty);

      await tapPlay(tester);
      expect(probeCalls, hasLength(1));

      await drain(tester);
    });

    testWidgets('generic_mp3_attachment_is_probed_only_on_tap',
        (tester) async {
      // DART-2: an ordinary music file is not a voice note, so it waits.
      final path = writeFile('holiday.mp3', _oggBytes);
      await pumpBubble(
        tester,
        attachment(
          name: 'holiday.mp3',
          ext: 'mp3',
          path: path,
          sizeBytes: _oggBytes.length,
        ),
      );

      expect(probeCalls, isEmpty);
      expect(transcodeCalls, isEmpty);

      await tapPlay(tester);
      expect(probeCalls, hasLength(1));

      await drain(tester);
    });

    testWidgets('a deferred prepare shows the button busy', (tester) async {
      final path = writeFile('holiday.mp3', _oggBytes);
      await pumpBubble(
        tester,
        attachment(
          name: 'holiday.mp3',
          ext: 'mp3',
          path: path,
          sizeBytes: _oggBytes.length,
        ),
      );

      await tapPlay(tester);

      // The work moved to the tap, so the tap has to look like it did
      // something: the control says busy and stops taking presses.
      expect(find.byIcon(LucideIcons.loader2), findsOneWidget);
      expect(find.byIcon(LucideIcons.play), findsNothing);
      final button = tester.widget<HollowPressable>(
        find.byType(HollowPressable),
      );
      expect(button.onTap, isNull);
      expect(button.semanticLabel, 'Preparing holiday.mp3');

      await drain(tester);
    });

    testWidgets('a file that vanished before the tap does not throw',
        (tester) async {
      final path = writeFile('voice_1725_gone.ogg', _oggBytes);
      final att = attachment(
        name: 'voice_1725_gone.ogg',
        ext: 'ogg',
        path: path,
        sizeBytes: _oggBytes.length,
      );
      // Pump with the file already gone: the eager path must give up quietly
      // rather than blow up on a missing handle.
      File(path).deleteSync();
      await pumpBubble(tester, att);

      expect(probeCalls, isEmpty);
      expect(tester.takeException(), isNull);

      await drain(tester);
    });
  });
}
