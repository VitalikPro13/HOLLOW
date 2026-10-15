import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/recent_files_sweep.dart';
import 'package:hollow/src/rust/api/storage.dart';
import 'package:hollow/src/rust/frb_generated.dart';

// md-review: hostile review of the linking track (wave md).

class _NodeApi implements RustLibApi {
  final rows = <String, StoredFileInfo>{};
  final settings = <String, String>{};
  final asks = <(String, String)>[];

  @override
  Future<List<String>> crateApiStorageGetMissingFileIds() async => rows.keys.toList();

  @override
  Future<StoredFileInfo?> crateApiStorageGetFileMetadata({required String fileId}) async =>
      rows[fileId];

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async => settings[key];

  @override
  Future<void> crateApiStorageSaveSetting({required String key, required String value}) async {
    settings[key] = value;
  }

  @override
  Future<void> crateApiNetworkRequestFileFromPeer(
      {required String fileId, required String peerId, required List<int> chunks}) async {
    asks.add((fileId, peerId));
  }

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Blocked extends BlockedUsersNotifier {
  @override
  Set<String> build() => const {'blocked-master'};
}

final _ref = Provider<Ref>((ref) => ref);

StoredFileInfo _recent(String id,
        {String context = 'dm', String contextId = 'friend-master', String sender = 'friend-device'}) =>
    StoredFileInfo(
      fileId: id,
      fileName: 'photo.png',
      fileExt: 'png',
      mimeType: 'image/png',
      sizeBytes: BigInt.from(200 * 1024),
      chunkCount: 1,
      chunksReceived: 0,
      isImage: true,
      contextType: context,
      contextId: contextId,
      senderId: sender,
      isMine: false,
      createdAt: DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch,
    );

void main() {
  final api = _NodeApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api.rows.clear();
    api.settings.clear();
    api.asks.clear();
  });

  Future<void> sweep() {
    final c = ProviderContainer(overrides: [blockedUsersProvider.overrideWith(_Blocked.new)]);
    addTearDown(c.dispose);
    return RecentFilesSweep(c.read(_ref), passes: const [Duration.zero], spacing: Duration.zero).run();
  }

  test('md-review: the post-link sweep never asks a blocked contact, nor pulls their files', () async {
    api.rows['theirs-dm'] = _recent('theirs-dm', contextId: 'blocked-master', sender: 'blocked-master');
    api.rows['theirs-channel'] = _recent('theirs-channel',
        context: 'channel', contextId: 'srv1:general', sender: 'blocked-master');
    api.rows['friend'] = _recent('friend');
    await sweep();
    expect(api.asks, [('friend', 'friend-master')],
        reason: 'a block cuts contact: no FileRequest to the blocked identity, and no '
            'automatic pull of what it sent through our own sibling either');
  });
}
