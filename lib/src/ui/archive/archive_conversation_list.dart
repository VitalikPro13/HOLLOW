import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/archive_conversation.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/hidden_archive_dm_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/dialogs/export_archive_dialog.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Left panel of "My Data" — DMs|Channels inner tabs + search + scrollable list.
class ArchiveConversationList extends ConsumerWidget {
  const ArchiveConversationList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final innerTab = ref.watch(myDataInnerTabProvider);

    return Column(
      children: [
        // ── Inner tab bar ──
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HollowSpacing.md, HollowSpacing.md, HollowSpacing.md, HollowSpacing.xs,
          ),
          child: Row(
            children: [
              Expanded(
                child: _TabPill(
                  label: 'DMs',
                  isSelected: innerTab == MyDataInnerTab.dms,
                  onTap: () => ref.read(myDataInnerTabProvider.notifier).state =
                      MyDataInnerTab.dms,
                ),
              ),
              const SizedBox(width: HollowSpacing.xs),
              Expanded(
                child: _TabPill(
                  label: 'Channels',
                  isSelected: innerTab == MyDataInnerTab.channels,
                  onTap: () => ref.read(myDataInnerTabProvider.notifier).state =
                      MyDataInnerTab.channels,
                ),
              ),
              const SizedBox(width: HollowSpacing.xs),
              Expanded(
                child: _TabPill(
                  label: 'Vault Files',
                  isSelected: innerTab == MyDataInnerTab.vaultFiles,
                  onTap: () => ref.read(myDataInnerTabProvider.notifier).state =
                      MyDataInnerTab.vaultFiles,
                ),
              ),
            ],
          ),
        ),

        // ── Search field (not shown for Vault Files tab) ──
        if (innerTab != MyDataInnerTab.vaultFiles)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.md,
              vertical: HollowSpacing.xs,
            ),
            child: HollowTextField(
              hintText: 'Search...',
              isDense: true,
              prefixIcon: Icon(LucideIcons.search, size: 14, color: hollow.textSecondary),
              onChanged: (val) =>
                  ref.read(archiveSearchProvider.notifier).state = val,
            ),
          ),

        const SizedBox(height: HollowSpacing.xs),

        // ── Content list ──
        Expanded(
          child: switch (innerTab) {
            MyDataInnerTab.dms => const _DmList(),
            MyDataInnerTab.channels => const _ChannelList(),
            MyDataInnerTab.vaultFiles => const _VaultFilesPlaceholder(),
          },
        ),
      ],
    );
  }
}

// ── Tab pill widget ─────────────────────────────────────────────

class _TabPill extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _TabPill({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return HollowPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? hollow.accent.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          border: Border.all(
            color: isSelected ? hollow.accent.withValues(alpha: 0.3) : hollow.border,
          ),
        ),
        child: Text(
          label,
          style: HollowTypography.caption.copyWith(
            color: isSelected ? hollow.accent : hollow.textSecondary,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

// ── DM list ─────────────────────────────────────────────────────

class _DmList extends ConsumerStatefulWidget {
  const _DmList();

  @override
  ConsumerState<_DmList> createState() => _DmListState();
}

class _DmListState extends ConsumerState<_DmList> {
  bool _hiddenExpanded = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final dmListAsync = ref.watch(archiveDmListProvider);
    final search = ref.watch(archiveSearchProvider).toLowerCase();
    final selectedDm = ref.watch(archiveSelectedDmProvider);
    final profiles = ref.watch(profileProvider);
    final hiddenSet = ref.watch(hiddenArchiveDmsProvider);

    return dmListAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('Failed to load: $e',
            style: TextStyle(color: hollow.error)),
      ),
      data: (entries) {
        final filtered = search.isEmpty
            ? entries
            : entries.where((e) {
                final name = displayNameFor(profiles, e.peerId).toLowerCase();
                return name.contains(search);
              }).toList();

        final visible =
            filtered.where((e) => !hiddenSet.contains(e.peerId)).toList();
        final hidden =
            filtered.where((e) => hiddenSet.contains(e.peerId)).toList();

        if (visible.isEmpty && hidden.isEmpty) {
          return Center(
            child: Text(
              search.isEmpty ? 'No DM conversations' : 'No matches',
              style: HollowTypography.body
                  .copyWith(color: hollow.textSecondary),
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
          children: [
            for (final entry in visible)
              _DmRow(
                entry: entry,
                isSelected: selectedDm == entry.peerId,
                isHidden: false,
                onTap: () {
                  ref.read(archiveSelectedDmProvider.notifier).state =
                      entry.peerId;
                  ref.read(archiveSelectedChannelProvider.notifier).state =
                      null;
                },
                onToggleHidden: () => ref
                    .read(hiddenArchiveDmsProvider.notifier)
                    .hide(entry.peerId),
              ),
            if (hidden.isNotEmpty) ...[
              const SizedBox(height: HollowSpacing.sm),
              _HiddenHeader(
                count: hidden.length,
                expanded: _hiddenExpanded,
                onTap: () =>
                    setState(() => _hiddenExpanded = !_hiddenExpanded),
              ),
              AnimatedSize(
                duration: HollowDurations.fast,
                curve: HollowCurves.subtle,
                alignment: Alignment.topCenter,
                child: _hiddenExpanded
                    ? Column(
                        children: [
                          const SizedBox(height: HollowSpacing.xs),
                          for (final entry in hidden)
                            _DmRow(
                              entry: entry,
                              isSelected: selectedDm == entry.peerId,
                              isHidden: true,
                              onTap: () {
                                ref
                                    .read(archiveSelectedDmProvider.notifier)
                                    .state = entry.peerId;
                                ref
                                    .read(
                                        archiveSelectedChannelProvider.notifier)
                                    .state = null;
                              },
                              onToggleHidden: () => ref
                                  .read(hiddenArchiveDmsProvider.notifier)
                                  .unhide(entry.peerId),
                            ),
                        ],
                      )
                    : const SizedBox(width: double.infinity, height: 0),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _DmRow extends ConsumerWidget {
  final ArchiveDmEntry entry;
  final bool isSelected;
  final bool isHidden;
  final VoidCallback onTap;
  final VoidCallback onToggleHidden;

  const _DmRow({
    required this.entry,
    required this.isSelected,
    required this.isHidden,
    required this.onTap,
    required this.onToggleHidden,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final name = displayNameFor(profiles, entry.peerId);

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: HollowPressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm,
          vertical: HollowSpacing.sm,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: isSelected
                ? hollow.accent.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm,
            vertical: HollowSpacing.xs,
          ),
          child: Row(
            children: [
              HollowAvatar(
                peerId: entry.peerId,
                size: 28,
              ),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  name,
                  style: HollowTypography.body.copyWith(
                    color: isSelected
                        ? hollow.accent
                        : hollow.textPrimary,
                    fontWeight:
                        isSelected ? FontWeight.w600 : FontWeight.normal,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              HollowPressable(
                onTap: onToggleHidden,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(4),
                child: Icon(
                  isHidden ? LucideIcons.eye : LucideIcons.eyeOff,
                  size: 13,
                  color: hollow.textSecondary,
                ),
              ),
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: hollow.elevated,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${entry.messageCount}',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HiddenHeader extends StatelessWidget {
  final int count;
  final bool expanded;
  final VoidCallback onTap;

  const _HiddenHeader({
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xs,
      ),
      child: Row(
        children: [
          AnimatedRotation(
            turns: expanded ? 0.25 : 0,
            duration: HollowDurations.fast,
            curve: HollowCurves.subtle,
            child: Icon(
              LucideIcons.chevronRight,
              size: 12,
              color: hollow.textSecondary,
            ),
          ),
          const SizedBox(width: HollowSpacing.xs),
          Text(
            'Hidden',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 10,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Channel list (grouped by server) ────────────────────────────

class _ChannelList extends ConsumerWidget {
  const _ChannelList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final channelListAsync = ref.watch(archiveChannelListProvider);
    final search = ref.watch(archiveSearchProvider).toLowerCase();
    final selectedChannel = ref.watch(archiveSelectedChannelProvider);

    return channelListAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('Failed to load: $e',
            style: TextStyle(color: hollow.error)),
      ),
      data: (groups) {
        // Flatten for rendering — filter by search.
        final items = <_ChannelListItem>[];
        for (final group in groups) {
          final matchingChannels = group.channels.where((ch) {
            if (search.isEmpty) return true;
            return ch.channelName.toLowerCase().contains(search) ||
                ch.serverName.toLowerCase().contains(search);
          }).toList();

          if (matchingChannels.isNotEmpty) {
            items.add(_ChannelListItem.header(group.serverName, group));
            for (final ch in matchingChannels) {
              items.add(_ChannelListItem.channel(ch));
            }
          }
        }

        if (items.isEmpty) {
          return Center(
            child: Text(
              search.isEmpty ? 'No channel history' : 'No matches',
              style: HollowTypography.body
                  .copyWith(color: hollow.textSecondary),
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];

            if (item.isHeader) {
              return Padding(
                padding: EdgeInsets.only(
                  left: HollowSpacing.sm,
                  right: HollowSpacing.sm,
                  top: index == 0 ? 0 : HollowSpacing.md,
                  bottom: HollowSpacing.xs,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.headerName!,
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontWeight: FontWeight.w700,
                          fontSize: 10,
                          letterSpacing: 0.5,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (item.group != null)
                      HollowPressable(
                        onTap: () {
                          final g = item.group!;
                          final totalMsgCount = g.channels
                              .fold<int>(0, (s, c) => s + c.messageCount);
                          showExportArchiveDialog(
                            context,
                            isDm: false,
                            isServer: true,
                            serverId: g.serverId,
                            serverName: g.serverName,
                            channels: g.channels
                                .map((c) => {
                                      'channel_id': c.channelId,
                                      'channel_name': c.channelName,
                                    })
                                .toList(),
                            name: g.serverName,
                            messageCount: totalMsgCount,
                          );
                        },
                        borderRadius:
                            BorderRadius.circular(hollow.radiusSm),
                        padding: const EdgeInsets.all(3),
                        child: Icon(LucideIcons.fileOutput,
                            size: 12, color: hollow.accent),
                      ),
                  ],
                ),
              );
            }

            final ch = item.entry!;
            final key = '${ch.serverId}:${ch.channelId}';
            final isSelected = selectedChannel == key;

            return Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: HollowPressable(
                onTap: () {
                  ref.read(archiveSelectedChannelProvider.notifier).state =
                      key;
                  ref.read(archiveSelectedDmProvider.notifier).state = null;
                },
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.sm,
                  vertical: HollowSpacing.xs,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: isSelected
                        ? hollow.accent.withValues(alpha: 0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.sm,
                    vertical: HollowSpacing.xs,
                  ),
                  child: Row(
                    children: [
                      Text(
                        '#',
                        style: TextStyle(
                          color: isSelected
                              ? hollow.accent
                              : hollow.textSecondary,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.xs),
                      Expanded(
                        child: Text(
                          ch.channelName,
                          style: HollowTypography.body.copyWith(
                            color: isSelected
                                ? hollow.accent
                                : hollow.textPrimary,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: hollow.elevated,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${ch.messageCount}',
                          style: HollowTypography.caption.copyWith(
                            color: hollow.textSecondary,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Helper for the flat channel list (mix of headers and entries).
class _ChannelListItem {
  final bool isHeader;
  final String? headerName;
  final ArchiveChannelGroup? group;
  final ArchiveChannelEntry? entry;

  _ChannelListItem.header(this.headerName, this.group)
      : isHeader = true,
        entry = null;
  _ChannelListItem.channel(this.entry)
      : isHeader = false,
        headerName = null,
        group = null;
}

// ── Vault files list (Evidence Recovery Phase A) ────────────────

class _VaultFilesPlaceholder extends StatelessWidget {
  const _VaultFilesPlaceholder();

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      child: Text(
        'Vault file details are shown in the right panel.',
        style: HollowTypography.caption.copyWith(
          color: hollow.textSecondary,
          fontSize: 11,
        ),
      ),
    );
  }
}
