import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/relay_status_provider.dart';

/// DEVICE_PROOF_DESIGN section 12, item 10: an owner on a relay older than 0.14
/// is told its invite lock cannot keep removed devices out; an unknown version
/// says nothing.
void main() {
  bool old(String? v) => relayPredatesDeviceLock(RelayStatus(version: v));

  test('a 0.13 relay predates the device lock', () {
    expect(old('0.13.0'), isTrue);
    expect(old('0.12.2'), isTrue);
  });

  test('0.14 and later do not', () {
    expect(old('0.14.0'), isFalse);
    expect(old('0.14'), isFalse);
    expect(old('0.15.1'), isFalse);
    expect(old('1.0.0'), isFalse);
  });

  test('an unknown or odd version says nothing', () {
    expect(relayPredatesDeviceLock(null), isFalse);
    expect(old(null), isFalse);
    expect(old(''), isFalse);
    expect(old('dev'), isFalse);
    expect(old('0'), isFalse);
  });
}
