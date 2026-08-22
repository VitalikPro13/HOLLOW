import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Voice and call surfaces show NO avatar frame (issue #54).
///
/// A frame is decoration; the speaking indicator is information. A built-in
/// frame is a coloured ring drawn in the accent family — which is the exact
/// language the VAD cue speaks — so on a call surface the two compete and the
/// decoration wins by being permanent. Measured: a quiet person wearing the
/// teal built-in is pixel-identical to a talking person wearing none.
///
/// So every avatar on a surface where a call or voice channel is ACTIVE
/// passes `frameId: ''`. The ringing screens are deliberately NOT in this
/// list: an incoming call has no speaking indicator to confuse, and "who is
/// calling me" is exactly where identity decoration earns its place.
///
/// Only files that are ENTIRELY call/VC surfaces are scanned. `chat_pane.dart`
/// carries both (its inline call panel opts out; its DM header and profile
/// card keep their frames), so it cannot be checked wholesale — those sites
/// carry the reasoning in a comment instead.
void main() {
  test('voice and call avatars opt out of frames', () {
    const files = [
      'lib/src/ui/chat/voice_channel_pane.dart',
      'lib/src/ui/components/call_video_view.dart',
      'lib/src/ui/mobile/mobile_call_video_view.dart',
      'lib/src/ui/mobile/mobile_voice_avatars.dart',
    ];

    final failures = <String>[];
    for (final path in files) {
      final file = File(path);
      if (!file.existsSync()) {
        failures.add('$path — file missing (surface moved/renamed?)');
        continue;
      }
      final src = file.readAsStringSync();
      for (final start in _callSites(src, 'HollowAvatar(')) {
        final args = _balanced(src, start + 'HollowAvatar('.length - 1);
        if (args == null) continue;
        if (args.contains("frameId: ''")) continue;
        final line = '\n'.allMatches(src.substring(0, start)).length + 1;
        failures.add('$path:$line — HollowAvatar on a call/VC surface without '
            "frameId: ''. Its frame competes with the speaking indicator.");
      }
    }

    if (failures.isNotEmpty) {
      fail('\nFrames on voice/call surfaces:\n\n  ${failures.join('\n\n  ')}'
          "\n\nPass frameId: '' — decoration must never be able to look like "
          'a VAD cue.');
    }
  });
}

Iterable<int> _callSites(String src, String needle) sync* {
  var i = src.indexOf(needle);
  while (i != -1) {
    yield i;
    i = src.indexOf(needle, i + needle.length);
  }
}

/// The text between the parens starting at [open], honouring nesting — the
/// argument lists here contain calls of their own (`.identityOf(peerId)`), so
/// a naive `[^)]*` stops in the wrong place.
String? _balanced(String src, int open) {
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    final c = src[i];
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return src.substring(open + 1, i);
    }
  }
  return null;
}
