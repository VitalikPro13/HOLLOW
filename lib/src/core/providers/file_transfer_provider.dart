import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/share.dart' as share_api;
import 'package:path/path.dart' as p;

import '../services/video_thumbnail_service.dart';

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
  /// Video thumbnail back-reference (Phase 6.75 video preview).
  /// When non-null, this file is a thumbnail image for the vault-stored video
  /// identified by `videoThumb.cid`. The UI renders a play button overlay and
  /// triggers a vault download on tap.
  final network_api.VideoThumbRef? videoThumb;
  /// Share root hash — set for share-backed files (>34 MB channel files).
  final String? shareRootHash;
  /// Number of active seeders — updated from ShareProgress events.
  final int? seeders;

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
    this.videoThumb,
    this.shareRootHash,
    this.seeders,
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
    network_api.VideoThumbRef? videoThumb,
    int? seeders,
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
      videoThumb: videoThumb ?? this.videoThumb,
      shareRootHash: shareRootHash,
      seeders: seeders ?? this.seeders,
    );
  }
}

/// Context for a pending share-backed file send. Stored until ShareCreated
/// fires, then the FileHeader is sent with share_ref.
class _PendingShareSend {
  /// DM target (null for channel sends).
  final String? peerId;
  final String? serverId;
  final String? channelId;
  final String messageText;
  final String fileName;
  final String messageId;
  final String filePath;
  final bool isVideo;
  final VideoThumbnailResult? videoThumb;
  _PendingShareSend({
    this.peerId,
    this.serverId,
    this.channelId,
    required this.messageText,
    required this.fileName,
    required this.messageId,
    required this.filePath,
    required this.isVideo,
    this.videoThumb,
  });
}

/// Tracks active file transfers.
class FileTransferNotifier
    extends Notifier<Map<String, FileTransferState>> {
  @override
  Map<String, FileTransferState> build() => {};

  final Map<String, _PendingShareSend> _pendingShareSends = {};

  /// Video file extensions handled by the Phase 6.75 video preview path.
  static const _videoExtensions = {
    'mp4', 'webm', 'mov', 'mkv', 'avi', 'm4v',
  };

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

    // Detect video files for the Phase 6.75 vault video preview path.
    final ext = p.extension(filePath).toLowerCase().replaceFirst('.', '');
    final isVideo = _videoExtensions.contains(ext);
    final isVaultMode =
        serverId != null && channelId != null && memberCount >= 6;

    // Phase 6.75: For ALL video files (vault or direct P2P), pre-extract a
    // thumbnail so we know the source video's pixel dimensions. We pass these
    // to the FileHeader's width/height fields so receivers can render the
    // bubble at the correct aspect ratio without their own probe round-trip.
    // The vault path (below) reuses the same VideoThumbnailResult to avoid
    // a second extraction.
    VideoThumbnailResult? videoThumb;
    if (isVideo) {
      videoThumb = await VideoThumbnailService.extractVideoThumbnail(
        videoPath: filePath,
      );
      if (videoThumb != null) {
        debugPrint(
            '[HOLLOW] Pre-extracted video dimensions: ${videoThumb.sourceWidth}x${videoThumb.sourceHeight}');
      }
    }

    try {
      // Large files (>34 MB) — DM or channel: host as a hidden Hollow Share for
      // chunked P2P delivery, then send the FileHeader with share_ref so
      // receivers download via Share. The caller has already shown the >34 MB
      // confirmation dialog (see large_file_share_dialog.dart) before reaching
      // here, so we always Share-route an oversized file (no silent reject).
      final fileSize = File(filePath).lengthSync();
      const maxDirectSize = 34 * 1024 * 1024;
      if (fileSize > maxDirectSize) {
        debugPrint('[HOLLOW] File >34 MB ($fileSize bytes) — creating hidden Share');
        _pendingShareSends[filePath] = _PendingShareSend(
          peerId: peerId,
          serverId: serverId,
          channelId: channelId,
          messageText: messageText,
          fileName: fileName,
          messageId: messageId,
          filePath: filePath,
          isVideo: isVideo,
          videoThumb: videoThumb,
        );
        await share_api.shareCreateFromFile(sourcePath: filePath);
        return;
      }

      if (isVideo && isVaultMode) {
        await _sendVaultVideo(
          serverId: serverId,
          channelId: channelId,
          filePath: filePath,
          fileName: fileName,
          ext: ext,
          messageId: messageId,
          messageText: messageText,
          preExtractedThumb: videoThumb,
        );
        return;
      }

      // Default path: P2P streaming for everything else (DMs, <6 servers,
      // images in any server, non-video files in 6+ servers).
      await network_api.sendFile(
        peerId: peerId,
        serverId: serverId,
        channelId: channelId,
        filePath: filePath,
        messageId: messageId,
        messageText: messageText,
        vthumb: null,
        // For videos, pass the source dimensions so the FileHeader carries
        // them to receivers. None for non-videos (Rust extracts image dims itself).
        overrideWidth: videoThumb?.sourceWidth,
        overrideHeight: videoThumb?.sourceHeight,
      );

      // For 6+ member servers (non-video): also trigger vault upload
      // (erasure coding + shard distribution). P2P streaming delivers to online
      // peers immediately; vault ensures offline peers can reconstruct later.
      // Skipped for videos because _sendVaultVideo handles the vault upload itself.
      if (isVaultMode) {
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

  /// Vault video send pipeline (Phase 6.75).
  ///
  /// Order matters:
  ///   1. Extract thumbnail (Dart-side, ffmpeg subprocess).
  ///   2. Vault-upload the video to obtain its content_id (synchronous return,
  ///      bounded by file-read + AES encrypt). The vault upload does NOT emit
  ///      a FileHeader broadcast — only the vault shard distribution starts.
  ///   3. Send the thumbnail via the existing image P2P path (sendFile), with
  ///      `vthumb` set to point at the just-obtained content_id. The recipient
  ///      sees one bubble: the thumbnail with a play button overlay.
  ///
  /// On thumbnail extraction failure (ffmpeg missing/crash/timeout), falls back
  /// to the dual-call legacy path so the video still uploads — the recipient
  /// sees a generic file card without the play button.
  Future<void> _sendVaultVideo({
    required String serverId,
    required String channelId,
    required String filePath,
    required String fileName,
    required String ext,
    required String messageId,
    required String messageText,
    VideoThumbnailResult? preExtractedThumb,
  }) async {
    // 1. Use the pre-extracted thumbnail from sendFile() if provided,
    //    otherwise extract one now (may return null on any failure).
    final thumb = preExtractedThumb ??
        await VideoThumbnailService.extractVideoThumbnail(videoPath: filePath);

    if (thumb == null) {
      // Fallback: thumbnail extraction failed → fall through to legacy
      // dual-call path so the video at least uploads successfully.
      debugPrint(
          '[HOLLOW] Video thumbnail extraction failed for $filePath — '
          'falling back to legacy file card path');
      await network_api.sendFile(
        peerId: null,
        serverId: serverId,
        channelId: channelId,
        filePath: filePath,
        messageId: messageId,
        messageText: messageText,
        vthumb: null,
        overrideWidth: null,
        overrideHeight: null,
      );
      try {
        final contentId = await crdt_api.vaultUploadFile(
          serverId: serverId,
          channelId: channelId,
          filePath: filePath,
          messageId: messageId,
        );
        final withCid = Map<String, FileTransferState>.from(state);
        final current = withCid[messageId];
        if (current != null) {
          withCid[messageId] = current.copyWith(contentId: contentId);
          state = withCid;
        }
      } catch (e) {
        debugPrint('[HOLLOW] Vault upload failed in fallback: $e');
      }
      return;
    }

    // 2. Vault-upload the video first to get its content_id.
    String contentId;
    try {
      contentId = await crdt_api.vaultUploadFile(
        serverId: serverId,
        channelId: channelId,
        filePath: filePath,
        messageId: messageId,
      );
    } catch (e) {
      debugPrint('[HOLLOW] Vault upload failed for video $filePath: $e');
      rethrow;
    }

    // 3. Write the thumbnail to a temp .webp file so we can hand its path
    //    to the existing sendFile FFI.
    final tempDir = await Directory.systemTemp.createTemp('hollow_vthumb_');
    final thumbPath = p.join(tempDir.path, '$messageId.webp');
    try {
      await File(thumbPath).writeAsBytes(thumb.webpBytes, flush: true);

      // 4. Build the VideoThumbRef linking field.
      final videoStat = await File(filePath).stat();
      final vthumb = network_api.VideoThumbRef(
        cid: contentId,
        ext: ext,
        name: fileName,
        size: BigInt.from(videoStat.size),
        durMs: thumb.durationMs,
      );

      // 5. Send the thumbnail via the image P2P path with the link.
      //    The recipient sees one bubble — the thumbnail .webp — that's
      //    rendered by VideoMessageBubble because vthumb is non-null.
      //    Pass the SOURCE VIDEO dimensions through override_width/height
      //    so the FileHeader carries the correct aspect ratio (the thumbnail
      //    .webp dimensions would be the scaled-down version, not what the
      //    bubble should size to).
      await network_api.sendFile(
        peerId: null,
        serverId: serverId,
        channelId: channelId,
        filePath: thumbPath,
        messageId: messageId,
        messageText: messageText,
        vthumb: vthumb,
        overrideWidth: thumb.sourceWidth,
        overrideHeight: thumb.sourceHeight,
      );

      // 6. Update local FileTransferState with both contentId and videoThumb so
      //    our own UI renders the play button immediately on the sender side.
      final withVThumb = Map<String, FileTransferState>.from(state);
      final current = withVThumb[messageId];
      if (current != null) {
        withVThumb[messageId] = current.copyWith(
          contentId: contentId,
          videoThumb: vthumb,
        );
        state = withVThumb;
      }
      debugPrint(
          '[HOLLOW] Vault video sent: cid=$contentId thumb=${thumb.webpBytes.length} bytes');
    } finally {
      // 7. Cleanup the temp dir + thumbnail file.
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Called when a ShareCreated event fires — if this share was triggered by a
  /// large file send, send the FileHeader with share_ref via the normal file path.
  void onShareCreatedForFile(String link, String fileName, String rootHash) {
    final matchKey = _pendingShareSends.keys.cast<String?>().firstWhere(
          (k) => k != null && k.endsWith(fileName),
          orElse: () => null,
        );
    if (matchKey == null) return;
    final ctx = _pendingShareSends.remove(matchKey)!;
    debugPrint('[HOLLOW] Share ready for large file — sending FileHeader with share_ref');

    final info = share_api.shareDecodeLink(link: link);
    info.then((decoded) async {
      final keyHex = _extractKeyHexFromLink(link);
      await network_api.sendFile(
        peerId: ctx.peerId,
        serverId: ctx.serverId,
        channelId: ctx.channelId,
        filePath: ctx.filePath,
        messageId: ctx.messageId,
        messageText: ctx.messageText,
        vthumb: null,
        overrideWidth: ctx.videoThumb?.sourceWidth,
        overrideHeight: ctx.videoThumb?.sourceHeight,
        shareRootHash: decoded.rootHash,
        shareKeyHex: keyHex,
      );
    }).catchError((e) {
      debugPrint('[HOLLOW] Failed to send share-backed file: $e');
    });
  }

  String _extractKeyHexFromLink(String link) {
    final payload = link.replaceFirst('hollow://share/', '');
    final bytes = base64Url.decode(base64Url.normalize(payload));
    if (bytes.length != 65) return '';
    final keyBytes = bytes.sublist(33, 65);
    return keyBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Handle FileHeaderReceived event.
  /// [isVaultMode] — if true (6+ member server), file data arrives via vault shards,
  /// not P2P streaming, so we don't mark it as "downloading".
  /// [videoThumb] — Phase 6.75 video preview link. When non-null, this file is a
  /// thumbnail for a vault-stored video; the UI will render a play button.
  void onFileHeaderReceived({
    required String fileId,
    required String fileName,
    required int sizeBytes,
    required bool isImage,
    int? width,
    int? height,
    bool isVaultMode = false,
    network_api.VideoThumbRef? videoThumb,
    String? shareRootHash,
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
      videoThumb: videoThumb,
      shareRootHash: shareRootHash,
    );
    state = updated;
  }

  /// Handle FileProgress event.
  void onFileProgress(String fileId, int chunksReceived, int totalChunks) {
    final updated = Map<String, FileTransferState>.from(state);
    final current = state[fileId];
    if (current == null) {
      // WebRTC race: progress arrived before FileHeader. Create a minimal entry
      // so the UI shows the progress bar.
      updated[fileId] = FileTransferState(
        fileId: fileId,
        fileName: '',
        sizeBytes: 0,
        totalChunks: totalChunks,
        chunksReceived: chunksReceived,
        isDownloading: true,
      );
    } else if (current.totalChunks == 0 && totalChunks > 0) {
      // For streamed transfers, chunks represent MB received / MB total.
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

  /// Update seeder count from ShareProgress events.
  void onSeedersUpdate(String fileId, int seeders) {
    final current = state[fileId];
    if (current == null) return;
    final updated = Map<String, FileTransferState>.from(state);
    updated[fileId] = current.copyWith(seeders: seeders);
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
