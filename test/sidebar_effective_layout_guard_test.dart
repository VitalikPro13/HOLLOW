import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CI guard: every channel list renders the EFFECTIVE layout.
///
/// Four surfaces decide what a category contains — the desktop sidebar, the
/// mobile channel list, the sidebar's context menus, and the Channels settings
/// editor — and all four must decide it the same way, from
/// `effectiveLayoutFrom`: the stored layout, minus references to channels that
/// no longer exist, plus every channel missing from it appended in list order.
///
/// The two list surfaces used to normalise a second time, by hand: walk the
/// stored layout, then append the leftover channels in a separate loop,
/// outside the pass that tracks which category is open. Two bugs came out of
/// that, and both looked like "the category does not really contain its
/// channels":
///
///  * A channel appended after a trailing category was drawn under it but was
///    not in it, so collapsing the category left the channel on screen.
///  * A stored layout holding a dead channel id (issue #61 shipped one: the
///    create-channel FFI returned the string "pending") shifts every index
///    after it once normalisation drops the reference, and the category menu
///    edits by INDEX. The sidebar handed out stored indices; the menu resolved
///    them against the normalised list.
///
/// Rule: ONE normalisation, `effectiveLayoutFrom`, and a list renders the
/// layout its indices will be resolved against.
void main() {
  // Desktop and mobile both render a channel list from the layout, and the
  // hand-rolled version shipped on both.
  const surfaces = [
    'lib/src/ui/shell/channel_sidebar.dart',
    'lib/src/ui/mobile/tabs/mobile_chats_tab.dart',
  ];

  for (final path in surfaces) {
    test('$path builds its rows from effectiveLayoutFrom', () {
      final file = File(path);
      expect(file.existsSync(), isTrue,
          reason: 'expected to run from the project root');
      final source = file.readAsStringSync();

      expect(source.contains('effectiveLayoutFrom('), isTrue,
          reason: '$path must build its rows from effectiveLayoutFrom, the '
              'same normalisation the context menus and the Channels settings '
              'editor resolve indices against');

      // The hand-rolled second normalisation, by the names it used.
      for (final smell in const [
        'placedChannels',
        'placedIds',
        'final unplaced',
      ]) {
        expect(source.contains(smell), isFalse,
            reason: '$path looks like it normalises the layout a second time '
                '("$smell"). Channels missing from the layout belong to '
                'effectiveLayoutFrom, so they flow through the same pass that '
                'tracks the open category and collapse with it');
      }
    });
  }
}
