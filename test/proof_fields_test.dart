import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/ui/settings/verify_proof_section.dart';

/// C-OLM-01: a proof whose text was split into an earlier field carries the
/// author's exact payload bytes, so only the field shapes can refuse it.
void main() {
  const mid = '0123456789abcdef0123456789abcdef';
  bool fits({
    String messageId = mid,
    String replyTo = '',
    String fileId = '',
    String lpDigest = '',
    String album = '',
  }) =>
      proofFieldsWellFormed(
          messageId: messageId,
          replyTo: replyTo,
          fileId: fileId,
          lpDigest: lpDigest,
          album: album);

  test('real ids and empty fields pass', () {
    expect(fits(), isTrue);
    expect(
        fits(
            replyTo: mid,
            fileId: 'c' * 64,
            lpDigest: 'a' * 64,
            album: '3f2a9c1e-7b4d-4e8a-9c2f-1a2b3c4d5e6f'),
        isTrue);
  });

  test('a colon or a wrong shape before the text fails', () {
    expect(fits(lpDigest: ':Do not click this'), isFalse);
    expect(fits(messageId: 'a:b'), isFalse);
    expect(fits(replyTo: ':'), isFalse);
    expect(fits(fileId: 'f:1'), isFalse);
    expect(fits(lpDigest: 'A' * 64), isFalse);
    expect(fits(messageId: 'a' * 65), isFalse);
    expect(fits(album: 'a:b'), isFalse);
  });
}
