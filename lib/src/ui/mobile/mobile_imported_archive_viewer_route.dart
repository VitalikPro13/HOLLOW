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
import 'package:hollow/src/rust/api/archive.dart' as archive_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/archive/shared/archive_message_list.dart';
import 'package:hollow/src/ui/archive/shared/archive_sender_filter.dart';
import 'package:hollow/src/ui/archive/shared/archive_shared_widgets.dart';
import 'package:hollow/src/ui/archive/shared/archive_toolbar.dart';
import 'package:hollow/src/ui/archive/shared/archive_verification_banner.dart';
import 'package:hollow/src/ui/archive/shared/imported_archive_prep.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_archive_message_actions.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Full-screen route for viewing an imported .hollow-archive file.
class MobileImportedArchiveViewerRoute extends ConsumerStatefulWidget {
  final String path;

  const MobileImportedArchiveViewerRoute({
    super.key,
    required this.path,
  });

  @override
  ConsumerState<MobileImportedArchiveViewerRoute> createState() =>
      _MobileImportedArchiveViewerRouteState();
}

class _MobileImportedArchiveViewerRouteState
    extends ConsumerState<MobileImportedArchiveViewerRoute> {
  final _listController = ArchiveMessageListController();
  bool _isPicking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(archiveFilterSenderProvider.notifier).state = null;
      ref.read(archiveMessageSearchOpenProvider.notifier).state = false;
      ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
      ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
      ref.read(archiveJumpToDateProvider.notifier).state = null;
      ref.read(importedArchiveSelectedChannelProvider.notifier).state =
          null;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        ref.read(archiveFilterSenderProvider.notifier).state = null;
        ref.read(archiveMessageSearchOpenProvider.notifier).state = false;
        ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
        ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
        ref.read(archiveJumpToDateProvider.notifier).state = null;
        ref.read(importedArchiveSelectedChannelProvider.notifier).state =
            null;
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
    final dataAsync =
        ref.watch(importedArchiveDataProvider(widget.path));

    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: ReduceMotionController.instance.isReduced
              ? Duration.zero
              : const Duration(milliseconds: 300),
          switchInCurve: Curves.easeOut,
          child: dataAsync.when(
          loading: () =>
              const Center(key: ValueKey('loading'), child: CircularProgressIndicator()),
          error: (e, _) => Column(
            key: const ValueKey('error'),
            children: [
              _backHeader(hollow),
              Expanded(
                child: Center(
                  child: Text('Failed to load: $e',
                      style: TextStyle(color: hollow.error)),
                ),
              ),
            ],
          ),
          data: (data) => _buildArchiveViewer(hollow, data),
        ),
        ),
      ),
    );
  }

  Widget _backHeader(HollowTheme hollow) {
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.xs, vertical: HollowSpacing.sm),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          HollowPressable(
            onTap: () => Navigator.pop(context),
            semanticLabel: 'Back',
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(8),
            child: Icon(LucideIcons.chevronLeft,
                size: 20, color: hollow.textPrimary),
          ),
          Expanded(
            child: Text('Imported Archive',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w600,
                )),
          ),
        ],
      ),
    );
  }

  Widget _buildArchiveViewer(
      HollowTheme hollow, archive_api.ArchiveData data) {
    final localPeerId = ref.watch(identityProvider).peerId ?? '';
    final profiles = ref.watch(profileProvider);
    final filterSender = ref.watch(archiveFilterSenderProvider);
    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);
    final selectedChannelId =
        ref.watch(importedArchiveSelectedChannelProvider);

    final prep = prepareImportedArchive(
      data: data,
      localPeerId: localPeerId,
      filterSender: filterSender,
      selectedChannelId: selectedChannelId,
      displayNameOf: (id) => displayNameFor(profiles, id),
      mobile: true,
    );
    final isDm = prep.isDm;
    final exporterPeerId = data.verification.exporterPeerId;

    final Widget headerLeading = isDm
        ? HollowAvatar(peerId: data.peerId ?? '', size: 24)
        : Text('#',
            style: TextStyle(
                color: hollow.textSecondary,
                fontWeight: FontWeight.w700,
                fontSize: 18));

    final visibleMessages = isDm
        ? (prep.dmMessages! as List<dynamic>)
        : (prep.channelMessages! as List<dynamic>);

    return Column(
      children: [
        // Back + title header
        ArchiveMobileToolbar(
          leading: headerLeading,
          title: prep.headerTitle,
          subtitle: prep.headerSubtitle,
          onBack: () => Navigator.pop(context),
          onFilter: !isDm &&
                  prep.uniqueSenders != null &&
                  prep.uniqueSenders!.length > 1
              ? () => _showFilterSheet(
                  prep.uniqueSenders!, filterSender, prep.senderNames)
              : null,
          filterActive: filterSender != null,
          onJumpToDate: visibleMessages.isNotEmpty
              ? () {
                  final first = visibleMessages.first is ChatMessage
                      ? (visibleMessages.first as ChatMessage).timestamp
                      : (visibleMessages.first as ChannelChatMessage)
                          .timestamp;
                  final last = visibleMessages.last is ChatMessage
                      ? (visibleMessages.last as ChatMessage).timestamp
                      : (visibleMessages.last as ChannelChatMessage)
                          .timestamp;
                  _pickDate(first, last);
                }
              : null,
          onToggleSearch: _toggleSearch,
          searchOpen: searchOpen,
        ),

        // Verification banner
        ArchiveVerificationBanner(
          archiveSigValid: prep.archiveSigValid,
          archiveSigText: prep.archiveSigText,
          msgSigWarning: prep.msgSigWarning,
          msgSigText: prep.msgSigText,
          dense: true,
        ),

        // Channel selector for server archives
        if (prep.isServer && data.channels.length > 1)
          ArchiveChannelSelector(
            channels: data.channels,
            activeChannelId: prep.activeChannelId,
            onChannelSelected: (channelId) {
              ref
                  .read(importedArchiveSelectedChannelProvider.notifier)
                  .state = channelId;
              ref.read(archiveFilterSenderProvider.notifier).state = null;
              ref.read(archiveMessageSearchQueryProvider.notifier).state =
                  '';
              ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
            },
          ),

        // Search bar
        if (searchOpen)
          ArchiveListSearchBar(
            texts: [
              for (final m in visibleMessages)
                m is ChatMessage ? m.text : (m as ChannelChatMessage).text,
            ],
            controller: _listController,
          ),

        // Message list
        Expanded(
          child: visibleMessages.isEmpty
              ? Center(
                  child: Text('No messages',
                      style: HollowTypography.body
                          .copyWith(color: hollow.textSecondary)),
                )
              : isDm
                  ? _buildDmMessageList(
                      prep.dmMessages!, profiles, localPeerId, data,
                      prep.editsMap, prep.proofContext, prep.proofMsgType,
                      exporterPeerId)
                  : _buildChannelMessageList(
                      prep.channelMessages!,
                      prep.unfilteredChannelMessages ?? prep.channelMessages!,
                      profiles, prep.editsMap, prep.proofContext,
                      prep.proofMsgType),
        ),
      ],
    );
  }

  Widget _buildDmMessageList(
    List<ChatMessage> messages,
    Map<String, storage_api.UserProfile> profiles,
    String localPeerId,
    archive_api.ArchiveData data,
    Map<String, List<ArchiveEditEntry>> editsMap,
    String proofContext,
    String proofMsgType,
    String exporterPeerId,
  ) {
    // Exporter-relative proof context (imported archives).
    String dmProofCtxFor(ChatMessage msg) {
      final senderPeerId = msg.isMe ? localPeerId : (data.peerId ?? '');
      return proofMsgType == 'dm'
          ? (senderPeerId == exporterPeerId ? proofContext : exporterPeerId)
          : proofContext;
    }

    return ArchiveDmMessageList(
      messages: messages,
      peerId: data.peerId ?? '',
      localPeerId: localPeerId,
      editsMap: editsMap,
      proofContextFor: dmProofCtxFor,
      proofMsgType: proofMsgType,
      controller: _listController,
      scrollDuration: _scrollDuration,
      actionWrapper: (context, msg, child) {
        final senderPeerId =
            msg.isMe ? localPeerId : (data.peerId ?? '');
        return ArchiveLongPressMessage(
          onLongPress: () => _showActions(
            msg.text,
            displayNameFor(profiles, senderPeerId),
            msg.timestamp,
            senderPeerId,
            msg.signature,
            msg.publicKey,
            msg.messageId,
            msg.editedAt,
            dmProofCtxFor(msg),
            proofMsgType,
            msg.fileAttachment,
            profiles,
          ),
          child: child,
        );
      },
    );
  }

  Widget _buildChannelMessageList(
    List<ChannelChatMessage> messages,
    List<ChannelChatMessage> allMessages,
    Map<String, storage_api.UserProfile> profiles,
    Map<String, List<ArchiveEditEntry>> editsMap,
    String proofContext,
    String proofMsgType,
  ) {
    return ArchiveChannelMessageList(
      messages: messages,
      allMessages: allMessages,
      serverId: proofContext.split(':').first,
      editsMap: editsMap,
      proofContext: proofContext,
      proofMsgType: proofMsgType,
      controller: _listController,
      scrollDuration: _scrollDuration,
      actionWrapper: (context, msg, child) => ArchiveLongPressMessage(
        onLongPress: () => _showActions(
          msg.text,
          displayNameFor(profiles, msg.senderId),
          msg.timestamp,
          msg.senderId,
          msg.signature,
          msg.publicKey,
          msg.messageId,
          msg.editedAt,
          proofContext,
          proofMsgType,
          msg.fileAttachment,
          profiles,
        ),
        child: child,
      ),
    );
  }

  // ── Shared helpers ─────────────────────────────────────────────

  void _showActions(
    String text,
    String senderName,
    DateTime timestamp,
    String senderPeerId,
    String? signature,
    String? publicKey,
    String? messageId,
    DateTime? editedAt,
    String proofContext,
    String proofMsgType,
    FileAttachment? fileAttachment,
    Map<String, storage_api.UserProfile> profiles,
  ) {
    final time =
        '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
    showMobileArchiveMessageActions(
      context: context,
      messageText: text,
      senderName: senderName,
      timestamp: time,
      onCopy: text.isNotEmpty && !text.startsWith('[file:')
          ? () {
              Clipboard.setData(ClipboardData(text: text));
              HollowToast.show(context, 'Copied to clipboard',
                  type: HollowToastType.success);
            }
          : null,
      onDownload:
          fileAttachment != null && fileAttachment.diskPath != null
              ? () => _saveFile(fileAttachment)
              : null,
      onInfo: messageId != null
          ? () {
              showMessageProofDialog(
                context,
                MessageProofData(
                  senderPeerId: senderPeerId,
                  senderDisplayName:
                      displayNameFor(profiles, senderPeerId),
                  text: text,
                  timestampMs: (editedAt ?? timestamp)
                      .millisecondsSinceEpoch,
                  signature: signature,
                  publicKey: publicKey,
                  messageId: messageId,
                  context: proofContext,
                  msgType: proofMsgType,
                  fileAttachment: fileAttachment,
                ),
              );
            }
          : null,
    );
  }

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
