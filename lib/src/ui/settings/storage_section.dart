import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/components/server_avatar.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

/// The top of Settings > Files & Storage, shared with the phone's settings
/// tab: what the space holds, a way to clean it up, and each conversation's
/// share behind a fold.
class StorageBreakdownView extends ConsumerWidget {
  const StorageBreakdownView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final async = ref.watch(storageBreakdownProvider);

    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(HollowSpacing.xl),
        child: Center(child: HollowSpinner.medium()),
      ),
      error: (e, _) => Text('Could not read storage: $e',
          style: HollowTypography.bodySmall.copyWith(color: hollow.error)),
      data: (b) {
        final contexts = [...b.contexts]
          ..sort((a, c) => c.bytesDb.compareTo(a.bytesDb));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _SummaryHeader(breakdown: b),
            const SizedBox(height: HollowSpacing.md),
            SettingsExpandRow(
              title: 'By conversation',
              subtitle: 'See what takes the space and clear one at a time',
              children: contexts.isEmpty
                  ? const [
                      HollowEmptyState(
                          dense: true,
                          title: 'No downloaded files are taking up space'),
                    ]
                  : [for (final c in contexts) _ContextRow(usage: c)],
            ),
          ],
        );
      },
    );
  }
}

class _UsageSegment {
  const _UsageSegment(this.label, this.bytes, this.color);
  final String label;
  final int bytes;
  final Color color;
}

/// The total, the cleanup menu, and a bar with its legend.
class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({required this.breakdown});
  final storage_api.StorageBreakdown breakdown;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final downloads = breakdown.totalDiskBytes.toInt();
    final cache = breakdown.vaultCacheBytes.toInt();
    final shards = breakdown.vaultShardBytes.toInt();
    final assets = breakdown.assetBlobBytes.toInt();
    final total = downloads + cache + shards + assets;

    final segments = [
      _UsageSegment('Downloads', downloads, hollow.accent),
      _UsageSegment('Vault', cache, hollow.warning),
      _UsageSegment('Held for friends', shards, hollow.textSecondary),
      _UsageSegment('Emotes and GIFs', assets, hollow.accentMuted),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: HollowSpacing.lg),
          child: Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: formatBytes(total),
                      style: HollowTypography.heading.copyWith(
                        color: hollow.textPrimary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    TextSpan(
                      text: ' used on this computer',
                      style: HollowTypography.body
                          .copyWith(color: hollow.textSecondary),
                    ),
                  ]),
                ),
              ),
              const SizedBox(width: HollowSpacing.lg),
              _CleanupButton(downloads: downloads, cache: cache, assets: assets),
            ],
          ),
        ),
        const SizedBox(height: HollowSpacing.md),
        _UsageBar(segments: segments, total: total),
        const SizedBox(height: HollowSpacing.sm),
        Wrap(
          spacing: HollowSpacing.md,
          runSpacing: HollowSpacing.xs,
          children: [for (final s in segments) _LegendEntry(segment: s)],
        ),
        const _AtRestStatusLine(),
      ],
    );
  }
}

/// Shown only while files still need protecting: the one-time sweep over an
/// older version's plaintext, or files it could not encrypt.
class _AtRestStatusLine extends ConsumerWidget {
  const _AtRestStatusLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final status = ref.watch(atRestStatusProvider).valueOrNull;
    if (status == null || (!status.running && status.failed == 0)) {
      return const SizedBox.shrink();
    }

    final String label;
    final Color color;
    if (status.running) {
      label = 'Protecting your files (${status.done} of ${status.total})';
      color = hollow.textSecondary;
    } else {
      label = status.failed == 1
          ? '1 file is not protected yet. Hollow will try again the next time '
              'it starts.'
          : '${status.failed} files are not protected yet. Hollow will try '
              'again the next time it starts.';
      color = hollow.warning;
    }

    return Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.sm),
      child: Row(
        children: [
          Icon(
            status.failed > 0 ? LucideIcons.shieldAlert : LucideIcons.shield,
            size: 14,
            color: color,
          ),
          const SizedBox(width: HollowSpacing.xs),
          Expanded(
            child: Text(label,
                style: HollowTypography.bodySmall.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}

/// How each kind of storage divides the total.
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
        height: HollowSpacing.sm,
        child: total <= 0
            ? ColoredBox(color: hollow.border)
            : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final s in segments)
                    if (s.bytes > 0)
                      Expanded(flex: s.bytes, child: ColoredBox(color: s.color)),
                ],
              ),
      ),
    );
  }
}

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
                fontFeatures: const [FontFeature.tabularFigures()])),
      ],
    );
  }
}

/// Under the trailing edge of the button that owns [context]; pair with
/// `alignEnd`, since every storage menu hangs off the right of its row.
Offset _below(BuildContext context) => overlayAnchorOf(
      context,
      localOffset: Offset(context.size?.width ?? 0,
          (context.size?.height ?? 0) + HollowSpacing.xs),
    );

/// Asks, clears, then says how much it freed.
Future<void> _confirmAndClear(
  BuildContext context, {
  required String title,
  required String message,
  required Future<int> Function() run,
}) async {
  final ok = await showHollowConfirm(
    context: context,
    title: title,
    message: message,
    confirmLabel: 'Clear',
    destructive: true,
  );
  if (!ok) return;
  final freed = await run();
  if (!context.mounted) return;
  if (freed > 0) {
    HollowToast.show(context, 'Freed ${formatBytes(freed)}',
        type: HollowToastType.success);
  } else {
    HollowToast.show(context, 'Nothing was cleared');
  }
}

/// The destructive clears, each with its size. Held-for-friends shards are
/// absent on purpose: they are not ours to drop.
class _CleanupButton extends ConsumerWidget {
  const _CleanupButton(
      {required this.downloads, required this.cache, required this.assets});
  final int downloads;
  final int cache;
  final int assets;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.read(storageActionsProvider);
    final enabled = downloads > 0 || cache > 0 || assets > 0;

    return Builder(
      builder: (buttonContext) => HollowButton.ghost(
        compact: true,
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
                      onTap: () => _confirmAndClear(
                        context,
                        title: 'Clear all downloaded files?',
                        message: 'Deletes every downloaded file from disk. '
                            'Messages stay, and files can be downloaded again '
                            'from peers later.',
                        run: actions.clearAllFileBytes,
                      ),
                    ),
                    HollowMenuItem(
                      icon: LucideIcons.hardDrive,
                      label: 'Clear vault cache',
                      trailing: formatBytes(cache),
                      enabled: cache > 0,
                      onTap: () => _confirmAndClear(
                        context,
                        title: 'Clear vault cache?',
                        message: 'Deletes cached vault files and videos. It is '
                            'only a cache and downloads again when played.',
                        run: actions.clearVaultCache,
                      ),
                    ),
                    HollowMenuItem(
                      icon: LucideIcons.smile,
                      label: 'Clear unused emotes and GIFs',
                      trailing: formatBytes(assets),
                      enabled: assets > 0,
                      onTap: () => _confirmAndClear(
                        context,
                        title: 'Clear unused emotes and GIFs?',
                        message: 'Deletes cached emote, sticker and GIF images '
                            'that are not in your personal set or any of your '
                            'servers. They download again from peers when '
                            'needed.',
                        run: actions.clearUnreferencedAssets,
                      ),
                    ),
                  ],
                ),
        child: const Text('Clean up'),
      ),
    );
  }
}

/// One conversation's downloads: who or where, how much, its auto-download
/// choice, and clearing it in the More menu.
class _ContextRow extends ConsumerWidget {
  const _ContextRow({required this.usage});
  final storage_api.StorageContextUsage usage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDm = usage.contextType == 'dm';

    String label;
    Widget leading;
    if (isDm) {
      final profile =
          ref.watch(profileProvider.select((m) => m[usage.contextId]));
      label = displayNameForPeer(profile, usage.contextId);
      leading = HollowAvatar(peerId: usage.contextId, size: 32);
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
      leading = ServerAvatar(serverId: serverId, name: serverName, size: 32);
    }
    final files = usage.fileCount == 1 ? '1 file' : '${usage.fileCount} files';

    return SettingsRow(
      leading: leading,
      title: label,
      subtitle: '${formatBytes(usage.bytesDb.toInt())} · $files',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Channel rows map to their SERVER: one override per server.
          _AutoDownloadOverrideButton(
            contextKey: isDm
                ? 'dm:${usage.contextId}'
                : 'server:${usage.contextId.split(':').first}',
            conversationLabel: label,
          ),
          const SizedBox(width: HollowSpacing.xs),
          Builder(
            builder: (buttonContext) => HollowIconButton(
              icon: LucideIcons.ellipsis,
              label: 'More for $label',
              tooltip: 'More',
              onPressed: () => showHollowMenu(
                context: buttonContext,
                anchor: _below(buttonContext),
                alignEnd: true,
                builder: (_, _) => [
                  HollowMenuItem(
                    icon: LucideIcons.trash2,
                    label: 'Clear downloaded files',
                    isDanger: true,
                    onTap: () => _confirmAndClear(
                      context,
                      title: 'Clear "$label"?',
                      message: 'Deletes the downloaded files for this '
                          'conversation from disk. The messages stay, and '
                          'files can be downloaded again later.',
                      run: () => ref
                          .read(storageActionsProvider)
                          .clearContext(usage.contextType, usage.contextId),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Per-conversation auto-download override (issue #41). The state lives in
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
          onTap: () => notifier.setOverride(contextKey, value).catchError((_) {
            if (context.mounted) {
              HollowToast.show(context, 'Could not save that setting',
                  type: HollowToastType.error);
            }
          }),
        );

    return Builder(
      builder: (buttonContext) => HollowIconButton(
        icon: override == false ? LucideIcons.cloudOff : LucideIcons.download,
        label: 'Auto-download for $conversationLabel',
        tooltip: 'Auto-download',
        // An override is a choice the user made, so it shows in the accent.
        color: override == null ? null : hollow.accentText,
        onPressed: () => showHollowMenu(
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
      ),
    );
  }
}
