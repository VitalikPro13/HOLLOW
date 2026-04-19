import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/rust/api/share.dart' as share_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_card.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

class ShareCard extends ConsumerWidget {
  final ShareItemState item;
  const ShareCard({super.key, required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    return HollowCard(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(hollow),
          const SizedBox(height: HollowSpacing.sm),
          if (item.state == 'downloading') _buildDownloadBody(context, ref, hollow),
          if (item.state == 'completed') _buildSeedingBody(context, ref, hollow),
          if (item.state == 'failed') _buildFailedBody(context, ref, hollow),
        ],
      ),
    );
  }

  Widget _buildHeader(HollowTheme hollow) {
    return Row(
      children: [
        Icon(LucideIcons.file, size: 16, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Text(
            item.fileName,
            style: HollowTypography.body.copyWith(
              color: item.state == 'failed' ? hollow.error : hollow.textPrimary,
              fontWeight: FontWeight.w500,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        Text(
          formatSize(item.totalSize),
          style: HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
        ),
      ],
    );
  }

  Widget _buildDownloadBody(BuildContext context, WidgetRef ref, HollowTheme hollow) {
    final progress = item.chunksTotal > 0
        ? item.chunksHave / item.chunksTotal
        : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            backgroundColor: hollow.border,
            valueColor: AlwaysStoppedAnimation<Color>(hollow.accent),
          ),
        ),
        const SizedBox(height: HollowSpacing.xs),
        Row(
          children: [
            Text(
              '${item.chunksHave}/${item.chunksTotal} chunks  ·  ${item.seeders} ${item.seeders == 1 ? 'seed' : 'seeds'}  ·  ${item.leechers} ${item.leechers == 1 ? 'peer' : 'peers'}  ·  ',
              style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
            ),
            Text(
              '${formatSpeed(item.bytesPerSec)}/s',
              style: HollowTypography.caption.copyWith(color: hollow.accent),
            ),
            const Spacer(),
            HollowButton.ghost(
              compact: true,
              onPressed: () => share_api.shareCancel(rootHash: item.rootHash),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSeedingBody(BuildContext context, WidgetRef ref, HollowTheme hollow) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(LucideIcons.arrowUp, size: 12, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.xs),
            Text(
              '${formatSize(item.bytesUploaded)} uploaded  ·  ${item.seeders} ${item.seeders == 1 ? 'seed' : 'seeds'}  ·  ${item.leechers} ${item.leechers == 1 ? 'peer' : 'peers'}',
              style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.sm),
        Row(
          children: [
            HollowButton.ghost(
              compact: true,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: item.shareLink));
                HollowToast.show(context, 'Link copied', type: HollowToastType.success);
              },
              icon: const Icon(LucideIcons.copy, size: 14),
              child: const Text('Copy Link'),
            ),
            const SizedBox(width: HollowSpacing.sm),
            if (item.diskPath != null && item.diskPath!.isNotEmpty)
              HollowButton.ghost(
                compact: true,
                onPressed: () {
                  final dir = File(item.diskPath!).parent.path;
                  Process.run('explorer.exe', [dir]);
                },
                icon: const Icon(LucideIcons.folderOpen, size: 14),
                child: const Text('Show'),
              ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.danger(
              compact: true,
              onPressed: () => _confirmRemove(context, ref),
              child: const Text('Remove'),
            ),
            const Spacer(),
            Text(
              'Seeding',
              style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowToggle(
              value: item.seeding,
              onChanged: (v) => share_api.shareSetSeeding(
                rootHash: item.rootHash, seeding: v,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFailedBody(BuildContext context, WidgetRef ref, HollowTheme hollow) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.error ?? 'Unknown error',
          style: HollowTypography.caption.copyWith(color: hollow.error),
        ),
        const SizedBox(height: HollowSpacing.sm),
        Row(
          children: [
            if (item.shareLink.isNotEmpty)
              HollowButton.ghost(
                compact: true,
                onPressed: () => share_api.shareOpenLink(link: item.shareLink),
                child: const Text('Retry'),
              ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.danger(
              compact: true,
              onPressed: () => _confirmRemove(context, ref),
              child: const Text('Remove'),
            ),
          ],
        ),
      ],
    );
  }

  void _confirmRemove(BuildContext context, WidgetRef ref) {
    showHollowDialog(
      context: context,
      builder: (ctx) => HollowDialog(
        title: 'Remove Share',
        content: Text('Remove "${item.fileName}" from your shares?'),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          HollowButton.danger(
            onPressed: () {
              share_api.shareRemove(rootHash: item.rootHash, deleteFile: false);
              ref.read(shareTabProvider.notifier).removeShare(item.rootHash);
              Navigator.pop(ctx);
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String formatSpeed(int bytesPerSec) {
    if (bytesPerSec < 1024) return '$bytesPerSec B';
    if (bytesPerSec < 1024 * 1024) return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB';
    if (bytesPerSec < 1024 * 1024 * 1024) return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytesPerSec / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
