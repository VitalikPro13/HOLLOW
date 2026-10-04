import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/screen_audio_renderer.dart';

Uint8List _packet(int seq, int opusBytes) {
  final p = Uint8List(4 + opusBytes);
  ByteData.sublistView(p).setUint32(0, seq, Endian.little);
  return p;
}

/// C-MEDIA-07: a sharer's packets reach the render exe as received, and the exe
/// reads seq 0xFFFFFFFF as a control frame that sets the gain, so a sharer could
/// turn a viewer's share audio back up, a deafened viewer included.
void main() {
  test('a sharer cannot send the render exe a control frame', () {
    final gain = Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0, 0, 0x80, 0x3F]);
    expect(ScreenAudioRenderer.isPlayable(gain), isFalse);
    expect(ScreenAudioRenderer.isPlayable(_packet(0xFFFFFFFF, 60)), isFalse);
  });

  test('a packet the exe would not read whole never reaches its pipe', () {
    // The exe skips a bad length without reading its bytes, so what follows would
    // be read as frames of the sharer's choosing.
    expect(ScreenAudioRenderer.isPlayable(_packet(7, 0)), isFalse);
    expect(ScreenAudioRenderer.isPlayable(_packet(7, 4001)), isFalse);
    expect(ScreenAudioRenderer.isPlayable(_packet(7, 70000)), isFalse);
  });

  test('audio still plays', () {
    expect(ScreenAudioRenderer.isPlayable(_packet(7, 1)), isTrue);
    expect(ScreenAudioRenderer.isPlayable(_packet(0xFFFFFFFE, 4000)), isTrue);
  });
}
