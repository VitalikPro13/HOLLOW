import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Vault health status for a server.
enum VaultHealth { healthy, degraded, critical }

/// Status of a single vault file upload/download.
class VaultFileStatus {
  final String contentId;
  final String phase; // "encrypting", "encoding", "distributing", "complete", "failed"
  final double progress; // 0.0 - 1.0
  final int shardsConfirmed;
  final int shardsTotal;
  final String? error;

  const VaultFileStatus({
    required this.contentId,
    this.phase = 'distributing',
    this.progress = 0.0,
    this.shardsConfirmed = 0,
    this.shardsTotal = 0,
    this.error,
  });

  VaultFileStatus copyWith({
    String? phase,
    double? progress,
    int? shardsConfirmed,
    int? shardsTotal,
    String? error,
  }) {
    return VaultFileStatus(
      contentId: contentId,
      phase: phase ?? this.phase,
      progress: progress ?? this.progress,
      shardsConfirmed: shardsConfirmed ?? this.shardsConfirmed,
      shardsTotal: shardsTotal ?? this.shardsTotal,
      error: error ?? this.error,
    );
  }
}

/// Aggregated vault status for a single server.
class VaultServerStatus {
  final Map<String, VaultFileStatus> activeUploads;
  final Map<String, VaultFileStatus> activeDownloads;
  final int shardsStoredLocally;

  const VaultServerStatus({
    this.activeUploads = const {},
    this.activeDownloads = const {},
    this.shardsStoredLocally = 0,
  });

  VaultServerStatus copyWith({
    Map<String, VaultFileStatus>? activeUploads,
    Map<String, VaultFileStatus>? activeDownloads,
    int? shardsStoredLocally,
  }) {
    return VaultServerStatus(
      activeUploads: activeUploads ?? this.activeUploads,
      activeDownloads: activeDownloads ?? this.activeDownloads,
      shardsStoredLocally: shardsStoredLocally ?? this.shardsStoredLocally,
    );
  }

  VaultHealth computeHealth() {
    if (activeUploads.values.any((u) => u.phase == 'failed')) {
      return VaultHealth.critical;
    }
    if (activeUploads.values.any((u) => u.phase != 'complete')) {
      return VaultHealth.degraded;
    }
    return VaultHealth.healthy;
  }

  String get healthMessage {
    final health = computeHealth();
    switch (health) {
      case VaultHealth.healthy:
        return 'All files distributed';
      case VaultHealth.degraded:
        final distributing = activeUploads.values
            .where((u) => u.phase != 'complete' && u.phase != 'failed')
            .length;
        return '$distributing file(s) distributing...';
      case VaultHealth.critical:
        return 'Distribution failed';
    }
  }
}

/// Tracks vault status across all servers. Keyed by serverId.
class VaultStatusNotifier extends Notifier<Map<String, VaultServerStatus>> {
  @override
  Map<String, VaultServerStatus> build() => {};

  VaultServerStatus _getServer(String serverId) {
    return state[serverId] ?? const VaultServerStatus();
  }

  void _updateServer(String serverId, VaultServerStatus status) {
    state = {...state, serverId: status};
  }

  // ── Upload events ──────────────────────────────────────────

  void onUploadProgress(
      String serverId, String contentId, String phase, double progress) {
    final server = _getServer(serverId);
    final current = server.activeUploads[contentId] ??
        VaultFileStatus(contentId: contentId);
    final updated = current.copyWith(phase: phase, progress: progress);
    _updateServer(
      serverId,
      server.copyWith(
        activeUploads: {...server.activeUploads, contentId: updated},
      ),
    );
  }

  void onUploadComplete(String serverId, String contentId) {
    final server = _getServer(serverId);
    final current = server.activeUploads[contentId] ??
        VaultFileStatus(contentId: contentId);
    final updated = current.copyWith(phase: 'complete', progress: 1.0);
    _updateServer(
      serverId,
      server.copyWith(
        activeUploads: {...server.activeUploads, contentId: updated},
      ),
    );
  }

  void onUploadFailed(String serverId, String contentId, String error) {
    final server = _getServer(serverId);
    final current = server.activeUploads[contentId] ??
        VaultFileStatus(contentId: contentId);
    final updated = current.copyWith(phase: 'failed', error: error);
    _updateServer(
      serverId,
      server.copyWith(
        activeUploads: {...server.activeUploads, contentId: updated},
      ),
    );
  }

  // ── Download events ────────────────────────────────────────

  void onDownloadProgress(
      String serverId, String contentId, String phase, double progress) {
    final server = _getServer(serverId);
    final current = server.activeDownloads[contentId] ??
        VaultFileStatus(contentId: contentId);
    final updated = current.copyWith(phase: phase, progress: progress);
    _updateServer(
      serverId,
      server.copyWith(
        activeDownloads: {...server.activeDownloads, contentId: updated},
      ),
    );
  }

  void onDownloadComplete(String serverId, String contentId) {
    final server = _getServer(serverId);
    // Remove from active downloads on completion
    final downloads = Map.of(server.activeDownloads)..remove(contentId);
    _updateServer(
      serverId,
      server.copyWith(activeDownloads: downloads),
    );
  }

  void onDownloadFailed(String serverId, String contentId, String error) {
    final server = _getServer(serverId);
    final current = server.activeDownloads[contentId] ??
        VaultFileStatus(contentId: contentId);
    final updated = current.copyWith(phase: 'failed', error: error);
    _updateServer(
      serverId,
      server.copyWith(
        activeDownloads: {...server.activeDownloads, contentId: updated},
      ),
    );
  }

  // ── Shard events ───────────────────────────────────────────

  void onShardStored(String serverId, String contentId) {
    final server = _getServer(serverId);
    _updateServer(
      serverId,
      server.copyWith(shardsStoredLocally: server.shardsStoredLocally + 1),
    );
  }

  void onShardAckReceived(
      String serverId, String contentId, bool success) {
    if (!success) return;
    final server = _getServer(serverId);
    final current = server.activeUploads[contentId];
    if (current != null) {
      final updated = current.copyWith(
        shardsConfirmed: current.shardsConfirmed + 1,
      );
      _updateServer(
        serverId,
        server.copyWith(
          activeUploads: {...server.activeUploads, contentId: updated},
        ),
      );
    }
  }
}

final vaultStatusProvider =
    NotifierProvider<VaultStatusNotifier, Map<String, VaultServerStatus>>(
  VaultStatusNotifier.new,
);
