import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/storage_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';

/// Shared Storage Manager widgets used by both the desktop settings dialog
/// (`user_settings_dialog.dart`) and the mobile settings tab
/// (`mobile_settings_tab.dart`). All read the same providers in
/// `storage_provider.dart` — layout only, no duplicated logic.

/// Modern storage dashboard: a summary header (total + segmented usage bar +
/// legend) with a "⋯" cleanup menu, followed by the per-conversation list.
class StorageBreakdownView extends ConsumerWidget {
  const StorageBreakdownView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final async = ref.watch(storageBreakdownProvider);

    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (e, _) => Text('Could not read storage: $e',
          style: HollowTypography.caption.copyWith(color: hollow.error)),
      data: (b) {
        final contexts = [...b.contexts]
          ..sort((a, c) => c.bytesDb.compareTo(a.bytesDb));

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SummaryHeader(breakdown: b),
            if (contexts.isNotEmpty) ...[
              const SizedBox(height: HollowSpacing.md),
              _SectionCaption(
                  'By conversation (${contexts.length})'),
              const SizedBox(height: HollowSpacing.xs),
              for (final c in contexts) _ContextRow(usage: c),
            ] else ...[
              const SizedBox(height: HollowSpacing.md),
              Text('No downloaded files are taking up space.',
                  style: HollowTypography.caption
                      .copyWith(color: hollow.textSecondary)),
            ],
          ],
        );
      },
    );
  }
}

class _SectionCaption extends StatelessWidget {
  const _SectionCaption(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Text(text.toUpperCase(),
        style: HollowTypography.caption.copyWith(
          color: hollow.textSecondary,
          fontSize: 10,
          letterSpacing: 0.6,
          fontWeight: FontWeight.w600,
        ));
  }
}

/// One legend/segment descriptor for the usage bar.
class _UsageSegment {
  const _UsageSegment(this.label, this.bytes, this.color);
  final String label;
  final int bytes;
  final Color color;
}

/// The summary header: big total, a segmented proportional usage bar, a legend
/// of byte values, and a "⋯" overflow menu for the destructive clear actions.
class _SummaryHeader extends ConsumerWidget {
  const _SummaryHeader({required this.breakdown});
  final storage_api.StorageBreakdown breakdown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final downloads = breakdown.totalDiskBytes.toInt();
    final cache = breakdown.vaultCacheBytes.toInt();
    final shards = breakdown.vaultShardBytes.toInt();
    final assets = breakdown.assetBlobBytes.toInt();
    final total = downloads + cache + shards + assets;

    final segments = [
      _UsageSegment('Downloads', downloads, hollow.accent),
      _UsageSegment('Vault cache', cache, hollow.warning),
      _UsageSegment('Held shards', shards, hollow.success),
      _UsageSegment('Emotes & GIFs', assets, hollow.accentMuted),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Storage used',
                      style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary, fontSize: 11)),
                  const SizedBox(height: 2),
                  Text(formatBytes(total),
                      style: HollowTypography.heading.copyWith(
                          color: hollow.textPrimary,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            _CleanupMenu(downloads: downloads, cache: cache, assets: assets),
          ],
        ),
        const SizedBox(height: HollowSpacing.sm),
        _UsageBar(segments: segments, total: total),
        const SizedBox(height: HollowSpacing.sm),
        Wrap(
          spacing: HollowSpacing.md,
          runSpacing: HollowSpacing.xs,
          children: [
            for (final s in segments) _LegendChip(segment: s),
          ],
        ),
      ],
    );
  }
}

/// Thin proportional bar showing how each storage class divides the total.
class _UsageBar extends StatelessWidget {
  const _UsageBar({required this.segments, required this.total});
  final List<_UsageSegment> segments;
  final int total;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      child: SizedBox(
        height: 8,
        child: total <= 0
            ? Container(color: hollow.border)
            : Row(
                children: [
                  for (final s in segments)
                    if (s.bytes > 0)
                      Expanded(
                        flex: s.bytes,
                        child: Container(color: s.color),
                      ),
                ],
              ),
      ),
    );
  }
}

class _LegendChip extends StatelessWidget {
  const _LegendChip({required this.segment});
  final _UsageSegment segment;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: segment.color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(segment.label,
            style: HollowTypography.caption
                .copyWith(color: hollow.textSecondary, fontSize: 11)),
        const SizedBox(width: 4),
        Text(formatBytes(segment.bytes),
            style: HollowTypography.caption.copyWith(
                color: hollow.textPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// The "⋯" overflow menu holding destructive clear actions, so they're reachable
/// but out of the way (held shards intentionally absent — read-only).
class _CleanupMenu extends ConsumerWidget {
  const _CleanupMenu(
      {required this.downloads, required this.cache, required this.assets});
  final int downloads;
  final int cache;
  final int assets;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final actions = ref.read(storageActionsProvider);
    final enabled = downloads > 0 || cache > 0 || assets > 0;

    return PopupMenuButton<String>(
      enabled: enabled,
      tooltip: 'Clean up',
      icon: Icon(LucideIcons.ellipsis,
          size: 18,
          color: enabled ? hollow.textSecondary : hollow.border,
          semanticLabel: 'Cleanup options'),
      color: hollow.elevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        side: BorderSide(color: hollow.border),
      ),
      onSelected: (value) async {
        switch (value) {
          case 'downloads':
            final ok = await _confirm(
              context,
              'Clear all downloaded files?',
              'Deletes every downloaded file from disk. Messages stay — files '
                  'can be downloaded again from peers later.',
            );
            if (ok) await actions.clearAllFileBytes();
          case 'cache':
            final ok = await _confirm(
              context,
              'Clear vault cache?',
              'Deletes cached vault file/video playback data. This is pure cache '
                  'and re-downloads on demand.',
            );
            if (ok) await actions.clearVaultCache();
          case 'assets':
            final ok = await _confirm(
              context,
              'Clear unused emotes & GIFs?',
              'Deletes cached emote, sticker and GIF images that are not part '
                  'of your personal set or any of your servers. They re-download '
                  'from peers on demand.',
            );
            if (ok) await actions.clearUnreferencedAssets();
        }
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'downloads',
          enabled: downloads > 0,
          child: _menuRow(hollow, LucideIcons.download,
              'Clear all downloads', formatBytes(downloads)),
        ),
        PopupMenuItem(
          value: 'cache',
          enabled: cache > 0,
          child: _menuRow(hollow, LucideIcons.hardDrive,
              'Clear vault cache', formatBytes(cache)),
        ),
        PopupMenuItem(
          value: 'assets',
          enabled: assets > 0,
          child: _menuRow(hollow, LucideIcons.smile,
              'Clear unused emotes & GIFs', formatBytes(assets)),
        ),
      ],
    );
  }

  Widget _menuRow(
      HollowTheme hollow, IconData icon, String label, String trailing) {
    return Row(
      children: [
        Icon(icon, size: 15, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.sm),
        Text(label,
            style:
                HollowTypography.body.copyWith(color: hollow.textPrimary)),
        const SizedBox(width: HollowSpacing.md),
        Text(trailing,
            style: HollowTypography.caption
                .copyWith(color: hollow.textSecondary)),
      ],
    );
  }
}

class _ContextRow extends ConsumerStatefulWidget {
  const _ContextRow({required this.usage});
  final storage_api.StorageContextUsage usage;

  @override
  ConsumerState<_ContextRow> createState() => _ContextRowState();
}

class _ContextRowState extends ConsumerState<_ContextRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final usage = widget.usage;
    final isDm = usage.contextType == 'dm';

    String label;
    Widget leading;
    if (isDm) {
      final profile =
          ref.watch(profileProvider.select((m) => m[usage.contextId]));
      label = displayNameForPeer(profile, usage.contextId);
      leading = HollowAvatar(peerId: usage.contextId, size: 30);
    } else {
      // context_id = "serverId:channelId"
      final parts = usage.contextId.split(':');
      final serverId = parts.isNotEmpty ? parts.first : usage.contextId;
      final server = ref.watch(serverListProvider.select((m) => m[serverId]));
      final serverName = server?.name ??
          (serverId.length > 8 ? '${serverId.substring(0, 8)}…' : serverId);
      final channelShort = parts.length > 1 && parts[1].length > 6
          ? parts[1].substring(0, 6)
          : (parts.length > 1 ? parts[1] : '');
      label = channelShort.isEmpty ? serverName : '$serverName • #$channelShort';
      leading = Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: hollow.surface,
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          border: Border.all(color: hollow.border),
        ),
        alignment: Alignment.center,
        child: Icon(LucideIcons.hash, size: 14, color: hollow.textSecondary),
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.only(top: HollowSpacing.xs),
        padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm, vertical: HollowSpacing.sm),
        decoration: BoxDecoration(
          // Zero-alpha rest color, not Colors.transparent (transparent BLACK
          // — the lerp flashed dark on hover/unhover, worst in light mode).
          color: _hovered
              ? hollow.surface
              : hollow.surface.withValues(alpha: 0.0),
          borderRadius: BorderRadius.circular(hollow.radiusMd),
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      overflow: TextOverflow.ellipsis,
                      style: HollowTypography.body
                          .copyWith(color: hollow.textPrimary)),
                  const SizedBox(height: 1),
                  Text(
                      '${formatBytes(usage.bytesDb.toInt())} · ${usage.fileCount} file${usage.fileCount == 1 ? '' : 's'}',
                      style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary, fontSize: 11)),
                ],
              ),
            ),
            // Trash is always tappable (works on touch); it just brightens on
            // hover on desktop. Always-visible keeps it discoverable on mobile.
            AnimatedOpacity(
              opacity: _hovered ? 1 : 0.55,
              duration: const Duration(milliseconds: 120),
              child: _RowTrashButton(
                label: label,
                onConfirmed: () => ref
                    .read(storageActionsProvider)
                    .clearContext(usage.contextType, usage.contextId),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RowTrashButton extends StatelessWidget {
  const _RowTrashButton({required this.label, required this.onConfirmed});
  final String label;
  final Future<void> Function() onConfirmed;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    void handleTap() async {
      final ok = await _confirm(
        context,
        'Clear "$label"?',
        'Deletes the downloaded files for this conversation from disk. '
            'The messages stay — files can be downloaded again later.',
      );
      if (ok) await onConfirmed();
    }

    // HollowPressable (never Material InkWell — no ripple in Hollow, and the
    // pressable already carries the focus ring + button semantics).
    return HollowPressable(
      onTap: handleTap,
      semanticLabel: 'Delete files',
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.all(6),
      child: Icon(LucideIcons.trash2, size: 16, color: hollow.error),
    );
  }
}

Future<bool> _confirm(BuildContext context, String title, String body) async {
  final hollow = HollowTheme.of(context);
  final result = await showHollowDialog<bool>(
    context: context,
    builder: (ctx) => HollowDialog(
      title: title,
      content: Text(body,
          style: HollowTypography.body.copyWith(color: hollow.textSecondary)),
      actions: [
        HollowButton.ghost(
          child: const Text('Cancel'),
          onPressed: () => Navigator.of(ctx).pop(false),
        ),
        HollowButton.danger(
          child: const Text('Clear'),
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  return result ?? false;
}
