import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/share.dart' as share_api;
import 'package:path/path.dart' as p;

import '../services/video_thumbnail_service.dart';

/// Why the bytes of a file are not here yet, as Rust's pending-ask walk sees it.
///
/// A card whose bytes are missing used to show one Download button that could
/// silently do nothing; Rust now says which of the four cases it is.
class FileAvailabilityState {
  /// A request is out to a holder and has not been answered yet.
  static const String requesting = 'requesting';

  /// Nobody who has the file is reachable; the ask is queued and self-heals.
  static const String waiting = 'waiting';

  /// A holder we asked answered "I do not have it".
  static const String gone = 'gone';

  /// The server's retention policy removed it.
  static const String expired = 'expired';

  /// One of [requesting], [waiting], [gone], [expired]. A string because it
  /// crosses the FFI as one; unknown values render as the old Download button.
  final String state;

  /// The MASTER identity the state is about (empty when none): the holder
  /// being asked, the DM counterparty who is offline, or the peer that
  /// answered "I do not have it".
  final String peerId;

  const FileAvailabilityState({required this.state, required this.peerId});

  @override
  bool operator ==(Object other) =>
      other is FileAvailabilityState &&
      other.state == state &&
      other.peerId == peerId;

  @override
  int get hashCode => Object.hash(state, peerId);

  @override
  String toString() => 'FileAvailabilityState($state, $peerId)';
}

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
  /// Video thumbnail back-reference: non-null means this file is a thumbnail
  /// for the vault-stored video at `videoThumb.cid`, so the UI draws a play button.
  final network_api.VideoThumbRef? videoThumb;
  /// Share root hash — set for share-backed files (>34 MB channel files).
  final String? shareRootHash;
  /// Number of active seeders — updated from ShareProgress events.
  final int? seeders;
  /// Declined by the auto-download gate (issue #41). While true, progress from
  /// ANY byte source is ignored: the sender pushes regardless and the bytes are
  /// discarded, so the bubble must keep its Download button, not a spinner.
  final bool declined;

  /// Why the bytes are not here yet. Null means nothing is known, which is the
  /// plain Download button. Cleared the moment real bytes move.
  final FileAvailabilityState? availability;

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
    this.declined = false,
    this.availability,
  });

  double get progress =>
      totalChunks > 0 ? chunksReceived / totalChunks : 0;

  /// [clearAvailability] is the only way back to "nothing known": the plain
  /// `??` merge below can never null a field out.
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
    bool? declined,
    FileAvailabilityState? availability,
    bool clearAvailability = false,
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
      declined: declined ?? this.declined,
      availability:
          clearAvailability ? null : (availability ?? this.availability),
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

  /// Initiate a file send. [memberCount] >= 6 also triggers a vault upload.
  /// [isVoice] marks a recorded voice message: the FileHeader carries a `voice`
  /// flag exempting it from the receiver's auto-download gate (the wire name is
  /// the recorder's temp basename, so Rust can't tell).
  Future<void> sendFile({
    String? peerId,
    String? serverId,
    String? channelId,
    required String filePath,
    required String messageId,
    String messageText = '',
    int memberCount = 0,
    bool isVoice = false,
  }) async {
    final parts = filePath.replaceAll('\\', '/').split('/');
    final fileName = parts.isNotEmpty ? parts.last : 'file';

    final updated = Map<String, FileTransferState>.from(state);
    updated[messageId] = FileTransferState(
      fileId: messageId,
      fileName: fileName,
      sizeBytes: 0,
      totalChunks: 0,
      isSending: true,
    );
    state = updated;

    final ext = p.extension(filePath).toLowerCase().replaceFirst('.', '');
    final isVideo = _videoExtensions.contains(ext);
    final isVaultMode =
        serverId != null && channelId != null && memberCount >= 6;

    // Pre-extract a thumbnail for ALL video files so the FileHeader can carry the
    // SOURCE pixel dimensions and receivers size the bubble without their own
    // probe. The vault path reuses the same result to avoid a second extraction.
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
      // Large files (>34 MB): host as a hidden Hollow Share for chunked P2P
      // delivery, then send the FileHeader with share_ref. The caller already
      // showed the >34 MB confirmation, so an oversized file is never rejected here.
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

      // Default path: P2P streaming for everything else.
      await network_api.sendFile(
        peerId: peerId,
        serverId: serverId,
        channelId: channelId,
        filePath: filePath,
        messageId: messageId,
        messageText: messageText,
        vthumb: null,
        // Videos pass source dimensions so the FileHeader carries them; ffmpeg's
        // stderr probe can yield 0x0, and Rust falls back to the poster frame's own.
        overrideWidth: videoThumb?.sourceWidth,
        overrideHeight: videoThumb?.sourceHeight,
        isVoice: isVoice,
        // Poster frame for the receiver's bubble: Rust re-encodes it small and rides
        // it on the FileHeader, so the video previews before any bytes download.
        posterBytes: videoThumb?.webpBytes,
      );

      // 6+ member servers (non-video) also trigger a vault upload: P2P streaming
      // delivers to online peers now, the vault lets offline peers reconstruct
      // later. Videos are skipped because _sendVaultVideo does its own.
      if (isVaultMode) {
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

  /// Vault video send pipeline.
  ///
  /// Order matters: extract the thumbnail, vault-upload the video for its
  /// content_id (which emits no FileHeader broadcast), then send the thumbnail
  /// through the image P2P path pointing at that id, so the recipient sees ONE
  /// bubble. A thumbnail failure falls back to the legacy dual-call path.
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
    // Reuse sendFile()'s thumbnail if provided, else extract one now.
    final thumb = preExtractedThumb ??
        await VideoThumbnailService.extractVideoThumbnail(videoPath: filePath);

    if (thumb == null) {
      // Extraction failed: fall through to the legacy dual-call path.
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

    // Write the thumbnail to a temp .webp so the existing sendFile FFI can take it.
    final tempDir = await Directory.systemTemp.createTemp('hollow_vthumb_');
    final thumbPath = p.join(tempDir.path, '$messageId.webp');
    try {
      await File(thumbPath).writeAsBytes(thumb.webpBytes, flush: true);

      final videoStat = await File(filePath).stat();
      final vthumb = network_api.VideoThumbRef(
        cid: contentId,
        ext: ext,
        name: fileName,
        size: BigInt.from(videoStat.size),
        durMs: thumb.durationMs,
      );

      // Send the thumbnail through the image P2P path with the link. Pass the
      // SOURCE VIDEO dimensions through override_width/height: the .webp's own
      // size is the scaled-down one, not what the bubble should size to.
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

      // So our own UI renders the play button immediately on the sender side.
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
        posterBytes: ctx.videoThumb?.webpBytes,
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

  /// Handle FileHeaderReceived. [isVaultMode] means data arrives via vault
  /// shards, not P2P streaming, so it is not marked "downloading". [videoThumb]
  /// links a thumbnail to its vault-stored video and draws a play button.
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
    // Don't overwrite an existing entry (a sync batch may have set isComplete).
    final existing = state[fileId];
    if (existing != null) {
      // A header for a file we were asking about IS the answer to that ask, so
      // the "Requesting..." caption goes even though the entry is left alone.
      if (existing.availability != null) {
        final cleared = Map<String, FileTransferState>.from(state);
        cleared[fileId] = existing.copyWith(clearAvailability: true);
        state = cleared;
      }
      return;
    }
    final updated = Map<String, FileTransferState>.from(state);
    updated[fileId] = FileTransferState(
      fileId: fileId,
      fileName: fileName,
      sizeBytes: sizeBytes,
      totalChunks: 0,
      isImage: isImage,
      width: width,
      height: height,
      // Don't set isDownloading on the header alone, or synced metadata shows
      // "Downloading..." forever; FileProgress or the button sets it.
      isDownloading: false,
      videoThumb: videoThumb,
      shareRootHash: shareRootHash,
    );
    state = updated;
  }

  /// Mark a file declined by the auto-download gate (issue #41): the bubble
  /// keeps its manual Download button while the unwanted push transits and is
  /// discarded. Keeps header metadata if an entry already exists.
  void markDeclined(String fileId) {
    final current = state[fileId];
    if (current?.isComplete == true) return;
    final updated = Map<String, FileTransferState>.from(state);
    updated[fileId] = FileTransferState(
      fileId: fileId,
      fileName: current?.fileName ?? '',
      sizeBytes: current?.sizeBytes ?? 0,
      totalChunks: 0,
      isImage: current?.isImage ?? false,
      width: current?.width,
      height: current?.height,
      videoThumb: current?.videoThumb,
      shareRootHash: current?.shareRootHash,
      declined: true,
    );
    state = updated;
  }

  /// Record why the bytes are not here yet. Rust's ask walk emits one of
  /// `requesting` / `waiting` / `gone` / `expired`, and the card says so instead
  /// of offering a button that would do nothing. Creates a minimal entry when
  /// none exists: a file that was never fetched has no transfer row.
  void onFileAvailability(String fileId, String availability, String peerId) {
    final current = state[fileId];
    if (current?.isComplete == true) return;
    final next =
        FileAvailabilityState(state: availability, peerId: peerId);
    final updated = Map<String, FileTransferState>.from(state);
    if (current == null) {
      updated[fileId] = FileTransferState(
        fileId: fileId,
        fileName: '',
        sizeBytes: 0,
        totalChunks: 0,
        availability: next,
      );
    } else {
      updated[fileId] = current.copyWith(
        availability: next,
        // We are the ones asking, so an old auto-download-gate pin must not survive
        // to swallow the answer (issue #41): Rust re-stamps the receipt on every
        // re-dispatch, and a stale `declined` would drop the bytes we asked for.
        declined: availability == FileAvailabilityState.requesting
            ? false
            : current.declined,
      );
    }
    state = updated;
  }

  /// Forget why the bytes were missing, so the card and the hover bar go back
  /// to their plain Download button at once. A no-op when there is no entry.
  void clearAvailability(String fileId) {
    final current = state[fileId];
    if (current == null || current.availability == null) return;
    final updated = Map<String, FileTransferState>.from(state);
    updated[fileId] = current.copyWith(clearAvailability: true);
    state = updated;
  }

  /// Stop waiting for a file: cancel the outstanding ask in Rust, then drop the
  /// local explanation so the card offers Download again at once.
  ///
  /// Rethrows, so the caller can toast a failure: a cancel that silently did
  /// nothing is the broken promise this feature exists to end.
  Future<void> stopWaitingForFile(String fileId) async {
    await network_api.cancelFileRequest(fileId: fileId);
    clearAvailability(fileId);
  }

  /// Clear the declined flag — called by every manual-download entry point so
  /// the real transfer's progress renders again.
  void clearDeclined(String fileId) {
    final current = state[fileId];
    if (current == null || !current.declined) return;
    final updated = Map<String, FileTransferState>.from(state);
    updated[fileId] = current.copyWith(declined: false);
    state = updated;
  }

  void onFileProgress(String fileId, int chunksReceived, int totalChunks) {
    final updated = Map<String, FileTransferState>.from(state);
    final current = state[fileId];
    // Declined by the gate: the arriving bytes are discarded, never surfaced (#41).
    if (current?.declined == true) return;
    if (current == null) {
      // WebRTC race: progress arrived before FileHeader, so make a minimal entry.
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
      // Bytes are moving: whatever the card was explaining is over.
      updated[fileId] = current.copyWith(
        chunksReceived: chunksReceived,
        clearAvailability: true,
      );
    }
    state = updated;
  }

  void onFileCompleted(String fileId, String diskPath) {
    final current = state[fileId];
    final updated = Map<String, FileTransferState>.from(state);
    if (current != null) {
      updated[fileId] = current.copyWith(
        isComplete: true,
        isDownloading: false,
        diskPath: diskPath,
        chunksReceived: current.totalChunks > 0 ? current.totalChunks : 1,
        declined: false,
        clearAvailability: true,
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
