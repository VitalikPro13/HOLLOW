import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/archive/shared/archive_message_list.dart';
import 'package:hollow/src/ui/archive/shared/archive_sender_filter.dart';
import 'package:hollow/src/ui/archive/shared/archive_shared_widgets.dart';
import 'package:hollow/src/ui/archive/shared/archive_toolbar.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/export_archive_dialog.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_archive_message_actions.dart';

/// Full-screen archive message viewer for My Data (DMs and channels).
class MobileArchiveViewerRoute extends ConsumerStatefulWidget {
  final String? peerId;
  final String? serverId;
  final String? channelId;

  const MobileArchiveViewerRoute({
    super.key,
    this.peerId,
    this.serverId,
    this.channelId,
  });

  bool get isDm => peerId != null;

  @override
  ConsumerState<MobileArchiveViewerRoute> createState() =>
      _MobileArchiveViewerRouteState();
}

class _MobileArchiveViewerRouteState
    extends ConsumerState<MobileArchiveViewerRoute> {
  final _listController = ArchiveMessageListController();
  bool _isPicking = false;

  @override
  void dispose() {
    // Reset search/filter state on exit.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        ref.read(archiveFilterSenderProvider.notifier).state = null;
        ref.read(archiveMessageSearchOpenProvider.notifier).state = false;
        ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
        ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
        ref.read(archiveJumpToDateProvider.notifier).state = null;
      } catch (_) {}
    });
    super.dispose();
  }

  Duration _scrollDuration() => ReduceMotionController.instance.isReduced
      ? Duration.zero
      : const Duration(milliseconds: 300);

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    if (widget.isDm) {
      return _buildDmViewer(hollow);
    }
    return _buildChannelViewer(hollow);
  }

  // ── DM Viewer ──────────────────────────────────────────────────

  Widget _buildDmViewer(HollowTheme hollow) {
    final peerId = widget.peerId!;
    final messagesAsync = ref.watch(archiveDmMessagesProvider(peerId));
    final peerProfile =
        ref.watch(profileProvider.select((p) => p[peerId]));
    final displayName = displayNameForPeer(peerProfile, peerId);
    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);
    final allMessages = messagesAsync.valueOrNull ?? [];

    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: Column(
          children: [
            ArchiveMobileToolbar(
              leading: HollowAvatar(peerId: peerId, size: 24),
              title: displayName,
              searchOpen: searchOpen,
              onBack: () => Navigator.pop(context),
              onToggleSearch: () => _toggleSearch(),
              onJumpToDate:
                  allMessages.isNotEmpty ? () => _pickDate(allMessages.first.timestamp, allMessages.last.timestamp) : null,
              onExport: () => showExportArchiveDialog(
                context,
                isDm: true,
                peerId: peerId,
                name: displayName,
                messageCount: allMessages.length,
              ),
            ),
            if (searchOpen)
              ArchiveListSearchBar(
                texts: [for (final m in allMessages) m.text],
                controller: _listController,
              ),
            Expanded(
              child: AnimatedSwitcher(
                duration: ReduceMotionController.instance.isReduced
                    ? Duration.zero
                    : const Duration(milliseconds: 300),
                switchInCurve: Curves.easeOut,
                child: messagesAsync.when(
                  loading: () =>
                      const Center(key: ValueKey('loading'), child: CircularProgressIndicator()),
                  error: (e, _) => Center(
                    key: const ValueKey('error'),
                    child: Text('Failed to load: $e',
                        style: TextStyle(color: hollow.error)),
                  ),
                  data: (messages) =>
                      _buildDmMessageList(messages, peerId),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDmMessageList(List<ChatMessage> messages, String peerId) {
    final localPeerId = ref.watch(identityProvider).peerId ?? '';
    final profiles = ref.watch(profileProvider);
    final editsMap =
        ref.watch(archiveDmEditsProvider(peerId)).valueOrNull ?? {};

    return ArchiveDmMessageList(
      messages: messages,
      peerId: peerId,
      localPeerId: localPeerId,
      editsMap: editsMap,
      proofContextFor: (msg) => msg.isMe ? peerId : localPeerId,
      proofMsgType: 'dm',
      controller: _listController,
      scrollDuration: _scrollDuration,
      actionWrapper: (context, msg, child) => ArchiveLongPressMessage(
        onLongPress: () => _showDmMessageActions(
          msg, msg.isMe ? localPeerId : peerId, profiles, localPeerId, peerId,
        ),
        child: child,
      ),
    );
  }

  void _showDmMessageActions(
    ChatMessage msg,
    String senderPeerId,
    Map<String, storage_api.UserProfile> profiles,
    String localPeerId,
    String peerId,
  ) {
    final time =
        '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}';
    showMobileArchiveMessageActions(
      context: context,
      messageText: msg.text,
      senderName: displayNameFor(profiles, senderPeerId),
      timestamp: time,
      onCopy: msg.text.isNotEmpty && !msg.text.startsWith('[file:')
          ? () {
              Clipboard.setData(ClipboardData(text: msg.text));
              HollowToast.show(context, 'Copied to clipboard',
                  type: HollowToastType.success);
            }
          : null,
      onDownload: msg.fileAttachment != null &&
              msg.fileAttachment!.diskPath != null
          ? () => _saveFile(msg.fileAttachment!)
          : null,
      onInfo: msg.messageId != null
          ? () {
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
                  context: msg.isMe ? peerId : localPeerId,
                  msgType: 'dm',
                  fileAttachment: msg.fileAttachment,
                ),
              );
            }
          : null,
    );
  }

  // ── Channel Viewer ─────────────────────────────────────────────

  Widget _buildChannelViewer(HollowTheme hollow) {
    final key = '${widget.serverId}:${widget.channelId}';
    final messagesAsync = ref.watch(archiveChannelMessagesProvider(key));
    final filterSender = ref.watch(archiveFilterSenderProvider);
    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);

    final channelGroups =
        ref.watch(archiveChannelListProvider).valueOrNull;
    String channelName = widget.channelId ?? '';
    String serverName = widget.serverId ?? '';
    if (channelGroups != null) {
      for (final group in channelGroups) {
        for (final ch in group.channels) {
          if (ch.serverId == widget.serverId &&
              ch.channelId == widget.channelId) {
            channelName = ch.channelName;
            serverName = ch.serverName;
            break;
          }
        }
      }
    }

    final allMessages = messagesAsync.valueOrNull ?? [];
    final uniqueSenders =
        allMessages.map((m) => m.senderId).toSet().toList()..sort();
    final profiles = ref.watch(profileProvider);
    final senderNames = {
      for (final id in uniqueSenders) id: displayNameFor(profiles, id),
    };
    final filtered = filterSender == null
        ? allMessages
        : allMessages
            .where((m) => m.senderId == filterSender)
            .toList();

    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: Column(
          children: [
            ArchiveMobileToolbar(
              leading: Text(
                '#',
                style: TextStyle(
                  color: hollow.textSecondary,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                ),
              ),
              title: channelName,
              subtitle: 'in $serverName',
              searchOpen: searchOpen,
              onBack: () => Navigator.pop(context),
              onToggleSearch: () => _toggleSearch(),
              onFilter: uniqueSenders.length > 1
                  ? () => _showFilterSheet(
                      uniqueSenders, filterSender, senderNames)
                  : null,
              filterActive: filterSender != null,
              onJumpToDate: filtered.isNotEmpty
                  ? () => _pickDate(
                      filtered.first.timestamp, filtered.last.timestamp)
                  : null,
              onExport: () => showExportArchiveDialog(
                context,
                isDm: false,
                serverId: widget.serverId,
                channelId: widget.channelId,
                channelName: channelName,
                name: channelName,
                messageCount: allMessages.length,
              ),
            ),
            if (searchOpen)
              ArchiveListSearchBar(
                texts: [for (final m in filtered) m.text],
                controller: _listController,
              ),
            Expanded(
              child: AnimatedSwitcher(
                duration: ReduceMotionController.instance.isReduced
                    ? Duration.zero
                    : const Duration(milliseconds: 300),
                switchInCurve: Curves.easeOut,
                child: messagesAsync.when(
                  loading: () =>
                      const Center(key: ValueKey('loading'), child: CircularProgressIndicator()),
                  error: (e, _) => Center(
                    key: const ValueKey('error'),
                    child: Text('Failed to load: $e',
                        style: TextStyle(color: hollow.error)),
                  ),
                  data: (_) => _buildChannelMessageList(
                      filtered, allMessages),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelMessageList(
    List<ChannelChatMessage> messages,
    List<ChannelChatMessage> allMessages,
  ) {
    final profiles = ref.watch(profileProvider);
    final editsMap = ref
            .watch(archiveChannelEditsProvider(
                '${widget.serverId}:${widget.channelId}'))
            .valueOrNull ??
        {};

    return ArchiveChannelMessageList(
      messages: messages,
      allMessages: allMessages,
      serverId: widget.serverId!,
      editsMap: editsMap,
      proofContext: '${widget.serverId}:${widget.channelId}',
      proofMsgType: 'ch',
      controller: _listController,
      scrollDuration: _scrollDuration,
      actionWrapper: (context, msg, child) => ArchiveLongPressMessage(
        onLongPress: () => _showChannelMessageActions(msg, profiles),
        child: child,
      ),
    );
  }

  void _showChannelMessageActions(
    ChannelChatMessage msg,
    Map<String, storage_api.UserProfile> profiles,
  ) {
    final time =
        '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}';
    showMobileArchiveMessageActions(
      context: context,
      messageText: msg.text,
      senderName: displayNameFor(profiles, msg.senderId),
      timestamp: time,
      onCopy: msg.text.isNotEmpty && !msg.text.startsWith('[file:')
          ? () {
              Clipboard.setData(ClipboardData(text: msg.text));
              HollowToast.show(context, 'Copied to clipboard',
                  type: HollowToastType.success);
            }
          : null,
      onDownload: msg.fileAttachment != null &&
              msg.fileAttachment!.diskPath != null
          ? () => _saveFile(msg.fileAttachment!)
          : null,
      onInfo: msg.messageId != null
          ? () {
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
                  context:
                      '${widget.serverId}:${widget.channelId}',
                  msgType: 'ch',
                  fileAttachment: msg.fileAttachment,
                ),
              );
            }
          : null,
    );
  }

  // ── Shared helpers ─────────────────────────────────────────────

  void _toggleSearch() {
    final open = ref.read(archiveMessageSearchOpenProvider);
    ref.read(archiveMessageSearchOpenProvider.notifier).state = !open;
    if (open) {
      ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
      ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
    }
  }

  Future<void> _pickDate(DateTime first, DateTime last) async {
    final hollow = HollowTheme.of(context);
    final picked = await showDatePicker(
      context: context,
      initialDate: last,
      firstDate: first,
      lastDate: last,
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

  void _showFilterSheet(
    List<String> senderIds,
    String? selectedSender,
    Map<String, String> senderNames,
  ) {
    showArchiveFilterSheet(
      context,
      senderIds: senderIds,
      selectedSender: selectedSender,
      senderNames: senderNames,
      onSelected: (sender) {
        ref.read(archiveFilterSenderProvider.notifier).state = sender;
        ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
        ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
      },
    );
  }

  Future<void> _saveFile(FileAttachment attachment) async {
    if (_isPicking || attachment.diskPath == null) return;
    _isPicking = true;
    try {
      Uint8List bytes;
      if (attachment.isImage && attachment.fileExt == 'webp') {
        bytes = await network_api.convertImageFormat(
          sourcePath: attachment.diskPath!,
          targetFormat: 'png',
        );
      } else {
        bytes = await File(attachment.diskPath!).readAsBytes();
      }

      final fileName = attachment.isImage && attachment.fileExt == 'webp'
          ? '${attachment.fileName.contains('.') ? attachment.fileName.substring(0, attachment.fileName.lastIndexOf('.')) : attachment.fileName}.png'
          : attachment.fileName;

      await FilePicker.platform.saveFile(
        dialogTitle: 'Save file',
        fileName: fileName,
        bytes: bytes,
      );

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
