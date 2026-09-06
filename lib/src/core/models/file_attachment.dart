import '../../rust/api/network.dart' as network_api;

/// File attachment metadata for messages.
class FileAttachment {
  final String fileId;
  final String fileName;
  final String fileExt;
  final String mimeType;
  final int sizeBytes;
  final bool isImage;
  final int? width;
  final int? height;
  final int totalChunks;
  final int chunksReceived;
  final bool isComplete;
  final String? diskPath;
  /// Video thumbnail back-reference: non-null means this file is a thumbnail
  /// for the vault-stored video at [videoThumb.cid], so the UI draws a play button.
  final network_api.VideoThumbRef? videoThumb;
  final int? expiredAt;
  /// Persisted share swarm reference for share-backed (>34 MB) files —
  /// a manual download rejoins the share instead of a direct FileRequest
  /// (whose response our own size cap would reject). Issue #41.
  final String? shareRootHash;
  final String? shareKeyHex;
  /// Tiny base64 WebP placeholder thumbnail riding the FileHeader (issue #41
  /// carry-over) — rendered blurred under the Download button while the real
  /// image bytes are gated/undownloaded.
  final String? thumbB64;

  const FileAttachment({
    required this.fileId,
    required this.fileName,
    required this.fileExt,
    required this.mimeType,
    required this.sizeBytes,
    required this.isImage,
    this.width,
    this.height,
    required this.totalChunks,
    this.chunksReceived = 0,
    this.isComplete = false,
    this.diskPath,
    this.videoThumb,
    this.expiredAt,
    this.shareRootHash,
    this.shareKeyHex,
    this.thumbB64,
  });

  bool get isExpired => expiredAt != null;

  double get progress =>
      totalChunks > 0 ? chunksReceived / totalChunks : 0;

  String get formattedSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  FileAttachment copyWith({
    int? chunksReceived,
    bool? isComplete,
    String? diskPath,
    network_api.VideoThumbRef? videoThumb,
    int? expiredAt,
    String? shareRootHash,
    String? shareKeyHex,
    String? thumbB64,
  }) {
    return FileAttachment(
      fileId: fileId,
      fileName: fileName,
      fileExt: fileExt,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      isImage: isImage,
      width: width,
      height: height,
      totalChunks: totalChunks,
      chunksReceived: chunksReceived ?? this.chunksReceived,
      isComplete: isComplete ?? this.isComplete,
      diskPath: diskPath ?? this.diskPath,
      videoThumb: videoThumb ?? this.videoThumb,
      expiredAt: expiredAt ?? this.expiredAt,
      shareRootHash: shareRootHash ?? this.shareRootHash,
      shareKeyHex: shareKeyHex ?? this.shareKeyHex,
      thumbB64: thumbB64 ?? this.thumbB64,
    );
  }
}
