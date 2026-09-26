import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/message_preview.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/rust/api/archive.dart' as archive_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/archive/archive_message_viewer.dart'
    show archiveLoadError, jumpToArchiveDate, toggleArchiveSearch;
import 'package:hollow/src/ui/archive/shared/archive_message_list.dart';
import 'package:hollow/src/ui/archive/shared/archive_sender_filter.dart';
import 'package:hollow/src/ui/archive/shared/archive_toolbar.dart';
import 'package:hollow/src/ui/archive/shared/archive_verification_banner.dart';
import 'package:hollow/src/ui/archive/shared/imported_archive_prep.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/long_press_message.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:hollow/src/ui/media/media_viewer_scope.dart';
import 'package:hollow/src/ui/mobile/mobile_archive_message_actions.dart';
import 'package:hollow/src/ui/mobile/mobile_archive_viewer_route.dart'
    show archiveMessageTimeLabel;
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Reading an imported .hollow-archive on a phone, its signatures checked.
class MobileImportedArchiveViewerRoute extends ConsumerStatefulWidget {
  final String path;

  const MobileImportedArchiveViewerRoute({super.key, required this.path});

  @override
  ConsumerState<MobileImportedArchiveViewerRoute> createState() =>
      _MobileImportedArchiveViewerRouteState();
}

class _MobileImportedArchiveViewerRouteState
    extends ConsumerState<MobileImportedArchiveViewerRoute> {
  final _listController = ArchiveMessageListController();

  @override
  void initState() {
    super.initState();
    // Past the first frame: a provider written while the tree builds asserts.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      resetArchiveViewerState(ref.read);
      ref.read(importedArchiveSelectedChannelProvider.notifier).state = null;
    });
  }

  Duration _scrollDuration() => ReduceMotionController.instance.isReduced
      ? Duration.zero
      : const Duration(milliseconds: 300);

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final dataAsync = ref.watch(importedArchiveDataProvider(widget.path));

    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        // Opening an archive checks every signature in it, so it can take a
        // while: Back is there from the first frame.
        child: dataAsync.when(
          loading: () => Column(
            children: [
              _backHeader(hollow),
              const Expanded(child: Center(child: _OpeningArchive())),
            ],
          ),
          error: (_, _) => Column(
            children: [
              _backHeader(hollow),
              Expanded(
                child: archiveLoadError(
                    () => ref
                        .invalidate(importedArchiveDataProvider(widget.path)),
                    touch: true),
              ),
            ],
          ),
          data: (data) => _viewer(hollow, data),
        ),
      ),
    );
  }

  Widget _backHeader(HollowTheme hollow) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xs),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          HollowIconButton(
            icon: LucideIcons.chevronLeft,
            label: 'Back',
            size: 44,
            onPressed: () => Navigator.pop(context),
          ),
          Expanded(
            child: Text(
              'Imported archive',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HollowTypography.subheading
                  .copyWith(color: hollow.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _viewer(HollowTheme hollow, archive_api.ArchiveData data) {
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
    );
    final isDm = prep.isDm;
    final List<(DateTime, String)> shown = isDm
        ? [for (final m in prep.dmMessages!) (m.timestamp, m.text)]
        : [for (final m in prep.channelMessages!) (m.timestamp, m.text)];

    return Column(
      children: [
        ArchiveMobileToolbar(
          leading: isDm
              ? HollowAvatar(peerId: data.peerId ?? '', size: 28)
              : Icon(LucideIcons.hash, size: 20, color: hollow.textSecondary),
          title: prep.headerTitle,
          subtitle: prep.headerSubtitle,
          onBack: () => Navigator.pop(context),
          onFilter: !isDm && (prep.uniqueSenders?.length ?? 0) > 1
              ? () => showArchiveFilterSheet(
                    context,
                    senderIds: prep.uniqueSenders!,
                    selectedSender: filterSender,
                    senderNames: prep.senderNames,
                    onSelected: _setSender,
                  )
              : null,
          filterActive: filterSender != null,
          onJumpToDate: shown.isNotEmpty
              ? () => jumpToArchiveDate(
                  context, ref, [for (final m in shown) m.$1])
              : null,
          onToggleSearch: () => toggleArchiveSearch(ref),
          searchOpen: searchOpen,
        ),
        ArchiveVerificationBanner(
          archiveSigValid: prep.archiveSigValid,
          archiveSigText: prep.archiveSigText,
          msgSigWarning: prep.msgSigWarning,
          msgSigText: prep.msgSigText,
        ),
        if (prep.isServer && data.channels.length > 1)
          ArchiveChannelSelector(
            channels: data.channels,
            activeChannelId: prep.activeChannelId,
            onChannelSelected: (channelId) {
              ref.read(importedArchiveSelectedChannelProvider.notifier).state =
                  channelId;
              _setSender(null);
            },
          ),
        if (searchOpen)
          ArchiveListSearchBar(
            texts: [for (final m in shown) m.$2],
            controller: _listController,
          ),
        Expanded(
          child: shown.isEmpty
              ? const HollowEmptyState(title: 'No messages')
              : MediaViewerScope(
                  // Read-only: an archived file can be saved and nothing else.
                  actions: MediaViewerActions(
                      onSaveAs: (a) => saveArchivedAttachmentMobile(context, a)),
                  child: isDm
                      ? _dmList(prep, data, localPeerId)
                      : _channelList(prep),
                ),
        ),
      ],
    );
  }

  Widget _dmList(ImportedArchivePrep prep, archive_api.ArchiveData data,
      String localPeerId) {
    final peerId = data.peerId ?? '';
    final exporter = data.verification.exporterPeerId;
    // A DM is signed for the OTHER side: the exporter's messages name the
    // peer, the peer's name the exporter.
    String proofContextFor(ChatMessage msg) {
      final sender = msg.isMe ? localPeerId : peerId;
      return prep.proofMsgType == 'dm'
          ? (sender == exporter ? prep.proofContext : exporter)
          : prep.proofContext;
    }

    return ArchiveDmMessageList(
      messages: prep.dmMessages!,
      peerId: peerId,
      localPeerId: localPeerId,
      editsMap: prep.editsMap,
      proofContextFor: proofContextFor,
      proofMsgType: prep.proofMsgType,
      controller: _listController,
      scrollDuration: _scrollDuration,
      actionWrapper: (context, msg, child) => LongPressMessage(
        onLongPress: () => _showActions(
          text: msg.text,
          timestamp: msg.timestamp,
          editedAt: msg.editedAt,
          senderPeerId: msg.isMe ? localPeerId : peerId,
          signature: msg.signature,
          publicKey: msg.publicKey,
          messageId: msg.messageId,
          proofContext: proofContextFor(msg),
          proofMsgType: prep.proofMsgType,
          attachment: msg.fileAttachment,
          preverified: msg.archiveSignatureValid,
        ),
        child: child,
      ),
    );
  }

  Widget _channelList(ImportedArchivePrep prep) {
    return ArchiveChannelMessageList(
      messages: prep.channelMessages!,
      allMessages: prep.unfilteredChannelMessages ?? prep.channelMessages!,
      serverId: prep.proofContext.split(':').first,
      editsMap: prep.editsMap,
      proofContext: prep.proofContext,
      proofMsgType: prep.proofMsgType,
      controller: _listController,
      scrollDuration: _scrollDuration,
      actionWrapper: (context, ChannelChatMessage msg, child) =>
          LongPressMessage(
        onLongPress: () => _showActions(
          text: msg.text,
          timestamp: msg.timestamp,
          editedAt: msg.editedAt,
          senderPeerId: msg.senderId,
          signature: msg.signature,
          publicKey: msg.publicKey,
          messageId: msg.messageId,
          proofContext: prep.proofContext,
          proofMsgType: prep.proofMsgType,
          attachment: msg.fileAttachment,
          preverified: msg.archiveSignatureValid,
        ),
        child: child,
      ),
    );
  }

  void _setSender(String? sender) {
    ref.read(archiveFilterSenderProvider.notifier).state = sender;
    ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
    ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
  }

  void _showActions({
    required String text,
    required DateTime timestamp,
    required DateTime? editedAt,
    required String senderPeerId,
    required String? signature,
    required String? publicKey,
    required String? messageId,
    required String proofContext,
    required String proofMsgType,
    required FileAttachment? attachment,
    required bool? preverified,
  }) {
    final profiles = ref.read(profileProvider);
    final senderName = displayNameFor(profiles, senderPeerId);
    showMobileArchiveMessageActions(
      context: context,
      messageText: messagePreviewText(text, attachment: attachment),
      senderName: senderName,
      timestamp: archiveMessageTimeLabel(timestamp),
      onCopy: text.isNotEmpty && !text.startsWith('[file:')
          ? () {
              Clipboard.setData(ClipboardData(text: text));
              HollowToast.show(context, 'Copied to clipboard',
                  type: HollowToastType.success);
            }
          : null,
      onDownload: attachment?.diskPath != null
          ? () => saveArchivedAttachmentMobile(context, attachment!)
          : null,
      onInfo: messageId == null
          ? null
          : () => showMessageProofDialog(
                context,
                MessageProofData(
                  senderPeerId: senderPeerId,
                  senderDisplayName: senderName,
                  text: text,
                  timestampMs: (editedAt ?? timestamp).millisecondsSinceEpoch,
                  signature: signature,
                  publicKey: publicKey,
                  messageId: messageId,
                  context: proofContext,
                  msgType: proofMsgType,
                  fileAttachment: attachment,
                  preverified: preverified,
                ),
              ),
    );
  }
}

/// The wait while an archive opens, held back for its first second like a
/// delayed spinner so a quick open never flashes.
class _OpeningArchive extends StatefulWidget {
  const _OpeningArchive();

  @override
  State<_OpeningArchive> createState() => _OpeningArchiveState();
}

class _OpeningArchiveState extends State<_OpeningArchive> {
  Timer? _reveal;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    _reveal = Timer(HollowSpinner.revealAfter, () {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  void dispose() {
    _reveal?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_shown) return const SizedBox.shrink();
    final hollow = HollowTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const HollowSpinner.large(),
        const SizedBox(height: HollowSpacing.md),
        Text(
          'Opening the archive',
          style: HollowTypography.bodyTouch.copyWith(color: hollow.textSecondary),
        ),
      ],
    );
  }
}
