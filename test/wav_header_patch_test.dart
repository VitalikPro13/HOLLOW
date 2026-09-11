/// ffmpeg cannot rewind a pipe, so the WAV it writes to stdout carries
/// 0xFFFFFFFF where both lengths belong and Media Foundation refuses it. The
/// transcode cache is only playable because these fields get filled in.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/audio_transcode_service.dart';

/// A WAV exactly as the pipe muxer emits one: `fmt ` chunk, a `LIST` chunk that
/// the walk has to step over, then `data` with a placeholder length.
Uint8List pipedWav({int samples = 8, int listPayload = 10}) {
  final body = BytesBuilder();
  void tag(String s) => body.add(s.codeUnits);
  void u32(int v) {
    final b = ByteData(4)..setUint32(0, v, Endian.little);
    body.add(b.buffer.asUint8List());
  }

  void u16(int v) {
    final b = ByteData(2)..setUint16(0, v, Endian.little);
    body.add(b.buffer.asUint8List());
  }

  tag('RIFF');
  u32(0xFFFFFFFF);
  tag('WAVE');

  tag('fmt ');
  u32(16);
  u16(1); // PCM
  u16(1); // mono
  u32(16000);
  u32(32000);
  u16(2);
  u16(16);

  if (listPayload > 0) {
    tag('LIST');
    u32(listPayload);
    body.add(Uint8List(listPayload));
    // RIFF pads every odd chunk to an even boundary; a walk that forgets the
    // pad byte lands one short and never finds `data`.
    if (listPayload.isOdd) body.add(<int>[0]);
  }

  tag('data');
  u32(0xFFFFFFFF);
  body.add(Uint8List(samples * 2));
  return body.takeBytes();
}

int u32At(Uint8List b, int offset) =>
    ByteData.sublistView(b).getUint32(offset, Endian.little);

int dataSizeOf(Uint8List b) {
  for (var i = 12; i + 8 <= b.length; i++) {
    if (String.fromCharCodes(b, i, i + 4) == 'data') return u32At(b, i + 4);
  }
  return -1;
}

void main() {
  test('both placeholder lengths are filled in', () {
    final wav = patchWavSizes(pipedWav(samples: 100));

    expect(u32At(wav, 4), wav.length - 8);
    expect(dataSizeOf(wav), 200);
  });

  test('an odd-sized chunk before data is stepped over with its pad byte', () {
    final wav = patchWavSizes(pipedWav(samples: 4, listPayload: 9));
    expect(dataSizeOf(wav), 8);
    expect(u32At(wav, 4), wav.length - 8);
  });

  test('a wav with no LIST chunk still patches', () {
    final wav = patchWavSizes(pipedWav(samples: 16, listPayload: 0));
    expect(u32At(wav, 4), wav.length - 8);
    expect(dataSizeOf(wav), 32);
  });

  test('non-wav bytes are returned untouched', () {
    final notWav = Uint8List.fromList(
        List<int>.generate(64, (i) => i & 0xFF));
    final before = Uint8List.fromList(notWav);
    expect(patchWavSizes(notWav), before);
  });

  test('a truncated header is refused rather than read past', () {
    final tiny = Uint8List.fromList('RIFF'.codeUnits);
    expect(patchWavSizes(tiny), tiny);
  });
}
