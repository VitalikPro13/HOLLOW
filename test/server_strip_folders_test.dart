import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';

/// Folder management from the server icon menu (issue #61, phase 4).
///
/// Folders used to be drag-only, and the layout quietly dissolved any folder
/// that held a single server. That second rule is what makes these tests worth
/// having: "Move to folder > New folder" creates exactly such a folder, so a
/// dissolve-at-one rule would have undone the user's action on the next
/// launch, in a place nothing would have shown it happening.
///
/// The notifier persists through `saveSetting`, which is FFI and not available
/// here, so every test drives the in-memory state and lets the (caught) write
/// fail. `_save` swallows its own errors, so state transitions are unaffected.
void main() {
  late ProviderContainer container;
  ServerStripLayoutNotifier notifier() =>
      container.read(serverStripLayoutProvider.notifier);
  List<StripItem> layout() => container.read(serverStripLayoutProvider);

  /// A readable rendering of the strip: `a`, `b` for servers, `Name[a,b]` for
  /// folders and `?a` for a parked join request.
  String outline() => layout().map((item) {
        return switch (item) {
          ServerStripItem(:final serverId) => serverId,
          PendingStripItem(:final serverId) => '?$serverId',
          FolderStripItem(:final name, :final serverIds) =>
            '$name[${serverIds.join(",")}]',
        };
      }).join(' ');

  void seed(List<StripItem> items) {
    // The notifier has no public setter; reorder() is the smallest public
    // mutation, so seed through the container's state directly.
    container.read(serverStripLayoutProvider.notifier).state = items;
  }

  setUp(() {
    container = ProviderContainer();
    // Build the provider before touching its state.
    container.read(serverStripLayoutProvider);
  });

  tearDown(() => container.dispose());

  test('New folder wraps one server in place', () {
    seed(const [
      ServerStripItem(serverId: 'a'),
      ServerStripItem(serverId: 'b'),
      ServerStripItem(serverId: 'c'),
    ]);

    notifier().createFolderWith('b', 'Games');

    expect(outline(), 'a Games[b] c');
  });

  test('a one-server folder survives, because that is what New folder makes',
      () {
    seed(const [
      ServerStripItem(serverId: 'a'),
      FolderStripItem(id: 'f1', name: 'Games', serverIds: ['b']),
    ]);

    // Moving out of a two-server folder leaves a one-server folder rather than
    // dissolving it: ONE rule for folder lifetime, everywhere.
    seed(const [
      FolderStripItem(id: 'f1', name: 'Games', serverIds: ['a', 'b']),
    ]);
    notifier().moveOutOfFolder('a');

    expect(outline(), 'Games[b] a');
  });

  test('a folder disappears only when it is empty', () {
    seed(const [
      FolderStripItem(id: 'f1', name: 'Games', serverIds: ['a']),
      ServerStripItem(serverId: 'b'),
    ]);

    notifier().moveOutOfFolder('a');

    expect(outline(), 'a b');
  });

  test('moving between folders leaves no copy behind', () {
    seed(const [
      FolderStripItem(id: 'f1', name: 'Games', serverIds: ['a', 'b']),
      FolderStripItem(id: 'f2', name: 'Work', serverIds: ['c']),
    ]);

    notifier().addToFolder('f2', 'a');

    expect(outline(), 'Games[b] Work[c,a]');
    expect(notifier().folderIdOf('a'), 'f2');
  });

  test('New folder pulls the server out of the folder it was in', () {
    seed(const [
      FolderStripItem(id: 'f1', name: 'Games', serverIds: ['a', 'b']),
    ]);

    notifier().createFolderWith('a', 'Solo');

    expect(outline(), 'Games[b] Solo[a]');
  });

  test('dissolving a folder spills its servers in order, in place', () {
    seed(const [
      ServerStripItem(serverId: 'x'),
      FolderStripItem(id: 'f1', name: 'Games', serverIds: ['a', 'b', 'c']),
      ServerStripItem(serverId: 'y'),
    ]);

    notifier().dissolveFolder('f1');

    expect(outline(), 'x a b c y');
  });

  test('folderIdOf and folders() see what the menu shows', () {
    seed(const [
      ServerStripItem(serverId: 'a'),
      FolderStripItem(id: 'f1', name: 'Games', serverIds: ['b', 'c']),
    ]);

    expect(notifier().folderIdOf('a'), isNull);
    expect(notifier().folderIdOf('b'), 'f1');
    expect(notifier().folders().map((f) => f.name).toList(), ['Games']);
  });

  test('a server deleted out from under a folder does not dissolve it', () {
    seed(const [
      FolderStripItem(id: 'f1', name: 'Games', serverIds: ['a', 'b']),
    ]);

    notifier().onServerDeleted('a');

    expect(outline(), 'Games[b]');
  });
}
