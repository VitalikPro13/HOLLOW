import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/archive_conversation.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/hidden_archive_dm_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/saved_messages_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/api/archive.dart' as archive_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/saved_messages_avatar.dart';
import 'package:hollow/src/ui/dialogs/export_archive_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_archive_viewer_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/core/providers/recovery_pool_provider.dart';
import 'package:hollow/src/core/providers/vault_file_status_provider.dart';
import 'package:hollow/src/ui/archive/recovery_pool_dashboard.dart';
import 'package:hollow/src/ui/dialogs/recovery_pool_dialog.dart';
import 'package:hollow/src/ui/dialogs/shard_bundle_dialog.dart';
import 'package:hollow/src/ui/shell/mobile_nav.dart';
import 'package:hollow/src/ui/mobile/mobile_imported_archive_viewer_route.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class MobileArchiveTab extends ConsumerWidget {
  const MobileArchiveTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final subTab = ref.watch(archiveSubTabProvider);
    final activeTab = ref.watch(mobileTabProvider);

    // Defer data loading until the Archive tab is actually visible.
    // The message store may not be open when the app first boots.
    if (activeTab != 2) {
      return const SizedBox.shrink();
    }

    return Column(
      children: [
        // ── Top header + sub-tab pills ──
        Container(
          padding: const EdgeInsets.fromLTRB(
            HollowSpacing.lg,
            HollowSpacing.md,
            HollowSpacing.lg,
            HollowSpacing.sm,
          ),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: hollow.border)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Archive',
                  style: HollowTypography.heading
                      .copyWith(color: hollow.textPrimary)),
              const SizedBox(height: HollowSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: _SubTabPill(
                      label: 'My Data',
                      isSelected: subTab == ArchiveSubTab.myData,
                      onTap: () => ref
                          .read(archiveSubTabProvider.notifier)
                          .state = ArchiveSubTab.myData,
                    ),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: _SubTabPill(
                      label: 'Imported',
                      isSelected:
                          subTab == ArchiveSubTab.importedArchives,
                      onTap: () => ref
                          .read(archiveSubTabProvider.notifier)
                          .state = ArchiveSubTab.importedArchives,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // ── Body ──
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: subTab == ArchiveSubTab.myData
                ? const _MobileMyDataView(
                    key: ValueKey('myData'))
                : const _MobileImportedArchivesView(
                    key: ValueKey('imported')),
          ),
        ),
      ],
    );
  }
}

// ── Sub-tab pill ───────────────────────────────────────────────

class _SubTabPill extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SubTabPill({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      padding: EdgeInsets.zero,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.lg,
          vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: isSelected ? hollow.accent : hollow.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? hollow.accent
                : hollow.border,
          ),
        ),
        child: Text(
          label,
          style: HollowTypography.body.copyWith(
            color: isSelected ? hollow.textOnAccent : hollow.textSecondary,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

// ── My Data view ───────────────────────────────────────────────

class _MobileMyDataView extends ConsumerStatefulWidget {
  const _MobileMyDataView({super.key});

  @override
  ConsumerState<_MobileMyDataView> createState() =>
      _MobileMyDataViewState();
}

class _MobileMyDataViewState extends ConsumerState<_MobileMyDataView> {
  bool _hiddenExpanded = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final innerTab = ref.watch(myDataInnerTabProvider);

    return Column(
      children: [
        // Inner pill tabs: DMs | Channels | Vault
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HollowSpacing.md,
            HollowSpacing.md,
            HollowSpacing.md,
            HollowSpacing.xs,
          ),
          child: Row(
            children: [
              Expanded(
                child: _InnerTabPill(
                  label: 'DMs',
                  isSelected: innerTab == MyDataInnerTab.dms,
                  onTap: () => ref
                      .read(myDataInnerTabProvider.notifier)
                      .state = MyDataInnerTab.dms,
                ),
              ),
              const SizedBox(width: HollowSpacing.xs),
              Expanded(
                child: _InnerTabPill(
                  label: 'Channels',
                  isSelected: innerTab == MyDataInnerTab.channels,
                  onTap: () => ref
                      .read(myDataInnerTabProvider.notifier)
                      .state = MyDataInnerTab.channels,
                ),
              ),
              const SizedBox(width: HollowSpacing.xs),
              Expanded(
                child: _InnerTabPill(
                  label: 'Vault',
                  isSelected: innerTab == MyDataInnerTab.vaultFiles,
                  onTap: () => ref
                      .read(myDataInnerTabProvider.notifier)
                      .state = MyDataInnerTab.vaultFiles,
                ),
              ),
            ],
          ),
        ),

        if (innerTab != MyDataInnerTab.vaultFiles) ...[
          // Search field
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.md,
              vertical: HollowSpacing.xs,
            ),
            child: HollowTextField(
              hintText: 'Search...',
              isDense: true,
              prefixIcon: Icon(LucideIcons.search,
                  size: 14, color: hollow.textSecondary),
              onChanged: (val) =>
                  ref.read(archiveSearchProvider.notifier).state = val,
            ),
          ),
          const SizedBox(height: HollowSpacing.xs),
        ],

        // Content list
        Expanded(
          child: switch (innerTab) {
            MyDataInnerTab.dms => _MobileDmList(
                hiddenExpanded: _hiddenExpanded,
                onToggleHidden: () =>
                    setState(() => _hiddenExpanded = !_hiddenExpanded),
              ),
            MyDataInnerTab.channels => const _MobileChannelList(),
            MyDataInnerTab.vaultFiles => const _MobileVaultFilesView(),
          },
        ),
      ],
    );
  }
}

class _InnerTabPill extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _InnerTabPill({
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
          color: isSelected
              ? hollow.accent.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          border: Border.all(
            color: isSelected
                ? hollow.accent.withValues(alpha: 0.3)
                : hollow.border,
          ),
        ),
        child: Text(
          label,
          style: HollowTypography.caption.copyWith(
            color: isSelected ? hollow.accent : hollow.textSecondary,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

// ── DM list ────────────────────────────────────────────────────

class _MobileDmList extends ConsumerWidget {
  final bool hiddenExpanded;
  final VoidCallback onToggleHidden;

  const _MobileDmList({
    required this.hiddenExpanded,
    required this.onToggleHidden,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final dmListAsync = ref.watch(archiveDmListProvider);
    final search = ref.watch(archiveSearchProvider).toLowerCase();
    final profiles = ref.watch(profileProvider);
    final hiddenSet = ref.watch(hiddenArchiveDmsProvider);

    return dmListAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('Failed to load: $e',
            style: TextStyle(color: hollow.error)),
      ),
      data: (entries) {
        // The self-DM renders as "Saved messages" — search should match that
        // label, not your own profile name.
        final savedId = ref.watch(savedMessagesPeerIdProvider);
        final filtered = search.isEmpty
            ? entries
            : entries.where((e) {
                final name = e.peerId == savedId
                    ? 'saved messages'
                    : displayNameFor(profiles, e.peerId).toLowerCase();
                return name.contains(search);
              }).toList();

        final visible =
            filtered.where((e) => !hiddenSet.contains(e.peerId)).toList();
        final hidden =
            filtered.where((e) => hiddenSet.contains(e.peerId)).toList();

        if (visible.isEmpty && hidden.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.messageSquare,
                    size: 40,
                    color:
                        hollow.textSecondary.withValues(alpha: 0.3)),
                const SizedBox(height: HollowSpacing.md),
                Text(
                  search.isEmpty
                      ? 'No DM conversations'
                      : 'No matches',
                  style: HollowTypography.body
                      .copyWith(color: hollow.textSecondary),
                ),
              ],
            ),
          );
        }

        return ListView(
          padding:
              const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
          children: [
            for (final entry in visible)
              _MobileDmRow(
                entry: entry,
                isHidden: false,
                onTap: () => _openDmViewer(context, ref, entry.peerId),
                onLongPress: () => _showDmSheet(
                    context, ref, entry, profiles, false),
                onToggleHidden: () => ref
                    .read(hiddenArchiveDmsProvider.notifier)
                    .hide(entry.peerId),
              ),
            if (hidden.isNotEmpty) ...[
              const SizedBox(height: HollowSpacing.sm),
              _HiddenHeader(
                count: hidden.length,
                expanded: hiddenExpanded,
                onTap: onToggleHidden,
              ),
              AnimatedSize(
                duration: HollowDurations.fast,
                curve: HollowCurves.subtle,
                alignment: Alignment.topCenter,
                child: hiddenExpanded
                    ? Column(
                        children: [
                          const SizedBox(height: HollowSpacing.xs),
                          for (final entry in hidden)
                            _MobileDmRow(
                              entry: entry,
                              isHidden: true,
                              onTap: () => _openDmViewer(
                                  context, ref, entry.peerId),
                              onLongPress: () => _showDmSheet(
                                  context, ref, entry, profiles, true),
                              onToggleHidden: () => ref
                                  .read(hiddenArchiveDmsProvider
                                      .notifier)
                                  .unhide(entry.peerId),
                            ),
                        ],
                      )
                    : const SizedBox(
                        width: double.infinity, height: 0),
              ),
            ],
          ],
        );
      },
    );
  }

  void _openDmViewer(
      BuildContext context, WidgetRef ref, String peerId) {
    ref.read(archiveSelectedDmProvider.notifier).state = peerId;
    ref.read(archiveSelectedChannelProvider.notifier).state = null;
    Navigator.of(context, rootNavigator: true)
        .push(hollowMobileRoute(
          builder: (_) =>
              MobileArchiveViewerRoute(peerId: peerId),
        ))
        .then((_) {
      ref.read(archiveSelectedDmProvider.notifier).state = null;
    });
  }

  void _showDmSheet(
    BuildContext context,
    WidgetRef ref,
    ArchiveDmEntry entry,
    Map<String, storage_api.UserProfile> profiles,
    bool isHidden,
  ) {
    final hollow = HollowTheme.of(context);
    // Export dialog title: the self-DM is "Saved messages", not your own name.
    final name = entry.peerId == ref.read(savedMessagesPeerIdProvider)
        ? 'Saved messages'
        : displayNameFor(profiles, entry.peerId);
    showModalBottomSheet(
      context: context,
      backgroundColor: hollow.surface,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: HollowSpacing.sm),
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: hollow.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
            HollowPressable(
              onTap: () {
                Navigator.pop(context);
                showExportArchiveDialog(
                  context,
                  isDm: true,
                  peerId: entry.peerId,
                  name: name,
                  messageCount: entry.messageCount,
                );
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg,
                  vertical: HollowSpacing.sm + 2,
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.fileOutput,
                        size: 18, color: hollow.textPrimary),
                    const SizedBox(width: HollowSpacing.md),
                    Text('Export Archive',
                        style: HollowTypography.body
                            .copyWith(color: hollow.textPrimary)),
                  ],
                ),
              ),
            ),
            HollowPressable(
              onTap: () {
                Navigator.pop(context);
                if (isHidden) {
                  ref
                      .read(hiddenArchiveDmsProvider.notifier)
                      .unhide(entry.peerId);
                } else {
                  ref
                      .read(hiddenArchiveDmsProvider.notifier)
                      .hide(entry.peerId);
                }
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg,
                  vertical: HollowSpacing.sm + 2,
                ),
                child: Row(
                  children: [
                    Icon(
                        isHidden
                            ? LucideIcons.eye
                            : LucideIcons.eyeOff,
                        size: 18,
                        color: hollow.textPrimary),
                    const SizedBox(width: HollowSpacing.md),
                    Text(isHidden ? 'Unhide' : 'Hide',
                        style: HollowTypography.body
                            .copyWith(color: hollow.textPrimary)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
          ],
        ),
      ),
    );
  }
}

class _MobileDmRow extends ConsumerWidget {
  final ArchiveDmEntry entry;
  final bool isHidden;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggleHidden;

  const _MobileDmRow({
    required this.entry,
    required this.isHidden,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleHidden,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    // Self-DM = Saved messages: bookmark avatar + fixed label instead of your
    // own profile name/picture. Row behavior (open/hide/export) is unchanged.
    final isSaved = entry.peerId == ref.watch(savedMessagesPeerIdProvider);
    final peerProfile =
        ref.watch(profileProvider.select((p) => p[entry.peerId]));
    final name =
        isSaved ? 'Saved messages' : displayNameForPeer(peerProfile, entry.peerId);

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: GestureDetector(
        onLongPress: onLongPress,
        child: HollowPressable(
          onTap: onTap,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm,
            vertical: HollowSpacing.sm,
          ),
          child: Row(
            children: [
              if (isSaved)
                const SavedMessagesAvatar(size: 32)
              else
                HollowAvatar(peerId: entry.peerId, size: 32),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  name,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              HollowPressable(
                onTap: onToggleHidden,
                semanticLabel: isHidden ? 'Show conversation' : 'Hide conversation',
                borderRadius:
                    BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(4),
                child: Icon(
                  isHidden ? LucideIcons.eye : LucideIcons.eyeOff,
                  size: 14,
                  color: hollow.textSecondary,
                ),
              ),
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: hollow.elevated,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${entry.messageCount}',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 11,
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
            child: Icon(LucideIcons.chevronRight,
                size: 14, color: hollow.textSecondary),
          ),
          const SizedBox(width: HollowSpacing.xs),
          Text(
            'Hidden',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontWeight: FontWeight.w700,
              fontSize: 11,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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

// ── Channel list ───────────────────────────────────────────────

class _MobileChannelList extends ConsumerWidget {
  const _MobileChannelList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final channelListAsync = ref.watch(archiveChannelListProvider);
    final search = ref.watch(archiveSearchProvider).toLowerCase();

    return channelListAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('Failed to load: $e',
            style: TextStyle(color: hollow.error)),
      ),
      data: (groups) {
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.hash,
                    size: 40,
                    color:
                        hollow.textSecondary.withValues(alpha: 0.3)),
                const SizedBox(height: HollowSpacing.md),
                Text(
                  search.isEmpty
                      ? 'No channel history'
                      : 'No matches',
                  style: HollowTypography.body
                      .copyWith(color: hollow.textSecondary),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding:
              const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];

            if (item.isHeader) {
              return GestureDetector(
                onLongPress: () {
                  final g = item.group!;
                  final totalMsgCount = g.channels
                      .fold<int>(0, (s, c) => s + c.messageCount);
                  _showServerExportSheet(context, g, totalMsgCount);
                },
                child: Padding(
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
                          item.headerName!.toUpperCase(),
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
                      HollowPressable(
                        onTap: () {
                          final g = item.group!;
                          final totalMsgCount = g.channels.fold<int>(
                              0, (s, c) => s + c.messageCount);
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
                        semanticLabel: 'Export conversation',
                        borderRadius:
                            BorderRadius.circular(hollow.radiusSm),
                        padding: const EdgeInsets.all(4),
                        child: Icon(LucideIcons.fileOutput,
                            size: 14, color: hollow.accent),
                      ),
                    ],
                  ),
                ),
              );
            }

            final ch = item.entry!;
            return _MobileChannelRow(
              entry: ch,
              onTap: () =>
                  _openChannelViewer(context, ref, ch),
              onLongPress: () =>
                  _showChannelExportSheet(context, ch),
            );
          },
        );
      },
    );
  }

  void _openChannelViewer(
      BuildContext context, WidgetRef ref, ArchiveChannelEntry ch) {
    final key = '${ch.serverId}:${ch.channelId}';
    ref.read(archiveSelectedChannelProvider.notifier).state = key;
    ref.read(archiveSelectedDmProvider.notifier).state = null;
    Navigator.of(context, rootNavigator: true)
        .push(hollowMobileRoute(
          builder: (_) => MobileArchiveViewerRoute(
            serverId: ch.serverId,
            channelId: ch.channelId,
          ),
        ))
        .then((_) {
      ref.read(archiveSelectedChannelProvider.notifier).state = null;
    });
  }

  void _showChannelExportSheet(
      BuildContext context, ArchiveChannelEntry ch) {
    final hollow = HollowTheme.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: hollow.surface,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: HollowSpacing.sm),
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: hollow.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
            HollowPressable(
              onTap: () {
                Navigator.pop(context);
                showExportArchiveDialog(
                  context,
                  isDm: false,
                  serverId: ch.serverId,
                  channelId: ch.channelId,
                  channelName: ch.channelName,
                  name: ch.channelName,
                  messageCount: ch.messageCount,
                );
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg,
                  vertical: HollowSpacing.sm + 2,
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.fileOutput,
                        size: 18, color: hollow.textPrimary),
                    const SizedBox(width: HollowSpacing.md),
                    Text('Export Channel Archive',
                        style: HollowTypography.body
                            .copyWith(color: hollow.textPrimary)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
          ],
        ),
      ),
    );
  }

  void _showServerExportSheet(BuildContext context,
      ArchiveChannelGroup group, int totalMsgCount) {
    final hollow = HollowTheme.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: hollow.surface,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: HollowSpacing.sm),
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: hollow.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
            HollowPressable(
              onTap: () {
                Navigator.pop(context);
                showExportArchiveDialog(
                  context,
                  isDm: false,
                  isServer: true,
                  serverId: group.serverId,
                  serverName: group.serverName,
                  channels: group.channels
                      .map((c) => {
                            'channel_id': c.channelId,
                            'channel_name': c.channelName,
                          })
                      .toList(),
                  name: group.serverName,
                  messageCount: totalMsgCount,
                );
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg,
                  vertical: HollowSpacing.sm + 2,
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.fileOutput,
                        size: 18, color: hollow.textPrimary),
                    const SizedBox(width: HollowSpacing.md),
                    Text('Export All Channels',
                        style: HollowTypography.body
                            .copyWith(color: hollow.textPrimary)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
          ],
        ),
      ),
    );
  }
}

class _MobileChannelRow extends StatelessWidget {
  final ArchiveChannelEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _MobileChannelRow({
    required this.entry,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: GestureDetector(
        onLongPress: onLongPress,
        child: HollowPressable(
          onTap: onTap,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm,
            vertical: HollowSpacing.sm,
          ),
          child: Row(
            children: [
              Text(
                '#',
                style: TextStyle(
                  color: hollow.textSecondary,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  entry.channelName,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: hollow.elevated,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${entry.messageCount}',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 11,
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

// ── Vault Files view ─────────────────────────────────────────

class _MobileVaultFilesView extends ConsumerWidget {
  const _MobileVaultFilesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final servers = ref.watch(serverListProvider);
    final pool = ref.watch(recoveryPoolProvider);

    if (servers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.hardDrive,
                size: 40,
                color: hollow.textSecondary.withValues(alpha: 0.3)),
            const SizedBox(height: HollowSpacing.md),
            Text('No servers',
                style: HollowTypography.body
                    .copyWith(color: hollow.textSecondary)),
            const SizedBox(height: HollowSpacing.xs),
            Text('Join a server to see vault files',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary.withValues(alpha: 0.6),
                  fontSize: 11,
                )),
          ],
        ),
      );
    }

    if (pool != null && pool.isActive && !pool.isPending) {
      return const RecoveryPoolDashboard();
    }

    return Column(
      children: [
        // Join Recovery Pool button
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HollowSpacing.md, HollowSpacing.sm, HollowSpacing.md, HollowSpacing.xs,
          ),
          child: HollowPressable(
            onTap: () => showJoinRecoveryPoolDialog(context),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: EdgeInsets.zero,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: hollow.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                border: Border.all(
                    color: hollow.accent.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(LucideIcons.logIn, size: 14, color: hollow.accent),
                  const SizedBox(width: HollowSpacing.sm),
                  Text('Join Recovery Pool',
                      style: HollowTypography.body.copyWith(
                        color: hollow.accent,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      )),
                ],
              ),
            ),
          ),
        ),
        // Server list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
            itemCount: servers.length,
            itemBuilder: (context, index) {
              final entry = servers.entries.elementAt(index);
              return _VaultServerSection(
                serverId: entry.key,
                serverName: entry.value.name,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _VaultServerSection extends ConsumerStatefulWidget {
  final String serverId;
  final String serverName;

  const _VaultServerSection({
    required this.serverId,
    required this.serverName,
  });

  @override
  ConsumerState<_VaultServerSection> createState() =>
      _VaultServerSectionState();
}

class _VaultServerSectionState extends ConsumerState<_VaultServerSection> {
  bool? _expanded;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final statusAsync = ref.watch(vaultFileStatusProvider(widget.serverId));

    if (_expanded == null && statusAsync.hasValue) {
      _expanded = statusAsync.value!.isNotEmpty;
    }
    final expanded = _expanded ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HollowPressable(
          onTap: () => setState(() => _expanded = !expanded),
          onLongPress: statusAsync.hasValue && statusAsync.value!.isNotEmpty
              ? () => _showVaultActionsSheet(context, statusAsync.value!)
              : null,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm,
            vertical: HollowSpacing.sm,
          ),
          child: Row(
            children: [
              Icon(
                expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                size: 16,
                color: hollow.textSecondary,
              ),
              const SizedBox(width: HollowSpacing.sm),
              Icon(LucideIcons.server, size: 16, color: hollow.accent),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  widget.serverName,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              statusAsync.when(
                data: (files) {
                  if (files.isEmpty) {
                    return Text('No vault files',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary, fontSize: 11));
                  }
                  final recoverable =
                      files.where((f) => f.isReconstructable).length;
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$recoverable/${files.length}',
                        style: HollowTypography.caption.copyWith(
                          color: recoverable == files.length
                              ? const Color(0xFF4CAF50)
                              : hollow.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.xs),
                      Icon(LucideIcons.ellipsisVertical,
                          size: 14, color: hollow.textSecondary),
                    ],
                  );
                },
                loading: () => const SizedBox(
                  width: 12, height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
                error: (_, _) => Text('Error',
                    style: HollowTypography.caption
                        .copyWith(color: hollow.error, fontSize: 11)),
              ),
            ],
          ),
        ),
        if (expanded)
          statusAsync.when(
            data: (files) {
              if (files.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.only(
                    left: HollowSpacing.xl, bottom: HollowSpacing.md),
                  child: Text('No erasure-coded files.',
                      style: HollowTypography.caption
                          .copyWith(color: hollow.textSecondary, fontSize: 12)),
                );
              }
              final sorted = List.of(files)
                ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
              return Padding(
                padding: const EdgeInsets.only(
                    left: HollowSpacing.sm, bottom: HollowSpacing.sm),
                child: Column(
                  children: [
                    for (final file in sorted)
                      _VaultFileRow(file: file),
                  ],
                ),
              );
            },
            loading: () => const Padding(
              padding: EdgeInsets.all(HollowSpacing.md),
              child: Center(child: SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(HollowSpacing.sm),
              child: Text('Failed to load: $e',
                  style: HollowTypography.caption
                      .copyWith(color: hollow.error, fontSize: 12)),
            ),
          ),
      ],
    );
  }

  void _showVaultActionsSheet(BuildContext context, List<VaultFileStatus> files) {
    final hollow = HollowTheme.of(context);
    final totalShards = files.fold<int>(0, (sum, f) => sum + f.localShardCount);

    showModalBottomSheet(
      context: context,
      backgroundColor: hollow.surface,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: HollowSpacing.sm),
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: hollow.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
            HollowPressable(
              onTap: () {
                Navigator.pop(context);
                showExportShardsDialog(
                  context,
                  serverId: widget.serverId,
                  serverName: widget.serverName,
                  shardCount: totalShards,
                );
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg,
                  vertical: HollowSpacing.sm + 2,
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.download,
                        size: 18, color: hollow.textPrimary),
                    const SizedBox(width: HollowSpacing.md),
                    Text('Export Shards',
                        style: HollowTypography.body
                            .copyWith(color: hollow.textPrimary)),
                  ],
                ),
              ),
            ),
            HollowPressable(
              onTap: () {
                Navigator.pop(context);
                showImportShardsDialog(
                  context,
                  onImported: () => ref.invalidate(
                      vaultFileStatusProvider(widget.serverId)),
                );
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg,
                  vertical: HollowSpacing.sm + 2,
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.upload,
                        size: 18, color: hollow.textPrimary),
                    const SizedBox(width: HollowSpacing.md),
                    Text('Import Shards',
                        style: HollowTypography.body
                            .copyWith(color: hollow.textPrimary)),
                  ],
                ),
              ),
            ),
            HollowPressable(
              onTap: () {
                Navigator.pop(context);
                showInitiateRecoveryPoolDialog(
                  context,
                  serverId: widget.serverId,
                  serverName: widget.serverName,
                );
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg,
                  vertical: HollowSpacing.sm + 2,
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.shield,
                        size: 18, color: hollow.textPrimary),
                    const SizedBox(width: HollowSpacing.md),
                    Text('Start Recovery Pool',
                        style: HollowTypography.body
                            .copyWith(color: hollow.textPrimary)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
          ],
        ),
      ),
    );
  }
}

class _VaultFileRow extends StatelessWidget {
  final VaultFileStatus file;

  const _VaultFileRow({required this.file});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final shardText = '${file.localShardCount}/${file.k}';
    final Color badgeColor;
    final Color badgeBg;
    if (file.isReconstructable) {
      badgeColor = const Color(0xFF4CAF50);
      badgeBg = const Color(0xFF4CAF50).withValues(alpha: 0.12);
    } else if (file.localShardCount > 0) {
      badgeColor = const Color(0xFFFFA726);
      badgeBg = const Color(0xFFFFA726).withValues(alpha: 0.12);
    } else {
      badgeColor = hollow.textSecondary;
      badgeBg = hollow.textSecondary.withValues(alpha: 0.08);
    }
    final progress = file.k > 0 ? file.localShardCount / file.k : 0.0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Container(
        padding: const EdgeInsets.all(HollowSpacing.sm),
        decoration: BoxDecoration(
          color: hollow.surface,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          border: Border.all(color: hollow.border),
        ),
        child: Row(
          children: [
            Icon(_iconForFile(file.fileName),
                size: 18, color: hollow.accent),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(file.fileName,
                      style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary,
                        fontSize: 13, fontWeight: FontWeight.w500),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(_formatSize(file.originalSize),
                          style: HollowTypography.caption.copyWith(
                            color: hollow.textSecondary, fontSize: 11)),
                      const SizedBox(width: HollowSpacing.sm),
                      Expanded(
                        child: SizedBox(
                          height: 3,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: progress.clamp(0.0, 1.0),
                              backgroundColor: hollow.border,
                              valueColor: AlwaysStoppedAnimation(badgeColor),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: badgeBg,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
              ),
              child: Text(shardText,
                  style: HollowTypography.caption.copyWith(
                    color: badgeColor,
                    fontSize: 11, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconForFile(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return switch (ext) {
      'mp4' || 'webm' || 'mov' || 'mkv' || 'avi' => LucideIcons.fileVideo,
      'mp3' || 'ogg' || 'wav' || 'flac' || 'm4a' => LucideIcons.fileAudio,
      'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' => LucideIcons.image,
      'pdf' || 'doc' || 'docx' || 'txt' || 'md' => LucideIcons.fileText,
      'zip' || 'rar' || '7z' || 'tar' => LucideIcons.fileArchive,
      _ => LucideIcons.file,
    };
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

// ── Imported archives view ─────────────────────────────────────

class _MobileImportedArchivesView extends ConsumerStatefulWidget {
  const _MobileImportedArchivesView({super.key});

  @override
  ConsumerState<_MobileImportedArchivesView> createState() =>
      _MobileImportedArchivesViewState();
}

class _MobileImportedArchivesViewState
    extends ConsumerState<_MobileImportedArchivesView> {
  Future<void> _pickArchive() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['hollow-archive'],
      dialogTitle: 'Load .hollow-archive',
    );
    if (result != null && result.files.isNotEmpty) {
      final path = result.files.first.path;
      if (path != null) {
        await _loadArchive(path);
      }
    }
  }

  Future<void> _loadArchive(String path) async {
    try {
      await archive_api.verifyArchive(archivePath: path);
      await ref
          .read(importedArchivePathsProvider.notifier)
          .addPath(path);
      ref.invalidate(importedArchiveVerifyProvider(path));
      if (mounted) {
        HollowToast.show(context, 'Archive loaded',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to load: $e',
            type: HollowToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final pathsAsync = ref.watch(importedArchivePathsProvider);

    return Column(
      children: [
        // Load button
        Padding(
          padding: const EdgeInsets.all(HollowSpacing.md),
          child: HollowPressable(
            onTap: _pickArchive,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: EdgeInsets.zero,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: hollow.accent.withValues(alpha: 0.12),
                borderRadius:
                    BorderRadius.circular(hollow.radiusSm),
                border: Border.all(
                    color: hollow.accent.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(LucideIcons.folderOpen,
                      size: 16, color: hollow.accent),
                  const SizedBox(width: HollowSpacing.sm),
                  Text(
                    'Load Archive',
                    style: HollowTypography.body.copyWith(
                      color: hollow.accent,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Archive list
        Expanded(
          child: pathsAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Text('Error: $e',
                  style: TextStyle(color: hollow.error)),
            ),
            data: (paths) {
              if (paths.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.fileArchive,
                          size: 40,
                          color: hollow.textSecondary
                              .withValues(alpha: 0.3)),
                      const SizedBox(height: HollowSpacing.md),
                      Text('No imported archives',
                          style: HollowTypography.body.copyWith(
                              color: hollow.textSecondary)),
                      const SizedBox(height: HollowSpacing.xs),
                      Text('Tap Load Archive above',
                          style: HollowTypography.caption.copyWith(
                            color: hollow.textSecondary
                                .withValues(alpha: 0.6),
                            fontSize: 11,
                          )),
                    ],
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.sm),
                itemCount: paths.length,
                itemBuilder: (context, index) {
                  return _MobileArchiveEntryCard(
                    path: paths[index],
                    onTap: () => _openArchiveViewer(
                        context, paths[index]),
                    onLongPress: () =>
                        _showRemoveSheet(context, paths[index]),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  void _openArchiveViewer(BuildContext context, String path) {
    ref.read(selectedImportedArchiveProvider.notifier).state = path;
    Navigator.of(context, rootNavigator: true)
        .push(hollowMobileRoute(
          builder: (_) =>
              MobileImportedArchiveViewerRoute(path: path),
        ))
        .then((_) {
      ref.read(selectedImportedArchiveProvider.notifier).state = null;
    });
  }

  void _showRemoveSheet(BuildContext context, String path) {
    final hollow = HollowTheme.of(context);
    final fileName = path.split(Platform.pathSeparator).last;
    showModalBottomSheet(
      context: context,
      backgroundColor: hollow.surface,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: HollowSpacing.sm),
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: hollow.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg),
              child: Text(fileName,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(height: HollowSpacing.sm),
            HollowPressable(
              onTap: () {
                Navigator.pop(context);
                ref
                    .read(importedArchivePathsProvider.notifier)
                    .removePath(path);
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg,
                  vertical: HollowSpacing.sm + 2,
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.trash2,
                        size: 18, color: hollow.error),
                    const SizedBox(width: HollowSpacing.md),
                    Text('Remove from List',
                        style: HollowTypography.body
                            .copyWith(color: hollow.error)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
          ],
        ),
      ),
    );
  }
}

class _MobileArchiveEntryCard extends ConsumerWidget {
  final String path;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _MobileArchiveEntryCard({
    required this.path,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final verifyAsync = ref.watch(importedArchiveVerifyProvider(path));
    final fileName = path.split(Platform.pathSeparator).last;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: GestureDetector(
        onLongPress: onLongPress,
        child: HollowPressable(
          onTap: onTap,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm,
            vertical: HollowSpacing.sm,
          ),
          child: verifyAsync.when(
            loading: () => Row(
              children: [
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Text(fileName,
                      style: HollowTypography.body.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            error: (e, _) => Row(
              children: [
                Icon(LucideIcons.alertCircle,
                    size: 16, color: hollow.error),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Text(fileName,
                      style: HollowTypography.body.copyWith(
                        color: hollow.error,
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            data: (result) {
              final isValid = result.archiveSignatureValid &&
                  result.messagesWithInvalidSig == 0;
              final hasWarning =
                  result.messagesWithInvalidSig > 0;

              final icon = isValid
                  ? Icon(LucideIcons.shieldCheck,
                      size: 16, color: hollow.accent)
                  : hasWarning
                      ? Icon(LucideIcons.alertTriangle,
                          size: 16,
                          color: Colors.amber.shade600)
                      : Icon(LucideIcons.shieldOff,
                          size: 16, color: hollow.error);

              final typeIcon = result.archiveType == 'dm'
                  ? LucideIcons.messageSquare
                  : result.archiveType == 'server'
                      ? LucideIcons.server
                      : LucideIcons.hash;

              final peerProfile = ref.watch(
                  profileProvider.select((p) =>
                      result.peerId != null
                          ? p[result.peerId!]
                          : null));
              final servers = ref.watch(serverListProvider);
              String name;
              String? detail;
              if (result.archiveType == 'dm') {
                name = result.peerId != null
                    ? displayNameForPeer(
                        peerProfile, result.peerId!)
                    : 'DM';
              } else if (result.archiveType == 'server') {
                name = result.serverName ?? 'Server';
                detail = '${result.channels.length} channels';
              } else {
                name = result.channelName ??
                    result.channelId ??
                    'Channel';
                if (result.serverId != null &&
                    servers.containsKey(result.serverId)) {
                  detail = servers[result.serverId]?.name;
                }
              }

              final exportDate =
                  DateTime.fromMillisecondsSinceEpoch(
                      result.exportTimestamp);
              final dateStr =
                  '${exportDate.year}-${exportDate.month.toString().padLeft(2, '0')}-${exportDate.day.toString().padLeft(2, '0')}';

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(typeIcon,
                          size: 14, color: hollow.textSecondary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(name,
                            style: HollowTypography.body.copyWith(
                              color: hollow.textPrimary,
                              fontWeight: FontWeight.w500,
                              fontSize: 14,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      icon,
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const SizedBox(width: 20),
                      if (detail != null) ...[
                        Text(detail,
                            style:
                                HollowTypography.caption.copyWith(
                              color: hollow.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            )),
                        Text('  ·  ',
                            style:
                                HollowTypography.caption.copyWith(
                              color: hollow.textSecondary
                                  .withValues(alpha: 0.4),
                              fontSize: 11,
                            )),
                      ],
                      Text('${result.messageCount} msgs',
                          style:
                              HollowTypography.caption.copyWith(
                            color: hollow.textSecondary,
                            fontSize: 11,
                          )),
                      const SizedBox(width: HollowSpacing.sm),
                      Text(dateStr,
                          style:
                              HollowTypography.caption.copyWith(
                            color: hollow.textSecondary
                                .withValues(alpha: 0.6),
                            fontSize: 11,
                          )),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
