// Issue #54: the sticky read pointer behind the "new messages" line.
//
// The line's POSITION is guarded in unread_divider_test.dart. What is guarded
// here is WHEN the pointer is captured, which is the half that decides whether
// the line is honest — and it cannot be seen by looking at a screenshot:
//
//  * captured once per visit, so it does not slide away as you read;
//  * not captured at all by a "mark as read" from outside the conversation,
//    which is the user dismissing messages rather than going to read them;
//  * released on leaving, so a visit with nothing new draws no line.
//
// The capture is driven off the SELECTION providers rather than the panes,
// because mark-seen runs from the sidebar callback before the pane exists,
// from the pane, from a context menu, from a notification and from the scroll
// handler. A test that only exercised the pane would miss four of those.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/unread_marker_provider.dart';

late ProviderContainer _c;

UnreadMarkerNotifier get _markers => _c.read(unreadMarkerProvider.notifier);

/// Opens [peerId] the way navigation does: selection first, then the badge is
/// cleared with the pointer that was there.
void _openDm(String peerId, {String? had}) {
  _c.read(selectedPeerProvider.notifier).state = peerId;
  _markers.noteSeen(dmMarkerKey(peerId), had);
}

void main() {
  setUp(() {
    _c = ProviderContainer();
    // Instantiate the notifier so its selection listeners are registered
    // before the first navigation, as the first mark-seen of a session does.
    _c.read(unreadMarkerProvider);
  });
  tearDown(() => _c.dispose());

  test('opening a conversation captures the pointer it had', () {
    _openDm('alice', had: 'm7');
    expect(_markers.entrySeenId(dmMarkerKey('alice')), 'm7');
  });

  test('a conversation never read before captures the empty pointer', () {
    _openDm('alice');
    expect(_markers.entrySeenId(dmMarkerKey('alice')), '');
  });

  test('the pointer does not move while you are still in there', () {
    _openDm('alice', had: 'm7');
    // Arrivals, sends and the scroll handler all mark seen again.
    _markers.noteSeen(dmMarkerKey('alice'), 'm12');
    _markers.noteSeen(dmMarkerKey('alice'), 'm13');
    expect(_markers.entrySeenId(dmMarkerKey('alice')), 'm7',
        reason: 'a line that slides as you read is a line you never see');
  });

  test('leaving drops the line, and a quiet return draws none', () {
    _openDm('alice', had: 'm7');
    _c.read(selectedPeerProvider.notifier).state = 'bob';
    expect(_markers.entrySeenId(dmMarkerKey('alice')), isNull);

    // Back in, having read everything: the pointer is now the newest message,
    // so unreadDividerIndex finds nothing after it.
    _openDm('alice', had: 'm13');
    expect(_markers.entrySeenId(dmMarkerKey('alice')), 'm13');
  });

  test('marking read from outside records nothing and stays armed', () {
    // "Mark as read" on a sidebar tile while looking at someone else.
    _c.read(selectedPeerProvider.notifier).state = 'bob';
    _markers.noteSeen(dmMarkerKey('alice'), 'm7');
    expect(_markers.entrySeenId(dmMarkerKey('alice')), isNull,
        reason: 'dismissing messages is not the same as going to read them');

    // The real visit still captures.
    _openDm('alice', had: 'm13');
    expect(_markers.entrySeenId(dmMarkerKey('alice')), 'm13');
  });

  test('channels key on the server AND the channel', () {
    _c.read(selectedServerProvider.notifier).state = 's1';
    _c.read(selectedChannelProvider.notifier).state = 'general';
    final general = channelMarkerKey('s1', 'general');
    _markers.noteSeen(general, 'm4');
    expect(_markers.entrySeenId(general), 'm4');

    // Same channel id on another server is a different conversation.
    _c.read(selectedServerProvider.notifier).state = 's2';
    expect(_markers.entrySeenId(general), isNull);
    expect(_markers.entrySeenId(channelMarkerKey('s2', 'general')), isNull);
  });

  test('switching channel within a server releases the old one', () {
    _c.read(selectedServerProvider.notifier).state = 's1';
    _c.read(selectedChannelProvider.notifier).state = 'general';
    _markers.noteSeen(channelMarkerKey('s1', 'general'), 'm4');
    _c.read(selectedChannelProvider.notifier).state = 'random';
    expect(_markers.entrySeenId(channelMarkerKey('s1', 'general')), isNull);
  });
}
