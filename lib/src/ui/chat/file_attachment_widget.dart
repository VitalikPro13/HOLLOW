import 'dart:convert' show base64Decode;
import 'dart:io';
import 'dart:typed_data' show Uint8List;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/event_provider.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
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
import 'package:hollow/src/ui/chat/file_card_status.dart';
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

    // Why the bytes are not here yet (tmp.txt item 1). ONE helper decides the
    // caption and the control for every surface below. Only the peer the
    // state is about is watched — a file bubble must not rebuild when an
    // unrelated profile changes — and a name asked for any other id falls
    // back to its short form, which is what an absent profile gives anyway.
    final statusPeer = transfer?.availability?.peerId ?? '';
    final statusProfile = statusPeer.isEmpty
        ? null
        : ref.watch(profileProvider.select((p) => p[statusPeer]));
    final status = fileCardStatus(
      attachment: attachment,
      transfer: transfer,
      nameOf: (master) => displayNameForPeer(statusProfile, master),
    );

    if (attachment.isExpired) {
      return _buildExpiredCard(hollow, status);
    }

    // Manual download entry (issue #41): the same flow as the hover-bar
    // Download button — share-backed files rejoin their share swarm, regular
    // files go out as a FileRequest to a holder. Self-contained: the file's
    // own metadata row carries the conversation context.
    void onDownload() => _startManualDownload(context, ref);

    // Share-backed file with no seeders and not yet downloaded.
    if (status.control == FileCardControl.retry) {
      return _buildUnavailableCard(hollow, status, onDownload);
    }

    // Phase 6.75: Video preview takes priority over generic file rendering.
    // Two cases handled by VideoMessageBubble:
    //  (a) vault video — videoThumb is set, attachment is the .webp thumbnail
    //  (b) direct P2P video — DM or <6 server, file is on disk locally
    // The bubble owns EVERY state — poster from the header thumb, download
    // button while the bytes aren't local, progress, then play — so the video
    // keeps one face instead of hopping between a placeholder and the bubble.
    if (_isVideoAttachment()) {
      return VideoMessageBubble(
          attachment: attachment, onDownload: onDownload, status: status);
    }

    // Phase 6.75: Audio preview — inline playback card. The bubble owns its
    // undownloaded state: the play button becomes a download button (issue
    // #41 carry-over).
    if (_isAudioAttachment()) {
      return AudioMessageBubble(
          attachment: attachment, onDownload: onDownload, status: status);
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
        // Without these the card said "Downloading…" under every pack that
        // was never fetched — old rows, and anything the auto-download gate
        // held back (issue #54).
        isDownloading: isDownloading,
        progress: progress,
        onDownload: onDownload,
        status: status,
      );
    }

    if (attachment.isImage) {
      return _buildImagePreview(context, hollow, isComplete, diskPath, isDownloading, progress, bytesReceived, vaultPhase, status, onDownload);
    }
    return _buildFileCard(hollow, isComplete, isDownloading, progress, bytesReceived, vaultPhase, status, onDownload);
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

      // A FileRequest answers itself on the card: it turns into "Requesting..."
      // and then says what came back. The other two branches have no such
      // state, so they keep their toast.
      var announce = true;

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
        announce = false;
      }
      if (announce && context.mounted) {
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

  Widget _buildExpiredCard(HollowTheme hollow, FileCardStatus status) {
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
                    status.caption ?? kFileCardExpiredCaption,
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

  Widget _buildUnavailableCard(
      HollowTheme hollow, FileCardStatus status, VoidCallback onDownload) {
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
                      status.caption ?? kFileCardWaitingCaption,
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

  /// Max preview box for images/videos in the chat feed.
  static const _previewMaxWidth = 300.0;
  static const _previewMaxHeight = 250.0;

  /// Display box for the preview/placeholder, aspect-corrected from the
  /// attachment's intrinsic dimensions (full box when unknown). Shared by the
  /// image preview and the undownloaded-video placeholder route.
  ({double w, double h}) _displayBoxSize() {
    double displayWidth = _previewMaxWidth;
    double displayHeight = _previewMaxHeight;
    if (attachment.width != null && attachment.height != null && attachment.height! > 0) {
      final aspect = attachment.width! / attachment.height!;
      if (aspect > _previewMaxWidth / _previewMaxHeight) {
        displayWidth = _previewMaxWidth;
        displayHeight = _previewMaxWidth / aspect;
      } else {
        displayHeight = _previewMaxHeight;
        displayWidth = _previewMaxHeight * aspect;
      }
    }
    return (w: displayWidth, h: displayHeight);
  }

  /// Decoded envelope-borne placeholder thumbnail (issue #41 carry-over) —
  /// a ~32 px WebP, so the per-build decode cost is negligible.
  Uint8List? _thumbBytes() {
    final b64 = attachment.thumbB64;
    if (b64 == null || b64.isEmpty) return null;
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  Widget _buildImagePreview(
      BuildContext context, HollowTheme hollow, bool isComplete, String? diskPath, bool isDownloading, double progress, int bytesReceived, String? vaultPhase, FileCardStatus status, VoidCallback onDownload) {
    const maxWidth = _previewMaxWidth;
    const maxHeight = _previewMaxHeight;
    final box = _displayBoxSize();
    final displayWidth = box.w;
    final displayHeight = box.h;

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
                            hollow, displayWidth, displayHeight, false, 1.0, 0, null, status),
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
                            hollow, displayWidth, displayHeight, false, 1.0, 0, null, status),
                      ),
              ),
            ),
          ),
        ),
      );
    }

    // Show placeholder with progress or downloading indicator.
    return _buildPlaceholder(hollow, displayWidth, displayHeight, isDownloading, progress, bytesReceived, vaultPhase, status, onDownload: onDownload);
  }

  Widget _buildPlaceholder(
      HollowTheme hollow, double width, double height, bool isDownloading, double progress, int bytesReceived, String? vaultPhase, FileCardStatus status, {VoidCallback? onDownload}) {
    // Placeholder box shell: when the header carried a tiny thumbnail (issue
    // #41 carry-over), it renders BLURRED under the content with a
    // theme-correct scrim so the download button / progress labels keep
    // contrast; otherwise the flat surface box as before.
    final thumbBytes = _thumbBytes();
    Widget shell(Widget child) => Container(
          width: width,
          height: height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: hollow.surface,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            border: Border.all(color: hollow.border),
          ),
          child: thumbBytes == null
              ? child
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    ImageFiltered(
                      imageFilter: ImageFilter.blur(
                          sigmaX: 10, sigmaY: 10, tileMode: TileMode.clamp),
                      child: Image.memory(
                        thumbBytes,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, e, st) => const SizedBox.shrink(),
                      ),
                    ),
                    ColoredBox(color: hollow.surface.withValues(alpha: 0.45)),
                    child,
                  ],
                ),
        );

    // Idle (not downloading, no partial progress) + a download hook = the
    // pressable placeholder (issue #41): image dimensions box with a download
    // button in it instead of a dead rectangle. When the card knows why the
    // bytes are missing it says so here too, and the circle stops taking taps
    // that would do nothing (tmp.txt item 1).
    if (!isDownloading && !(progress > 0 && progress < 1) && onDownload != null) {
      // Same circle, three faces: the button, its busy spinner, or the reason
      // there is nothing to press.
      final Widget circleContent = switch (status.control) {
        FileCardControl.busy => Padding(
            padding: const EdgeInsets.all(12),
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(hollow.textPrimary),
              backgroundColor: hollow.border,
            ),
          ),
        FileCardControl.none => Icon(LucideIcons.cloudOff,
            size: 20, color: hollow.textSecondary),
        _ => Icon(LucideIcons.download, size: 20, color: hollow.textPrimary),
      };
      final body = shell(
        Column(
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
              child: circleContent,
            ),
            const SizedBox(height: HollowSpacing.sm),
            if (status.caption != null)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
                child: Text(
                  status.caption!,
                  textAlign: TextAlign.center,
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 10,
                  ),
                ),
              )
            else
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
      );
      // A queued or dead ask has nothing to press: no tap target, and no
      // Download label for a screen reader to offer.
      if (status.control == FileCardControl.busy ||
          status.control == FileCardControl.none) {
        return body;
      }
      return HollowPressable(
        onTap: onDownload,
        semanticLabel: 'Download ${attachment.fileName}',
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        child: body,
      );
    }
    return shell(
      Column(
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

  Widget _buildFileCard(HollowTheme hollow, bool isComplete, bool isDownloading, double progress, int bytesReceived, String? vaultPhase, FileCardStatus status, VoidCallback onDownload) {
    final idle = !isComplete && !isDownloading && vaultPhase == null;
    final showDownload = idle && status.control == FileCardControl.download;
    // The button's own busy state (tmp.txt item 1): same footprint, a spinner,
    // no tap target, so a second press cannot queue a second ask.
    final showBusy = idle && status.control == FileCardControl.busy;
    // The caption is the card's answer for the tap, so it replaces the size
    // line rather than crowding in beside it.
    final showCaption = idle && status.caption != null;
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
                        showCaption
                            ? status.caption!
                            : vaultPhase != null
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
                ] else if (showBusy) ...[
                  const SizedBox(width: HollowSpacing.md),
                  Padding(
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(hollow.textPrimary),
                        backgroundColor: hollow.border,
                      ),
                    ),
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
