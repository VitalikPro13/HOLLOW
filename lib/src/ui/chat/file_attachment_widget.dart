import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:lucide_icons/lucide_icons.dart';

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

    if (attachment.isImage) {
      return _buildImagePreview(context, hollow, isComplete, diskPath, isDownloading, progress, bytesReceived, vaultPhase);
    }
    return _buildFileCard(hollow, isComplete, isDownloading, progress, bytesReceived, vaultPhase);
  }

  Widget _buildImagePreview(
      BuildContext context, HollowTheme hollow, bool isComplete, String? diskPath, bool isDownloading, double progress, int bytesReceived, String? vaultPhase) {
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
      // Show the actual image — tap to open fullscreen.
      return GestureDetector(
        onTap: () => _showFullscreen(context, diskPath),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: maxHeight,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              child: Image.file(
                File(diskPath),
                fit: BoxFit.contain,
                errorBuilder: (_, e, st) => _buildPlaceholder(
                    hollow, displayWidth, displayHeight, false, 1.0, 0, null),
              ),
            ),
          ),
        ),
      );
    }

    // Show placeholder with progress or downloading indicator.
    return _buildPlaceholder(hollow, displayWidth, displayHeight, isDownloading, progress, bytesReceived, vaultPhase);
  }

  Widget _buildPlaceholder(
      HollowTheme hollow, double width, double height, bool isDownloading, double progress, int bytesReceived, String? vaultPhase) {
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

  Widget _buildFileCard(HollowTheme hollow, bool isComplete, bool isDownloading, double progress, int bytesReceived, String? vaultPhase) {
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
                                    : attachment.formattedSize,
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
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
      'mp3' || 'ogg' || 'wav' || 'flac' => LucideIcons.fileAudio,
      'mp4' || 'webm' || 'avi' || 'mkv' => LucideIcons.fileVideo,
      'txt' || 'md' || 'log' => LucideIcons.fileText,
      _ => LucideIcons.file,
    };
  }

  /// Open image in fullscreen overlay with blur backdrop.
  static void _showFullscreen(BuildContext context, String diskPath) {
    showHollowDialog(
      context: context,
      builder: (ctx) => _FullscreenImageView(diskPath: diskPath),
    );
  }
}

/// Fullscreen image view with blur backdrop and close button.
class _FullscreenImageView extends StatelessWidget {
  final String diskPath;

  const _FullscreenImageView({required this.diskPath});

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
                child: Image.file(
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
