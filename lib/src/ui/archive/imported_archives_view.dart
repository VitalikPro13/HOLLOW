import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/download_manager_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/rust/api/archive.dart' as archive_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/channel_message_bubble.dart';
import 'package:hollow/src/ui/chat/chat_input_shortcuts.dart';
import 'package:hollow/src/ui/chat/chat_pane.dart'
    show shouldGroup, shouldShowDateSeparator, DateSeparator;
import 'package:hollow/src/ui/chat/message_action_bar.dart';
import 'package:hollow/src/ui/chat/message_bubble.dart';
import 'package:hollow/src/ui/archive/archive_message_viewer.dart'
    show ArchiveSearchBar, EditHistoryIndicator;
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// Two-panel layout for "Imported Archives" sub-tab.
class ImportedArchivesView extends ConsumerWidget {
  const ImportedArchivesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    return Row(
      children: [
        SizedBox(
          width: 280,
          child: Container(
            decoration: BoxDecoration(
              color: hollow.opaqueBackground,
              border: Border(right: BorderSide(color: hollow.border)),
            ),
            child: const _ImportedArchiveList(),
          ),
        ),
        const Expanded(child: _ImportedArchiveViewer()),
      ],
    );
  }
}

// ── Left Panel: Archive list ────────────────────────────────────

class _ImportedArchiveList extends ConsumerStatefulWidget {
  const _ImportedArchiveList();

  @override
  ConsumerState<_ImportedArchiveList> createState() =>
      _ImportedArchiveListState();
}

class _ImportedArchiveListState extends ConsumerState<_ImportedArchiveList> {
  bool _dragging = false;

  Future<void> _loadArchive(String path) async {
    try {
      // Quick verify first.
      await archive_api.verifyArchive(archivePath: path);
      await ref.read(importedArchivePathsProvider.notifier).addPath(path);
      // Invalidate the verify provider so it re-fetches.
      ref.invalidate(importedArchiveVerifyProvider(path));
      if (mounted) {
        HollowToast.show(context, 'Archive loaded',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to load archive: $e',
            type: HollowToastType.error);
      }
    }
  }

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

  Future<void> _handleDrop(DropDoneDetails details) async {
    setState(() => _dragging = false);
    if (details.files.isEmpty) return;
    final path = details.files.first.path;
    if (path.isEmpty) return;
    await _loadArchive(path);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final pathsAsync = ref.watch(importedArchivePathsProvider);
    final selectedPath = ref.watch(selectedImportedArchiveProvider);

    return Column(
      children: [
        // ── Load button ──
        Padding(
          padding: const EdgeInsets.all(HollowSpacing.md),
          child: HollowPressable(
            onTap: _pickArchive,
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
                  Icon(LucideIcons.folderOpen,
                      size: 14, color: hollow.accent),
                  const SizedBox(width: HollowSpacing.sm),
                  Text(
                    'Load Archive',
                    style: HollowTypography.body.copyWith(
                      color: hollow.accent,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // ── Archive list with drag-drop ──
        Expanded(
          child: DropTarget(
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: _handleDrop,
            child: Stack(
              children: [
                pathsAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(
                    child: Text('Error: $e',
                        style: TextStyle(color: hollow.error)),
                  ),
                  data: (paths) {
                    if (paths.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(HollowSpacing.lg),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(LucideIcons.fileArchive,
                                  size: 40,
                                  color: hollow.textSecondary
                                      .withValues(alpha: 0.3)),
                              const SizedBox(height: HollowSpacing.md),
                              Text(
                                'No imported archives',
                                style: HollowTypography.body.copyWith(
                                    color: hollow.textSecondary),
                              ),
                              const SizedBox(height: HollowSpacing.xs),
                              Text(
                                'Load or drag a .hollow-archive file',
                                style: HollowTypography.caption.copyWith(
                                  color: hollow.textSecondary
                                      .withValues(alpha: 0.6),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }

                    return ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: HollowSpacing.sm),
                      itemCount: paths.length,
                      itemBuilder: (context, index) {
                        return _ArchiveEntryCard(
                          path: paths[index],
                          isSelected: selectedPath == paths[index],
                        );
                      },
                    );
                  },
                ),

                // Drag overlay
                if (_dragging)
                  Positioned.fill(
                    child: Container(
                      color: hollow.background.withValues(alpha: 0.85),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.all(HollowSpacing.xl),
                          decoration: BoxDecoration(
                            color: hollow.surface,
                            borderRadius: BorderRadius.circular(
                                hollow.radiusLg),
                            border: Border.all(
                                color: hollow.accent, width: 2),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(LucideIcons.upload,
                                  size: 36, color: hollow.accent),
                              const SizedBox(height: HollowSpacing.sm),
                              Text(
                                'Drop .hollow-archive file',
                                style: HollowTypography.body.copyWith(
                                    color: hollow.accent,
                                    fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Archive entry card ──────────────────────────────────────────

class _ArchiveEntryCard extends ConsumerWidget {
  final String path;
  final bool isSelected;

  const _ArchiveEntryCard({required this.path, required this.isSelected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final verifyAsync = ref.watch(importedArchiveVerifyProvider(path));
    final fileName = path.split(Platform.pathSeparator).last;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: HollowPressable(
        onTap: () {
          ref.read(selectedImportedArchiveProvider.notifier).state = path;
        },
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
          padding: const EdgeInsets.all(HollowSpacing.sm),
          child: verifyAsync.when(
            loading: () => Row(
              children: [
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Text(fileName,
                      style: HollowTypography.caption
                          .copyWith(color: hollow.textSecondary, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            error: (e, _) => Row(
              children: [
                Icon(LucideIcons.alertCircle, size: 14, color: hollow.error),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Text(fileName,
                      style: HollowTypography.caption
                          .copyWith(color: hollow.error, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                _removeButton(ref, hollow),
              ],
            ),
            data: (result) {
              final isValid = result.archiveSignatureValid &&
                  result.messagesWithInvalidSig == 0;
              final hasWarning = result.messagesWithInvalidSig > 0;

              final icon = isValid
                  ? Icon(LucideIcons.shieldCheck,
                      size: 14, color: hollow.accent)
                  : hasWarning
                      ? Icon(LucideIcons.alertTriangle,
                          size: 14,
                          color: Colors.amber.shade600)
                      : Icon(LucideIcons.shieldOff,
                          size: 14, color: hollow.error);

              final typeIcon = result.archiveType == 'dm'
                  ? LucideIcons.messageSquare
                  : result.archiveType == 'server'
                      ? LucideIcons.server
                      : LucideIcons.hash;

              // Resolve display name for DMs, channel name for channels, or server name.
              final profiles = ref.watch(profileProvider);
              final servers = ref.watch(serverListProvider);
              String name;
              String? serverLabel;
              if (result.archiveType == 'dm') {
                name = result.peerId != null
                    ? displayNameFor(profiles, result.peerId!)
                    : 'DM';
              } else if (result.archiveType == 'server') {
                name = result.serverName ?? 'Server';
                serverLabel = '${result.channels.length} channels';
              } else {
                name = result.channelName ?? result.channelId ?? 'Channel';
                if (result.serverId != null && servers.containsKey(result.serverId)) {
                  serverLabel = servers[result.serverId]?.name;
                }
              }

              final exportDate = DateTime.fromMillisecondsSinceEpoch(
                  result.exportTimestamp);
              final dateStr =
                  '${exportDate.year}-${exportDate.month.toString().padLeft(2, '0')}-${exportDate.day.toString().padLeft(2, '0')}';

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(typeIcon,
                          size: 13, color: hollow.textSecondary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          name,
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
                      icon,
                      const SizedBox(width: 4),
                      _removeButton(ref, hollow),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const SizedBox(width: 19),
                      if (serverLabel != null) ...[
                        Text(
                          serverLabel,
                          style: HollowTypography.caption.copyWith(
                            color: hollow.textSecondary,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '  ·  ',
                          style: HollowTypography.caption.copyWith(
                            color: hollow.textSecondary
                                .withValues(alpha: 0.4),
                            fontSize: 10,
                          ),
                        ),
                      ],
                      Text(
                        '${result.messageCount} msgs',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 10,
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      Text(
                        dateStr,
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary
                              .withValues(alpha: 0.6),
                          fontSize: 10,
                        ),
                      ),
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

  Widget _removeButton(WidgetRef ref, HollowTheme hollow) {
    return HollowPressable(
      onTap: () {
        ref.read(importedArchivePathsProvider.notifier).removePath(path);
      },
      borderRadius: BorderRadius.circular(4),
      padding: const EdgeInsets.all(2),
      child: Icon(LucideIcons.x, size: 12, color: hollow.textSecondary),
    );
  }
}

// ── Right Panel: POV Viewer ─────────────────────────────────────

class _ImportedArchiveViewer extends ConsumerWidget {
  const _ImportedArchiveViewer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final selectedPath = ref.watch(selectedImportedArchiveProvider);

    if (selectedPath == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.fileArchive,
                size: 64,
                color: hollow.textSecondary.withValues(alpha: 0.3)),
            const SizedBox(height: HollowSpacing.lg),
            Text(
              'Select an archive to view its contents',
              style: HollowTypography.body
                  .copyWith(color: hollow.textSecondary),
            ),
          ],
        ),
      );
    }

    final dataAsync = ref.watch(importedArchiveDataProvider(selectedPath));

    return Container(
      color: hollow.background,
      child: dataAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text('Failed to load archive: $e',
              style: TextStyle(color: hollow.error)),
        ),
        data: (data) => _ArchivePovViewer(
          key: ValueKey(selectedPath),
          data: data,
        ),
      ),
    );
  }
}

class _ArchivePovViewer extends ConsumerStatefulWidget {
  final archive_api.ArchiveData data;

  const _ArchivePovViewer({super.key, required this.data});

  @override
  ConsumerState<_ArchivePovViewer> createState() => _ArchivePovViewerState();
}

class _ArchivePovViewerState extends ConsumerState<_ArchivePovViewer> {
  @override
  void initState() {
    super.initState();
    // Reset shared state for the new archive.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(archiveFilterSenderProvider.notifier).state = null;
      ref.read(archiveMessageSearchOpenProvider.notifier).state = false;
      ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
      ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
      ref.read(archiveJumpToDateProvider.notifier).state = null;
      ref.read(importedArchiveSelectedChannelProvider.notifier).state = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final data = widget.data;
    final localPeerId = ref.watch(identityProvider).peerId ?? '';
    final v = data.verification;
    final profiles = ref.watch(profileProvider);
    final filterSender = ref.watch(archiveFilterSenderProvider);
    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);

    // Determine verification banner state.
    final isFullyValid =
        v.archiveSignatureValid && v.messagesWithInvalidSig == 0;
    final hasWarning = v.messagesWithInvalidSig > 0;

    final bannerColor = isFullyValid
        ? hollow.accent
        : hasWarning
            ? Colors.amber.shade700
            : hollow.error;

    final exportDate =
        DateTime.fromMillisecondsSinceEpoch(v.exportTimestamp);
    final dateStr =
        '${exportDate.year}-${exportDate.month.toString().padLeft(2, '0')}-${exportDate.day.toString().padLeft(2, '0')}';

    final String bannerText;
    if (isFullyValid) {
      bannerText =
          'Verified — ${v.messagesWithValidSig} messages signed by original senders, exported on $dateStr';
    } else if (!v.archiveSignatureValid) {
      bannerText =
          'Archive signature invalid — this archive may have been tampered with';
    } else {
      bannerText =
          'Warning — ${v.messagesWithInvalidSig} messages failed signature verification';
    }

    final bannerIcon = isFullyValid
        ? LucideIcons.shieldCheck
        : hasWarning
            ? LucideIcons.alertTriangle
            : LucideIcons.shieldOff;

    final isDm = data.archiveType == 'dm';
    final isServer = data.archiveType == 'server';

    // For server archives, handle channel selection.
    final selectedChannelId = ref.watch(importedArchiveSelectedChannelProvider);
    String? activeChannelId;
    String? activeChannelName;
    if (isServer && data.channels.isNotEmpty) {
      activeChannelId = selectedChannelId ?? data.channels.first.channelId;
      activeChannelName = data.channels
          .where((c) => c.channelId == activeChannelId)
          .firstOrNull
          ?.channelName ?? activeChannelId;
    }

    // Convert archive messages (filter by channel for server archives).
    List<ChatMessage>? dmMessages;
    List<ChannelChatMessage>? allChannelMessages;
    List<ChannelChatMessage>? channelMessages;

    if (isDm) {
      dmMessages = convertArchiveDmMessages(data, localPeerId);
    } else {
      allChannelMessages = convertArchiveChannelMessages(data, localPeerId);
      if (isServer && activeChannelId != null) {
        // Filter messages by selected channel using the raw FFI data's channel_id.
        final channelMsgIds = <String>{};
        for (final m in data.messages) {
          if (m.channelId == activeChannelId) {
            channelMsgIds.add(m.messageId);
          }
        }
        channelMessages = allChannelMessages
            .where((m) => channelMsgIds.contains(m.messageId))
            .toList();
      } else {
        channelMessages = allChannelMessages;
      }
    }

    // Apply sender filter.
    if (filterSender != null && channelMessages != null) {
      channelMessages = channelMessages
          .where((m) => m.senderId == filterSender)
          .toList();
    }

    // Collect unique senders for filter (channel archives only).
    final unfilteredChannelMessages = isDm ? null : (isServer && activeChannelId != null
        ? allChannelMessages!.where((m) {
            final channelMsgIds = <String>{};
            for (final raw in data.messages) {
              if (raw.channelId == activeChannelId) channelMsgIds.add(raw.messageId);
            }
            return channelMsgIds.contains(m.messageId);
          }).toList()
        : allChannelMessages);
    final uniqueSenders = unfilteredChannelMessages?.map((m) => m.senderId).toSet().toList()?..sort();
    final senderNames = uniqueSenders != null
        ? {for (final id in uniqueSenders) id: displayNameFor(profiles, id)}
        : <String, String>{};
    final senderAvatars = uniqueSenders != null
        ? {for (final id in uniqueSenders) id: profiles[id]?.avatarBytes}
        : <String, dynamic>{};

    // Build edits map from archive data.
    final editsMap = <String, List<ArchiveEditEntry>>{};
    for (final e in data.edits) {
      editsMap.putIfAbsent(e.messageId, () => []).add(ArchiveEditEntry(
        messageId: e.messageId,
        oldText: e.oldText,
        newText: e.newText,
        editedAt: DateTime.fromMillisecondsSinceEpoch(e.editedAt),
        signature: e.signature,
        publicKey: e.publicKey,
      ));
    }

    // Context for Message Proof.
    final proofContext = isDm
        ? (data.peerId ?? '')
        : '${data.serverId ?? ''}:${activeChannelId ?? data.channelId ?? ''}';
    final proofMsgType = isDm ? 'dm' : 'ch';

    // Header title/subtitle.
    String headerTitle;
    String? headerSubtitle;
    Widget headerLeading;
    if (isDm) {
      headerTitle = displayNameFor(profiles, data.peerId ?? '');
      headerLeading = HollowAvatar(
        peerId: data.peerId ?? '',
        size: 24,
        imageBytes: profiles[data.peerId]?.avatarBytes,
      );
    } else if (isServer) {
      headerTitle = activeChannelName ?? 'Channel';
      headerSubtitle = 'in ${data.serverName ?? 'Server'}';
      headerLeading = Text('#', style: TextStyle(
        color: hollow.textSecondary, fontWeight: FontWeight.w700, fontSize: 18));
    } else {
      headerTitle = data.channelName ?? 'Channel';
      headerSubtitle = data.serverId != null ? 'in ${data.serverId}' : null;
      headerLeading = Text('#', style: TextStyle(
        color: hollow.textSecondary, fontWeight: FontWeight.w700, fontSize: 18));
    }

    final visibleMessages = isDm ? dmMessages! : channelMessages!;
    final totalForFilter = isDm ? null : unfilteredChannelMessages?.length;

    return Column(
      children: [
        // ── Verification banner ──
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg, vertical: 10),
          decoration: BoxDecoration(
            color: bannerColor.withValues(alpha: 0.08),
            border: Border(
                bottom: BorderSide(
                    color: bannerColor.withValues(alpha: 0.2))),
          ),
          child: Row(
            children: [
              Icon(bannerIcon, size: 16, color: bannerColor),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  bannerText,
                  style: HollowTypography.caption.copyWith(
                    color: bannerColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),

        // ── Channel selector for server archives ──
        if (isServer && data.channels.length > 1)
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
            decoration: BoxDecoration(
              color: hollow.surface,
              border: Border(bottom: BorderSide(color: hollow.border)),
            ),
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: data.channels.map((ch) {
                final isActive = ch.channelId == activeChannelId;
                return Padding(
                  padding: const EdgeInsets.only(right: HollowSpacing.xs),
                  child: Center(
                    child: HollowPressable(
                      onTap: () {
                        ref.read(importedArchiveSelectedChannelProvider.notifier).state =
                            ch.channelId;
                        // Reset filter/search when switching channels.
                        ref.read(archiveFilterSenderProvider.notifier).state = null;
                        ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
                        ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
                      },
                      borderRadius: BorderRadius.circular(hollow.radiusSm),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isActive
                              ? hollow.accent.withValues(alpha: 0.15)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(hollow.radiusSm),
                          border: Border.all(
                            color: isActive
                                ? hollow.accent.withValues(alpha: 0.3)
                                : hollow.border,
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        child: Text(
                          '# ${ch.channelName}',
                          style: HollowTypography.caption.copyWith(
                            color: isActive ? hollow.accent : hollow.textSecondary,
                            fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),

        // ── Header with toolbar ──
        _ImportedArchiveHeader(
          leading: headerLeading,
          title: headerTitle,
          subtitle: headerSubtitle,
          messageCount: visibleMessages.length,
          totalMessageCount: filterSender != null ? totalForFilter : null,
          senderIds: uniqueSenders,
          selectedSender: filterSender,
          senderDisplayNames: senderNames,
          senderAvatars: senderAvatars,
          onSenderFilterChanged: (sender) {
            ref.read(archiveFilterSenderProvider.notifier).state = sender;
            ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
            ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
          },
          onJumpToDate: visibleMessages.isNotEmpty
              ? () async {
                  final msgs = visibleMessages;
                  final ts = isDm
                      ? (msgs as List<ChatMessage>).map((m) => m.timestamp).toList()
                      : (msgs as List<ChannelChatMessage>).map((m) => m.timestamp).toList();
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: ts.last,
                    firstDate: ts.first,
                    lastDate: ts.last,
                    builder: (context, child) => Theme(
                      data: ThemeData.dark().copyWith(
                        colorScheme: ColorScheme.dark(
                          primary: hollow.accent,
                          surface: hollow.surface,
                        ),
                      ),
                      child: child!,
                    ),
                  );
                  if (picked != null) {
                    ref.read(archiveJumpToDateProvider.notifier).state = picked;
                  }
                }
              : null,
          searchOpen: searchOpen,
          onToggleSearch: () {
            final open = ref.read(archiveMessageSearchOpenProvider);
            ref.read(archiveMessageSearchOpenProvider.notifier).state = !open;
            if (open) {
              ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
              ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
            }
          },
        ),

        // ── Messages ──
        Expanded(
          child: isDm
              ? _ImportedDmMessageList(
                  messages: dmMessages!,
                  peerId: data.peerId ?? '',
                  editsMap: editsMap,
                  proofContext: proofContext,
                  proofMsgType: proofMsgType,
                )
              : _ImportedChannelMessageList(
                  messages: channelMessages!,
                  allMessages: unfilteredChannelMessages ?? channelMessages!,
                  serverId: data.serverId ?? '',
                  channelId: activeChannelId ?? data.channelId ?? '',
                  editsMap: editsMap,
                  proofContext: proofContext,
                  proofMsgType: proofMsgType,
                ),
        ),
      ],
    );
  }
}

// ── Imported Archive Header ────────────────────────────────────

class _ImportedArchiveHeader extends StatelessWidget {
  final Widget leading;
  final String title;
  final String? subtitle;
  final int? messageCount;
  final int? totalMessageCount;
  final VoidCallback? onJumpToDate;
  final VoidCallback? onToggleSearch;
  final bool searchOpen;
  final List<String>? senderIds;
  final String? selectedSender;
  final ValueChanged<String?>? onSenderFilterChanged;
  final Map<String, String>? senderDisplayNames;
  final Map<String, dynamic>? senderAvatars;

  const _ImportedArchiveHeader({
    required this.leading,
    required this.title,
    this.subtitle,
    this.messageCount,
    this.totalMessageCount,
    this.onJumpToDate,
    this.onToggleSearch,
    this.searchOpen = false,
    this.senderIds,
    this.selectedSender,
    this.onSenderFilterChanged,
    this.senderDisplayNames,
    this.senderAvatars,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final countText = selectedSender != null && totalMessageCount != null
        ? '$messageCount of $totalMessageCount'
        : '${messageCount ?? 0}';

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          leading,
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: subtitle != null
                ? Text.rich(
                    TextSpan(children: [
                      TextSpan(text: title, style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary, fontWeight: FontWeight.w600)),
                      TextSpan(text: '  $subtitle', style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary, fontSize: 12)),
                    ]),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                  )
                : Text(title, style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary, fontWeight: FontWeight.w600),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (messageCount != null)
            Text('$countText messages', style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary, fontSize: 11)),
          if (senderIds != null && senderIds!.length > 1) ...[
            const SizedBox(width: HollowSpacing.xs),
            _ImportedFilterButton(
              senderIds: senderIds!,
              selectedSender: selectedSender,
              senderDisplayNames: senderDisplayNames ?? {},
              senderAvatars: senderAvatars ?? {},
              onSenderFilterChanged: onSenderFilterChanged,
            ),
          ],
          if (onJumpToDate != null) ...[
            const SizedBox(width: HollowSpacing.xs),
            HollowPressable(
              onTap: onJumpToDate,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(LucideIcons.calendar, size: 16, color: hollow.textSecondary),
            ),
          ],
          if (onToggleSearch != null) ...[
            const SizedBox(width: HollowSpacing.xs),
            HollowPressable(
              onTap: onToggleSearch,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(LucideIcons.search, size: 16,
                  color: searchOpen ? hollow.accent : hollow.textSecondary),
            ),
          ],
          const SizedBox(width: HollowSpacing.sm),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
            ),
            child: Text('read-only', style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary, fontSize: 10)),
          ),
        ],
      ),
    );
  }
}

/// Searchable filter button for imported archive headers.
class _ImportedFilterButton extends StatelessWidget {
  final List<String> senderIds;
  final String? selectedSender;
  final Map<String, String> senderDisplayNames;
  final Map<String, dynamic> senderAvatars;
  final ValueChanged<String?>? onSenderFilterChanged;

  const _ImportedFilterButton({
    required this.senderIds,
    this.selectedSender,
    required this.senderDisplayNames,
    this.senderAvatars = const {},
    this.onSenderFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: () async {
        final picked = await showDialog<String?>(
          context: context,
          barrierColor: Colors.transparent,
          builder: (ctx) => _ImportedFilterDialog(
            senderIds: senderIds,
            selectedSender: selectedSender,
            senderDisplayNames: senderDisplayNames,
            senderAvatars: senderAvatars,
          ),
        );
        if (picked != null) {
          onSenderFilterChanged?.call(picked == '_clear_' ? null : picked);
        }
      },
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.all(6),
      child: Icon(LucideIcons.filter, size: 16,
          color: selectedSender != null ? hollow.accent : hollow.textSecondary),
    );
  }
}

class _ImportedFilterDialog extends StatefulWidget {
  final List<String> senderIds;
  final String? selectedSender;
  final Map<String, String> senderDisplayNames;
  final Map<String, dynamic> senderAvatars;

  const _ImportedFilterDialog({
    required this.senderIds,
    this.selectedSender,
    required this.senderDisplayNames,
    this.senderAvatars = const {},
  });

  @override
  State<_ImportedFilterDialog> createState() => _ImportedFilterDialogState();
}

class _ImportedFilterDialogState extends State<_ImportedFilterDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final filtered = _query.isEmpty ? widget.senderIds
        : widget.senderIds.where((id) =>
            (widget.senderDisplayNames[id] ?? id).toLowerCase().contains(_query.toLowerCase())).toList();

    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 100, right: 80),
        child: Material(type: MaterialType.transparency, child: Container(
          width: 240, constraints: const BoxConstraints(maxHeight: 360),
          decoration: BoxDecoration(
            color: hollow.elevated, borderRadius: BorderRadius.circular(hollow.radiusSm),
            border: Border.all(color: hollow.border),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 4))],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(padding: const EdgeInsets.all(HollowSpacing.sm), child: HollowTextField(
              hintText: 'Search participants...', isDense: true, autofocus: true,
              prefixIcon: Icon(LucideIcons.search, size: 12, color: hollow.textSecondary),
              onChanged: (val) => setState(() => _query = val),
            )),
            HollowPressable(
              onTap: () => Navigator.of(context).pop('_clear_'),
              padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md, vertical: 6),
              child: Row(children: [
                Icon(LucideIcons.users, size: 14,
                    color: widget.selectedSender == null ? hollow.accent : hollow.textSecondary),
                const SizedBox(width: HollowSpacing.sm),
                Text('All participants', style: HollowTypography.body.copyWith(
                  color: widget.selectedSender == null ? hollow.accent : hollow.textPrimary,
                  fontWeight: widget.selectedSender == null ? FontWeight.w600 : FontWeight.normal, fontSize: 13)),
              ]),
            ),
            Divider(height: 1, color: hollow.border),
            Flexible(child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
              shrinkWrap: true, itemCount: filtered.length,
              itemBuilder: (_, index) {
                final id = filtered[index];
                final name = widget.senderDisplayNames[id] ?? id.substring(0, 8);
                final isActive = widget.selectedSender == id;
                return HollowPressable(
                  onTap: () => Navigator.of(context).pop(id),
                  padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md, vertical: 5),
                  child: Row(children: [
                    HollowAvatar(peerId: id, size: 20, imageBytes: widget.senderAvatars[id]),
                    const SizedBox(width: HollowSpacing.sm),
                    Expanded(child: Text(name, style: HollowTypography.body.copyWith(
                      color: isActive ? hollow.accent : hollow.textPrimary,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.normal, fontSize: 13),
                      maxLines: 1, overflow: TextOverflow.ellipsis)),
                    if (isActive) Icon(LucideIcons.check, size: 14, color: hollow.accent),
                  ]),
                );
              },
            )),
          ]),
        )),
      ),
    );
  }
}

// ── Imported DM Message List ────────────────────────────────────

class _ImportedDmMessageList extends ConsumerStatefulWidget {
  final List<ChatMessage> messages;
  final String peerId;
  final Map<String, List<ArchiveEditEntry>> editsMap;
  final String proofContext;
  final String proofMsgType;

  const _ImportedDmMessageList({
    required this.messages,
    required this.peerId,
    this.editsMap = const {},
    required this.proofContext,
    required this.proofMsgType,
  });

  @override
  ConsumerState<_ImportedDmMessageList> createState() =>
      _ImportedDmMessageListState();
}

class _ImportedDmMessageListState
    extends ConsumerState<_ImportedDmMessageList> {
  bool _isPicking = false;
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  int? _highlightIndex;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listen(archiveJumpToDateProvider, (_, date) {
        if (date != null && widget.messages.isNotEmpty) {
          _jumpToDate(date);
          ref.read(archiveJumpToDateProvider.notifier).state = null;
        }
      });
    });
  }

  void _jumpToDate(DateTime target) {
    final targetStart = DateTime(target.year, target.month, target.day);
    int lo = 0, hi = widget.messages.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (widget.messages[mid].timestamp.isBefore(targetStart)) lo = mid + 1;
      else hi = mid;
    }
    if (lo < widget.messages.length && _itemScrollController.isAttached) {
      _itemScrollController.scrollTo(
        index: lo, duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic, alignment: 0.1);
    }
  }

  void _scrollToIndex(int index) {
    if (!_itemScrollController.isAttached) return;
    setState(() => _highlightIndex = index);
    _itemScrollController.scrollTo(
      index: index, duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic, alignment: 0.3);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightIndex = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final messages = widget.messages;
    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);
    final searchQuery = ref.watch(archiveMessageSearchQueryProvider);
    final matchIdx = ref.watch(archiveSearchMatchIndexProvider);

    final matchIndices = <int>[];
    if (searchQuery.isNotEmpty) {
      final q = searchQuery.toLowerCase();
      for (int i = 0; i < messages.length; i++) {
        if (messages[i].text.toLowerCase().contains(q)) matchIndices.add(i);
      }
    }

    if (messages.isEmpty) {
      return Center(
        child: Text('No messages',
            style:
                HollowTypography.body.copyWith(color: hollow.textSecondary)),
      );
    }

    final localPeerId = ref.watch(identityProvider).peerId ?? '';
    final profiles = ref.watch(profileProvider);

    return Column(
      children: [
        if (searchOpen)
          ArchiveSearchBar(
            matchCount: matchIndices.length, currentMatch: matchIdx,
            onQueryChanged: (q) {
              ref.read(archiveMessageSearchQueryProvider.notifier).state = q;
              ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
            },
            onNext: matchIndices.isNotEmpty ? () {
              final next = (matchIdx + 1) % matchIndices.length;
              ref.read(archiveSearchMatchIndexProvider.notifier).state = next;
              _scrollToIndex(matchIndices[next]);
            } : null,
            onPrev: matchIndices.isNotEmpty ? () {
              final prev = (matchIdx - 1 + matchIndices.length) % matchIndices.length;
              ref.read(archiveSearchMatchIndexProvider.notifier).state = prev;
              _scrollToIndex(matchIndices[prev]);
            } : null,
            onClose: () {
              ref.read(archiveMessageSearchOpenProvider.notifier).state = false;
              ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
              ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
            },
          ),
        Expanded(child: MessageActionBarScope(
      child: Builder(
        builder: (scopeContext) =>
            NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollUpdateNotification) {
              MessageActionBarScope.of(scopeContext)?.dismissAll();
            }
            return false;
          },
          child: SelectionArea(
            contextMenuBuilder: (_, __) => const SizedBox.shrink(),
            child: ScrollablePositionedList.builder(
              itemScrollController: _itemScrollController,
              itemPositionsListener: _itemPositionsListener,
              padding:
                  const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final msg = messages[index];
                final prev = index > 0 ? messages[index - 1] : null;

                final showDate = shouldShowDateSeparator(
                    msg.timestamp, prev?.timestamp);
                final showHeader = prev == null ||
                    showDate ||
                    !shouldGroup(
                      currentIsMe: msg.isMe,
                      previousIsMe: prev.isMe,
                      currentTime: msg.timestamp,
                      previousTime: prev.timestamp,
                    );

                String? replyToText;
                String? replyToSenderName;
                if (msg.replyToMid != null) {
                  final r = messages
                      .where((m) => m.messageId == msg.replyToMid)
                      .firstOrNull;
                  if (r != null) {
                    replyToText = r.text;
                    replyToSenderName = r.isMe
                        ? displayNameFor(profiles, localPeerId)
                        : displayNameFor(profiles, widget.peerId);
                  }
                }

                final isCurrentMatch = matchIndices.isNotEmpty &&
                    matchIdx < matchIndices.length &&
                    matchIndices[matchIdx] == index;

                Widget bubble = MessageBubble(
                  message: msg,
                  peerId: widget.peerId,
                  showHeader: showHeader,
                  replyToText: replyToText,
                  replyToSenderName: replyToSenderName,
                  isHighlighted: _highlightIndex == index || isCurrentMatch,
                  onReplyTap: null,
                  onToggleReaction: null,
                );

                if (msg.hiddenAt != null) {
                  bubble = _DeletedOverlay(
                      hiddenAt: msg.hiddenAt!, child: bubble);
                }

                // Edit history indicator.
                final msgEdits = msg.messageId != null
                    ? widget.editsMap[msg.messageId]
                    : null;
                final senderPeerId =
                    msg.isMe ? localPeerId : widget.peerId;
                if (msgEdits != null && msgEdits.isNotEmpty) {
                  bubble = Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      bubble,
                      EditHistoryIndicator(
                        edits: msgEdits,
                        senderPeerId: senderPeerId,
                        proofContext: widget.proofContext,
                        proofMsgType: widget.proofMsgType,
                        messageId: msg.messageId,
                      ),
                    ],
                  );
                }

                bubble = MessageHoverWrapper(
                  isMe: msg.isMe,
                  messageId: msg.messageId,
                  currentText: msg.text,
                  onDownload: msg.fileAttachment?.diskPath != null
                      ? () => _saveFile(msg.fileAttachment!)
                      : null,
                  onCopy: msg.text.isNotEmpty &&
                          !msg.text.startsWith('[file:')
                      ? () {
                          Clipboard.setData(
                              ClipboardData(text: msg.text));
                          HollowToast.show(
                              context, 'Copied to clipboard',
                              type: HollowToastType.success);
                        }
                      : null,
                  onCopyImage: msg.fileAttachment != null &&
                          msg.fileAttachment!.diskPath != null &&
                          msg.fileAttachment!.isImage
                      ? () async {
                          final ok = await copyImageToClipboard(
                              msg.fileAttachment!.diskPath!);
                          if (mounted) {
                            HollowToast.show(
                                context,
                                ok
                                    ? 'Image copied'
                                    : 'Failed to copy image',
                                type: ok
                                    ? HollowToastType.success
                                    : HollowToastType.error);
                          }
                        }
                      : null,
                  onInfo: () {
                    showMessageProofDialog(
                      context,
                      MessageProofData(
                        senderPeerId: senderPeerId,
                        senderDisplayName:
                            displayNameFor(profiles, senderPeerId),
                        senderAvatar:
                            profiles[senderPeerId]?.avatarBytes,
                        text: msg.text,
                        timestampMs: (msg.editedAt ?? msg.timestamp)
                            .millisecondsSinceEpoch,
                        signature: msg.signature,
                        publicKey: msg.publicKey,
                        messageId: msg.messageId,
                        context: widget.proofContext,
                        msgType: widget.proofMsgType,
                        fileAttachment: msg.fileAttachment,
                      ),
                    );
                  },
                  child: bubble,
                );

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (showDate) DateSeparator(date: msg.timestamp),
                    bubble,
                  ],
                );
              },
            ),
          ),
        ),
      ),
      ),
      ),
      ],
    );
  }

  Future<void> _saveFile(FileAttachment attachment) async {
    if (_isPicking) return;
    _isPicking = true;
    try {
      final isImage = attachment.isImage;
      final isGif = attachment.fileExt.toLowerCase() == 'gif';
      final allowedExtensions = isImage
          ? ['png', 'jpg', 'jpeg', 'webp', 'gif']
          : [attachment.fileExt];
      final baseName = attachment.fileName.contains('.')
          ? attachment.fileName
              .substring(0, attachment.fileName.lastIndexOf('.'))
          : attachment.fileName;
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save file',
        fileName: isImage
            ? (isGif ? '$baseName.gif' : '$baseName.png')
            : attachment.fileName,
        type: FileType.custom,
        allowedExtensions: allowedExtensions,
      );
      if (savePath == null || attachment.diskPath == null) return;
      final targetExt = savePath.contains('.')
          ? savePath.split('.').last.toLowerCase()
          : attachment.fileExt;
      if (isImage && targetExt != 'webp' && attachment.fileExt == 'webp') {
        final converted = await network_api.convertImageFormat(
            sourcePath: attachment.diskPath!, targetFormat: targetExt);
        await File(savePath).writeAsBytes(converted);
      } else {
        await File(attachment.diskPath!).copy(savePath);
      }
      ref.read(downloadManagerStateProvider.notifier).recordSavedFile(
          savedPath: savePath, isImage: isImage, isVideo: false);
      if (mounted) {
        HollowToast.show(context, 'File saved',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Save failed: $e',
            type: HollowToastType.error);
      }
    } finally {
      _isPicking = false;
    }
  }
}

// ── Imported Channel Message List ───────────────────────────────

class _ImportedChannelMessageList extends ConsumerStatefulWidget {
  final List<ChannelChatMessage> messages;
  final List<ChannelChatMessage> allMessages;
  final String serverId;
  final String channelId;
  final Map<String, List<ArchiveEditEntry>> editsMap;
  final String proofContext;
  final String proofMsgType;

  const _ImportedChannelMessageList({
    required this.messages,
    required this.allMessages,
    required this.serverId,
    required this.channelId,
    this.editsMap = const {},
    required this.proofContext,
    required this.proofMsgType,
  });

  @override
  ConsumerState<_ImportedChannelMessageList> createState() =>
      _ImportedChannelMessageListState();
}

class _ImportedChannelMessageListState
    extends ConsumerState<_ImportedChannelMessageList> {
  bool _isPicking = false;
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  int? _highlightIndex;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listen(archiveJumpToDateProvider, (_, date) {
        if (date != null && widget.messages.isNotEmpty) {
          _jumpToDate(date);
          ref.read(archiveJumpToDateProvider.notifier).state = null;
        }
      });
    });
  }

  void _jumpToDate(DateTime target) {
    final targetStart = DateTime(target.year, target.month, target.day);
    int lo = 0, hi = widget.messages.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (widget.messages[mid].timestamp.isBefore(targetStart)) lo = mid + 1;
      else hi = mid;
    }
    if (lo < widget.messages.length && _itemScrollController.isAttached) {
      _itemScrollController.scrollTo(
        index: lo, duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic, alignment: 0.1);
    }
  }

  void _scrollToIndex(int index) {
    if (!_itemScrollController.isAttached) return;
    setState(() => _highlightIndex = index);
    _itemScrollController.scrollTo(
      index: index, duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic, alignment: 0.3);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightIndex = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final messages = widget.messages;
    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);
    final searchQuery = ref.watch(archiveMessageSearchQueryProvider);
    final matchIdx = ref.watch(archiveSearchMatchIndexProvider);

    final matchIndices = <int>[];
    if (searchQuery.isNotEmpty) {
      final q = searchQuery.toLowerCase();
      for (int i = 0; i < messages.length; i++) {
        if (messages[i].text.toLowerCase().contains(q)) matchIndices.add(i);
      }
    }

    if (messages.isEmpty) {
      return Center(
        child: Text('No messages',
            style:
                HollowTypography.body.copyWith(color: hollow.textSecondary)),
      );
    }

    final profiles = ref.watch(profileProvider);

    return Column(
      children: [
        if (searchOpen)
          ArchiveSearchBar(
            matchCount: matchIndices.length, currentMatch: matchIdx,
            onQueryChanged: (q) {
              ref.read(archiveMessageSearchQueryProvider.notifier).state = q;
              ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
            },
            onNext: matchIndices.isNotEmpty ? () {
              final next = (matchIdx + 1) % matchIndices.length;
              ref.read(archiveSearchMatchIndexProvider.notifier).state = next;
              _scrollToIndex(matchIndices[next]);
            } : null,
            onPrev: matchIndices.isNotEmpty ? () {
              final prev = (matchIdx - 1 + matchIndices.length) % matchIndices.length;
              ref.read(archiveSearchMatchIndexProvider.notifier).state = prev;
              _scrollToIndex(matchIndices[prev]);
            } : null,
            onClose: () {
              ref.read(archiveMessageSearchOpenProvider.notifier).state = false;
              ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
              ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
            },
          ),
        Expanded(child: MessageActionBarScope(
      child: Builder(
        builder: (scopeContext) =>
            NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollUpdateNotification) {
              MessageActionBarScope.of(scopeContext)?.dismissAll();
            }
            return false;
          },
          child: SelectionArea(
            contextMenuBuilder: (_, __) => const SizedBox.shrink(),
            child: ScrollablePositionedList.builder(
              itemScrollController: _itemScrollController,
              itemPositionsListener: _itemPositionsListener,
              padding:
                  const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final msg = messages[index];
                final prev = index > 0 ? messages[index - 1] : null;

                final showDate = shouldShowDateSeparator(
                    msg.timestamp, prev?.timestamp);
                final showHeader = prev == null ||
                    showDate ||
                    !shouldGroup(
                      currentIsMe: msg.isMe,
                      previousIsMe: prev.isMe,
                      currentTime: msg.timestamp,
                      previousTime: prev.timestamp,
                      currentSenderId: msg.senderId,
                      previousSenderId: prev.senderId,
                    );

                String? replyToText;
                String? replyToSenderName;
                if (msg.replyToMid != null) {
                  final r = widget.allMessages
                      .where((m) => m.messageId == msg.replyToMid)
                      .firstOrNull;
                  if (r != null) {
                    replyToText = r.text;
                    replyToSenderName =
                        displayNameFor(profiles, r.senderId);
                  }
                }

                final isCurrentMatch = matchIndices.isNotEmpty &&
                    matchIdx < matchIndices.length &&
                    matchIndices[matchIdx] == index;

                Widget bubble = ChannelMessageBubble(
                  message: msg,
                  serverId: widget.serverId,
                  showHeader: showHeader,
                  replyToText: replyToText,
                  replyToSenderName: replyToSenderName,
                  isHighlighted: _highlightIndex == index || isCurrentMatch,
                  onReplyTap: null,
                  onToggleReaction: null,
                );

                if (msg.hiddenAt != null) {
                  bubble = _DeletedOverlay(
                      hiddenAt: msg.hiddenAt!, child: bubble);
                }

                // Edit history indicator.
                final msgEdits = msg.messageId != null
                    ? widget.editsMap[msg.messageId]
                    : null;
                if (msgEdits != null && msgEdits.isNotEmpty) {
                  bubble = Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      bubble,
                      EditHistoryIndicator(
                        edits: msgEdits,
                        senderPeerId: msg.senderId,
                        proofContext: widget.proofContext,
                        proofMsgType: widget.proofMsgType,
                        messageId: msg.messageId,
                      ),
                    ],
                  );
                }

                bubble = MessageHoverWrapper(
                  isMe: msg.isMe,
                  messageId: msg.messageId,
                  currentText: msg.text,
                  onDownload: msg.fileAttachment?.diskPath != null
                      ? () => _saveFile(msg.fileAttachment!)
                      : null,
                  onCopy: msg.text.isNotEmpty &&
                          !msg.text.startsWith('[file:')
                      ? () {
                          Clipboard.setData(
                              ClipboardData(text: msg.text));
                          HollowToast.show(
                              context, 'Copied to clipboard',
                              type: HollowToastType.success);
                        }
                      : null,
                  onCopyImage: msg.fileAttachment != null &&
                          msg.fileAttachment!.diskPath != null &&
                          msg.fileAttachment!.isImage
                      ? () async {
                          final ok = await copyImageToClipboard(
                              msg.fileAttachment!.diskPath!);
                          if (mounted) {
                            HollowToast.show(
                                context,
                                ok
                                    ? 'Image copied'
                                    : 'Failed to copy image',
                                type: ok
                                    ? HollowToastType.success
                                    : HollowToastType.error);
                          }
                        }
                      : null,
                  onInfo: () {
                    showMessageProofDialog(
                      context,
                      MessageProofData(
                        senderPeerId: msg.senderId,
                        senderDisplayName:
                            displayNameFor(profiles, msg.senderId),
                        senderAvatar:
                            profiles[msg.senderId]?.avatarBytes,
                        text: msg.text,
                        timestampMs: (msg.editedAt ?? msg.timestamp)
                            .millisecondsSinceEpoch,
                        signature: msg.signature,
                        publicKey: msg.publicKey,
                        messageId: msg.messageId,
                        context: widget.proofContext,
                        msgType: widget.proofMsgType,
                        fileAttachment: msg.fileAttachment,
                      ),
                    );
                  },
                  child: bubble,
                );

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (showDate) DateSeparator(date: msg.timestamp),
                    bubble,
                  ],
                );
              },
            ),
          ),
        ),
      ),
      ),
      ),
      ],
    );
  }

  Future<void> _saveFile(FileAttachment attachment) async {
    if (_isPicking) return;
    _isPicking = true;
    try {
      final isImage = attachment.isImage;
      final isGif = attachment.fileExt.toLowerCase() == 'gif';
      final allowedExtensions = isImage
          ? ['png', 'jpg', 'jpeg', 'webp', 'gif']
          : [attachment.fileExt];
      final baseName = attachment.fileName.contains('.')
          ? attachment.fileName
              .substring(0, attachment.fileName.lastIndexOf('.'))
          : attachment.fileName;
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save file',
        fileName: isImage
            ? (isGif ? '$baseName.gif' : '$baseName.png')
            : attachment.fileName,
        type: FileType.custom,
        allowedExtensions: allowedExtensions,
      );
      if (savePath == null || attachment.diskPath == null) return;
      final targetExt = savePath.contains('.')
          ? savePath.split('.').last.toLowerCase()
          : attachment.fileExt;
      if (isImage && targetExt != 'webp' && attachment.fileExt == 'webp') {
        final converted = await network_api.convertImageFormat(
            sourcePath: attachment.diskPath!, targetFormat: targetExt);
        await File(savePath).writeAsBytes(converted);
      } else {
        await File(attachment.diskPath!).copy(savePath);
      }
      ref.read(downloadManagerStateProvider.notifier).recordSavedFile(
          savedPath: savePath, isImage: isImage, isVideo: false);
      if (mounted) {
        HollowToast.show(context, 'File saved',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Save failed: $e',
            type: HollowToastType.error);
      }
    } finally {
      _isPicking = false;
    }
  }
}

// ── Deleted message overlay ─────────────────────────────────────

class _DeletedOverlay extends StatelessWidget {
  final DateTime hiddenAt;
  final Widget child;

  const _DeletedOverlay({required this.hiddenAt, required this.child});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final time =
        '${hiddenAt.hour.toString().padLeft(2, '0')}:${hiddenAt.minute.toString().padLeft(2, '0')}';

    return AnimatedOpacity(
      opacity: 0.4,
      duration: Duration.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          child,
          Padding(
            padding: const EdgeInsets.only(left: 42, top: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.trash2,
                    size: 11,
                    color: hollow.error.withValues(alpha: 0.7)),
                const SizedBox(width: 4),
                Text(
                  'Deleted at $time',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.error.withValues(alpha: 0.7),
                    fontSize: 10,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
