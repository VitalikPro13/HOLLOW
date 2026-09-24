import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/services/at_rest.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Live storage-usage breakdown for the Storage Manager UI (Settings → Storage).
///
/// Settings warms it on open ([warmStorageBreakdown]) and it outlives its last
/// listener for a minute, so the Storage tab paints its figures on the first
/// frame instead of a spinner. The action methods below invalidate it after
/// any clear or evict.
final storageBreakdownProvider =
    FutureProvider.autoDispose<storage_api.StorageBreakdown>((ref) async {
  final link = ref.keepAlive();
  final timer = Timer(const Duration(minutes: 1), link.close);
  ref.onDispose(timer.cancel);
  return storage_api.getStorageBreakdown();
});

/// Starts reading the breakdown before the Storage tab is on screen.
void warmStorageBreakdown(ProviderContainer container) =>
    container.read(storageBreakdownProvider.future).ignore();

/// Progress of the one-time sweep that encrypts files left in the clear by an
/// older version.
///
/// Polls only while the sweep is running, and only while the Storage Manager is
/// on screen; the last value is a settled state that cannot change again this
/// launch.
final atRestStatusProvider = StreamProvider.autoDispose<AtRestStatus>((ref) {
  const interval = Duration(seconds: 2);
  final controller = StreamController<AtRestStatus>();
  Timer? timer;

  Future<void> tick() async {
    try {
      final status = await AtRest.status();
      if (controller.isClosed) return;
      controller.add(status);
      if (!status.running) {
        timer?.cancel();
        await controller.close();
      }
    } catch (_) {
      timer?.cancel();
      if (!controller.isClosed) await controller.close();
    }
  }

  tick();
  timer = Timer.periodic(interval, (_) => tick());
  ref.onDispose(() {
    timer?.cancel();
    if (!controller.isClosed) controller.close();
  });
  return controller.stream;
});

/// Actions for the Storage Manager: clear cached file bytes, enforce the files
/// cap, and clear/evict the vault cache. Each refreshes the breakdown. The
/// FFIs keep the signed FileHeader rows, so only the heavy bytes go.
final storageActionsProvider = Provider<StorageActions>((ref) {
  return StorageActions(ref);
});

class StorageActions {
  StorageActions(this._ref);
  final Ref _ref;

  void _refresh() => _ref.invalidate(storageBreakdownProvider);

  /// Delete ALL downloaded file bytes (keep headers). Returns bytes freed.
  Future<int> clearAllFileBytes() async {
    try {
      final freed = await storage_api.clearAllFileBytes();
      return freed.toInt();
    } catch (e) {
      debugPrint('[HOLLOW-STORAGE] clearAllFileBytes failed: $e');
      return 0;
    } finally {
      _refresh();
    }
  }

  /// Delete file bytes for a single conversation/server. Returns bytes freed.
  Future<int> clearContext(String contextType, String contextId) async {
    try {
      final freed = await storage_api.clearFileBytesForContext(
        contextType: contextType,
        contextId: contextId,
      );
      return freed.toInt();
    } catch (e) {
      debugPrint('[HOLLOW-STORAGE] clearContext($contextType,$contextId) failed: $e');
      return 0;
    } finally {
      _refresh();
    }
  }

  /// Clear the entire vault cache (pure cache). Returns bytes freed.
  Future<int> clearVaultCache() async {
    try {
      final freed = await storage_api.clearVaultCache();
      return freed.toInt();
    } catch (e) {
      debugPrint('[HOLLOW-STORAGE] clearVaultCache failed: $e');
      return 0;
    } finally {
      _refresh();
    }
  }

  /// Delete cached asset blobs (emotes/stickers/GIFs) not referenced by a
  /// personal set or a server's CRDT state. Returns bytes freed.
  Future<int> clearUnreferencedAssets() async {
    try {
      final freed = await storage_api.clearUnreferencedAssetBlobs();
      return freed.toInt();
    } catch (e) {
      debugPrint('[HOLLOW-STORAGE] clearUnreferencedAssets failed: $e');
      return 0;
    } finally {
      _refresh();
    }
  }
}

/// Format a byte count as a human-readable size (e.g. "1.4 GB", "320 MB").
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final fixed = (unit == 0 || size >= 100) ? 0 : 1;
  return '${size.toStringAsFixed(fixed)} ${units[unit]}';
}
