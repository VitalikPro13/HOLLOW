import 'package:flutter/material.dart';

import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';

/// The single direct-transfer size ceiling: past it there is no chunking or
/// resume, so the file rides a Hollow Share link instead.
const int kLargeFileThresholdBytes = 34 * 1024 * 1024;

String _fmtMb(int bytes) {
  final mb = bytes / (1024 * 1024);
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
  return '${mb.toStringAsFixed(0)} MB';
}

/// Asks whether to send an oversized file as a Hollow Share link, true if they
/// chose to. Every file-send site calls it, so the behaviour cannot drift.
Future<bool> confirmLargeFileShare(
  BuildContext context, {
  required String fileName,
  required int sizeBytes,
}) async {
  final limit = _fmtMb(kLargeFileThresholdBytes);
  final result = await showHollowDialog<bool>(
    context: context,
    builder: (ctx) => HollowDialog(
      title: 'File is large (${_fmtMb(sizeBytes)})',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HollowDialogText(
            '"$fileName" is over $limit, so Hollow sends it as a Share link '
            'that the other side downloads straight from you.',
          ),
          const SizedBox(height: HollowSpacing.md),
          const HollowDialogText(
            "Keep Hollow open until they finish. If your two devices can't "
            "connect directly, the download can't start.",
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          child: const Text("Don't send it"),
          onPressed: () => Navigator.of(ctx).pop(false),
        ),
        HollowButton.filled(
          child: const Text('Send as Share'),
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// The several-file twin of [confirmLargeFileShare]: ONE question for every
/// oversized file in a batch, true if they go as Hollow Shares.
Future<bool> confirmLargeFilesShare(
  BuildContext context, {
  required List<({String name, int sizeBytes})> files,
}) async {
  if (files.length == 1) {
    return confirmLargeFileShare(context,
        fileName: files.first.name, sizeBytes: files.first.sizeBytes);
  }
  final hollow = HollowTheme.of(context);
  final limit = _fmtMb(kLargeFileThresholdBytes);
  final result = await showHollowDialog<bool>(
    context: context,
    builder: (ctx) => HollowDialog(
      title: '${files.length} files are large',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HollowDialogText(
            'These are over $limit, so Hollow sends them as Share links that '
            'the other side downloads straight from you.',
          ),
          const SizedBox(height: HollowSpacing.sm),
          for (final f in files)
            Text(
              '${f.name} (${_fmtMb(f.sizeBytes)})',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HollowTypography.label.copyWith(color: hollow.textPrimary),
            ),
          const SizedBox(height: HollowSpacing.md),
          const HollowDialogText(
            "Keep Hollow open until they finish. If your two devices can't "
            "connect directly, the downloads can't start.",
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          child: const Text("Don't send them"),
          onPressed: () => Navigator.of(ctx).pop(false),
        ),
        HollowButton.filled(
          child: const Text('Send as Shares'),
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  return result ?? false;
}
