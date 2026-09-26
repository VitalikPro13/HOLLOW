import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/download_manager_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/core/services/reveal_in_folder.dart';
import 'package:hollow/src/theme/hollow_colors.dart';
import 'package:hollow/src/theme/hollow_shadows.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/overlay_hosts.dart';
import 'package:hollow/src/ui/share/share_card.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';

/// Shows a download manager popup anchored near the tap position.
void showDownloadManagerPopup({
  required BuildContext context,
  required Offset anchor,
  bool anchorBottom = false,
}) {
  final overlay = Overlay.of(context);
  late final OverlayEntry entry;
  var removed = false;
  void close() {
    if (removed) return;
    removed = true;
    OverlayHosts.unregister(entry);
    entry.remove();
    entry.dispose();
  }

  entry = OverlayEntry(
    builder: (context) => _DownloadManagerOverlay(
      anchor: anchor,
      anchorBottom: anchorBottom,
      onDismiss: close,
    ),
  );

  overlay.insert(entry);
  OverlayHosts.register(entry, close);
}

class _DownloadManagerOverlay extends ConsumerStatefulWidget {
  final Offset anchor;
  final bool anchorBottom;
  final VoidCallback onDismiss;

  const _DownloadManagerOverlay({
    required this.anchor,
    this.anchorBottom = false,
    required this.onDismiss,
  });

  @override
  ConsumerState<_DownloadManagerOverlay> createState() =>
      _DownloadManagerOverlayState();
}

class _DownloadManagerOverlayState
    extends ConsumerState<_DownloadManagerOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnim;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.fast,
    );
    final curve = CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.enter,
      reverseCurve: HollowCurves.exit,
    );
    _scaleAnim = Tween<double>(begin: HollowMotion.popoverScale, end: 1.0)
        .animate(curve);
    _fadeAnim = curve;
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    if (_controller.status == AnimationStatus.reverse) return;
    _controller.reverseDuration = HollowDurations.exit;
    _controller.reverse().then((_) => widget.onDismiss());
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final entries = ref.watch(downloadManagerEntriesProvider);
    final allShares = ref.watch(shareTabProvider);
    final shareItems = downloadingShares(allShares)
        .where((s) => s.contextType == null)
        .toList();

    const cardWidth = 340.0;
    const maxHeight = 420.0;

    final screenSize = MediaQuery.of(context).size;
    double left = widget.anchor.dx;

    if (left < 8) left = 8;
    if (left + cardWidth > screenSize.width - 8) {
      left = screenSize.width - cardWidth - 8;
    }

    double? top;
    double? bottom;
    if (widget.anchorBottom) {
      bottom = screenSize.height - widget.anchor.dy;
      if (bottom < 8) bottom = 8;
    } else {
      top = widget.anchor.dy;
      if (top < 8) top = 8;
    }

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: _dismiss,
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          ),
        ),

        Positioned(
          left: left,
          top: top,
          bottom: bottom,
          child: FadeTransition(
            opacity: _fadeAnim,
            child: ScaleTransition(
              scale: _scaleAnim,
              alignment: Alignment.bottomCenter,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: cardWidth,
                  constraints: const BoxConstraints(maxHeight: maxHeight),
                  decoration: BoxDecoration(
                    color: hollow.overlay,
                    borderRadius: BorderRadius.circular(hollow.radiusLg),
                    border: Border.all(
                      color: hollow.accent.withValues(alpha: 0.15),
                    ),
                    boxShadow: HollowShadows.float,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          HollowSpacing.md,
                          HollowSpacing.sm + 2,
                          HollowSpacing.sm,
                          HollowSpacing.xs,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              LucideIcons.download,
                              size: 14,
                              color: hollow.textSecondary,
                            ),
                            const SizedBox(width: HollowSpacing.xs),
                            Text(
                              'Downloads',
                              style: HollowTypography.label.copyWith(
                                color: hollow.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            if (entries.isNotEmpty || shareItems.isNotEmpty)
                              HollowPressable(
                                onTap: () {
                                  ref.read(downloadManagerStateProvider.notifier).clearAll();
                                },
                                borderRadius:
                                    BorderRadius.circular(hollow.radiusMd),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: HollowSpacing.sm,
                                  vertical: HollowSpacing.xxs,
                                ),
                                child: Text(
                                  'Clear',
                                  style: HollowTypography.caption.copyWith(
                                    color: hollow.textSecondary,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),

                      Container(height: 1, color: hollow.border),

                      if (entries.isEmpty && shareItems.isEmpty)
                        const HollowEmptyState(
                          title: 'No downloads yet',
                          description:
                              'Downloaded files and shard activity show up here.',
                        )
                      else
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(
                              vertical: HollowSpacing.xs,
                            ),
                            itemCount: shareItems.length + entries.length,
                            separatorBuilder: (_, _) => Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: HollowSpacing.md,
                              ),
                              child: Container(
                                height: 1,
                                color: hollow.border.withValues(alpha: 0.3),
                              ),
                            ),
                            itemBuilder: (context, index) {
                              if (index < shareItems.length) {
                                return _ShareDownloadTile(item: shareItems[index]);
                              }
                              final entry = entries[index - shareItems.length];
                              if (entry.type == DownloadEntryType.rebalance) {
                                return _RebalanceTile(entry: entry);
                              }
                              return _SavedFileTile(entry: entry);
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SavedFileTile extends ConsumerWidget {
  final DownloadManagerEntry entry;

  const _SavedFileTile({required this.entry});

  Future<void> _revealInFolder(BuildContext context) async {
    final path = entry.savedPath;
    if (path == null) return;
    try {
      await revealInFolder(path);
    } catch (_) {
      if (!context.mounted) return;
      HollowToast.show(
        context,
        "Couldn't open the folder",
        type: HollowToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final hasMedia = entry.isImage || entry.isVideo;

    return HollowPressable(
      onTap: () => _revealInFolder(context),
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            child: SizedBox(
              width: 40,
              height: 40,
              child: hasMedia && entry.savedPath != null
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.file(
                          File(entry.savedPath!),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _fileIconFallback(hollow),
                        ),
                        if (entry.isVideo)
                          Container(
                            color: HollowColors.mediaBlack.withValues(alpha: 0.3),
                            alignment: Alignment.center,
                            child: const Icon(
                              LucideIcons.play,
                              size: 16,
                              color: HollowColors.onMedia,
                            ),
                          ),
                      ],
                    )
                  : _fileIconFallback(hollow),
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),

          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.displayName,
                  style: HollowTypography.bodySmall.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: HollowSpacing.xxs),
                if (entry.savedPath != null)
                  Text(
                    entry.savedPath!,
                    style: HollowTypography.monoSmall.copyWith(
                      color: hollow.textSecondary.withValues(alpha: 0.7),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),

          const SizedBox(width: HollowSpacing.xs),

          Icon(
            LucideIcons.folderOpen,
            size: 12,
            color: hollow.textSecondary.withValues(alpha: 0.5),
          ),
        ],
      ),
    );
  }

  Widget _fileIconFallback(HollowTheme hollow) {
    return Container(
      color: hollow.elevated,
      alignment: Alignment.center,
      child: Icon(
        entry.isVideo
            ? LucideIcons.film
            : (entry.isImage ? LucideIcons.image : LucideIcons.file),
        size: 18,
        color: hollow.textSecondary,
      ),
    );
  }
}

class _ShareDownloadTile extends StatelessWidget {
  final ShareItemState item;

  const _ShareDownloadTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final completed = item.state == 'completed';
    final failed = item.state == 'failed';
    final progress = item.chunksTotal > 0
        ? item.chunksHave / item.chunksTotal
        : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          if (completed)
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: hollow.success.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(hollow.radiusMd),
              ),
              alignment: Alignment.center,
              child: Icon(LucideIcons.check, size: 16, color: hollow.success),
            )
          else
            SizedBox(
              width: 40,
              height: 40,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  HollowSpinner.large(
                    value: progress,
                    color: failed ? hollow.error : null,
                  ),
                  Text(
                    '${(progress * 100).round()}%',
                    style: HollowTypography.micro.copyWith(
                      color: hollow.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.fileName,
                  style: HollowTypography.bodySmall.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: HollowSpacing.xxs),
                Text(
                  completed
                      ? ShareCard.formatSize(item.totalSize)
                      : failed
                          ? friendlyError(item.error ?? '',
                              fallback: 'This download stopped. Try again.')
                          : '${item.chunksHave}/${item.chunksTotal} chunks  ·  ${ShareCard.formatSpeed(item.bytesPerSec)}/s',
                  style: HollowTypography.micro.copyWith(
                    color: completed ? hollow.success
                        : failed ? hollow.error
                        : hollow.textSecondary,
                  ),
                  maxLines: 1,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RebalanceTile extends StatelessWidget {
  final DownloadManagerEntry entry;

  const _RebalanceTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final active = entry.status == DownloadEntryStatus.active;
    final accentColor = active ? hollow.accent : hollow.success;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(hollow.radiusMd),
            ),
            alignment: Alignment.center,
            child: Icon(
              LucideIcons.shuffle,
              size: 16,
              color: accentColor,
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.displayName,
                  style: HollowTypography.bodySmall.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                ),
                const SizedBox(height: HollowSpacing.xxs),
                if (entry.statusText != null)
                  Text(
                    entry.statusText!,
                    style: HollowTypography.micro.copyWith(
                      color: active ? hollow.textSecondary : hollow.success,
                    ),
                    maxLines: 1,
                  ),
              ],
            ),
          ),
          if (!active)
            Icon(LucideIcons.check, size: 12, color: hollow.success),
        ],
      ),
    );
  }
}
