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
  final hollow = HollowTheme.of(context);
  final result = await showHollowDialog<bool>(
    context: context,
    builder: (ctx) => HollowDialog(
      title: 'File is large (${_fmtMb(sizeBytes)})',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '"$fileName" is over 34 MB, so it can\'t be sent directly. It will '
            'be hosted as a Hollow Share link and transferred peer-to-peer.',
            style:
                HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.md),
          Text(
            'Heads up: Share transfers are direct (STUN-only, no relay fallback), '
            'and you need to stay online to host the file until the other side '
            'has finished downloading it.',
            style: HollowTypography.caption
                .copyWith(color: hollow.textSecondary),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          child: const Text('Cancel'),
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
  final result = await showHollowDialog<bool>(
    context: context,
    builder: (ctx) => HollowDialog(
      title: '${files.length} files are large',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'These are over 34 MB, so they can\'t be sent directly. They will '
            'be hosted as Hollow Share links and transferred peer-to-peer.',
            style: HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.sm),
          for (final f in files)
            Text(
              '${f.name} (${_fmtMb(f.sizeBytes)})',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HollowTypography.caption.copyWith(color: hollow.textPrimary),
            ),
          const SizedBox(height: HollowSpacing.md),
          Text(
            'Heads up: Share transfers are direct (STUN-only, no relay fallback), '
            'and you need to stay online to host the files until the other side '
            'has finished downloading them.',
            style:
                HollowTypography.caption.copyWith(color: hollow.textSecondary),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          child: const Text('Leave them out'),
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
