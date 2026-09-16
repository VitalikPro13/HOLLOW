import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/ui/media/media_playback_session.dart';

/// File extensions the viewer plays rather than paints. Mirrored in Rust by
/// `MEDIA_VIDEO_EXTS`, which decides what `list_media_for_context` returns.
const Set<String> kMediaVideoExtensions = {
  'mp4',
  'webm',
  'mov',
  'mkv',
  'avi',
  'm4v',
};

/// How one item is drawn: a still, an animation, or a player.
enum MediaKind { image, gif, video }

/// The conversation a viewer may walk. Absent for an archive, where there is
/// nothing to page through.
@immutable
class MediaContext {
  /// `dm` or `channel`, as the files table stores it.
  final String contextType;

  /// The peer master id for a DM, `{serverId}:{channelId}` for a channel.
  final String contextId;

  const MediaContext({required this.contextType, required this.contextId});

  @override
  bool operator ==(Object other) =>
      other is MediaContext &&
      other.contextType == contextType &&
      other.contextId == contextId;

  @override
  int get hashCode => Object.hash(contextType, contextId);
}

/// One page of the media viewer.
@immutable
class MediaItem {
  final FileAttachment attachment;
  final String? messageId;

  /// The sender as the message carried it; display collapses it to a master.
  final String? senderId;
  final int? timestampMs;

  /// Content hash, shown in the info panel. Only the walked rows carry one.
  final String? contentId;
  final bool isMine;

  /// A live player handed over by the bubble that opened the viewer, so
  /// position and play state survive the push. Null for a walked item, which
  /// opens its own.
  final MediaPlaybackSession? session;

  const MediaItem({
    required this.attachment,
    this.messageId,
    this.senderId,
    this.timestampMs,
    this.contentId,
    this.isMine = false,
    this.session,
  });

  String get fileId => attachment.fileId;
  String? get diskPath => attachment.diskPath;

  MediaKind get kind {
    final ext = attachment.fileExt.toLowerCase();
    // A vault video's own row is its poster, so the back-reference decides
    // before the extension does.
    if (attachment.videoThumb != null) return MediaKind.video;
    if (ext == 'gif') return MediaKind.gif;
    if (!attachment.isImage && kMediaVideoExtensions.contains(ext)) {
      return MediaKind.video;
    }
    return MediaKind.image;
  }

  bool get isVideo => kind == MediaKind.video;

  /// Pixel size, when the sender told us. Unknown dimensions keep the mobile
  /// surface in portrait and leave "actual size" to the decoded image.
  Size? get pixelSize {
    final w = attachment.width;
    final h = attachment.height;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return Size(w.toDouble(), h.toDouble());
  }

  /// The same item pointing at a path the caller resolved, which a stored row
  /// may not carry yet.
  MediaItem withDiskPath(String path) => attachment.diskPath == path
      ? this
      : _copy(attachment: attachment.copyWith(diskPath: path));

  MediaItem withContentId(String? id) =>
      id == null || id == contentId ? this : _copy(contentId: id);

  MediaItem _copy({FileAttachment? attachment, String? contentId}) =>
      MediaItem(
        attachment: attachment ?? this.attachment,
        messageId: messageId,
        senderId: senderId,
        timestampMs: timestampMs,
        contentId: contentId ?? this.contentId,
        isMine: isMine,
        session: session,
      );
}

/// Loads a conversation's media, newest first. Replaced in widget tests, which
/// have no FFI binding.
typedef MediaPageLoader = Future<List<MediaItem>> Function({
  required String contextType,
  required String contextId,
  int? beforeMs,
  int? afterMs,
  required int limit,
});

/// The conversation's images and videos, newest first.
///
/// [beforeMs] and [afterMs] are exclusive bounds, so the viewer pages in both
/// directions from the item it was opened at.
class MediaLibrary {
  const MediaLibrary._();

  @visibleForTesting
  static MediaPageLoader? debugLoader;

  static Future<List<MediaItem>> page({
    required String contextType,
    required String contextId,
    int? beforeMs,
    int? afterMs,
    int limit = 40,
  }) {
    final override = debugLoader;
    if (override != null) {
      return override(
        contextType: contextType,
        contextId: contextId,
        beforeMs: beforeMs,
        afterMs: afterMs,
        limit: limit,
      );
    }
    return _load(
      contextType: contextType,
      contextId: contextId,
      beforeMs: beforeMs,
      afterMs: afterMs,
      limit: limit,
    );
  }

  static Future<List<MediaItem>> _load({
    required String contextType,
    required String contextId,
    int? beforeMs,
    int? afterMs,
    required int limit,
  }) async {
    final rows = await storage_api.listMediaForContext(
      contextType: contextType,
      contextId: contextId,
      beforeTs: beforeMs,
      afterTs: afterMs,
      limit: limit,
    );
    return [
      for (final row in rows)
        fromStoredFile(row.file,
            tsMs: row.ts.toInt(), contentId: row.contentId),
    ];
  }

  /// One stored row as a viewer page. [tsMs] is the owning message's time.
  static MediaItem fromStoredFile(
    storage_api.StoredFileInfo file, {
    required int tsMs,
    String? contentId,
  }) {
    return MediaItem(
      attachment: FileAttachment(
        fileId: file.fileId,
        fileName: file.fileName,
        fileExt: file.fileExt,
        mimeType: file.mimeType,
        sizeBytes: file.sizeBytes.toInt(),
        isImage: file.isImage,
        width: file.width,
        height: file.height,
        totalChunks: file.chunkCount,
        chunksReceived: file.chunksReceived,
        isComplete: true,
        diskPath: file.diskPath,
        videoThumb: file.videoThumb,
        shareRootHash: file.shareRootHash,
        shareKeyHex: file.shareKeyHex,
        thumbB64: file.thumbB64,
      ),
      messageId: file.messageId,
      senderId: file.senderId,
      timestampMs: tsMs,
      contentId: contentId,
      isMine: file.isMine,
    );
  }
}
