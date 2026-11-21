import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/recovery.dart' as recovery_api;

/// The phrase restore on Welcome (PHRASE_RESTORE_DESIGN): the branch the
/// person chose and the copy for a phrase Rust refused.

/// "Could someone else have your old device?" No = an admission beside the
/// old device; Yes = a recovery that drops it as lost or stolen since a time.
enum PhraseRestoreBranch { admit, recover }

/// The branch as Rust names it (`"admit"`, `"recover"`); null for anything else.
PhraseRestoreBranch? phraseRestoreBranchFrom(String wire) => switch (wire) {
      'admit' => PhraseRestoreBranch.admit,
      'recover' => PhraseRestoreBranch.recover,
      _ => null,
    };

/// The restore mode for [branch]; [lostSinceMs] is read on a recovery only.
identity_api.WelcomeRestoreMode welcomeRestoreMode(PhraseRestoreBranch branch,
        {int? lostSinceMs}) =>
    switch (branch) {
      PhraseRestoreBranch.admit => const identity_api.WelcomeRestoreMode.admit(),
      PhraseRestoreBranch.recover =>
        identity_api.WelcomeRestoreMode.recover(lostSinceMs: lostSinceMs ?? 0),
    };

/// How long Home keeps the "Finish restoring" card: the restore mark's window.
const kWelcomeRestoreWindow = Duration(days: 30);

/// The copy for a phrase Rust refused, by the error it names; null for any
/// other failure, which `friendlyError` words.
String? phraseErrorText(Object error) {
  final raw = error.toString();
  final words = RegExp(r'phrase_words:(\d+)').firstMatch(raw);
  if (words != null) {
    return 'A recovery phrase is 24 words. This one has ${words.group(1)}.';
  }
  final word = RegExp(r'phrase_word:(\d+)').firstMatch(raw);
  if (word != null) {
    return "Word ${word.group(1)} isn't a recovery phrase word. Check how "
        "it's spelled.";
  }
  if (raw.contains('phrase_checksum')) {
    return "These words aren't a recovery phrase. Check each word and the "
        'order.';
  }
  return null;
}

/// Welcome's note after "Type my phrase again" set an identity aside, with the
/// relay that identity used: its database moved away with it, and the next
/// restore must land there, never on the default unasked. Null when nothing was
/// set aside; [relayDomain] null when the note names none.
typedef SetAsideNote = ({String? relayDomain});

/// Reads the set-aside note Welcome shows once.
Future<SetAsideNote?> readSetAsideNote() async {
  final note = await recovery_api.setAsideWelcome();
  return note == null ? null : (relayDomain: note.relay);
}
