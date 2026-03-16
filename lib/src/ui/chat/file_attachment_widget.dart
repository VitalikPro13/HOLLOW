import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/models/file_attachment.dart';
import 'package:haven/src/core/providers/file_transfer_provider.dart';
import 'package:haven/src/ui/components/haven_dialog.dart';
import 'package:haven/src/ui/components/haven_pressable.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
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
    final haven = HavenTheme.of(context);

    // Watch live transfer progress.
    final transfer = ref.watch(
      fileTransferProvider.select((s) => s[attachment.fileId]),
    );

    // Use attachment's own state if it's already complete (e.g., sender's optimistic message).
    // Only override from transfer provider if it provides better info.
    final isComplete = attachment.isComplete || (transfer?.isComplete ?? false);
    final diskPath = attachment.diskPath ?? transfer?.diskPath;
    final progress = (transfer != null && transfer.progress > 0)
        ? transfer.progress
        : attachment.progress;

    if (attachment.isImage) {
      return _buildImagePreview(context, haven, isComplete, diskPath, progress);
    }
    return _buildFileCard(haven, isComplete, progress);
  }

  Widget _buildImagePreview(
      BuildContext context, HavenTheme haven, bool isComplete, String? diskPath, double progress) {
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
              borderRadius: BorderRadius.circular(haven.radiusSm),
              child: Image.file(
                File(diskPath),
                fit: BoxFit.contain,
                errorBuilder: (_, e, st) => _buildPlaceholder(
                    haven, displayWidth, displayHeight, 1.0),
              ),
            ),
          ),
        ),
      );
    }

    // Show placeholder with progress.
    return _buildPlaceholder(haven, displayWidth, displayHeight, progress);
  }

  Widget _buildPlaceholder(
      HavenTheme haven, double width, double height, double progress) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: haven.surface,
        borderRadius: BorderRadius.circular(haven.radiusSm),
        border: Border.all(color: haven.border),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.image, size: 32, color: haven.textSecondary),
          const SizedBox(height: HavenSpacing.sm),
          if (progress > 0 && progress < 1) ...[
            SizedBox(
              width: 80,
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: haven.elevated,
                valueColor: AlwaysStoppedAnimation(haven.accent),
              ),
            ),
            const SizedBox(height: HavenSpacing.xs),
            Text(
              '${(progress * 100).toInt()}%',
              style: HavenTypography.caption.copyWith(
                color: haven.textSecondary,
                fontSize: 10,
              ),
            ),
          ] else
            Text(
              attachment.formattedSize,
              style: HavenTypography.caption.copyWith(
                color: haven.textSecondary,
                fontSize: 10,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFileCard(HavenTheme haven, bool isComplete, double progress) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.all(HavenSpacing.md),
      decoration: BoxDecoration(
        color: haven.surface,
        borderRadius: BorderRadius.circular(haven.radiusSm),
        border: Border.all(color: haven.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _fileIcon(),
            size: 28,
            color: haven.accent,
          ),
          const SizedBox(width: HavenSpacing.md),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  attachment.fileName,
                  style: HavenTypography.body.copyWith(
                    color: haven.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: HavenSpacing.xxs),
                if (!isComplete && progress > 0) ...[
                  SizedBox(
                    height: 4,
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: haven.elevated,
                      valueColor: AlwaysStoppedAnimation(haven.accent),
                    ),
                  ),
                  const SizedBox(height: HavenSpacing.xxs),
                ],
                Text(
                  attachment.formattedSize,
                  style: HavenTypography.caption.copyWith(
                    color: haven.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
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
    showHavenDialog(
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
    final haven = HavenTheme.of(context);

    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Center(
        child: Stack(
          children: [
            // Image
            Padding(
              padding: const EdgeInsets.all(HavenSpacing.xxl),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(haven.radiusMd),
                child: Image.file(
                  File(diskPath),
                  fit: BoxFit.contain,
                ),
              ),
            ),

            // Close button (top-right)
            Positioned(
              top: HavenSpacing.lg,
              right: HavenSpacing.lg,
              child: HavenPressable(
                onTap: () => Navigator.of(context).pop(),
                borderRadius: BorderRadius.circular(haven.radiusMd),
                backgroundColor: haven.elevated.withValues(alpha: 0.8),
                padding: const EdgeInsets.all(HavenSpacing.sm),
                child: Icon(
                  LucideIcons.x,
                  color: haven.textPrimary,
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
