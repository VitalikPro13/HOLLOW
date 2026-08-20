import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/channel_layout.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';

/// Contract tests for the ONE channel-layout mutation path (issue #61).
///
/// Every layout edit — the sidebar's category menu, the Channels settings
/// editor — goes through [ChannelLayoutNotifier.mutate]. Three properties make
/// that path correct, and all three were bugs before it existed:
///
///  1. The mutator sees a NORMALISED layout. Appending a category to a server
///     whose layout was `[]` used to write "one category, no channels", which
///     the sidebar drew as an empty category while the settings editor drew
///     every channel nested under it.
///  2. State is published BEFORE the FFI. `update_channel_layout` only queues
///     a CRDT op, so a read-back returns the previous value.
///  3. A reload cannot stomp a fresh local write. Server events call
///     `loadForServer` constantly, and the DB still holds the pre-write layout
///     for as long as the op is queued.
///
/// These run with no FFI: the bridge is uninitialised, so the write throws and
/// the reload fails, which is exactly the hostile case the guards must survive.
void main() {
  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  /// Two channels whose alphabetical order is the REVERSE of their map order,
  /// so a test can tell "sorted by name" from "whatever order the map had".
  Map<String, ChannelInfo> channels() => {
        'id-beta': const ChannelInfo(channelId: 'id-beta', name: 'beta'),
        'id-alpha': const ChannelInfo(channelId: 'id-alpha', name: 'alpha'),
      };

  test('the mutator receives every channel, in sidebar order', () {
    final c = container();
    final notifier = c.read(channelLayoutProvider.notifier);
    notifier.setLayout('[]');

    List<LayoutItem>? seen;
    notifier.mutate('srv', channels(), (layout) {
      seen = List.of(layout);
      return layout;
    });

    expect(seen, isNotNull);
    expect(seen!.whereType<ChannelItem>().map((i) => i.channelId).toList(),
        ['id-alpha', 'id-beta'],
        reason: 'an empty stored layout must still present both channels, '
            'sorted by name the way the sidebar renders unplaced channels');
  });

  test('a new category lands at the bottom and starts empty', () {
    final c = container();
    final notifier = c.read(channelLayoutProvider.notifier);
    notifier.setLayout('[]');

    notifier.mutate('srv', channels(),
        (layout) => layout..add(const CategoryItem('New')));

    final items = parseLayoutJson(c.read(channelLayoutProvider));
    expect(items.length, 3);
    expect(items.last, isA<CategoryItem>(),
        reason: 'appending to a normalised layout puts the category AFTER '
            'every channel, so it cannot appear to swallow them');
  });

  test('state is published synchronously, before the write can land', () {
    final c = container();
    final notifier = c.read(channelLayoutProvider.notifier);
    notifier.setLayout('[]');

    notifier.mutate('srv', channels(),
        (layout) => layout..add(const CategoryItem('Instant')));

    expect(c.read(channelLayoutProvider), contains('Instant'),
        reason: 'the optimistic publish must not wait on the FFI');
  });

  test('a reload during the pending window cannot stomp the write', () async {
    final c = container();
    final notifier = c.read(channelLayoutProvider.notifier);
    notifier.setLayout('[]');

    notifier.mutate('srv', channels(),
        (layout) => layout..add(const CategoryItem('Survives')));
    final afterWrite = c.read(channelLayoutProvider);

    // What a server event does. With no bridge this resolves to '[]', which is
    // precisely the stale value that used to overwrite the local edit.
    await notifier.loadForServer('srv');

    expect(c.read(channelLayoutProvider), afterWrite,
        reason: 'the pending-write guard must hold the local layout');
  });

  test('a reload for a DIFFERENT server is not blocked by the guard', () async {
    final c = container();
    final notifier = c.read(channelLayoutProvider.notifier);
    notifier.setLayout('[{"type":"category","name":"Old"}]');

    notifier.mutate('srv', channels(),
        (layout) => layout..add(const CategoryItem('Mine')));

    // Switching to another server must still be able to load, or the sidebar
    // would show the previous server's layout.
    await notifier.loadForServer('other-srv');
    expect(c.read(channelLayoutProvider), '[]',
        reason: 'the guard is scoped to the server that was written');
  });

  test('setLayout for the SAME server cannot undo a pending write', () {
    final c = container();
    final notifier = c.read(channelLayoutProvider.notifier);

    notifier.mutate('srv', channels(),
        (layout) => layout..add(const CategoryItem('Mine')));
    final afterWrite = c.read(channelLayoutProvider);

    // Every setLayout caller is a "navigate to server X" flow that just read
    // the DB. For the server we are mid-write on, that read is stale by
    // construction — landing it is what made a new category jump back to the
    // top and re-swallow every channel after a server switch.
    notifier.setLayout('[{"type":"category","name":"Stale"}]', serverId: 'srv');

    expect(c.read(channelLayoutProvider), afterWrite);
  });

  test('setLayout for a DIFFERENT server applies and ends the guard', () async {
    final c = container();
    final notifier = c.read(channelLayoutProvider.notifier);

    notifier.mutate('srv', channels(),
        (layout) => layout..add(const CategoryItem('Mine')));

    // Switching away must always win, or the sidebar would show the previous
    // server's layout.
    notifier.setLayout('[{"type":"category","name":"Other"}]',
        serverId: 'other-srv');
    expect(c.read(channelLayoutProvider), contains('Other'));

    await notifier.loadForServer('srv');
    expect(c.read(channelLayoutProvider), '[]',
        reason: 'the guard ended when we left the server that was written');
  });

  test('a pending write is never reconciled from the DB behind our back',
      () async {
    final c = container();
    final notifier = c.read(channelLayoutProvider.notifier);

    notifier.mutate('srv', channels(),
        (layout) => layout..add(const CategoryItem('Kept')));
    final afterWrite = c.read(channelLayoutProvider);

    // Past the guard window. The state we published IS what we wrote, so the
    // DB can only be equal to it or behind it; a timer that re-read would only
    // ever be able to make this worse.
    await Future<void>.delayed(const Duration(milliseconds: 1800));

    expect(c.read(channelLayoutProvider), afterWrite);
  });

  test('normalisation drops channels that no longer exist', () {
    final c = container();
    final notifier = c.read(channelLayoutProvider.notifier);
    notifier.setLayout(
        '[{"type":"channel","channel_id":"id-alpha"},'
        '{"type":"channel","channel_id":"deleted-id"}]');

    notifier.mutate('srv', channels(), (layout) => layout);

    final ids = parseLayoutJson(c.read(channelLayoutProvider))
        .whereType<ChannelItem>()
        .map((i) => i.channelId)
        .toList();
    expect(ids, ['id-alpha', 'id-beta']);
    expect(ids, isNot(contains('deleted-id')));
  });
}
