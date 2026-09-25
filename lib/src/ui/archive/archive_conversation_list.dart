import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/archive_conversation.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/hidden_archive_dm_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/saved_messages_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/saved_messages_avatar.dart';
import 'package:hollow/src/ui/dialogs/export_archive_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Everything this device keeps, in the sidebar's order: direct messages, then
/// each server's channels. One list, one search.
class ArchiveConversationList extends ConsumerStatefulWidget {
  const ArchiveConversationList({super.key});

  @override
  ConsumerState<ArchiveConversationList> createState() =>
      _ArchiveConversationListState();
}

class _ArchiveConversationListState
    extends ConsumerState<ArchiveConversationList> {
  bool _hiddenExpanded = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final dmsAsync = ref.watch(archiveDmListProvider);
    final channelsAsync = ref.watch(archiveChannelListProvider);
    final search = ref.watch(archiveSearchProvider).trim().toLowerCase();

    final field = Padding(
      padding: const EdgeInsets.all(HollowSpacing.md),
      child: HollowTextField(
        hintText: 'Search conversations',
        isDense: true,
        prefixIcon:
            Icon(LucideIcons.search, size: 14, color: hollow.textSecondary),
        onChanged: (val) => ref.read(archiveSearchProvider.notifier).state = val,
      ),
    );

    if (dmsAsync.isLoading || channelsAsync.isLoading) {
      return Column(children: [
        field,
        const Expanded(child: Center(child: HollowSpinner.medium())),
      ]);
    }
    if (dmsAsync.hasError || channelsAsync.hasError) {
      return Column(children: [
        field,
        Expanded(
          child: HollowEmptyState(
            title: "Your conversations didn't load",
            action: HollowButton.ghost(
              compact: true,
              onPressed: () {
                ref.invalidate(archiveDmListProvider);
                ref.invalidate(archiveChannelListProvider);
              },
              child: const Text('Try again'),
            ),
          ),
        ),
      ]);
    }

    final profiles = ref.watch(profileProvider);
    final savedId = ref.watch(savedMessagesPeerIdProvider);
    final hiddenSet = ref.watch(hiddenArchiveDmsProvider);

    // The self-DM renders as "Saved messages", so search matches that label
    // rather than your own profile name.
    String dmName(String peerId) => peerId == savedId
        ? 'Saved messages'
        : displayNameFor(profiles, peerId);

    final dms = [
      for (final e in dmsAsync.value ?? const <ArchiveDmEntry>[])
        if (search.isEmpty || dmName(e.peerId).toLowerCase().contains(search))
          e,
    ];
    final visible = dms.where((e) => !hiddenSet.contains(e.peerId)).toList();
    final hidden = dms.where((e) => hiddenSet.contains(e.peerId)).toList();

    final groups = <(ArchiveChannelGroup, List<ArchiveChannelEntry>)>[
      for (final g in channelsAsync.value ?? const <ArchiveChannelGroup>[])
        (
          g,
          [
            for (final ch in g.channels)
              if (search.isEmpty ||
                  ch.channelName.toLowerCase().contains(search) ||
                  ch.serverName.toLowerCase().contains(search))
                ch,
          ]
        ),
    ].where((g) => g.$2.isNotEmpty).toList();

    if (dms.isEmpty && groups.isEmpty) {
      return Column(children: [
        field,
        Expanded(
          child: search.isEmpty
              ? const HollowEmptyState(
                  title: 'No conversations yet',
                  description: 'Direct messages and channel history you keep '
                      'on this device show up here.',
                )
              : const HollowEmptyState(title: 'No matches'),
        ),
      ]);
    }

    return Column(
      children: [
        field,
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
                HollowSpacing.sm, 0, HollowSpacing.sm, HollowSpacing.lg),
            children: [
              if (dms.isNotEmpty) ...[
                const _GroupLabel('Direct messages'),
                for (final e in visible)
                  _DmRow(entry: e, name: dmName(e.peerId), isSaved: e.peerId == savedId),
                if (hidden.isNotEmpty) ...[
                  _HiddenToggle(
                    count: hidden.length,
                    expanded: _hiddenExpanded,
                    onTap: () =>
                        setState(() => _hiddenExpanded = !_hiddenExpanded),
                  ),
                  if (_hiddenExpanded || search.isNotEmpty)
                    for (final e in hidden)
                      _DmRow(
                          entry: e,
                          name: dmName(e.peerId),
                          isSaved: e.peerId == savedId,
                          hidden: true),
                ],
              ],
              for (final (group, channels) in groups) ...[
                _GroupLabel(group.serverName, action: _exportServer(group)),
                for (final ch in channels) _ChannelRow(entry: ch),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _exportServer(ArchiveChannelGroup g) {
    return HollowIconButton(
      icon: LucideIcons.fileOutput,
      label: 'Export ${g.serverName}',
      size: 24,
      onPressed: () => showExportArchiveDialog(
        context,
        isDm: false,
        isServer: true,
        serverId: g.serverId,
        serverName: g.serverName,
        channels: [
          for (final c in g.channels)
            {'channel_id': c.channelId, 'channel_name': c.channelName},
        ],
        name: g.serverName,
        messageCount: g.channels.fold<int>(0, (s, c) => s + c.messageCount),
      ),
    );
  }
}

/// A group's name above its rows, its text on the rows' text edge.
class _GroupLabel extends StatelessWidget {
  final String title;
  final Widget? action;
  const _GroupLabel(this.title, {this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          HollowSpacing.md, HollowSpacing.md, HollowSpacing.xs, 0),
      child: HollowSectionHeader(title, dense: true, action: action),
    );
  }
}

/// How many messages a conversation holds, quiet at the row's end.
Widget _count(HollowTheme hollow, int n) => Text(
      '$n',
      style: HollowTypography.caption.copyWith(
        color: hollow.textTertiary,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );

class _DmRow extends ConsumerWidget {
  final ArchiveDmEntry entry;
  final String name;
  final bool isSaved;
  final bool hidden;

  const _DmRow({
    required this.entry,
    required this.name,
    required this.isSaved,
    this.hidden = false,
  });

  void _open(WidgetRef ref) =>
      selectArchiveConversation(ref.read, dm: entry.peerId);

  void _menu(BuildContext context, WidgetRef ref, Offset anchor) {
    final hiddenDms = ref.read(hiddenArchiveDmsProvider.notifier);
    showHollowMenu(
      context: context,
      anchor: anchor,
      builder: (_, _) => [
        HollowMenuItem(
          icon: LucideIcons.fileOutput,
          label: 'Export conversation',
          onTap: () => showExportArchiveDialog(
            context,
            isDm: true,
            peerId: entry.peerId,
            name: name,
            messageCount: entry.messageCount,
          ),
        ),
        HollowMenuItem(
          icon: hidden ? LucideIcons.eye : LucideIcons.eyeOff,
          label: hidden ? 'Show in the list' : 'Hide from the list',
          onTap: () => hidden
              ? hiddenDms.unhide(entry.peerId)
              : hiddenDms.hide(entry.peerId),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final selected =
        ref.watch(archiveSelectedDmProvider.select((id) => id == entry.peerId));
    return ContextMenuTarget(
      semanticLabel: 'Conversation actions',
      onOpen: (anchor) => _menu(context, ref, anchor),
      child: HollowListRow(
        title: name,
        selected: selected,
        leading: isSaved
            ? const SavedMessagesAvatar(size: 24)
            : HollowAvatar(peerId: entry.peerId, size: 24),
        trailing: _count(hollow, entry.messageCount),
        onTap: () => _open(ref),
      ),
    );
  }
}

class _HiddenToggle extends StatelessWidget {
  final int count;
  final bool expanded;
  final VoidCallback onTap;

  const _HiddenToggle({
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: onTap,
      subtle: true,
      semanticLabel: expanded
          ? 'Hide the $count hidden conversations'
          : 'Show the $count hidden conversations',
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md, vertical: HollowSpacing.sm),
      child: Row(
        children: [
          Icon(expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
              size: 14, color: hollow.textTertiary),
          const SizedBox(width: HollowSpacing.xs),
          Text('Hidden',
              style:
                  HollowTypography.label.copyWith(color: hollow.textSecondary)),
          const Spacer(),
          _count(hollow, count),
        ],
      ),
    );
  }
}

class _ChannelRow extends ConsumerWidget {
  final ArchiveChannelEntry entry;
  const _ChannelRow({required this.entry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final key = '${entry.serverId}:${entry.channelId}';
    final selected =
        ref.watch(archiveSelectedChannelProvider.select((k) => k == key));
    return HollowListRow(
      title: entry.channelName,
      selected: selected,
      // The avatar column's width, so channel names line up with DM names.
      leading: SizedBox.square(
        dimension: 24,
        child: Icon(LucideIcons.hash,
            size: 16,
            color: selected ? hollow.accentText : hollow.textTertiary),
      ),
      trailing: _count(hollow, entry.messageCount),
      onTap: () => selectArchiveConversation(ref.read, channel: key),
    );
  }
}
