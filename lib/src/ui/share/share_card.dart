import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/core/services/reveal_in_folder.dart';
import 'package:hollow/src/rust/api/share.dart' as share_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_progress_bar.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';

/// Byte and speed formatting shared by every surface that shows a share.
abstract final class ShareCard {
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

/// The bottom-right corner of [context]'s box in overlay space, where a menu
/// with `alignEnd` hangs from a trailing button.
Offset _bottomEndOf(BuildContext context) {
  final size = (context.findRenderObject() as RenderBox?)?.size ?? Size.zero;
  return overlayAnchorOf(context,
      localOffset: Offset(size.width, size.height));
}

String _people(int n) => n == 1 ? '1 person' : '$n people';

/// One share in the Share place: a flush list row whose subtitle and actions
/// follow the transfer's state. Remove lives in the More menu, never at rest.
class ShareRow extends ConsumerWidget {
  final ShareItemState item;
  const ShareRow({super.key, required this.item});

  bool get _failed => item.state == 'failed';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final metaStyle = HollowTypography.bodySmall.copyWith(
      color: hollow.textSecondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    final Widget subtitle = switch (item.state) {
      'downloading' => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: HollowSpacing.xs),
            HollowProgressBar(
              value: item.chunksTotal > 0
                  ? item.chunksHave / item.chunksTotal
                  : 0,
              semanticLabel: 'Download progress',
            ),
            const SizedBox(height: HollowSpacing.xs),
            Text(_downloadLine(), style: metaStyle, maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      'failed' => Text(
          item.error == null
              ? "The transfer didn't finish"
              : friendlyError(item.error!,
                  fallback: 'This download stopped. Try again.'),
          style: metaStyle.copyWith(color: hollow.error),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      _ => Text(_seedingLine(), style: metaStyle, maxLines: 1,
          overflow: TextOverflow.ellipsis),
    };

    return ContextMenuTarget(
      semanticLabel: 'Actions for ${item.fileName}',
      onOpen: (anchor) => _openMenu(context, ref, anchor),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(LucideIcons.file, size: 20, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Flexible(
                        child: Text(
                          item.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HollowTypography.label.copyWith(
                            color: _failed ? hollow.error : hollow.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      Text(
                        ShareCard.formatSize(item.totalSize),
                        style: HollowTypography.bodySmall.copyWith(
                          color: hollow.textTertiary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  subtitle,
                ],
              ),
            ),
            const SizedBox(width: HollowSpacing.md),
            ..._actions(context, ref, hollow),
          ],
        ),
      ),
    );
  }

  String _downloadLine() {
    final have = item.chunksTotal > 0
        ? (item.totalSize * item.chunksHave / item.chunksTotal).round()
        : 0;
    final parts = [
      '${ShareCard.formatSize(have)} of ${ShareCard.formatSize(item.totalSize)}',
      if (item.bytesPerSec > 0) '${ShareCard.formatSpeed(item.bytesPerSec)}/s',
      if (item.seeders > 0)
        'from ${_people(item.seeders)}'
      else
        'looking for someone to download from',
    ];
    return parts.join(' · ');
  }

  String _seedingLine() {
    final base = !item.seeding
        ? 'Paused'
        : item.leechers > 0
            ? 'Seeding to ${_people(item.leechers)}'
            : 'Seeding';
    if (item.bytesUploaded <= 0) return base;
    return '$base · ${ShareCard.formatSize(item.bytesUploaded)} sent';
  }

  List<Widget> _actions(
      BuildContext context, WidgetRef ref, HollowTheme hollow) {
    final more = Builder(
      builder: (buttonContext) => HollowIconButton(
        icon: LucideIcons.moreHorizontal,
        label: 'More actions for ${item.fileName}',
        onPressed: () => _openMenu(
          context,
          ref,
          _bottomEndOf(buttonContext),
          alignEnd: true,
        ),
      ),
    );

    switch (item.state) {
      case 'downloading':
        return [
          HollowButton.ghost(
            compact: true,
            onPressed: () => _cancel(context),
            child: const Text('Cancel'),
          ),
        ];
      case 'failed':
        return [
          if (item.shareLink.isNotEmpty) ...[
            HollowButton.outline(
              compact: true,
              onPressed: () => _retry(context),
              child: const Text('Retry'),
            ),
            const SizedBox(width: HollowSpacing.xs),
          ],
          more,
        ];
      default:
        return [
          HollowTooltip(
            message: item.seeding
                ? 'Others can download this file from you'
                : 'Nobody can download this file from you right now',
            child: HollowToggle(
              value: item.seeding,
              semanticLabel: 'Seeding',
              onChanged: (v) => _setSeeding(context, v),
            ),
          ),
          const SizedBox(width: HollowSpacing.md),
          HollowButton.outline(
            compact: true,
            icon: const Icon(LucideIcons.link, size: 14),
            onPressed: () => _copyLink(context),
            child: const Text('Copy link'),
          ),
          const SizedBox(width: HollowSpacing.xs),
          more,
        ];
    }
  }

  void _openMenu(BuildContext context, WidgetRef ref, Offset anchor,
      {bool alignEnd = false}) {
    final hasFolder = item.diskPath != null && item.diskPath!.isNotEmpty;
    showHollowMenu(
      context: context,
      anchor: anchor,
      alignEnd: alignEnd,
      builder: (_, _) => [
        // The row's own Copy link button sits beside More; a right click has none.
        if (!alignEnd && item.state == 'completed' && item.shareLink.isNotEmpty)
          HollowMenuItem(
            icon: LucideIcons.link,
            label: 'Copy link',
            onTap: () => _copyLink(context),
          ),
        if (hasFolder)
          HollowMenuItem(
            icon: LucideIcons.folderOpen,
            label: 'Show in folder',
            onTap: () => _reveal(context),
          ),
        if (item.state == 'downloading')
          HollowMenuItem(
            icon: LucideIcons.x,
            label: 'Cancel download',
            onTap: () => _cancel(context),
          ),
        if (item.state != 'downloading') ...[
          if (hasFolder || item.state == 'completed') const HollowMenuDivider(),
          HollowMenuItem(
            icon: LucideIcons.trash2,
            label: 'Remove',
            isDanger: true,
            onTap: () => _confirmRemove(context, ref),
          ),
        ],
      ],
    );
  }

  void _copyLink(BuildContext context) {
    Clipboard.setData(ClipboardData(text: item.shareLink));
    HollowToast.show(context, 'Link copied', type: HollowToastType.success);
  }

  Future<void> _reveal(BuildContext context) async {
    try {
      await revealInFolder(item.diskPath!);
    } catch (_) {
      if (context.mounted) {
        HollowToast.show(context, "Couldn't open the folder",
            type: HollowToastType.error);
      }
    }
  }

  Future<void> _setSeeding(BuildContext context, bool seeding) async {
    try {
      await share_api.shareSetSeeding(
          rootHash: item.rootHash, seeding: seeding);
    } catch (_) {
      if (context.mounted) {
        HollowToast.show(
            context,
            seeding ? "Couldn't resume seeding" : "Couldn't pause seeding",
            type: HollowToastType.error);
      }
    }
  }

  Future<void> _cancel(BuildContext context) async {
    try {
      await share_api.shareCancel(rootHash: item.rootHash);
    } catch (_) {
      if (context.mounted) {
        HollowToast.show(context, "Couldn't cancel the download",
            type: HollowToastType.error);
      }
    }
  }

  Future<void> _retry(BuildContext context) async {
    try {
      await share_api.shareOpenLink(link: item.shareLink);
    } catch (_) {
      if (context.mounted) {
        HollowToast.show(context, "Couldn't retry the download",
            type: HollowToastType.error);
      }
    }
  }

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final shares = ref.read(shareTabProvider.notifier);
    final removed = await showHollowConfirm(
      context: context,
      title: 'Remove ${item.fileName}?',
      message: 'The file stays on your device.',
      confirmLabel: 'Remove',
      destructive: true,
      onConfirm: () =>
          share_api.shareRemove(rootHash: item.rootHash, deleteFile: false),
    );
    if (removed) shares.removeShare(item.rootHash);
  }
}
