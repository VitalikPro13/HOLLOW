/// The lock offer after a link or a restore (C-IDENTITY-15) never routes above a
/// lock: the shell asks only once the device belongs and the app lock's cover is
/// down, and only from the start, never on its own later.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the shell offers a lock only after the roster lock and the app lock lift', () {
    final src = File('lib/src/ui/shell/hollow_shell.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final start = src.indexOf('Future<void> _offerProtection() async {');
    expect(start, isNot(-1), reason: '_offerProtection is gone');
    final body = src.substring(start, src.indexOf('\n  }\n', start));
    final unlocked = body.indexOf('await _untilUnlocked();');
    final belongs = body.lastIndexOf('RosterGateKind.none) return;');
    final offer = body.indexOf('offerProtectionIfDue(');
    expect(unlocked, greaterThan(-1), reason: 'the offer no longer waits for the app lock');
    expect(belongs, greaterThan(unlocked), reason: 'the offer no longer checks the roster lock last');
    expect(offer, greaterThan(belongs), reason: 'the offer runs before both checks');
    expect(src.split('offerProtectionIfDue(').length, 2, reason: 'one caller only');
    expect(src.contains('unawaited(_offerAfterStart(setUpThisLaunch: setUpThisLaunch))'), isTrue);
    // The keychain offer comes after the lock offer, so the two never stack.
    final chain = src.indexOf('Future<void> _offerAfterStart(');
    expect(src.indexOf('await _offerProtection();', chain),
        lessThan(src.indexOf('await _offerKeychainLock();', chain)));
  });
}
