import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Live storage-usage breakdown for the Storage Manager UI (Settings → Storage).
/// Auto-disposes so it re-reads disk on each panel open; invalidated by the
/// action methods below after any clear/evict.
final storageBreakdownProvider =
    FutureProvider.autoDispose<storage_api.StorageBreakdown>((ref) async {
  return storage_api.getStorageBreakdown();
});

/// Actions for the Storage Manager: clear cached file bytes (all / per-context),
/// enforce the files cache cap, and clear/evict the vault cache. Each refreshes
/// `storageBreakdownProvider` afterward. The clear/evict FFIs keep the signed
/// FileHeader rows (messages stay re-downloadable) — only the heavy bytes go.
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
