import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/event_provider.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/audio_message_bubble.dart';
import 'package:hollow/src/ui/chat/sticker_pack_card.dart';
import 'package:hollow/src/ui/chat/video_message_bubble.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// File extensions that trigger the video bubble (Phase 6.75 video preview).
const _videoExtensions = {'mp4', 'webm', 'mov', 'mkv', 'avi', 'm4v'};

/// File extensions that trigger the audio bubble (Phase 6.75 audio preview).
const _audioExtensions = {'mp3', 'ogg', 'wav', 'flac', 'm4a', 'aac', 'wma'};

/// Renders a file attachment inline in a message bubble.
///
/// - Images: inline preview (rounded, max 300x250).
/// - Other files: card with icon + name + size + progress.
class FileAttachmentWidget extends ConsumerWidget {
  final FileAttachment attachment;

  const FileAttachmentWidget({
    super.key,
    required this.attachment,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    // Watch live transfer progress.
    final transfer = ref.watch(
      fileTransferProvider.select((s) => s[attachment.fileId]),
    );

    // Use attachment's own state if it's already complete (e.g., sender's optimistic message).
    final isComplete = attachment.isComplete || (transfer?.isComplete ?? false);
    final diskPath = attachment.diskPath ?? transfer?.diskPath;
    final isDownloading = !isComplete && (transfer?.isDownloading ?? false);
    final vaultPhase = transfer?.vaultPhase;
    final progress = (transfer != null && transfer.progress > 0)
        ? transfer.progress
        : attachment.progress;
    // Compute bytes received from progress ratio × total size.
    // This works for both WSS (MB-based chunks) and WebRTC (64KB-based chunks).
    final totalBytes = (transfer != null && transfer.sizeBytes > 0)
        ? transfer.sizeBytes
        : attachment.sizeBytes;
    final bytesReceived = (progress * totalBytes).round();

    if (attachment.isExpired) {
      return _buildExpiredCard(hollow);
    }

    // Manual download entry (issue #41): the same flow as the hover-bar
    // Download button — share-backed files rejoin their share swarm, regular
    // files go out as a FileRequest to a holder. Self-contained: the file's
    // own metadata row carries the conversation context.
    void onDownload() => _startManualDownload(context, ref);

    // Share-backed file with no seeders and not yet downloaded.
    if (transfer?.shareRootHash != null &&
        !isComplete &&
        (transfer?.seeders ?? -1) == 0 &&
        (transfer?.chunksReceived ?? 0) == 0) {
      return _buildUnavailableCard(hollow, onDownload);
    }

    // Phase 6.75: Video preview takes priority over generic file rendering.
    // Two cases handled by VideoMessageBubble:
    //  (a) vault video — videoThumb is set, attachment is the .webp thumbnail
    //  (b) direct P2P video — DM or <6 server, file is on disk locally
    if (_isVideoAttachment()) {
      return VideoMessageBubble(attachment: attachment);
    }

    // Phase 6.75: Audio preview — inline playback card.
    if (_isAudioAttachment()) {
      return AudioMessageBubble(attachment: attachment);
    }

    // A shared sticker pack is an ordinary file on the wire — only its face
    // in the feed differs, so it gets an "add this pack" card instead of a
    // generic row. Nothing about the transfer changes (issue #36).
    if (isStickerPackFile(attachment.fileName)) {
      return StickerPackCard(
        // Gate on isComplete: a half-written pack would fail to parse and
        // show a bogus error rather than "Downloading…".
        diskPath: isComplete ? diskPath : null,
        fileName: attachment.fileName,
      );
    }

    if (attachment.isImage) {
      return _buildImagePreview(context, hollow, isComplete, diskPath, isDownloading, progress, bytesReceived, vaultPhase, onDownload);
    }
    return _buildFileCard(hollow, isComplete, isDownloading, progress, bytesReceived, vaultPhase, onDownload);
  }

  /// Start a manual download for this attachment — the pressable placeholder
  /// twin of the hover-bar Download button (issue #41). Routes by what the
  /// file actually is:
  ///  - share-backed (>34 MB): rejoin the share swarm via the PERSISTED share
  ///    ref (a direct FileRequest response would be rejected by our own size
  ///    cap and cannot resume a share);
  ///  - guest public channel: receipt-gated RequestPublicFile;
  ///  - everything else: FileRequest to the DM peer / file sender (Rust
  ///    resolves devices and reroutes to another holder when offline).
  Future<void> _startManualDownload(BuildContext context, WidgetRef ref) async {
    final transfer = ref.read(fileTransferProvider)[attachment.fileId];
    if (transfer?.isDownloading == true) {
      HollowToast.show(context, 'File is already downloading...',
          type: HollowToastType.info);
      return;
    }
    ref.read(fileTransferProvider.notifier).clearDeclined(attachment.fileId);
    try {
      final info =
          await storage_api.getFileMetadata(fileId: attachment.fileId);
      final shareRoot = attachment.shareRootHash ??
          info?.shareRootHash ??
          transfer?.shareRootHash;
      final shareKey = attachment.shareKeyHex ?? info?.shareKeyHex;
      final contextType = info?.contextType ?? '';
      final contextId = info?.contextId ?? '';
      final isChannel = contextType == 'channel' && contextId.contains(':');
      final serverId = isChannel ? contextId.split(':').first : '';

      if (shareRoot != null && shareKey != null) {
        final isVideo =
            _videoExtensions.contains(attachment.fileExt.toLowerCase());
        await ref.read(eventStreamProvider.notifier).startManualShareDownload(
              fileId: attachment.fileId,
              rootHash: shareRoot,
              keyHex: shareKey,
              serverId: serverId,
              sequential: isVideo,
            );
      } else if (isChannel &&
          !ref.read(serverListProvider).containsKey(serverId)) {
        // Not a member of this server — guest viewing a public channel.
        await crdt_api.requestPublicFile(
          serverId: serverId,
          fileId: attachment.fileId,
          peerHint: info?.senderId,
        );
      } else {
        final target = contextType == 'dm' ? contextId : info?.senderId;
        if (target == null || target.isEmpty) {
          throw Exception('no known holder for this file');
        }
        await network_api.requestFileFromPeer(
            fileId: attachment.fileId, peerId: target, chunks: []);
      }
      if (context.mounted) {
        HollowToast.show(context, 'Requesting file...',
            type: HollowToastType.info);
      }
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(context, 'Download failed: $e',
            type: HollowToastType.error);
      }
    }
  }

  /// True when this attachment should be rendered as a video bubble.
  /// Either it's a vault video (videoThumb is set) or its extension matches
  /// a video format (DM / <6 server direct P2P video).
  bool _isVideoAttachment() {
    if (attachment.videoThumb != null) return true;
    // Don't claim images even if their ext somehow matches.
    if (attachment.isImage) return false;
    return _videoExtensions.contains(attachment.fileExt.toLowerCase());
  }

  /// True when this attachment should be rendered as an audio bubble.
  bool _isAudioAttachment() {
    if (attachment.isImage) return false;
    return _audioExtensions.contains(attachment.fileExt.toLowerCase());
  }

  Widget _buildExpiredCard(HollowTheme hollow) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(HollowSpacing.sm),
        border: Border.all(color: hollow.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.md),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.clock, size: 24, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.md),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    attachment.fileName,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: HollowSpacing.xxs),
                  Text(
                    'File expired · ${attachment.formattedSize}',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUnavailableCard(HollowTheme hollow, VoidCallback onDownload) {
    return HollowPressable(
      onTap: onDownload,
      semanticLabel: 'Retry download of ${attachment.fileName}',
      borderRadius: BorderRadius.circular(HollowSpacing.sm),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: hollow.surface,
          borderRadius: BorderRadius.circular(HollowSpacing.sm),
          border: Border.all(color: hollow.border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.md),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.cloudOff, size: 24, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.md),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      attachment.fileName,
                      style: HollowTypography.body.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: HollowSpacing.xxs),
                    Text(
                      'No seeders · tap to retry · ${attachment.formattedSize}',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImagePreview(
      BuildContext context, HollowTheme hollow, bool isComplete, String? diskPath, bool isDownloading, double progress, int bytesReceived, String? vaultPhase, VoidCallback onDownload) {
    // Calculate display size maintaining aspect ratio.
    const maxWidth = 300.0;
    const maxHeight = 250.0;

    double displayWidth = maxWidth;
    double displayHeight = maxHeight;
    if (attachment.width != null && attachment.height != null && attachment.height! > 0) {
      final aspect = attachment.width! / attachment.height!;
      if (aspect > maxWidth / maxHeight) {
        displayWidth = maxWidth;
        displayHeight = maxWidth / aspect;
      } else {
        displayHeight = maxHeight;
        displayWidth = maxHeight * aspect;
      }
    }

    if (isComplete && diskPath != null && File(diskPath).existsSync()) {
      final isGif = attachment.fileExt.toLowerCase() == 'gif';

      // Show the actual image — tap to open fullscreen.
      return HollowFocusRing(
        enabled: true,
        onActivate: () => _showFullscreen(context, diskPath, isGif: isGif),
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        child: GestureDetector(
          onTap: () => _showFullscreen(context, diskPath, isGif: isGif),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: maxWidth,
                maxHeight: maxHeight,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                child: isGif
                    ? GifFileImage(
                        diskPath: diskPath,
                        fit: BoxFit.contain,
                        errorWidget: _buildPlaceholder(
                            hollow, displayWidth, displayHeight, false, 1.0, 0, null),
                      )
                    : Image.file(
                        File(diskPath),
                        fit: BoxFit.contain,
                        // Decode at bubble size, not the photo's full
                        // resolution — a 12 MP camera image otherwise decodes
                        // on first paint (a visible beat on phones). ResizeImage
                        // never upscales, so small images are untouched;
                        // fullscreen view decodes full-res separately.
                        cacheWidth: (maxWidth *
                                MediaQuery.devicePixelRatioOf(context))
                            .ceil(),
                        errorBuilder: (_, e, st) => _buildPlaceholder(
                            hollow, displayWidth, displayHeight, false, 1.0, 0, null),
                      ),
              ),
            ),
          ),
        ),
      );
    }

    // Show placeholder with progress or downloading indicator.
    return _buildPlaceholder(hollow, displayWidth, displayHeight, isDownloading, progress, bytesReceived, vaultPhase, onDownload: onDownload);
  }

  Widget _buildPlaceholder(
      HollowTheme hollow, double width, double height, bool isDownloading, double progress, int bytesReceived, String? vaultPhase, {VoidCallback? onDownload}) {
    // Idle (not downloading, no partial progress) + a download hook = the
    // pressable placeholder (issue #41): image dimensions box with a download
    // button in it instead of a dead rectangle.
    if (!isDownloading && !(progress > 0 && progress < 1) && onDownload != null) {
      return HollowPressable(
        onTap: onDownload,
        semanticLabel: 'Download ${attachment.fileName}',
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: hollow.surface,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            border: Border.all(color: hollow.border),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: hollow.elevated,
                  shape: BoxShape.circle,
                  border: Border.all(color: hollow.border),
                ),
                child: Icon(LucideIcons.download,
                    size: 20, color: hollow.textPrimary),
              ),
              const SizedBox(height: HollowSpacing.sm),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Media-type hint: image and video previews share this
                  // placeholder shape, so say which one this is.
                  Icon(
                    _isVideoAttachment() ? LucideIcons.video : LucideIcons.image,
                    size: 12,
                    color: hollow.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    attachment.formattedSize,
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        border: Border.all(color: hollow.border),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (isDownloading) ...[
            SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                value: progress > 0 ? progress.clamp(0.0, 1.0) : null,
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation(hollow.accent),
                backgroundColor: hollow.border,
              ),
            ),
            const SizedBox(height: HollowSpacing.sm),
            Text(
              vaultPhase != null
                  ? vaultPhase
                  : progress > 0
                      ? '${_formatSize(bytesReceived)} / ${attachment.formattedSize}'
                      : 'Downloading...',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 10,
              ),
            ),
          ] else if (progress > 0 && progress < 1) ...[
            SizedBox(
              width: 80,
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: hollow.elevated,
                valueColor: AlwaysStoppedAnimation(hollow.accent),
              ),
            ),
            const SizedBox(height: HollowSpacing.xs),
            Text(
              '${(progress * 100).toInt()}%',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 10,
              ),
            ),
          ] else ...[
            Icon(LucideIcons.image, size: 32, color: hollow.textSecondary),
            const SizedBox(height: HollowSpacing.sm),
            Text(
              attachment.formattedSize,
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 10,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    final b = bytes.toDouble();
    if (b < 1024) return '${b.toInt()} B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Widget _buildFileCard(HollowTheme hollow, bool isComplete, bool isDownloading, double progress, int bytesReceived, String? vaultPhase, VoidCallback onDownload) {
    final showDownload = !isComplete && !isDownloading && vaultPhase == null;
    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        border: Border.all(color: hollow.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(HollowSpacing.md),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _fileIcon(),
                  size: 28,
                  color: hollow.accent,
                ),
                const SizedBox(width: HollowSpacing.md),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        attachment.fileName,
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: HollowSpacing.xxs),
                      Text(
                        vaultPhase != null
                            ? '$vaultPhase  ${attachment.formattedSize}'
                            : isDownloading && progress > 0
                                ? '${_formatSize(bytesReceived)} / ${attachment.formattedSize}'
                                : isDownloading
                                    ? 'Downloading... ${attachment.formattedSize}'
                                    // The name column ellipsizes, so long
                                    // filenames hide their extension — repeat
                                    // it next to the size (issue #41 feedback).
                                    : attachment.fileExt.isEmpty
                                        ? attachment.formattedSize
                                        : '${attachment.formattedSize} · .${attachment.fileExt.toLowerCase()}',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                if (showDownload) ...[
                  const SizedBox(width: HollowSpacing.md),
                  HollowPressable(
                    onTap: onDownload,
                    semanticLabel: 'Download ${attachment.fileName}',
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    child: Icon(LucideIcons.download,
                        size: 18, color: hollow.textPrimary),
                  ),
                ],
              ],
            ),
          ),
          // Thin progress bar at the bottom of the card.
          if (isDownloading || (!isComplete && progress > 0))
            SizedBox(
              height: 3,
              child: LinearProgressIndicator(
                value: progress > 0 ? progress.clamp(0.0, 1.0) : null,
                backgroundColor: hollow.border,
                valueColor: AlwaysStoppedAnimation(hollow.accent),
              ),
            ),
        ],
      ),
    );
  }

  IconData _fileIcon() {
    final ext = attachment.fileExt.toLowerCase();
    return switch (ext) {
      'pdf' => LucideIcons.fileText,
      'zip' || 'rar' || '7z' || 'tar' || 'gz' => LucideIcons.fileArchive,
      'mp3' || 'ogg' || 'wav' || 'flac' || 'm4a' || 'aac' || 'wma' => LucideIcons.fileAudio,
      'mp4' || 'webm' || 'avi' || 'mkv' => LucideIcons.fileVideo,
      'txt' || 'md' || 'log' => LucideIcons.fileText,
      _ => LucideIcons.file,
    };
  }

  /// Open image in fullscreen overlay with blur backdrop.
  static void _showFullscreen(BuildContext context, String diskPath, {bool isGif = false}) {
    showHollowDialog(
      context: context,
      builder: (ctx) => _FullscreenImageView(diskPath: diskPath, isGif: isGif),
    );
  }
}

/// Fullscreen image view with blur backdrop and close button.
class _FullscreenImageView extends StatelessWidget {
  final String diskPath;
  final bool isGif;

  const _FullscreenImageView({required this.diskPath, this.isGif = false});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Center(
        child: Stack(
          children: [
            // Image
            Padding(
              padding: const EdgeInsets.all(HollowSpacing.xxl),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                child: isGif
                    ? GifFileImage(
                        diskPath: diskPath,
                        fit: BoxFit.contain,
                      )
                    : Image.file(
                        File(diskPath),
                        fit: BoxFit.contain,
                      ),
              ),
            ),

            // Close button (top-right)
            Positioned(
              top: HollowSpacing.lg,
              right: HollowSpacing.lg,
              child: HollowPressable(
                onTap: () => Navigator.of(context).pop(),
                semanticLabel: 'Close',
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                backgroundColor: hollow.elevated.withValues(alpha: 0.8),
                padding: const EdgeInsets.all(HollowSpacing.sm),
                child: Icon(
                  LucideIcons.x,
                  color: hollow.textPrimary,
                  size: 20,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
