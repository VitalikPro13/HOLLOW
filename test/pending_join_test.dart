import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/pending_join_info.dart';
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/core/providers/pending_join_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';

/// Parked server joins: a join whose members were all offline is held instead
/// of failed, and the strip shows a tile for it until somebody answers.
///
/// These are the parts that decide what the user SEES: the sentence a wire
/// reason turns into, the reconciliation between the pending map and the
/// strip, and the state machine the two new events drive. The persistence
/// itself lives in Rust and is covered by the multi-node harness.
///
/// The layout notifier persists through `saveSetting`, which is FFI and not
/// available here; `_save` swallows its own errors, so state transitions are
/// unaffected.
void main() {
  // The event handlers toast through `hollowNavigatorKey`, and reading a
  // GlobalKey's context touches WidgetsBinding.instance. Nothing here pumps a
  // widget, so the binding has to be brought up explicitly. With no navigator
  // attached the toast is a no-op, which is exactly what these tests want.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reason mapping', () {
    test('banned reads as a sentence, not a wire token', () {
      expect(pendingJoinReasonText('banned'),
          'You are banned from this server');
    });

    test('private and full carry the server name', () {
      expect(pendingJoinReasonText('server_private:Night Shift'),
          'Night Shift is private');
      expect(pendingJoinReasonText('server_full:Night Shift:50'),
          'Night Shift is full');
    });

    test('a nameless private/full still reads', () {
      expect(pendingJoinReasonText('server_private:'),
          'This server is private');
      expect(pendingJoinReasonText('server_full::50'), 'This server is full');
    });

    test('twitch failures collapse to one line', () {
      expect(
        pendingJoinReasonText('twitch_failed:chan:Server:not following long '
            'enough'),
        'Twitch verification failed',
      );
    });

    test('an unknown reason is shown raw rather than swallowed', () {
      expect(pendingJoinReasonText('something_new:42'), 'something_new:42');
    });

    test('an empty reason still says something', () {
      expect(pendingJoinReasonText(''), 'The request was declined');
      expect(pendingJoinReasonText('   '), 'The request was declined');
    });
  });

  group('strip item persistence', () {
    test('a pending tile round-trips through the layout JSON', () {
      const item = PendingStripItem(serverId: 'abc');
      final read = StripItem.fromJson(item.toJson());
      expect(read, isA<PendingStripItem>());
      expect((read! as PendingStripItem).serverId, 'abc');
    });

    test('an unknown kind is skipped, never read as a server', () {
      // A newer client's row must not come back as a ServerStripItem: the
      // reconcile pass would then prune it as a server that went away, and
      // the user's layout would quietly lose a row on every launch.
      expect(StripItem.fromJson({'type': 'quasar', 'id': 'x'}), isNull);
      expect(StripItem.fromJson({'type': 'server'}), isNull);
    });

    test('a row with no type is still a server (old layouts)', () {
      expect(StripItem.fromJson({'id': 'a'}), isA<ServerStripItem>());
    });
  });

  group('pending joins drive the strip', () {
    late ProviderContainer container;

    ServerStripLayoutNotifier layout() =>
        container.read(serverStripLayoutProvider.notifier);
    PendingJoinsNotifier pending() =>
        container.read(pendingJoinsProvider.notifier);

    String outline() =>
        container.read(serverStripLayoutProvider).map((item) {
          return switch (item) {
            ServerStripItem(:final serverId) => serverId,
            PendingStripItem(:final serverId) => '?$serverId',
            FolderStripItem(:final name, :final serverIds) =>
              '$name[${serverIds.join(",")}]',
          };
        }).join(' ');

    setUp(() {
      container = ProviderContainer();
      container.read(serverStripLayoutProvider);
      container.read(pendingJoinsProvider);
    });

    tearDown(() => container.dispose());

    test('parking a join adds a tile, discarding it takes the tile away', () {
      layout().state = const [ServerStripItem(serverId: 'a')];

      pending().park('s1');
      expect(outline(), 'a ?s1');
      expect(container.read(pendingJoinsProvider)['s1']!.isRejected, isFalse);

      pending().remove('s1');
      expect(outline(), 'a');
    });

    test('a rejection keeps the tile and records the reason', () {
      pending().park('s1');
      pending().markRejected('s1', 'banned');

      final info = container.read(pendingJoinsProvider)['s1']!;
      expect(info.isRejected, isTrue);
      expect(info.reason, 'banned');
      // The tile stays: a rejection the user never sees is a rejection that
      // never happened.
      expect(outline(), '?s1');
    });

    test('requesting again clears the reason and the rejected state', () {
      pending().park('s1');
      pending().markRejected('s1', 'server_full:X:5');
      pending().markRequestedAgain('s1');

      final info = container.read(pendingJoinsProvider)['s1']!;
      expect(info.isRejected, isFalse);
      expect(info.reason, '');
      expect(outline(), '?s1');
    });

    test('a completed join replaces its tile IN PLACE', () {
      layout().state = const [ServerStripItem(serverId: 'a')];
      pending().park('s1');
      layout().reorder(1, 0); // user drags the pending tile to the front
      expect(outline(), '?s1 a');

      // The ServerJoined order the event dispatcher uses.
      layout().onServerCreated('s1');
      pending().remove('s1');

      expect(outline(), 's1 a');
    });

    test('setPendingJoins is idempotent and keeps existing slots', () {
      layout().state = const [
        PendingStripItem(serverId: 's1'),
        ServerStripItem(serverId: 'a'),
      ];

      layout().setPendingJoins({'s1', 's2'});
      expect(outline(), '?s1 a ?s2');

      layout().setPendingJoins({'s1', 's2'});
      expect(outline(), '?s1 a ?s2');

      layout().setPendingJoins({'s2'});
      expect(outline(), 'a ?s2');
    });

    test('reconciling servers never prunes a pending tile', () {
      // _syncWithServers removes top-level servers that are not in the server
      // list. A parked join is not a server we hold, so it must survive.
      layout().state = const [PendingStripItem(serverId: 's1')];
      layout().loadLayout(); // no saved JSON -> falls through to the sync pass
      expect(container.read(serverStripLayoutProvider),
          contains(isA<PendingStripItem>()));
    });
  });

  group('event state machine', () {
    late ProviderContainer container;
    late Ref ref;

    // A throwaway provider is the only way to hand a real `Ref` to the
    // handlers the event dispatcher calls.
    final refProbe = Provider<Ref>((ref) => ref);

    setUp(() {
      container = ProviderContainer();
      ref = container.read(refProbe);
    });

    tearDown(() => container.dispose());

    test('parked, then rejected, then requested again', () {
      onServerJoinParked(ref, 's1');
      expect(container.read(pendingJoinsProvider).containsKey('s1'), isTrue);

      onPendingJoinUpdated(ref, 's1', kPendingJoinRejected, 'banned');
      expect(container.read(pendingJoinsProvider)['s1']!.isRejected, isTrue);
      expect(container.read(pendingJoinsProvider)['s1']!.reason, 'banned');
    });

    test('admitted drops the row and raises the awaiting-setup flair', () {
      onServerJoinParked(ref, 's1');

      onPendingJoinUpdated(ref, 's1', kPendingJoinAdmitted, '');
      expect(container.read(pendingJoinsProvider).containsKey('s1'), isFalse);
      expect(container.read(awaitingSetupProvider), contains('s1'));

      onPendingJoinUpdated(ref, 's1', kPendingJoinReady, '');
      expect(container.read(awaitingSetupProvider), isEmpty);
    });

    test('discarded drops the row', () {
      onServerJoinParked(ref, 's1');
      onPendingJoinUpdated(ref, 's1', kPendingJoinDiscarded, '');
      expect(container.read(pendingJoinsProvider), isEmpty);
    });

    test('an unknown state is ignored rather than crashing the event loop',
        () {
      onServerJoinParked(ref, 's1');
      onPendingJoinUpdated(ref, 's1', 'teleported', '');
      expect(container.read(pendingJoinsProvider).containsKey('s1'), isTrue);
    });
  });
}
