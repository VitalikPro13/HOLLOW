import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/version_compare.dart';

void main() {
  group('isNewerVersion', () {
    test('strictly newer only', () {
      expect(isNewerVersion('0.10.2', '0.10.1'), isTrue);
      expect(isNewerVersion('0.11.0', '0.10.9'), isTrue);
      expect(isNewerVersion('1.0.0', '0.99.99'), isTrue);
      expect(isNewerVersion('0.10.1', '0.10.1'), isFalse);
    });

    test('a replayed older manifest is never an update', () {
      expect(isNewerVersion('0.9.5', '0.10.1'), isFalse);
      expect(isNewerVersion('0.10.0', '0.10.1'), isFalse);
    });

    test('numeric, not lexical', () {
      expect(isNewerVersion('0.10.0', '0.9.0'), isTrue);
      expect(isNewerVersion('0.9.0', '0.10.0'), isFalse);
    });

    test('missing parts count as zero, garbage is never newer', () {
      expect(isNewerVersion('1.0', '1.0.0'), isFalse);
      expect(isNewerVersion('1.0.1', '1.0'), isTrue);
      expect(isNewerVersion('', '1.0.0'), isFalse);
      expect(isNewerVersion('next', '1.0.0'), isFalse);
      expect(isNewerVersion('1.0.0', 'x'), isFalse);
    });
  });
}
