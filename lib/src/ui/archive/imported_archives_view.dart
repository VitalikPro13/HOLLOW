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
import 'package:hollow/src/ui/chat/chat_input_shortcuts.dart';
import 'package:hollow/src/ui/chat/message_action_bar.dart';
import 'package:hollow/src/ui/archive/shared/archive_message_list.dart';
import 'package:hollow/src/ui/archive/shared/archive_toolbar.dart';
import 'package:hollow/src/ui/archive/shared/archive_verification_banner.dart';
import 'package:hollow/src/ui/archive/shared/imported_archive_prep.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
  // Gates the Load button AND drag-drop while verifyArchive runs (Ed25519
  // over the whole archive — seconds for a large one); a re-drop mid-verify
  // would otherwise double-fire with zero feedback.
  bool _loading = false;

  Future<void> _loadArchive(String path) async {
    if (_loading) return;
    setState(() => _loading = true);
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
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickArchive() async {
    if (_loading) return;
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
    if (_loading || details.files.isEmpty) return;
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
            onTap: _loading ? null : _pickArchive,
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
                  if (_loading)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: hollow.accent),
                    )
                  else
                    Icon(LucideIcons.folderOpen,
                        size: 14, color: hollow.accent),
                  const SizedBox(width: HollowSpacing.sm),
                  Text(
                    _loading ? 'Verifying…' : 'Load Archive',
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
          child: _wrapDropTarget(
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

  Widget _wrapDropTarget({required Widget child}) {
    if (Platform.isAndroid || Platform.isIOS) return child;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: _handleDrop,
      child: child,
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
        // Selection bg lives ON the pressable so it fills the exact same
        // rounded rect the hover highlight paints — an inner Container was
        // inset by the pressable padding and read as a mismatched outline.
        backgroundColor:
            isSelected ? hollow.accent.withValues(alpha: 0.12) : null,
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm,
          vertical: HollowSpacing.sm,
        ),
        child: Padding(
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
              final peerProfile = ref.watch(profileProvider.select(
                  (p) => result.peerId != null ? p[result.peerId!] : null));
              final servers = ref.watch(serverListProvider);
              String name;
              String? serverLabel;
              if (result.archiveType == 'dm') {
                name = result.peerId != null
                    ? displayNameForPeer(peerProfile, result.peerId!)
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
      semanticLabel: 'Remove archive',
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
    final profiles = ref.watch(profileProvider);
    final filterSender = ref.watch(archiveFilterSenderProvider);
    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);
    final selectedChannelId = ref.watch(importedArchiveSelectedChannelProvider);

    final prep = prepareImportedArchive(
      data: data,
      localPeerId: localPeerId,
      filterSender: filterSender,
      selectedChannelId: selectedChannelId,
      displayNameOf: (id) => displayNameFor(profiles, id),
      avatarOf: (id) => profiles[id]?.avatarBytes,
      mobile: false,
    );
    final isDm = prep.isDm;

    final Widget headerLeading = isDm
        ? HollowAvatar(
            peerId: data.peerId ?? '',
            size: 24,
          )
        : Text('#', style: TextStyle(
            color: hollow.textSecondary, fontWeight: FontWeight.w700, fontSize: 18));

    final visibleMessages = isDm ? prep.dmMessages! : prep.channelMessages!;
    final totalForFilter = isDm ? null : prep.unfilteredChannelMessages?.length;

    return Column(
      children: [
        // ── Verification banner ──
        ArchiveVerificationBanner(
          archiveSigValid: prep.archiveSigValid,
          archiveSigText: prep.archiveSigText,
          msgSigWarning: prep.msgSigWarning,
          msgSigText: prep.msgSigText,
        ),

        // ── Channel selector for server archives ──
        if (prep.isServer && data.channels.length > 1)
          ArchiveChannelSelector(
            channels: data.channels,
            activeChannelId: prep.activeChannelId,
            onChannelSelected: (channelId) {
              ref.read(importedArchiveSelectedChannelProvider.notifier).state =
                  channelId;
              // Reset filter/search when switching channels.
              ref.read(archiveFilterSenderProvider.notifier).state = null;
              ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
              ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
            },
          ),

        // ── Header with toolbar ──
        ArchiveToolbar(
          leading: headerLeading,
          title: prep.headerTitle,
          subtitle: prep.headerSubtitle,
          messageCount: visibleMessages.length,
          totalMessageCount: filterSender != null ? totalForFilter : null,
          senderIds: prep.uniqueSenders,
          selectedSender: filterSender,
          senderDisplayNames: prep.senderNames,
          senderAvatars: prep.senderAvatars,
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
                  messages: prep.dmMessages!,
                  peerId: data.peerId ?? '',
                  editsMap: prep.editsMap,
                  proofContext: prep.proofContext,
                  proofMsgType: prep.proofMsgType,
                  exporterPeerId: data.exporterPeerId,
                )
              : _ImportedChannelMessageList(
                  messages: prep.channelMessages!,
                  allMessages: prep.unfilteredChannelMessages ?? prep.channelMessages!,
                  serverId: data.serverId ?? '',
                  channelId: prep.activeChannelId ?? data.channelId ?? '',
                  editsMap: prep.editsMap,
                  proofContext: prep.proofContext,
                  proofMsgType: prep.proofMsgType,
                ),
        ),
      ],
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
  final String? exporterPeerId;

  const _ImportedDmMessageList({
    required this.messages,
    required this.peerId,
    this.editsMap = const {},
    required this.proofContext,
    required this.proofMsgType,
    this.exporterPeerId,
  });

  @override
  ConsumerState<_ImportedDmMessageList> createState() =>
      _ImportedDmMessageListState();
}

class _ImportedDmMessageListState
    extends ConsumerState<_ImportedDmMessageList> {
  bool _isPicking = false;

  @override
  Widget build(BuildContext context) {
    final localPeerId = ref.watch(identityProvider).peerId ?? '';
    final profiles = ref.watch(profileProvider);

    return ArchiveDmMessageList(
      messages: widget.messages,
      peerId: widget.peerId,
      localPeerId: localPeerId,
      editsMap: widget.editsMap,
      proofContextFor: (_) => widget.proofContext,
      proofMsgType: widget.proofMsgType,
      desktopChrome: true,
      actionWrapper: (context, msg, child) {
        final senderPeerId = msg.isMe ? localPeerId : widget.peerId;
        return MessageHoverWrapper(
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
                  // itemBuilder shadows the State's context — check THIS element.
                  if (context.mounted) {
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
                text: msg.text,
                timestampMs: (msg.editedAt ?? msg.timestamp)
                    .millisecondsSinceEpoch,
                signature: msg.signature,
                publicKey: msg.publicKey,
                messageId: msg.messageId,
                context: widget.proofMsgType == 'dm' && widget.exporterPeerId != null
                    ? (senderPeerId == widget.exporterPeerId ? widget.proofContext : widget.exporterPeerId!)
                    : widget.proofContext,
                msgType: widget.proofMsgType,
                fileAttachment: msg.fileAttachment,
              ),
            );
          },
          child: child,
        );
      },
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

  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(profileProvider);

    return ArchiveChannelMessageList(
      messages: widget.messages,
      allMessages: widget.allMessages,
      serverId: widget.serverId,
      editsMap: widget.editsMap,
      proofContext: widget.proofContext,
      proofMsgType: widget.proofMsgType,
      desktopChrome: true,
      actionWrapper: (context, msg, child) => MessageHoverWrapper(
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
                // itemBuilder shadows the State's context — check THIS element.
                if (context.mounted) {
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
        child: child,
      ),
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
