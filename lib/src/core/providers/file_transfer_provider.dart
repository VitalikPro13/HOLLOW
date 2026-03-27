import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// State for a single file transfer (sending or receiving).
class FileTransferState {
  final String fileId;
  final String fileName;
  final int sizeBytes;
  final int totalChunks;
  final int chunksReceived;
  final bool isComplete;
  final bool isSending;
  /// True while a streamed transfer is in flight (no chunk-based progress).
  final bool isDownloading;
  /// Vault content ID (set when vault_upload_file is called for 6+ member servers).
  final String? contentId;
  /// Vault download phase ("Collecting shards...", "Reconstructing...", "Decrypting...").
  final String? vaultPhase;
  final String? error;
  final String? diskPath;
  final bool isImage;
  final int? width;
  final int? height;

  const FileTransferState({
    required this.fileId,
    required this.fileName,
    required this.sizeBytes,
    required this.totalChunks,
    this.chunksReceived = 0,
    this.isComplete = false,
    this.isSending = false,
    this.isDownloading = false,
    this.contentId,
    this.vaultPhase,
    this.error,
    this.diskPath,
    this.isImage = false,
    this.width,
    this.height,
  });

  double get progress =>
      totalChunks > 0 ? chunksReceived / totalChunks : 0;

  FileTransferState copyWith({
    int? chunksReceived,
    bool? isComplete,
    bool? isDownloading,
    String? contentId,
    String? vaultPhase,
    String? error,
    String? diskPath,
  }) {
    return FileTransferState(
      fileId: fileId,
      fileName: fileName,
      sizeBytes: sizeBytes,
      totalChunks: totalChunks,
      chunksReceived: chunksReceived ?? this.chunksReceived,
      isComplete: isComplete ?? this.isComplete,
      isSending: isSending,
      isDownloading: isDownloading ?? this.isDownloading,
      contentId: contentId ?? this.contentId,
      vaultPhase: vaultPhase ?? this.vaultPhase,
      error: error ?? this.error,
      diskPath: diskPath ?? this.diskPath,
      isImage: isImage,
      width: width,
      height: height,
    );
  }
}

/// Tracks active file transfers.
class FileTransferNotifier
    extends Notifier<Map<String, FileTransferState>> {
  @override
  Map<String, FileTransferState> build() => {};

  /// Initiate a file send.
  /// [memberCount] is the server's member count — if >= 6, also triggers vault upload.
  Future<void> sendFile({
    String? peerId,
    String? serverId,
    String? channelId,
    required String filePath,
    required String messageId,
    String messageText = '',
    int memberCount = 0,
  }) async {
    // Extract filename for display.
    final parts = filePath.replaceAll('\\', '/').split('/');
    final fileName = parts.isNotEmpty ? parts.last : 'file';

    // Add optimistic transfer state.
    final updated = Map<String, FileTransferState>.from(state);
    updated[messageId] = FileTransferState(
      fileId: messageId,
      fileName: fileName,
      sizeBytes: 0,
      totalChunks: 0,
      isSending: true,
    );
    state = updated;

    // Call Rust FFI — P2P streaming path (works for all modes).
    try {
      await network_api.sendFile(
        peerId: peerId,
        serverId: serverId,
        channelId: channelId,
        filePath: filePath,
        messageId: messageId,
        messageText: messageText,
      );

      // For 6+ member servers: also trigger vault upload (erasure coding + shard distribution).
      // P2P streaming delivers to online peers immediately; vault ensures offline peers
      // can reconstruct from shards later.
      if (serverId != null && channelId != null && memberCount >= 6) {
        try {
          final contentId = await crdt_api.vaultUploadFile(
            serverId: serverId,
            channelId: channelId,
            filePath: filePath,
            messageId: messageId,
          );
          // Store contentId for vault status tracking.
          final withCid = Map<String, FileTransferState>.from(state);
          final current = withCid[messageId];
          if (current != null) {
            withCid[messageId] = current.copyWith(contentId: contentId);
            state = withCid;
          }
          debugPrint('[HOLLOW] Vault upload started: $contentId');
        } catch (e) {
          debugPrint('[HOLLOW] Vault upload failed (P2P still ok): $e');
        }
      }
    } catch (e) {
      final err = Map<String, FileTransferState>.from(state);
      err[messageId] = FileTransferState(
        fileId: messageId,
        fileName: fileName,
        sizeBytes: 0,
        totalChunks: 0,
        isSending: true,
        error: e.toString(),
      );
      state = err;
    }
  }

  /// Handle FileHeaderReceived event.
  /// [isVaultMode] — if true (6+ member server), file data arrives via vault shards,
  /// not P2P streaming, so we don't mark it as "downloading".
  void onFileHeaderReceived({
    required String fileId,
    required String fileName,
    required int sizeBytes,
    required bool isImage,
    int? width,
    int? height,
    bool isVaultMode = false,
  }) {
    // Don't overwrite an existing entry (e.g., from a sync batch that already
    // set isComplete, or a prior live transfer). Only create new entries.
    if (state.containsKey(fileId)) return;
    final updated = Map<String, FileTransferState>.from(state);
    updated[fileId] = FileTransferState(
      fileId: fileId,
      fileName: fileName,
      sizeBytes: sizeBytes,
      totalChunks: 0,
      isImage: isImage,
      width: width,
      height: height,
      // Don't set isDownloading on header alone — it will be set when actual
      // progress starts (FileProgress event) or by the download button.
      // This prevents synced file metadata from showing "Downloading..." forever.
      isDownloading: false,
    );
    state = updated;
  }

  /// Handle FileProgress event.
  void onFileProgress(String fileId, int chunksReceived, int totalChunks) {
    final current = state[fileId];
    if (current == null) return;
    final updated = Map<String, FileTransferState>.from(state);
    // For streamed transfers, chunks represent MB received / MB total.
    if (current.totalChunks == 0 && totalChunks > 0) {
      updated[fileId] = FileTransferState(
        fileId: current.fileId,
        fileName: current.fileName,
        sizeBytes: current.sizeBytes,
        totalChunks: totalChunks,
        chunksReceived: chunksReceived,
        isSending: current.isSending,
        isDownloading: true, // Active progress → actively downloading.
        isImage: current.isImage,
        width: current.width,
        height: current.height,
      );
    } else {
      updated[fileId] = current.copyWith(chunksReceived: chunksReceived);
    }
    state = updated;
  }

  /// Handle FileCompleted event.
  void onFileCompleted(String fileId, String diskPath) {
    final current = state[fileId];
    final updated = Map<String, FileTransferState>.from(state);
    if (current != null) {
      updated[fileId] = current.copyWith(
        isComplete: true,
        isDownloading: false,
        diskPath: diskPath,
        chunksReceived: current.totalChunks > 0 ? current.totalChunks : 1,
      );
    } else {
      // File completed without a prior header (e.g., received via sync then stream).
      updated[fileId] = FileTransferState(
        fileId: fileId,
        fileName: 'file',
        sizeBytes: 0,
        totalChunks: 1,
        chunksReceived: 1,
        isComplete: true,
        isDownloading: false,
        diskPath: diskPath,
      );
    }
    state = updated;
  }

  /// Handle FileFailed event.
  void onFileFailed(String fileId, String error) {
    final current = state[fileId];
    final updated = Map<String, FileTransferState>.from(state);
    updated[fileId] = FileTransferState(
      fileId: fileId,
      fileName: current?.fileName ?? 'file',
      sizeBytes: current?.sizeBytes ?? 0,
      totalChunks: current?.totalChunks ?? 0,
      chunksReceived: current?.chunksReceived ?? 0,
      isSending: current?.isSending ?? false,
      error: error,
    );
    state = updated;
  }

  /// Handle vault download progress — update phase text on file transfer.
  /// contentId is matched against transfers that have contentId set.
  void onVaultDownloadProgress(String contentId, String phase, double progress) {
    final updated = Map<String, FileTransferState>.from(state);
    for (final entry in updated.entries) {
      if (entry.value.contentId == contentId) {
        updated[entry.key] = entry.value.copyWith(
          vaultPhase: phase,
          isDownloading: true,
        );
        break;
      }
    }
    state = updated;
  }

  /// Handle vault download complete.
  void onVaultDownloadComplete(String contentId, String diskPath) {
    final updated = Map<String, FileTransferState>.from(state);
    bool found = false;
    for (final entry in updated.entries) {
      if (entry.value.contentId == contentId) {
        updated[entry.key] = entry.value.copyWith(
          isComplete: true,
          isDownloading: false,
          diskPath: diskPath,
          vaultPhase: null,
        );
        found = true;
        break;
      }
    }
    // If no entry matched by contentId, create one so the polling loop can find it.
    if (!found) {
      updated['vault:$contentId'] = FileTransferState(
        fileId: 'vault:$contentId',
        fileName: 'file',
        sizeBytes: 0,
        totalChunks: 1,
        chunksReceived: 1,
        isComplete: true,
        isDownloading: false,
        diskPath: diskPath,
        contentId: contentId,
      );
    }
    state = updated;
  }
}

final fileTransferProvider = NotifierProvider<FileTransferNotifier,
    Map<String, FileTransferState>>(FileTransferNotifier.new);
