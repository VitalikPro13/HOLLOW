import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/api/storage.dart' show StoredFileInfo;

/// Set from the launch after a link until the sweep's last pass ran.
const String kRecentFilesSweepDue = 'recent_files_sweep_due';

/// How far back a freshly linked device fetches files without the chat being opened.
const Duration kRecentFilesWindow = Duration(days: 7);

/// Stays well under the node's 256 pending asks, whose overflow evicts the oldest:
/// asked newest first, those would be the newest files.
const int kRecentFilesMaxAsks = 100;

class RecentFileAsk {
  final String fileId;

  /// The conversation (DM) or the poster (channel); the node walks the other
  /// holders, own siblings included, when this one cannot answer.
  final String peerId;
  const RecentFileAsk(this.fileId, this.peerId);
}

/// The files a linked device pulls on its own: from the last [kRecentFilesWindow],
/// newest first, and only what the auto-download settings would have pulled for
/// that conversation (voice notes exempt, as everywhere). Nothing of a blocked
/// identity: [blocked] takes any peer id, device or master.
List<RecentFileAsk> selectRecentFilesToFetch(
  Iterable<StoredFileInfo> missing, {
  required DateTime now,
  required int Function(String contextKey) effectiveMb,
  required bool Function(String fileId) busy,
  required bool Function(String peerId) blocked,
  int limit = kRecentFilesMaxAsks,
}) {
  final since = now.subtract(kRecentFilesWindow).millisecondsSinceEpoch;
  final picked = <(int, RecentFileAsk)>[];
  for (final f in missing) {
    if (f.completedAt != null || f.expiredAt != null) continue;
    // A share-backed file is pulled through its swarm, never a FileRequest.
    if (f.shareRootHash != null) continue;
    if (busy(f.fileId)) continue;
    // Our own siblings would answer for them, past the node's block guard.
    if (blocked(f.senderId) || (f.contextType == 'dm' && blocked(f.contextId))) {
      continue;
    }
    final String key;
    final String peer;
    switch (f.contextType) {
      case 'dm':
        key = 'dm:${f.contextId}';
        peer = f.contextId;
      case 'channel':
        final server = f.contextId.split(':').first;
        if (server.isEmpty) continue;
        key = 'server:$server';
        peer = f.senderId;
      default:
        continue;
    }
    // Older rows stamped seconds; a millisecond stamp is far past this mark.
    final created = f.createdAt < 100000000000 ? f.createdAt * 1000 : f.createdAt;
    if (created < since) continue;
    final size = f.sizeBytes.toInt();
    final voice = isGenuineVoiceNote(
        voice: true, name: f.fileName, ext: f.fileExt, sizeBytes: size);
    final mb = effectiveMb(key);
    if (!voice && (mb == 0 || size > mb * 1024 * 1024)) continue;
    picked.add((created, RecentFileAsk(f.fileId, peer)));
  }
  picked.sort((a, b) => b.$1.compareTo(a.$1));
  return [for (final p in picked.take(limit)) p.$2];
}

final recentFilesSweepProvider =
    Provider<RecentFilesSweep>((ref) => RecentFilesSweep(ref));

/// When the first launch after a link sweeps, counted from node start. One pass is
/// not enough: a sibling refuses (silently) a device its roster has not counted
/// yet, and a settled ask is walked again only when it is asked for again.
const List<Duration> kRecentFilesPasses = [
  Duration.zero,
  Duration(seconds: 45),
  Duration(minutes: 3),
];

/// Run by the first launch after a link: the new device's recent chats show
/// their images without each being opened first.
class RecentFilesSweep {
  RecentFilesSweep(this._ref,
      {this.passes = kRecentFilesPasses, this.spacing = const Duration(milliseconds: 150)});
  final Ref _ref;
  final List<Duration> passes;

  /// Each answer is a whole file streamed by its holder; spacing the asks keeps a
  /// long history from landing on one holder in the same instant.
  final Duration spacing;

  /// Sweeps on the launch after a link and on every later launch until a sweep
  /// finished: a person who quits right after the post-link restart still gets them.
  Future<void> runIfDue({required bool linkedThisLaunch}) async {
    if (linkedThisLaunch) {
      await storage_api.saveSetting(key: kRecentFilesSweepDue, value: '1').catchError((_) {});
    } else if (await storage_api.loadSetting(key: kRecentFilesSweepDue).catchError((_) => null) != '1') {
      return;
    }
    await run();
    await storage_api.saveSetting(key: kRecentFilesSweepDue, value: '').catchError((_) {});
  }

  Future<void> run() async {
    var waited = Duration.zero;
    for (final at in passes) {
      await Future<void>.delayed(at - waited);
      waited = at;
      await _pass();
    }
  }

  Future<void> _pass() async {
    // Nobody taps anything here, so a setting not yet read (or unreadable) must not
    // fall back to the permissive default the gate's readers use.
    try {
      await _ref.read(autoDownloadThresholdProvider.future);
      await _ref.read(autoDownloadOverridesProvider.future);
    } catch (_) {
      return;
    }
    await _ref.read(blockedUsersProvider.notifier).load();
    final rows = <StoredFileInfo>[];
    for (final id in await storage_api.getMissingFileIds()) {
      final info = await storage_api.getFileMetadata(fileId: id);
      if (info != null) rows.add(info);
    }
    final transfers = _ref.read(fileTransferProvider);
    final blockedIds = _ref.read(blockedUsersProvider);
    final links = _ref.read(deviceLinkProvider);
    final asks = selectRecentFilesToFetch(
      rows,
      now: DateTime.now(),
      effectiveMb: (key) => effectiveAutoDownloadMbRead(_ref, key),
      busy: (id) {
        final t = transfers[id];
        return t != null && (t.isDownloading || t.isComplete);
      },
      blocked: (peer) => blockedIds.contains(links.identityOf(peer)),
    );
    unawaited(network_api
        .logFromDart(
            message: '[HOLLOW-LINK] Fetching ${asks.length} recent file(s) '
                'of ${rows.length} missing')
        .catchError((_) {}));
    for (final ask in asks) {
      await network_api
          .requestFileFromPeer(fileId: ask.fileId, peerId: ask.peerId, chunks: const [])
          .catchError((_) {});
      await Future<void>.delayed(spacing);
    }
  }
}
