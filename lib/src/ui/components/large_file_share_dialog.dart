import 'package:flutter/material.dart';

import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';

/// The single direct-transfer size ceiling. Files larger than this can't stream
/// directly over P2P (no chunking/resume), so they're hosted as a Hollow Share
/// link instead — with the user's explicit confirmation.
const int kLargeFileThresholdBytes = 34 * 1024 * 1024;

String _fmtMb(int bytes) {
  final mb = bytes / (1024 * 1024);
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
  return '${mb.toStringAsFixed(0)} MB';
}

/// Ask the user whether to send an oversized (>34 MB) file as a Hollow Share
/// link. Returns true if they chose to send. Used by every file-send site (DM +
/// channel, desktop + mobile) so the behavior is identical everywhere.
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
