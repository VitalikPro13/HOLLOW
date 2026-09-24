import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/storage_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';

/// Shared Storage Manager widgets for the desktop dialog and the mobile
/// settings tab. Layout only: both read the same providers.

/// Storage dashboard: a summary header with a cleanup menu, then the
/// per-conversation list.
class StorageBreakdownView extends ConsumerWidget {
  const StorageBreakdownView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final async = ref.watch(storageBreakdownProvider);

    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: HollowSpinner.large()),
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
              HollowSectionHeader('By conversation',
                  count: '${contexts.length}', dense: true),
              for (final c in contexts) _ContextRow(usage: c),
            ] else ...[
              const SizedBox(height: HollowSpacing.md),
              const HollowEmptyState(
                  dense: true,
                  title: 'No downloaded files are taking up space'),
            ],
          ],
        );
      },
    );
  }
}

/// One legend/segment descriptor for the usage bar.
class _UsageSegment {
  const _UsageSegment(this.label, this.bytes, this.color);
  final String label;
  final int bytes;
  final Color color;
}

/// The summary header: total, a proportional usage bar with a byte legend, and
/// an overflow menu for the destructive clear actions.
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
    // A Dart-owned disk cache, outside the Rust breakdown, so it is appended as
    // its own segment.
    final gifCache =
        ref.watch(gifThumbCacheSizeProvider).valueOrNull ?? 0;
    final total = downloads + cache + shards + assets + gifCache;

    final segments = [
      _UsageSegment('Downloads', downloads, hollow.accent),
      _UsageSegment('Vault cache', cache, hollow.warning),
      _UsageSegment('Held shards', shards, hollow.success),
      _UsageSegment('Emotes & GIFs', assets, hollow.accentMuted),
      _UsageSegment('GIF search', gifCache, hollow.textTertiary),
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
            _CleanupMenu(
                downloads: downloads,
                cache: cache,
                assets: assets,
                gifCache: gifCache),
          ],
        ),
        const SizedBox(height: HollowSpacing.sm),
        _UsageBar(segments: segments, total: total),
        const SizedBox(height: HollowSpacing.sm),
        Wrap(
          spacing: HollowSpacing.md,
          runSpacing: HollowSpacing.xs,
          children: [
            for (final s in segments) _LegendEntry(segment: s),
          ],
        ),
        const SizedBox(height: HollowSpacing.sm),
        const _AtRestStatusLine(),
      ],
    );
  }
}

/// Whether the files on disk are encrypted yet, and how far the one-time sweep
/// over an older version's plaintext has got.
class _AtRestStatusLine extends ConsumerWidget {
  const _AtRestStatusLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final status = ref.watch(atRestStatusProvider).valueOrNull;
    if (status == null) return const SizedBox.shrink();

    final String label;
    final Color color;
    if (status.running) {
      label = 'Protecting your files (${status.done} of ${status.total})';
      color = hollow.textSecondary;
    } else if (status.failed > 0) {
      label = status.failed == 1
          ? '1 file is not protected yet. Hollow will try again the next time '
              'it starts.'
          : '${status.failed} files are not protected yet. Hollow will try '
              'again the next time it starts.';
      color = hollow.warning;
    } else {
      label = 'Protected';
      color = hollow.textSecondary;
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            status.failed > 0 ? LucideIcons.shieldAlert : LucideIcons.shield,
            size: 12,
            color: color,
          ),
        ),
        const SizedBox(width: HollowSpacing.xs),
        Expanded(
          child: Text(label,
              style: HollowTypography.caption
                  .copyWith(color: color, fontSize: 11)),
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
      borderRadius: BorderRadius.circular(hollow.radiusXs),
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

/// One key of the usage bar: swatch, category, size.
class _LegendEntry extends StatelessWidget {
  const _LegendEntry({required this.segment});
  final _UsageSegment segment;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: HollowSpacing.sm,
          height: HollowSpacing.sm,
          decoration: BoxDecoration(
            color: segment.color,
            borderRadius: BorderRadius.circular(hollow.radiusXs / 2),
          ),
        ),
        const SizedBox(width: HollowSpacing.xs),
        Text(segment.label,
            style: HollowTypography.caption
                .copyWith(color: hollow.textSecondary)),
        const SizedBox(width: HollowSpacing.xs),
        Text(formatBytes(segment.bytes),
            style: HollowTypography.caption.copyWith(
                color: hollow.textPrimary,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()])),
      ],
    );
  }
}

/// Overflow menu for the destructive clear actions. Held shards are absent on
/// purpose: they are read-only.
class _CleanupMenu extends ConsumerWidget {
  const _CleanupMenu(
      {required this.downloads,
      required this.cache,
      required this.assets,
      required this.gifCache});
  final int downloads;
  final int cache;
  final int assets;
  final int gifCache;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.read(storageActionsProvider);
    final enabled = downloads > 0 || cache > 0 || assets > 0 || gifCache > 0;

    Future<void> clear(
        String title, String body, Future<void> Function() run) async {
      final ok = await showHollowConfirm(
        context: context,
        title: title,
        message: body,
        confirmLabel: 'Clear',
        destructive: true,
      );
      if (ok) await run();
    }

    return HollowTooltip(
      message: 'Clean up',
      child: Builder(
        builder: (buttonContext) => HollowButton.ghost(
          compact: true,
          semanticLabel: 'Cleanup options',
          onPressed: !enabled
              ? null
              : () => showHollowMenu(
                    context: buttonContext,
                    anchor: _below(buttonContext),
                    alignEnd: true,
                    builder: (_, _) => [
                      HollowMenuItem(
                        icon: LucideIcons.download,
                        label: 'Clear all downloads',
                        trailing: formatBytes(downloads),
                        enabled: downloads > 0,
                        onTap: () => clear(
                          'Clear all downloaded files?',
                          'Deletes every downloaded file from disk. Messages '
                              'stay, and files can be downloaded again from '
                              'peers later.',
                          actions.clearAllFileBytes,
                        ),
                      ),
                      HollowMenuItem(
                        icon: LucideIcons.hardDrive,
                        label: 'Clear vault cache',
                        trailing: formatBytes(cache),
                        enabled: cache > 0,
                        onTap: () => clear(
                          'Clear vault cache?',
                          'Deletes cached vault file/video playback data. This '
                              'is pure cache and re-downloads on demand.',
                          actions.clearVaultCache,
                        ),
                      ),
                      HollowMenuItem(
                        icon: LucideIcons.smile,
                        label: 'Clear unused emotes & GIFs',
                        trailing: formatBytes(assets),
                        enabled: assets > 0,
                        onTap: () => clear(
                          'Clear unused emotes & GIFs?',
                          'Deletes cached emote, sticker and GIF images that '
                              'are not part of your personal set or any of '
                              'your servers. They re-download from peers on '
                              'demand.',
                          actions.clearUnreferencedAssets,
                        ),
                      ),
                      // A pure thumbnail cache, so nothing is lost and nothing
                      // is asked.
                      HollowMenuItem(
                        icon: LucideIcons.search,
                        label: 'Clear GIF search cache',
                        trailing: formatBytes(gifCache),
                        enabled: gifCache > 0,
                        onTap: actions.clearGifThumbCache,
                      ),
                    ],
                  ),
          child: const Icon(LucideIcons.ellipsis),
        ),
      ),
    );
  }
}

/// Under the trigger's trailing edge: both storage menus hang off buttons at
/// the right of their row, so they open right-aligned (pair with `alignEnd`).
Offset _below(BuildContext context) => overlayAnchorOf(
      context,
      localOffset: Offset(context.size?.width ?? 0,
          (context.size?.height ?? 0) + HollowSpacing.xs),
    );

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
          color: hollow.elevated,
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
        duration: HollowDurations.fast,
        margin: const EdgeInsets.only(top: HollowSpacing.xs),
        padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm, vertical: HollowSpacing.sm),
        decoration: BoxDecoration(
          // Zero-alpha rest colour, not `Colors.transparent`: that is
          // transparent BLACK, and the lerp flashes dark on hover.
          color: _hovered
              ? hollow.hover
              : hollow.hover.withValues(alpha: 0.0),
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
            // Per-conversation auto-download override (issue #41). Channel rows
            // map to their SERVER: one override per server, not per channel.
            _AutoDownloadOverrideButton(
              contextKey: isDm
                  ? 'dm:${usage.contextId}'
                  : 'server:${usage.contextId.split(':').first}',
              conversationLabel: label,
            ),
            // Always tappable and always visible, so touch can reach it; hover
            // only brightens it.
            AnimatedOpacity(
              opacity: _hovered ? 1 : 0.55,
              duration: HollowDurations.fast,
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

/// Per-conversation auto-download override menu (issue #41). The state lives in
/// [autoDownloadOverridesProvider] and is pushed to Rust on every change.
class _AutoDownloadOverrideButton extends ConsumerWidget {
  const _AutoDownloadOverrideButton(
      {required this.contextKey, required this.conversationLabel});
  final String contextKey;
  final String conversationLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final override = (ref.watch(autoDownloadOverridesProvider).valueOrNull ??
        const {})[contextKey];
    final notifier = ref.read(autoDownloadOverridesProvider.notifier);

    HollowMenuItem item(String label, bool? value) => HollowMenuItem(
          label: label,
          isChecked: override == value,
          onTap: () => notifier.setOverride(contextKey, value),
        );

    return HollowTooltip(
      message: 'Auto-download',
      child: Builder(
        builder: (buttonContext) => HollowPressable(
          semanticLabel: 'Auto-download settings for $conversationLabel',
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          padding: const EdgeInsets.all(HollowSpacing.xs),
          onTap: () => showHollowMenu(
            context: buttonContext,
            anchor: _below(buttonContext),
                    alignEnd: true,
            builder: (_, _) => [
              const HollowMenuSection('Auto-download'),
              item('Default', null),
              item('Always on', true),
              item('Off', false),
            ],
          ),
          child: Icon(
            override == false ? LucideIcons.cloudOff : LucideIcons.download,
            size: 16,
            // An override is a choice the user made, so it shows in the accent.
            color: override == null ? hollow.textSecondary : hollow.accentText,
          ),
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
      final ok = await showHollowConfirm(
        context: context,
        title: 'Clear "$label"?',
        message: 'Deletes the downloaded files for this conversation from '
            'disk. The messages stay, and files can be downloaded again later.',
        confirmLabel: 'Clear',
        destructive: true,
      );
      if (ok) await onConfirmed();
    }

    // Never a Material InkWell: no ripple in Hollow, and the pressable already
    // carries the focus ring and button semantics.
    return HollowPressable(
      onTap: handleTap,
      semanticLabel: 'Delete files',
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      padding: const EdgeInsets.all(6),
      child: Icon(LucideIcons.trash2, size: 16, color: hollow.error),
    );
  }
}
