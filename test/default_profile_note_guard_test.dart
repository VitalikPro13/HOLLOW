/// #155: the note about an identity left in the Default profile runs first in the
/// start chain, never above the app lock, and only once per profile.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the shell says it once, after the lock, first in the start chain', () {
    final src = File('lib/src/ui/shell/hollow_shell.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final chain = src.indexOf('Future<void> _offerAfterStart(');
    final note = src.indexOf('await _noteDefaultProfileLeftBehind();', chain);
    expect(note, greaterThan(chain));
    // First: every other offer concerns the identity this copy runs on.
    for (final offer in [
      'await _askTermsAgreement();',
      'await _offerPhraseUpgrade();',
      'await _offerProtection();',
      'await _offerKeychainLock();',
      'await _finishKeychainRekey();',
      'await _restoreOffers.atStart(',
    ]) {
      expect(note, lessThan(src.indexOf(offer, chain)), reason: '$offer runs before the note');
    }
    final start = src.indexOf('Future<void> _noteDefaultProfileLeftBehind() async {');
    expect(start, isNot(-1));
    final body = src.substring(start, src.indexOf('\n  }\n', start));
    final unlocked = body.indexOf('await _untilUnlocked();');
    final check = body.indexOf('defaultRoot == null');
    final saved = body.indexOf('saveSetting(key: _kDefaultProfileNoteKey');
    final shown = body.indexOf('DefaultProfileNoteDialog(defaultRoot: defaultRoot)');
    expect(unlocked, greaterThan(-1));
    expect(check, greaterThan(unlocked));
    expect(body.indexOf('if (shown != null'), greaterThan(check));
    expect(saved, greaterThan(check));
    expect(shown, greaterThan(saved), reason: 'marked shown before it shows, so it never repeats');
  });
}
