import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/archive_conversation.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/hidden_archive_dm_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/recovery_pool_provider.dart';
import 'package:hollow/src/core/providers/saved_messages_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/vault_file_status_provider.dart';
import 'package:hollow/src/core/time_labels.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/archive/imported_archives_view.dart'
    show importedArchiveBusyProvider, pickAndLoadImportedArchive;
import 'package:hollow/src/ui/archive/recovery_pool_dashboard.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/saved_messages_avatar.dart';
import 'package:hollow/src/ui/dialogs/export_archive_dialog.dart';
import 'package:hollow/src/ui/dialogs/recovery_pool_dialog.dart';
import 'package:hollow/src/ui/dialogs/shard_bundle_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_archive_viewer_route.dart';
import 'package:hollow/src/ui/mobile/mobile_imported_archive_viewer_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/share/share_card.dart' show ShareCard;
import 'package:hollow/src/ui/shell/mobile_nav.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The phone's Archive: the desktop place's three views at touch size.
class MobileArchiveTab extends ConsumerWidget {
  const MobileArchiveTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final section = ref.watch(archiveSectionProvider);

    // Deferred until the tab is visible: the message store may not be open
    // when the app first boots.
    if (ref.watch(mobileTabProvider) != 2) return const SizedBox.shrink();

    void show(ArchiveSection s) =>
        ref.read(archiveSectionProvider.notifier).state = s;
    Widget chip(String label, ArchiveSection s) => Expanded(
          child: HollowChip(
            expand: true,
            label: label,
            selected: section == s,
            onTap: () => show(s),
          ),
        );

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(HollowSpacing.lg,
              HollowSpacing.md, HollowSpacing.lg, HollowSpacing.sm),
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
                  chip('Messages', ArchiveSection.messages),
                  const SizedBox(width: HollowSpacing.sm),
                  chip('Vault files', ArchiveSection.vault),
                  const SizedBox(width: HollowSpacing.sm),
                  chip('Imported', ArchiveSection.imported),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: switch (section) {
            ArchiveSection.messages => const _MobileMessagesView(),
            ArchiveSection.vault => const _MobileVaultView(),
            ArchiveSection.imported => const _MobileImportedView(),
          },
        ),
      ],
    );
  }
}

/// One action in a row's long-press sheet.
typedef _SheetAction = ({IconData icon, String label, VoidCallback onTap});

void _showRowActions(BuildContext context, List<_SheetAction> actions) {
  final hollow = HollowTheme.of(context);
  showHollowSheet(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final a in actions)
            HollowListRow(
              touch: true,
              title: a.label,
              leading: Icon(a.icon, size: 20, color: hollow.textSecondary),
              onTap: () {
                Navigator.pop(sheetContext);
                a.onTap();
              },
            ),
          const SizedBox(height: HollowSpacing.sm),
        ],
      ),
    ),
  );
}

/// How many messages a conversation holds, quiet at the row's end.
Widget _count(HollowTheme hollow, int n) => Text(
      '$n',
      style: HollowTypography.caption.copyWith(
        color: hollow.textTertiary,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );

/// A group's name above its rows, on the rows' leading edge.
class _GroupLabel extends StatelessWidget {
  final String title;
  final Widget? action;
  const _GroupLabel(this.title, {this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(HollowSpacing.lg, HollowSpacing.lg,
          action == null ? HollowSpacing.lg : HollowSpacing.xs, 0),
      child: HollowSectionHeader(title, dense: true, action: action),
    );
  }
}

class _MobileMessagesView extends ConsumerStatefulWidget {
  const _MobileMessagesView();

  @override
  ConsumerState<_MobileMessagesView> createState() =>
      _MobileMessagesViewState();
}

class _MobileMessagesViewState extends ConsumerState<_MobileMessagesView> {
  bool _hiddenExpanded = false;

  void _openDm(String peerId) {
    selectArchiveConversation(ref.read, dm: peerId);
    Navigator.of(context, rootNavigator: true)
        .push(hollowMobileRoute(
          builder: (_) => MobileArchiveViewerRoute(peerId: peerId),
        ))
        .then((_) {
      if (mounted) selectArchiveConversation(ref.read);
    });
  }

  void _openChannel(ArchiveChannelEntry ch) {
    selectArchiveConversation(ref.read,
        channel: '${ch.serverId}:${ch.channelId}');
    Navigator.of(context, rootNavigator: true)
        .push(hollowMobileRoute(
          builder: (_) => MobileArchiveViewerRoute(
            serverId: ch.serverId,
            channelId: ch.channelId,
          ),
        ))
        .then((_) {
      if (mounted) selectArchiveConversation(ref.read);
    });
  }

  void _dmActions(ArchiveDmEntry entry, String name, bool hidden) {
    final hiddenDms = ref.read(hiddenArchiveDmsProvider.notifier);
    _showRowActions(context, [
      (
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
      (
        icon: hidden ? LucideIcons.eye : LucideIcons.eyeOff,
        label: hidden ? 'Show in the list' : 'Hide from the list',
        onTap: () => hidden
            ? hiddenDms.unhide(entry.peerId)
            : hiddenDms.hide(entry.peerId),
      ),
    ]);
  }

  void _channelActions(ArchiveChannelEntry ch) {
    _showRowActions(context, [
      (
        icon: LucideIcons.fileOutput,
        label: 'Export channel',
        onTap: () => showExportArchiveDialog(
              context,
              isDm: false,
              serverId: ch.serverId,
              channelId: ch.channelId,
              channelName: ch.channelName,
              name: ch.channelName,
              messageCount: ch.messageCount,
            ),
      ),
    ]);
  }

  Widget _exportServer(ArchiveChannelGroup g) {
    return HollowIconButton(
      icon: LucideIcons.fileOutput,
      label: 'Export ${g.serverName}',
      size: 44,
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

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final dmsAsync = ref.watch(archiveDmListProvider);
    final channelsAsync = ref.watch(archiveChannelListProvider);
    final search = ref.watch(archiveSearchProvider).trim().toLowerCase();

    final field = Padding(
      padding: const EdgeInsets.fromLTRB(
          HollowSpacing.lg, HollowSpacing.md, HollowSpacing.lg, 0),
      child: HollowTextField(
        hintText: 'Search conversations',
        isDense: true,
        prefixIcon:
            Icon(LucideIcons.search, size: 16, color: hollow.textSecondary),
        onChanged: (val) => ref.read(archiveSearchProvider.notifier).state = val,
      ),
    );

    Widget body;
    if (dmsAsync.isLoading || channelsAsync.isLoading) {
      body = const Center(child: HollowSpinner.medium());
    } else if (dmsAsync.hasError || channelsAsync.hasError) {
      body = HollowEmptyState(
        title: "Your conversations didn't load",
        action: HollowButton.ghost(
          touch: true,
          onPressed: () {
            ref.invalidate(archiveDmListProvider);
            ref.invalidate(archiveChannelListProvider);
          },
          child: const Text('Try again'),
        ),
      );
    } else {
      body = _list(hollow, dmsAsync.value!, channelsAsync.value!, search);
    }

    return Column(children: [field, Expanded(child: body)]);
  }

  Widget _list(HollowTheme hollow, List<ArchiveDmEntry> allDms,
      List<ArchiveChannelGroup> allGroups, String search) {
    final profiles = ref.watch(profileProvider);
    final savedId = ref.watch(savedMessagesPeerIdProvider);
    final hiddenSet = ref.watch(hiddenArchiveDmsProvider);

    // The self-DM renders as "Saved messages", so search matches that label
    // rather than your own profile name.
    String dmName(String peerId) => peerId == savedId
        ? 'Saved messages'
        : displayNameFor(profiles, peerId);

    final dms = [
      for (final e in allDms)
        if (search.isEmpty || dmName(e.peerId).toLowerCase().contains(search))
          e,
    ];
    final visible = dms.where((e) => !hiddenSet.contains(e.peerId)).toList();
    final hidden = dms.where((e) => hiddenSet.contains(e.peerId)).toList();
    final groups = [
      for (final g in allGroups)
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
      return search.isEmpty
          ? const HollowEmptyState(
              title: 'No conversations yet',
              description: 'Direct messages and channel history you keep on '
                  'this device show up here.',
            )
          : const HollowEmptyState(title: 'No matches');
    }

    Widget dmRow(ArchiveDmEntry e, {bool isHidden = false}) {
      final name = dmName(e.peerId);
      return HollowListRow(
        key: ValueKey('dm:${e.peerId}'),
        touch: true,
        title: name,
        leading: e.peerId == savedId
            ? const SavedMessagesAvatar(size: 32)
            : HollowAvatar(peerId: e.peerId, size: 32),
        trailing: _count(hollow, e.messageCount),
        onTap: () => _openDm(e.peerId),
        onLongPress: () => _dmActions(e, name, isHidden),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: HollowSpacing.lg),
      children: [
        if (dms.isNotEmpty) ...[
          const _GroupLabel('Direct messages'),
          for (final e in visible) dmRow(e),
          if (hidden.isNotEmpty) ...[
            HollowListRow(
              touch: true,
              title: 'Hidden',
              semanticLabel: _hiddenExpanded
                  ? 'Hide the ${hidden.length} hidden conversations'
                  : 'Show the ${hidden.length} hidden conversations',
              leading: SizedBox.square(
                dimension: 32,
                child: Icon(
                    _hiddenExpanded
                        ? LucideIcons.chevronDown
                        : LucideIcons.chevronRight,
                    size: 16,
                    color: hollow.textTertiary),
              ),
              trailing: _count(hollow, hidden.length),
              onTap: () => setState(() => _hiddenExpanded = !_hiddenExpanded),
            ),
            if (_hiddenExpanded || search.isNotEmpty)
              for (final e in hidden) dmRow(e, isHidden: true),
          ],
        ],
        for (final (group, channels) in groups) ...[
          _GroupLabel(group.serverName, action: _exportServer(group)),
          for (final ch in channels)
            HollowListRow(
              key: ValueKey('ch:${ch.serverId}:${ch.channelId}'),
              touch: true,
              title: ch.channelName,
              // The avatar column's width, so channel names line up with
              // DM names.
              leading: SizedBox.square(
                dimension: 32,
                child: Icon(LucideIcons.hash,
                    size: 20, color: hollow.textTertiary),
              ),
              trailing: _count(hollow, ch.messageCount),
              onTap: () => _openChannel(ch),
              onLongPress: () => _channelActions(ch),
            ),
        ],
      ],
    );
  }
}

/// Vault files at touch size: each server opens to its files and the three
/// shard actions.
class _MobileVaultView extends ConsumerWidget {
  const _MobileVaultView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(serverListProvider);
    final pool = ref.watch(recoveryPoolProvider);

    if (pool != null && pool.isActive && !pool.isPending) {
      return const RecoveryPoolDashboard();
    }
    if (servers.isEmpty) {
      return const HollowEmptyState(
        glyph: LucideIcons.hardDrive,
        title: 'No vault files yet',
        description: 'A server keeps its large files as shards across its '
            'members. Join one and its files show up here.',
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: HollowSpacing.lg),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(HollowSpacing.lg,
              HollowSpacing.md, HollowSpacing.lg, HollowSpacing.xs),
          child: Align(
            alignment: Alignment.centerLeft,
            child: HollowButton.ghost(
              touch: true,
              icon: const Icon(LucideIcons.logIn, size: 16),
              onPressed: () => showJoinRecoveryPoolDialog(context),
              child: const Text('Join a recovery pool'),
            ),
          ),
        ),
        for (final entry in servers.entries)
          _MobileVaultServer(
            key: ValueKey(entry.key),
            serverId: entry.key,
            serverName: entry.value.name,
          ),
      ],
    );
  }
}

class _MobileVaultServer extends ConsumerStatefulWidget {
  final String serverId;
  final String serverName;

  const _MobileVaultServer({
    super.key,
    required this.serverId,
    required this.serverName,
  });

  @override
  ConsumerState<_MobileVaultServer> createState() => _MobileVaultServerState();
}

class _MobileVaultServerState extends ConsumerState<_MobileVaultServer> {
  bool? _expanded;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final statusAsync = ref.watch(vaultFileStatusProvider(widget.serverId));

    // Set once, then the user's toggle takes over.
    if (_expanded == null && statusAsync.hasValue) {
      _expanded = statusAsync.value!.isNotEmpty;
    }
    final expanded = _expanded ?? false;

    final Widget status = statusAsync.when(
      loading: () => const HollowSpinner(),
      error: (_, _) => Text("Didn't load",
          style: HollowTypography.caption.copyWith(color: hollow.error)),
      data: (files) {
        if (files.isEmpty) {
          return Text('No vault files',
              style:
                  HollowTypography.caption.copyWith(color: hollow.textTertiary));
        }
        final recoverable = files.where((f) => f.isReconstructable).length;
        return Text(
          '$recoverable of ${files.length} recoverable',
          style: HollowTypography.caption.copyWith(
            color: recoverable == files.length
                ? hollow.success
                : hollow.textSecondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HollowListRow(
          touch: true,
          title: widget.serverName,
          semanticLabel:
              '${widget.serverName}, ${expanded ? 'collapse' : 'expand'}',
          leading: Icon(
              expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
              size: 20,
              color: hollow.textTertiary),
          trailing: status,
          onTap: () => setState(() => _expanded = !expanded),
        ),
        if (expanded)
          statusAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(HollowSpacing.lg),
              child: Center(child: HollowSpinner.medium()),
            ),
            error: (_, _) => Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm),
              child: HollowEmptyState(
                dense: true,
                title: "This server's vault files didn't load",
                action: HollowButton.ghost(
                  touch: true,
                  onPressed: () => ref
                      .invalidate(vaultFileStatusProvider(widget.serverId)),
                  child: const Text('Try again'),
                ),
              ),
            ),
            data: (files) => files.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: HollowSpacing.lg,
                        vertical: HollowSpacing.sm),
                    child: HollowEmptyState(
                      dense: true,
                      title: 'No vault files on this server yet',
                    ),
                  )
                : _files(hollow, files),
          ),
      ],
    );
  }

  Widget _files(HollowTheme hollow, List<VaultFileStatus> files) {
    final sorted = [...files]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg, vertical: HollowSpacing.xs),
          child: Wrap(
            spacing: HollowSpacing.sm,
            runSpacing: HollowSpacing.sm,
            children: [
              HollowButton.ghost(
                touch: true,
                icon: const Icon(LucideIcons.download, size: 16),
                onPressed: () => showExportShardsDialog(
                  context,
                  serverId: widget.serverId,
                  serverName: widget.serverName,
                  shardCount:
                      files.fold<int>(0, (sum, f) => sum + f.localShardCount),
                ),
                child: const Text('Export shards'),
              ),
              HollowButton.ghost(
                touch: true,
                icon: const Icon(LucideIcons.upload, size: 16),
                onPressed: () => showImportShardsDialog(
                  context,
                  onImported: () =>
                      ref.invalidate(vaultFileStatusProvider(widget.serverId)),
                ),
                child: const Text('Import shards'),
              ),
              HollowButton.ghost(
                touch: true,
                icon: const Icon(LucideIcons.shield, size: 16),
                onPressed: () => showInitiateRecoveryPoolDialog(
                  context,
                  serverId: widget.serverId,
                  serverName: widget.serverName,
                ),
                child: const Text('Start a recovery pool'),
              ),
            ],
          ),
        ),
        for (final file in sorted)
          HollowListRow(
            key: ValueKey(file.fileName + file.createdAt.toString()),
            touch: true,
            leading: Icon(_iconForFile(file.fileName),
                size: 20, color: hollow.textSecondary),
            title: file.fileName,
            subtitle: '${calendarDateLabel(DateTime.fromMillisecondsSinceEpoch(file.createdAt * 1000))}'
                ' · ${ShareCard.formatSize(file.originalSize)}',
            trailing: HollowBadge(
              file.isReconstructable
                  ? 'Recoverable'
                  : '${file.localShardCount} of ${file.k} shards',
              kind: file.isReconstructable
                  ? HollowBadgeKind.success
                  : (file.localShardCount > 0
                      ? HollowBadgeKind.warning
                      : HollowBadgeKind.neutral),
            ),
          ),
        const SizedBox(height: HollowSpacing.sm),
      ],
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
}

/// Imported archives at touch size: one primary, then the list.
class _MobileImportedView extends ConsumerWidget {
  const _MobileImportedView();

  void _open(BuildContext context, WidgetRef ref, String path) {
    ref.read(selectedImportedArchiveProvider.notifier).state = path;
    Navigator.of(context, rootNavigator: true)
        .push(hollowMobileRoute(
          builder: (_) => MobileImportedArchiveViewerRoute(path: path),
        ))
        .then((_) {
      if (context.mounted) {
        ref.read(selectedImportedArchiveProvider.notifier).state = null;
      }
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pathsAsync = ref.watch(importedArchivePathsProvider);

    final list = pathsAsync.when(
      loading: () => const Center(child: HollowSpinner.medium()),
      error: (_, _) => HollowEmptyState(
        title: "Your archives didn't load",
        action: HollowButton.ghost(
          touch: true,
          onPressed: () => ref.invalidate(importedArchivePathsProvider),
          child: const Text('Try again'),
        ),
      ),
      data: (paths) => paths.isEmpty
          ? const HollowEmptyState(
              glyph: LucideIcons.fileArchive,
              title: 'No archives loaded',
              description: 'Someone can export a conversation and send you '
                  'the .hollow-archive file.',
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: HollowSpacing.lg),
              itemCount: paths.length,
              itemBuilder: (context, index) => _MobileArchiveEntryRow(
                key: ValueKey(paths[index]),
                path: paths[index],
                onTap: () => _open(context, ref, paths[index]),
              ),
            ),
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(HollowSpacing.lg,
              HollowSpacing.md, HollowSpacing.lg, HollowSpacing.sm),
          child: HollowButton.filled(
            touch: true,
            expand: true,
            loading: ref.watch(importedArchiveBusyProvider),
            icon: const Icon(LucideIcons.folderOpen, size: 16),
            onPressed: () => pickAndLoadImportedArchive(context, ref),
            child: const Text('Load an archive'),
          ),
        ),
        Expanded(child: list),
      ],
    );
  }
}

class _MobileArchiveEntryRow extends ConsumerWidget {
  final String path;
  final VoidCallback onTap;

  const _MobileArchiveEntryRow(
      {super.key, required this.path, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final verifyAsync = ref.watch(importedArchiveVerifyProvider(path));
    final fileName = path.split(RegExp(r'[\\/]')).last;

    void actions() => _showRowActions(context, [
          (
            icon: LucideIcons.x,
            label: 'Remove from the list',
            onTap: () => ref
                .read(importedArchivePathsProvider.notifier)
                .removePath(path),
          ),
        ]);

    return verifyAsync.when(
      loading: () => HollowListRow(
        touch: true,
        title: fileName,
        subtitle: 'Checking signatures',
        leading: const SizedBox.square(
            dimension: 20, child: Center(child: HollowSpinner())),
        onTap: onTap,
        onLongPress: actions,
      ),
      error: (_, _) => HollowListRow(
        touch: true,
        title: fileName,
        subtitle: "This file isn't a readable archive",
        leading: Icon(LucideIcons.alertCircle, size: 20, color: hollow.error),
        onTap: onTap,
        onLongPress: actions,
      ),
      data: (result) {
        final peerProfile = ref.watch(profileProvider.select(
            (p) => result.peerId != null ? p[result.peerId!] : null));
        final servers = ref.watch(serverListProvider);
        final String name;
        final String kindLabel;
        final IconData kindIcon;
        switch (result.archiveType) {
          case 'dm':
            name = result.peerId != null
                ? displayNameForPeer(peerProfile, result.peerId!)
                : 'Direct messages';
            kindLabel = 'Direct messages';
            kindIcon = LucideIcons.messageSquare;
          case 'server':
            name = result.serverName ?? 'Server';
            kindLabel = '${result.channels.length} channels';
            kindIcon = LucideIcons.server;
          default:
            name = result.channelName ?? result.channelId ?? 'Channel';
            kindLabel = (result.serverId != null
                    ? servers[result.serverId]?.name
                    : null) ??
                'Channel';
            kindIcon = LucideIcons.hash;
        }
        final exported = calendarDateLabel(
            DateTime.fromMillisecondsSinceEpoch(result.exportTimestamp));
        final problem = !result.archiveSignatureValid
            ? (LucideIcons.shieldOff, hollow.error,
                "The archive's signature doesn't match")
            : result.messagesWithInvalidSig > 0
                ? (LucideIcons.shieldAlert, hollow.warning,
                    'Some messages failed their signature check')
                : null;

        return HollowListRow(
          touch: true,
          title: name,
          subtitle: '$kindLabel · ${result.messageCount} messages · $exported',
          leading: Icon(kindIcon, size: 20, color: hollow.textSecondary),
          trailing: problem == null
              ? null
              : Icon(problem.$1,
                  size: 20, color: problem.$2, semanticLabel: problem.$3),
          onTap: onTap,
          onLongPress: actions,
        );
      },
    );
  }
}
