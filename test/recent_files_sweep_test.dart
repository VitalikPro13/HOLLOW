import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/recent_files_sweep.dart';
import 'package:hollow/src/rust/api/storage.dart';
import 'package:hollow/src/rust/frb_generated.dart';

/// The node as the sweep sees it: the missing rows, the settings, and the asks.
class _NodeApi implements RustLibApi {
  final rows = <String, StoredFileInfo>{};
  final settings = <String, String>{};
  bool settingsFail = false;
  final asks = <(String, String)>[];
  final blocked = <String>[];

  @override
  Future<List<String>> crateApiStorageLoadBlockedPeers() async => blocked;

  @override
  Future<List<String>> crateApiStorageGetMissingFileIds() async => rows.keys.toList();

  @override
  Future<StoredFileInfo?> crateApiStorageGetFileMetadata({required String fileId}) async =>
      rows[fileId];

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async {
    if (settingsFail) throw StateError('locked');
    return settings[key];
  }

  @override
  Future<void> crateApiStorageSaveSetting({required String key, required String value}) async {
    settings[key] = value;
  }

  @override
  Future<void> crateApiNetworkRequestFileFromPeer(
      {required String fileId, required String peerId, required List<int> chunks}) async {
    dueAtFirstAsk ??= settings[kRecentFilesSweepDue] ?? '';
    asks.add((fileId, peerId));
  }

  /// What a quit at this moment would leave for the next launch.
  String? dueAtFirstAsk;

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _mb = 1024 * 1024;
final _now = DateTime.utc(2026, 10, 10, 12);

StoredFileInfo _file(
  String id, {
  Duration age = const Duration(hours: 1),
  String context = 'dm',
  String contextId = 'friend-master',
  String sender = 'friend-device',
  String name = 'photo.png',
  String ext = 'png',
  int size = 200 * 1024,
  bool seconds = false,
  int? completedAt,
  int? expiredAt,
  String? share,
}) {
  final created = _now.subtract(age).millisecondsSinceEpoch;
  return StoredFileInfo(
    fileId: id,
    fileName: name,
    fileExt: ext,
    mimeType: 'image/png',
    sizeBytes: BigInt.from(size),
    chunkCount: 1,
    chunksReceived: 0,
    isImage: true,
    contextType: context,
    contextId: contextId,
    senderId: sender,
    isMine: false,
    createdAt: seconds ? created ~/ 1000 : created,
    completedAt: completedAt,
    expiredAt: expiredAt,
    shareRootHash: share,
  );
}

List<String> _select(
  List<StoredFileInfo> rows, {
  Map<String, int> mb = const {},
  Set<String> busy = const {},
  int limit = kRecentFilesMaxAsks,
}) =>
    selectRecentFilesToFetch(
      rows,
      now: _now,
      effectiveMb: (key) => mb[key] ?? 169,
      busy: busy.contains,
      blocked: (_) => false,
      limit: limit,
    ).map((a) => a.fileId).toList();

void main() {
  test('only the last seven days are fetched, the newest first', () {
    final picked = _select([
      _file('two-days', age: const Duration(days: 2)),
      _file('eight-days', age: const Duration(days: 8)),
      _file('an-hour'),
      _file('six-days-in-seconds', age: const Duration(days: 6), seconds: true),
    ]);
    expect(picked, ['an-hour', 'two-days', 'six-days-in-seconds']);
  });

  test('a conversation with auto-download off gives up only its voice notes', () {
    final picked = _select([
      _file('their-photo'),
      _file('their-empty-file', size: 0),
      _file('their-voice', name: 'voice_1791_ab12.ogg', ext: 'ogg', size: 90 * 1024),
      _file('their-fake-voice', name: 'voice_1791_cd34.ogg', ext: 'ogg', size: 9 * _mb),
      _file('other-photo', contextId: 'other-master'),
    ], mb: {'dm:friend-master': 0});
    expect(picked.toSet(), {'their-voice', 'other-photo'});
  });

  test('a file over the auto-download size waits for a tap', () {
    final picked = _select([
      _file('small', size: 30 * _mb),
      _file('large', size: 40 * _mb),
    ], mb: {'dm:friend-master': 34});
    expect(picked, ['small']);
  });

  test('a channel file is gated by its server and asked of its poster', () {
    final rows = [
      _file('ch', context: 'channel', contextId: 'srv1:general', sender: 'poster-master'),
      _file('muted', context: 'channel', contextId: 'srv2:general'),
    ];
    final asks = selectRecentFilesToFetch(
      rows,
      now: _now,
      effectiveMb: (key) => key == 'server:srv2' ? 0 : 169,
      busy: (_) => false,
      blocked: (_) => false,
    );
    expect(asks.map((a) => (a.fileId, a.peerId)), [('ch', 'poster-master')]);
  });

  test('a DM file is asked of the conversation', () {
    final asks = selectRecentFilesToFetch(
      [_file('dm', contextId: 'friend-master', sender: 'friend-device')],
      now: _now,
      effectiveMb: (_) => 169,
      busy: (_) => false,
      blocked: (_) => false,
    );
    expect(asks.single.peerId, 'friend-master');
  });

  test('nothing held, expired, in flight, share-backed or of an unknown kind is asked', () {
    final picked = _select([
      _file('held', completedAt: 1),
      _file('expired', expiredAt: 1),
      _file('in-flight'),
      _file('shared', share: 'ab' * 32),
      _file('guest', context: 'guest'),
      _file('wanted'),
    ], busy: {'in-flight'});
    expect(picked, ['wanted']);
  });

  test('a long history asks for no more than the limit', () {
    final rows = [
      for (var i = 0; i < 10; i++) _file('f$i', age: Duration(minutes: i)),
    ];
    expect(_select(rows, limit: 3), ['f0', 'f1', 'f2']);
  });

  group('the sweep after a link', () {
    final api = _NodeApi();
    setUpAll(() => RustLib.initMock(api: api));
    setUp(() {
      api.rows.clear();
      api.settings.clear();
      api.settingsFail = false;
      api.asks.clear();
      api.dueAtFirstAsk = null;
      api.blocked.clear();
    });

    Future<void> sweep({int passes = 1, List<Override> overrides = const []}) {
      final c = ProviderContainer(overrides: overrides);
      addTearDown(c.dispose);
      final s = RecentFilesSweep(c.read(_ref),
          passes: List.filled(passes, Duration.zero), spacing: Duration.zero);
      return s.run();
    }

    /// A missing file [age] old on the real clock, which the sweep reads.
    StoredFileInfo recent(String id, Duration age,
        {String context = 'dm', String contextId = 'friend-master', String sender = 'friend-device'}) {
      final f = _file(id, context: context, contextId: contextId, sender: sender);
      return StoredFileInfo(
        fileId: f.fileId,
        fileName: f.fileName,
        fileExt: f.fileExt,
        mimeType: f.mimeType,
        sizeBytes: f.sizeBytes,
        chunkCount: f.chunkCount,
        chunksReceived: f.chunksReceived,
        isImage: f.isImage,
        contextType: f.contextType,
        contextId: f.contextId,
        senderId: f.senderId,
        isMine: f.isMine,
        createdAt: DateTime.now().subtract(age).millisecondsSinceEpoch,
      );
    }

    test('every pass asks the node for what the settings allow, newest first', () async {
      api.rows['older'] = recent('older', const Duration(hours: 5));
      api.rows['newer'] = recent('newer', const Duration(minutes: 5));
      api.rows['muted'] = recent('muted', const Duration(minutes: 1), contextId: 'muted-master');
      api.settings['auto_download_overrides'] = '{"dm:muted-master":false}';
      await sweep(passes: 2);
      expect(api.asks, [
        ('newer', 'friend-master'),
        ('older', 'friend-master'),
        ('newer', 'friend-master'),
        ('older', 'friend-master'),
      ]);
    });

    test('auto-download off pulls nothing, even before the settings were read', () async {
      api.rows['photo'] = recent('photo', const Duration(minutes: 1));
      api.settings['auto_download_threshold_mb'] = '0';
      await sweep();
      expect(api.asks, isEmpty);
    });

    Future<void> launch({required bool linked}) {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return RecentFilesSweep(c.read(_ref), passes: const [Duration.zero], spacing: Duration.zero)
          .runIfDue(linkedThisLaunch: linked);
    }

    test('a sweep cut short by a quit runs again on the next launch', () async {
      api.rows['photo'] = recent('photo', const Duration(minutes: 1));
      api.settings[kRecentFilesSweepDue] = '1';
      await launch(linked: false);
      expect(api.asks, [('photo', 'friend-master')]);
      expect(api.settings[kRecentFilesSweepDue], isEmpty, reason: 'a finished sweep is not due');
    });

    test('the launch after a link sweeps once; later launches do not', () async {
      api.rows['photo'] = recent('photo', const Duration(minutes: 1));
      await launch(linked: true);
      expect(api.dueAtFirstAsk, '1', reason: 'a quit mid-sweep must leave the sweep due');
      await launch(linked: false);
      expect(api.asks, [('photo', 'friend-master')]);
    });

    test('a launch that never linked sweeps nothing', () async {
      api.rows['photo'] = recent('photo', const Duration(minutes: 1));
      await launch(linked: false);
      expect(api.asks, isEmpty);
    });

    test('nothing of a blocked identity is asked, whichever of its devices sent it', () async {
      api.blocked.add('blocked-master');
      api.rows['their-channel-file'] = recent('their-channel-file', Duration.zero,
          context: 'channel', contextId: 'srv1:general', sender: 'blocked-phone');
      api.rows['ours-in-their-dm'] =
          recent('ours-in-their-dm', Duration.zero, contextId: 'blocked-master', sender: 'me-master');
      api.rows['photo'] = recent('photo', const Duration(minutes: 1));
      await sweep(overrides: [deviceLinkProvider.overrideWith(_Links.new)]);
      expect(api.asks, [('photo', 'friend-master')]);
    });

    test('settings that cannot be read pull nothing', () async {
      api.rows['photo'] = recent('photo', const Duration(minutes: 1));
      api.settingsFail = true;
      await sweep();
      expect(api.asks, isEmpty);
    });
  });
}

/// What the node's resolver says: the blocked identity's phone.
class _Links extends DeviceLinkNotifier {
  @override
  DeviceLinkState build() => const DeviceLinkState(links: {'blocked-phone': 'blocked-master'});
}

/// A [Ref] for constructing the sweep inside a plain container.
final _ref = Provider<Ref>((ref) => ref);
