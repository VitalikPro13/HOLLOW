import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/webrtc_native_log.dart';

/// C-MEDIA-05: libwebrtc's frame cryptor logs the key it derives at info level, so a
/// widened native log (HOLLOW_WEBRTC_LOG=info) wrote every SFrame key to the log
/// users send to support.
void main() {
  test('a native line that carries key material never reaches the log', () {
    // frame_crypto_transformer.cc, PBKDF2 and HKDF derivations.
    expect(
        WebRtcNativeLog.carriesKey('(frame_crypto_transformer.cc:284): raw_key '
            '[1, 2, 3] len 32 slat << [104, 111] len 18\n derived_key [9, 8] len 16'),
        isTrue);
    expect(
        WebRtcNativeLog.carriesKey('secret [1, 2] len 32 salt [3] len 18\n '
            'derived_key [4] len 16'),
        isTrue);
  });

  test('ordinary native lines still do', () {
    expect(WebRtcNativeLog.carriesKey('(audio_device_pulse_linux.cc:42): Failed to '
        'initialize the audio device module'), isFalse);
    expect(WebRtcNativeLog.carriesKey('FrameCryptorTransformer::decryptFrame() '
        'failed'), isFalse);
  });
}
