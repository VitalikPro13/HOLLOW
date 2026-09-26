import 'dart:async';
import 'dart:io';

import 'package:hollow/src/core/friendly_error.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/ui/components/conversation_row.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/album_grouping.dart';
import 'package:hollow/src/ui/chat/album_bubble.dart';
import 'package:hollow/src/ui/chat/chat_drop_zone.dart';
import 'package:hollow/src/ui/chat/staged_attachments.dart';
import 'package:hollow/src/ui/chat/chat_input_shortcuts.dart';
import 'package:hollow/src/ui/chat/emote_composer.dart';
import 'package:hollow/src/ui/chat/emote_image.dart';
import 'package:hollow/src/core/message_preview.dart';
import 'package:hollow/src/core/providers/emote_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/call_record.dart';
import 'package:hollow/src/core/providers/call_records_provider.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/providers/app_shortcuts_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/event_provider.dart';
import 'package:hollow/src/core/providers/link_preview_settings_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/download_manager_provider.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/ui/components/call_duration_text.dart';
import 'package:hollow/src/core/providers/unread_marker_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/core/providers/saved_messages_provider.dart';
import 'package:hollow/src/core/providers/typing_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/message_action_bar.dart';
import 'package:hollow/src/ui/chat/message_bubble.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/chat/voice_recorder_bar.dart';
import 'package:hollow/src/core/services/voice_message_recorder.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/saved_messages_avatar.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/media/media_item.dart';
import 'package:hollow/src/ui/media/media_viewer_scope.dart';
import 'package:hollow/src/ui/components/large_file_share_dialog.dart';
import 'package:hollow/src/ui/components/identity_destroyed_banner.dart';
import 'package:hollow/src/ui/components/security_alert_banner.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'package:hollow/src/ui/call/call_actions.dart';
import 'package:hollow/src/ui/call/call_side_panel.dart';
import 'package:hollow/src/ui/call/call_stage.dart';
import 'package:hollow/src/ui/call/call_stage_sources.dart';
import 'package:hollow/src/ui/call/dm_call_row.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/chat/dm_profile_panel.dart';
import 'package:hollow/src/ui/chat/expression_picker.dart';
import 'package:hollow/src/core/services/attachment_export.dart';

// The twins' shared building blocks live in chat_pane_shared.dart, re-exported
// here for the existing consumers (mobile routes, archive viewers).
export 'package:hollow/src/ui/chat/chat_pane_shared.dart'
    show
        shouldGroup,
        shouldShowDateSeparator,
        DateSeparator,
        TypingIndicatorBar,
        TypingDots,
        chatSelectionArea,
        selectionMustBeScopedToRows,
        ChatScrollRail,
        chatListWithRail,
        unreadDividerIndex;

final dmProfilePanelProvider = StateProvider<bool>((ref) => true);

class ChatPane extends ConsumerStatefulWidget {
  final String peerId;
  final int? splitPaneIndex;

  const ChatPane({
    super.key,
    required this.peerId,
    this.splitPaneIndex,
  });

  @override
  ConsumerState<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends ConsumerState<ChatPane> {
  void _handleSplitToggle(WidgetRef ref) {
    final split = ref.read(splitViewProvider);
    if (split.isSplit) {
      ref.read(splitViewProvider.notifier).closePane(
            widget.splitPaneIndex ?? 0,
          );
    } else {
      ref.read(splitViewProvider.notifier).openSplit();
    }
  }

  final _controller = EmoteComposerController();
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  final _scrollOffsetController = ScrollOffsetController();
  final _focusNode = FocusNode();
  // `:` shortcode autocomplete (emotes + Unicode emoji).
  final _composerLayerLink = LayerLink();
  late final EmoteAutocomplete _emoteAutocomplete = EmoteAutocomplete(
    link: _composerLayerLink,
    controller: _controller,
    emotesSource: _composerEmotes,
  );

  List<ComposerEmote> _composerEmotes() =>
      (ref.read(personalEmotesProvider).valueOrNull ?? const [])
          .map((e) => ComposerEmote(e.name, e.hash))
          .toList();
  bool _historyLoaded = false;
  bool _historyStarted = false;
  bool _historyFailed = false;
  bool _isPicking = false;
  String? _editingMessageId;
  String? _replyToMessageId;
  String? _replyToText;
  String? _replyToSenderName;
  String? _replyToImagePath;
  DateTime? _lastTypingSent;
  int? _highlightIndex;
  bool _showScrollPill = false;
  /// In-conversation message search (issue #54).
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<storage_api.StoredMessage> _searchResults = const [];
  /// Picked but not yet sent.
  List<StagedAttachment> _staged = const [];
  /// True while recording, which swaps the input row for the
  /// [VoiceRecorderBar].
  bool _isRecordingVoice = false;
  /// Set while a typed URL's OG metadata is being fetched in the background.
  String? _stagedPreviewUrl;
  network_api.LinkPreviewRef? _stagedPreview;
  bool _stagedPreviewLoading = false;
  HollowLink? _stagedHollowLink;
  /// Sent-before-the-fetch-landed bookkeeping (issue #45).
  final LatePreviewAttacher _latePreview = LatePreviewAttacher();
  Timer? _urlDebounce;
  static final RegExp _urlRegex = RegExp(r'(?:https?|hollow)://[^\s<>"' "'" r')\]}]+');

  /// The one side panel while the call's stage is up: the chat by default.
  _StagePanel? _stagePanel = _StagePanel.chat;

  @override
  void initState() {
    super.initState();
    // Close search on entering a conversation; it cannot be reset in dispose,
    // where Riverpod forbids all ref usage.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(chatSearchOpenProvider.notifier).state = false;
    });
    _loadHistory();
    _itemPositionsListener.itemPositions.addListener(_onScrollPositionChanged);
  }

  bool _wasNearBottom = false;

  void _onScrollPositionChanged() {
    final nearBottom = _isNearBottom;
    if (_showScrollPill == nearBottom) {
      setState(() => _showScrollPill = !nearBottom);
    }
    ref.read(chatAtBottomProvider.notifier).state = nearBottom;
    // Edge-triggered: per scroll frame this is a map clone and an FFI settings
    // write on every tick.
    if (nearBottom && !_wasNearBottom) {
      final msgs = ref.read(chatProvider)[widget.peerId];
      // Reached the bottom: release the freeze, and snap to the true newest row
      // if anything was held back.
      if (_frozenLen != null && msgs != null && msgs.length > _frozenLen!) {
        _jumpToBottom();
      } else {
        _frozenLen = null;
      }
      if (msgs != null && msgs.isNotEmpty) {
        ref.read(unreadProvider.notifier).markDmSeen(
              widget.peerId, msgs.last.messageId);
      }
    } else if (!nearBottom && _wasNearBottom) {
      // Left the bottom: freeze the display so arrivals cannot shift the
      // reading position. No setState, because nothing changes until a message
      // arrives and that arrival rebuilds via the watch.
      _frozenLen ??= (ref.read(chatProvider)[widget.peerId] ?? const []).length;
    }
    _wasNearBottom = nearBottom;
  }

  Future<void> _loadHistory() async {
    if (_historyStarted) return;
    _historyStarted = true;
    final ok = await ref.read(chatProvider.notifier).loadHistory(widget.peerId);
    if (!mounted) return;
    setState(() {
      _historyLoaded = true;
      _historyFailed = !ok;
    });
    // ScrollablePositionedList honours `initialScrollIndex` only at first
    // build, so a list grown by loadHistory needs an explicit jump.
    _jumpToBottom();
    final msgs = ref.read(chatProvider)[widget.peerId];
    final latestId = msgs != null && msgs.isNotEmpty
        ? msgs.last.messageId
        : null;
    ref.read(unreadProvider.notifier).markDmSeen(widget.peerId, latestId);
    // Re-request files whose bytes never arrived, so an image stuck as a
    // metadata-only bubble fills in when the thread is opened.
    ref.read(eventStreamProvider.notifier)
        .requestMissingDmFilesOnOpen(widget.peerId);
  }

  @override
  void dispose() {
    _urlDebounce?.cancel();
    _latePreview.disarm();
    _emoteAutocomplete.dismiss();
    _itemPositionsListener.itemPositions.removeListener(_onScrollPositionChanged);
    _controller.dispose();
    _focusNode.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  // Reversed list: the NEWEST message is index 0 pinned to the bottom, so "at
  // bottom" is simply "index 0 visible", length-independent and immune to burst
  // growth. While the user reads history the display list is FROZEN
  // (_frozenLen) so arrivals cannot shift the view; reaching the bottom,
  // tapping the pill or sending releases it and jumps, never animates.

  /// Non-null while the user is scrolled up: display list capped here.
  int? _frozenLen;

  /// Albums of the list last displayed, for the rows built from it.
  AlbumCollapse<ChatMessage> _albums = collapseDmAlbums(const []);

  /// The messages currently displayed: the frozen prefix while scrolled up,
  /// with every album folded into its first item.
  List<ChatMessage> _displayMessages(List<ChatMessage> messages) {
    final frozen = _frozenLen;
    final visible = (frozen == null || messages.length <= frozen)
        ? messages
        : messages.sublist(0, frozen);
    _albums = collapseDmAlbums(visible);
    return _albums.display;
  }

  bool get _isNearBottom {
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return true;
    return positions.any((p) => p.index <= 0);
  }

  void _releaseFreeze() {
    if (_frozenLen != null) setState(() => _frozenLen = null);
  }

  /// Snaps to the newest message, INSTANT everywhere: an animated scroll on
  /// receive renders the new row and then glides to it, which reads as a jump
  /// followed by a move.
  void _jumpToBottom() {
    _releaseFreeze();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScrollController.isAttached) return;
      _itemScrollController.jumpTo(index: 0, alignment: 0.0);
    });
  }

  void _scrollToBottom() => _jumpToBottom();

  /// [index] is CHRONOLOGICAL (0 = oldest); the conversion to the reversed
  /// builder index happens here, in one place.
  void _scrollToMessage(int index) {
    if (!_itemScrollController.isAttached) return;
    final messages =
        _displayMessages(ref.read(chatProvider)[widget.peerId] ?? []);
    if (index < 0 || index >= messages.length) return;
    setState(() => _highlightIndex = index);
    // Reversed alignment measures from the BOTTOM edge, so 0.6 lands the
    // target in the upper-middle area.
    if (HollowDurations.animationsDisabled) {
      _itemScrollController.jumpTo(
          index: messages.length - 1 - index, alignment: 0.6);
    } else {
      _itemScrollController.scrollTo(
        index: messages.length - 1 - index,
        duration: const Duration(milliseconds: 300),
        curve: HollowCurves.enter,
        alignment: 0.6,
      );
    }
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightIndex = null);
    });
  }

  void _onTextChanged(String text) {
    _urlDebounce?.cancel();
    _urlDebounce = Timer(const Duration(milliseconds: 600), _detectUrl);

    _emoteAutocomplete.update(context, text);

    if (text.isEmpty) return;
    final amInvisible =
        ref.read(invisibleModeProvider);
    if (amInvisible) return;
    final now = DateTime.now();
    if (_lastTypingSent != null &&
        now.difference(_lastTypingSent!).inSeconds < 3) {
      return;
    }
    _lastTypingSent = now;
    network_api.sendTypingIndicator(
      serverId: '',
      channelId: widget.peerId,
    ).catchError((_) {});
  }

  /// Kicks off a background OG fetch for the first URL in the compose text when
  /// it differs from the staged one, and clears the staged preview when the URL
  /// is removed.
  void _detectUrl() {
    if (!mounted) return;
    // Previews off: never touch the pasted URL at all (issue #45). Hollow deep
    // links still resolve, because those are parsed locally.
    if (!ref.read(linkPreviewsEnabledProvider)) return;
    final text = _controller.text;
    final match = _urlRegex.firstMatch(text);
    final url = match?.group(0);
    if (url == _stagedPreviewUrl) return;
    if (url == null) {
      setState(() {
        _stagedPreviewUrl = null;
        _stagedPreview = null;
        _stagedPreviewLoading = false;
        _stagedHollowLink = null;
      });
      return;
    }

    final hollowLinks = extractHollowLinks(url);
    if (hollowLinks.isNotEmpty) {
      setState(() {
        _stagedPreviewUrl = url;
        _stagedPreview = null;
        _stagedPreviewLoading = false;
        _stagedHollowLink = hollowLinks.first;
      });
      return;
    }

    setState(() {
      _stagedPreviewUrl = url;
      _stagedPreview = null;
      _stagedPreviewLoading = true;
      _stagedHollowLink = null;
    });
    _fetchPreview(url);
  }

  Future<void> _fetchPreview(String url) async {
    try {
      final preview = await network_api.fetchLinkPreview(url: url);
      if (!mounted) return;
      // The send raced this fetch, so the card lands on the message that
      // already went out (issue #45).
      final lateMid = _latePreview.claim(url);
      if (lateMid != null) _attachPreview(lateMid, preview);
      // The user changed or dismissed the URL while the fetch ran.
      if (_stagedPreviewUrl != url) return;
      setState(() {
        _stagedPreview = preview;
        _stagedPreviewLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      // A failed fetch has nothing to attach, and leaving the record would let
      // a later unrelated fetch inherit it.
      _latePreview.claim(url);
      if (_stagedPreviewUrl != url) return;
      // Failed silently: the URL stays, the staged card does not.
      setState(() {
        _stagedPreviewUrl = null;
        _stagedPreview = null;
        _stagedPreviewLoading = false;
      });
    }
  }

  /// Lands a card on an already-sent message. Deliberately quiet on failure:
  /// the send already succeeded and is on screen, so a missing card is cosmetic
  /// and a toast would be noise about something nobody asked for.
  void _attachPreview(String messageId, network_api.LinkPreviewRef? preview) {
    ref
        .read(chatProvider.notifier)
        .attachLinkPreview(widget.peerId, messageId, preview)
        .catchError((Object e) {
      debugPrint('[HOLLOW] Late link preview attach failed: $e');
    });
  }

  Future<void> _handleSend({bool refocus = true}) async {
    _emoteAutocomplete.dismiss();
    if (_staged.isNotEmpty) {
      // FileHeaderPayload has no link_preview slot, so the staged card must be
      // cleared here or it stays on screen attached to a message that never
      // carried it.
      _urlDebounce?.cancel();
      setState(() {
        _stagedPreviewUrl = null;
        _stagedPreview = null;
        _stagedPreviewLoading = false;
        _stagedHollowLink = null;
      });
      final items = _staged;
      setState(() => _staged = const []);
      await _sendFiles(items);
      return;
    }
    // Expand inline-emote placeholders to [e:name:hash] wire tokens.
    final text = _controller.expandedText().trim();
    if (text.isEmpty) return;
    if (exceedsAssetLimit(text)) {
      HollowToast.show(context, kAssetLimitMessage,
          type: HollowToastType.error);
      return;
    }
    _controller.clear();
    _lastTypingSent = null;
    if (refocus) _focusNode.requestFocus();
    final replyMid = _replyToMessageId;
    // Capture the staged preview BEFORE clearing state; with the fetch still in
    // flight there is nothing to capture, so the URL is remembered and the card
    // attaches when it lands (issue #45).
    final preview = _stagedPreview;
    final wasLoading = _stagedPreviewLoading;
    final pendingUrl = pendingPreviewUrl(
      previewsEnabled: ref.read(linkPreviewsEnabledProvider),
      alreadyStaged: preview != null,
      stagedLoading: wasLoading,
      stagedUrl: _stagedPreviewUrl,
      text: text,
      urlRegex: _urlRegex,
    );
    _urlDebounce?.cancel();
    setState(() {
      _replyToMessageId = null;
      _replyToText = null;
      _replyToSenderName = null;
      _replyToImagePath = null;
      _stagedPreviewUrl = null;
      _stagedPreview = null;
      _stagedPreviewLoading = false;
      _stagedHollowLink = null;
    });
    try {
      final sentMid = await ref
          .read(chatProvider.notifier)
          .sendMessage(widget.peerId, text,
              replyToMid: replyMid, linkPreview: preview);
      if (pendingUrl != null) {
        _latePreview.arm(pendingUrl, sentMid);
        // Nothing is in flight when the debounce never fired.
        if (!wasLoading) _fetchPreview(pendingUrl);
      }
    } catch (_) {
      // The provider adds the bubble only AFTER the network send, so a failure
      // here would vanish silently: composer cleared, no bubble.
      if (!mounted) return;
      HollowToast.show(context, 'Failed to send message',
          type: HollowToastType.error);
      return;
    }
    _scrollToBottom();
  }

  void _stageClipboardImage(String path, String name) {
    unawaited(_stageFiles([StagedAttachment.fromPath(path, name: name)]));
  }

  /// Adds files to the composer's album. Over 34 MB they are offered as
  /// Hollow Shares, one question for the whole batch.
  Future<void> _stageFiles(List<StagedAttachment> incoming) async {
    if (!mounted || incoming.isEmpty) return;
    final accepted = await admitStagedAttachments(context,
        current: _staged, incoming: incoming);
    if (!mounted || accepted.isEmpty) return;
    setState(() => _staged = appendStaged(_staged, accepted));
    _focusNode.requestFocus();
  }

  Future<void> _pickAndStageFile() async {
    if (_isPicking) return;
    _isPicking = true;
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      await _stageFiles([
        for (final f in result.files)
          if (f.path != null)
            StagedAttachment(path: f.path!, name: f.name, sizeBytes: f.size),
      ]);
      // Defer the re-focus until the OS has returned window focus from the
      // native file dialog: a synchronous requestFocus() marks the node focused
      // while keystrokes still go nowhere.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    } finally { _isPicking = false; }
  }

  /// Sends the recorder's `.ogg` immediately, because a voice message should
  /// not need a confirmation click.
  Future<void> _stageVoiceMessage(VoiceRecordingResult result) async {
    if (!mounted) return;
    final file = File(result.filePath);
    if (!await file.exists()) {
      setState(() => _isRecordingVoice = false);
      return;
    }
    final size = await file.length();
    if (size > kLargeFileThresholdBytes) {
      final ok = mounted &&
          await confirmLargeFileShare(context,
              fileName: 'Voice message.ogg', sizeBytes: size);
      if (!ok) {
        try { await file.delete(); } catch (_) {}
        if (mounted) setState(() => _isRecordingVoice = false);
        return;
      }
    }
    setState(() => _isRecordingVoice = false);
    await _sendFiles([
      StagedAttachment(
          path: result.filePath, name: 'Voice message.ogg', sizeBytes: size),
    ]);
  }

  /// Sends an already-written file straight into this conversation with no save
  /// dialog, the "Share pack to this chat" path (issue #36).
  ///
  /// The file is NOT deleted afterwards: our own bubble keeps pointing at it,
  /// so it lives out its life in the temp directory the OS sweeps.
  Future<void> _shareFileToChat(String path, String fileName) async {
    if (!mounted) return;
    await _sendFiles([StagedAttachment.fromPath(path, name: fileName)]);
  }

  /// Sends [items] with the composer text as the caption: one file message,
  /// or an album for two or more.
  Future<void> _sendFiles(List<StagedAttachment> items) async {
    if (items.isEmpty) return;
    final caption = _controller.expandedText().trim();
    _controller.clear();
    final failed = await sendStagedAttachments(
      items: items,
      caption: caption,
      addOptimistic: (item, messageId, text, albumId) {
        ref.read(chatProvider.notifier).addFileMessage(
              widget.peerId,
              messageId,
              item.name,
              item.sizeBytes,
              item.ext,
              item.isImage,
              item.path,
              text: text,
              albumId: albumId,
            );
        _jumpToBottom();
      },
      send: (item, messageId, text, albumId) async {
        await ref.read(fileTransferProvider.notifier).sendFile(
              peerId: widget.peerId,
              filePath: item.path,
              messageId: messageId,
              messageText: text,
              // The display name is the voice-recorder signal; the wire carries a
              // dedicated flag (auto-download gate exemption, issue #41).
              isVoice: item.name == 'Voice message.ogg',
              album: albumId,
            );
        if (item.name.endsWith('.ogg') && item.path.contains('temp')) {
          try { await File(item.path).delete(); } catch (_) {}
        }
      },
    );
    if (failed > 0 && mounted) {
      HollowToast.show(
          context,
          failed == 1 ? 'A file failed to send' : '$failed files failed to send',
          type: HollowToastType.error);
    }
  }

  Future<void> _saveFile(FileAttachment attachment) async {
    if (_isPicking) return;
    _isPicking = true;
    try {
      final isImage = attachment.isImage;
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save file',
        fileName: _saveDialogFileName(attachment),
        type: FileType.custom,
        allowedExtensions:
            isImage ? ['png', 'jpg', 'jpeg', 'webp', 'gif'] : [attachment.fileExt],
      );
      if (savePath == null || attachment.diskPath == null) return;

      await _writeSavedFile(savePath, attachment);

      ref.read(downloadManagerStateProvider.notifier).recordSavedFile(
            savedPath: savePath,
            isImage: isImage,
            isVideo: attachment.videoThumb != null,
          );

      if (mounted) {
        HollowToast.show(context, exportedCopyMessage(savePath),
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, friendlyError(e, fallback: "Couldn't save the file. Try again."), type: HollowToastType.error);
      }
    } finally {
      _isPicking = false;
    }
  }

  /// Default filename for the save dialog: images normalise to .png, gifs stay
  /// .gif, everything else keeps its original name.
  String _saveDialogFileName(FileAttachment attachment) {
    if (!attachment.isImage) return attachment.fileName;
    final baseName = attachment.fileName.contains('.')
        ? attachment.fileName.substring(0, attachment.fileName.lastIndexOf('.'))
        : attachment.fileName;
    return attachment.fileExt.toLowerCase() == 'gif'
        ? '$baseName.gif'
        : '$baseName.png';
  }

  /// Writes the attachment to [savePath], converting a stored WebP image when
  /// the chosen extension asks for another format.
  Future<void> _writeSavedFile(String savePath, FileAttachment attachment) async {
    final targetExt = savePath.contains('.')
        ? savePath.split('.').last.toLowerCase()
        : attachment.fileExt;

    if (attachment.isImage && targetExt != 'webp' && attachment.fileExt == 'webp') {
      final converted = await network_api.convertImageFormat(
        sourcePath: attachment.diskPath!,
        targetFormat: targetExt,
      );
      await File(savePath).writeAsBytes(converted);
    } else {
      await exportAttachmentTo(attachment.diskPath!, savePath);
    }
  }

  Future<void> _requestFileFromPeer(FileAttachment attachment, String senderId) async {
    if (senderId.isEmpty) {
      if (mounted) {
        HollowToast.show(context, 'Cannot download: unknown sender', type: HollowToastType.error);
      }
      return;
    }
    // Manual pull: lift the auto-download-gate pin so real progress renders.
    ref.read(fileTransferProvider.notifier).clearDeclined(attachment.fileId);
    try {
      // No toast: the card itself answers the tap, saying "Requesting..." and
      // then what came back. Failures still toast.
      await network_api.requestFileFromPeer(
        fileId: attachment.fileId,
        peerId: senderId,
        chunks: [],
      );
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, friendlyError(e, fallback: "Couldn't request the file. Try again."), type: HollowToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // Per-conversation select: the map is replaced wholesale on every insert,
    // so watching it rebuilds this pane for activity in any conversation.
    final messages =
        ref.watch(chatProvider.select((m) => m[widget.peerId])) ?? [];

    _registerBuildListeners();

    final typingPeers =
        ref.watch(typingProvider.select((t) => t[widget.peerId])) ?? {};
    final showProfilePanel = ref.watch(dmProfilePanelProvider);
    final profiles = ref.watch(profileProvider);
    final localPeerId = ref.watch(identityProvider).peerId ?? '';

    // The call's stage replaces the message list while a camera or a share
    // needs it, or the user opened it (D2); the chat moves to the side panel.
    final stageShown = watchDmStageShown(ref, widget.peerId);

    // Saved messages is a DM with our OWN master identity: only the header and
    // the call buttons differ, everything below works like any other DM.
    final savedId = ref.watch(savedMessagesPeerIdProvider);
    final isSavedMessages = savedId != null &&
        ref.watch(deviceLinkProvider).identityOf(widget.peerId) == savedId;

    // Custom-emote pull source for every token and reaction in this DM: the
    // counterpart's devices.
    final main = ChatDropZone(
      onFilesDropped: _stageFiles,
      child: Column(
        children: [
          _buildHeader(hollow,
              isSavedMessages: isSavedMessages,
              showProfilePanel: showProfilePanel,
              stageShown: stageShown),

          DmCallRow(peerMaster: widget.peerId),

          if (ref.watch(chatSearchOpenProvider))
            _buildSearchBar(hollow, isSavedMessages),

          // Pinned above the message list rather than a toast, because the
          // warning has to survive scrollback and restarts.
          if (!isSavedMessages) SecurityAlertBanner(peerId: widget.peerId),

          if (!isSavedMessages)
            IdentityDestroyedBanner(peerId: widget.peerId),

          if (stageShown)
            Expanded(
              child: CallStage(source: DmCallStageSource(widget.peerId)),
            )
          else
            ..._buildMessageArea(
                hollow, messages, typingPeers, profiles, localPeerId),
        ],
      ),
    );

    // Custom-emote pull source for every token and reaction in this DM: the
    // counterpart's devices.
    return EmoteScope(
      peerHint: widget.peerId,
      child: stageShown && _stagePanel == _StagePanel.chat
          // The same resizable panel as a voice room's and a meeting's chat.
          ? CallStageWithPanel(
              stage: main,
              panel: _StageChatPanel(
                children: _buildMessageArea(
                    hollow, messages, typingPeers, profiles, localPeerId),
              ),
            )
          : Row(
              children: [
                Expanded(child: main),
                if (stageShown)
                  _stagePanel == _StagePanel.profile
                      ? DmProfilePanel(peerId: widget.peerId)
                      : const SizedBox.shrink()
                else
                  _DmProfilePanelSlider(
                    visible: showProfilePanel,
                    peerId: widget.peerId,
                  ),
              ],
            ),
    );
  }

  /// All build-time ref.listen registrations. MUST be invoked from build():
  /// Riverpod re-registers listeners per build and silently no-ops a
  /// registration made anywhere else.
  void _registerBuildListeners() {
    // Following re-pins to the newest row; reading history freezes the display
    // so the view never shifts mid-read.
    ref.listen<Map<String, List<ChatMessage>>>(
        chatProvider, _onMessageListGrowth);
    // A message arriving while the window is unfocused counts as unread, and if
    // this chat was already open at the bottom nothing else clears it: the
    // scroll handler only marks seen on a bottom re-ENTRY.
    ref.listen<bool>(windowFocusedProvider, _onWindowFocusChanged);
    // Opened by the global quick-search shortcut, which unlike the header
    // button cannot focus the field itself.
    ref.listen<bool>(chatSearchOpenProvider, _onSearchOpenChanged);
  }

  void _onSearchOpenChanged(bool? prev, bool open) {
    if (open) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _searchFocusNode.requestFocus());
      return;
    }
    if (_searchResults.isEmpty && _searchController.text.isEmpty) return;
    _searchController.clear();
    setState(() => _searchResults = const []);
  }

  Future<void> _onSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      setState(() => _searchResults = const []);
      return;
    }
    try {
      final results = await storage_api.searchDmMessages(
        peerId: widget.peerId,
        query: q,
        limit: 20,
      );
      if (mounted) setState(() => _searchResults = results);
    } catch (_) {
      // Store closed or a transient FFI error: leave the last results up rather
      // than blanking the list under the cursor.
    }
  }

  /// Closes search and scrolls to the tapped result. The index is against the
  /// DISPLAY list, possibly frozen, which is what [_scrollToMessage] takes.
  void _jumpToSearchResult(storage_api.StoredMessage msg) {
    final messages =
        _displayMessages(ref.read(chatProvider)[widget.peerId] ?? []);
    final idx = messages.indexWhere((m) => m.messageId == msg.messageId);
    ref.read(chatSearchOpenProvider.notifier).state = false;
    _searchController.clear();
    setState(() => _searchResults = const []);
    if (idx != -1) _scrollToMessage(idx);
  }

  void _onMessageListGrowth(Map<String, List<ChatMessage>>? prev,
      Map<String, List<ChatMessage>> next) {
    final prevLen = (prev?[widget.peerId] ?? const []).length;
    final nextLen = (next[widget.peerId] ?? const []).length;
    if (nextLen <= prevLen) return;
    if (_frozenLen != null) return;
    if (!_isNearBottom) {
      // Scroll-away raced the freeze, so freeze at the pre-growth length and
      // hold this arrival back too.
      _frozenLen = prevLen;
      return;
    }
    _jumpToBottom();
  }

  void _onWindowFocusChanged(bool? prev, bool focused) {
    if (!focused || prev == true) return;
    if (!_isNearBottom || _frozenLen != null) return;
    final msgs = ref.read(chatProvider)[widget.peerId];
    if (msgs == null || msgs.isEmpty) return;
    ref
        .read(unreadProvider.notifier)
        .markDmSeen(widget.peerId, msgs.last.messageId);
  }

  /// DM header: avatar, name(s), connection status, and pane actions.
  Widget _buildHeader(HollowTheme hollow,
      {required bool isSavedMessages,
      required bool showProfilePanel,
      required bool stageShown}) {
    final searchOpen = ref.watch(chatSearchOpenProvider);
    final isSplit = ref.watch(splitViewProvider).isSplit;
    final profile =
        ref.watch(profileProvider.select((p) => p[widget.peerId]));
    final localNick =
        ref.watch(localNicknameProvider.select((m) => m[widget.peerId]));
    final realName = displayNameForPeer(profile, widget.peerId);
    final hasNick = localNick != null && localNick.isNotEmpty;
    final status = profile?.status ?? '';
    return ChatHeaderBar(
      leading: isSavedMessages
          ? const SavedMessagesAvatar(size: 28)
          : PresenceAvatar(
              peerId: widget.peerId,
              size: 28,
              online: identityIsOnline(ref, widget.peerId),
              ring: hollow.surface,
            ),
      title: isSavedMessages ? 'Saved messages' : (hasNick ? localNick : realName),
      subtitle: isSavedMessages ? null : (hasNick ? realName : status),
      badges: [if (stageShown) const _InCallMark()],
      actions: [
        // Hidden for Saved messages (you cannot call yourself) and during a
        // call with this person, which has its own controls.
        if (!isSavedMessages && !_inCallWithPeer()) ...[
          _buildVoiceCallButton(hollow),
          _buildVideoCallButton(hollow),
        ],
        HollowIconButton(
          icon: LucideIcons.search,
          label: 'Search messages',
          selected: searchOpen,
          onPressed: () {
            ref.read(chatSearchOpenProvider.notifier).state = !searchOpen;
            if (!searchOpen) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _searchFocusNode.requestFocus();
              });
            }
          },
        ),
        if (ref.watch(layoutModeProvider) == LayoutMode.dock)
          HollowIconButton(
            icon: LucideIcons.columns,
            label: isSplit ? 'Close this pane' : 'Split view',
            selected: isSplit,
            onPressed: () => _handleSplitToggle(ref),
          ),
        // Last, next to the ONE panel they swap.
        if (stageShown) ...[
          _stagePanelButton(_StagePanel.chat, LucideIcons.messageSquare,
              'Show the chat', 'Hide the chat'),
          _stagePanelButton(_StagePanel.profile, LucideIcons.circleUser,
              'Show profile', 'Hide profile'),
        ] else
          HollowIconButton(
            icon: LucideIcons.circleUser,
            label: showProfilePanel ? 'Hide profile' : 'Show profile',
            selected: showProfilePanel,
            onPressed: () => ref.read(dmProfilePanelProvider.notifier).state =
                !showProfilePanel,
          ),
      ],
    );
  }

  /// Panels swap instantly: a width animation re-lays the stage.
  Widget _stagePanelButton(
      _StagePanel panel, IconData icon, String show, String hide) {
    final open = _stagePanel == panel;
    return HollowIconButton(
      icon: icon,
      label: open ? hide : show,
      selected: open,
      onPressed: () => setState(() => _stagePanel = open ? null : panel),
    );
  }

  bool _inCallWithPeer() =>
      isDmCallWith(ref, ref.watch(callProvider), widget.peerId);

  /// In-conversation message search: query field + up to 20 tappable results.
  Widget _buildSearchBar(HollowTheme hollow, bool isSavedMessages) {
    final name = isSavedMessages
        ? 'Saved messages'
        : displayNameFor(ref.watch(profileProvider), widget.peerId);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          HollowTextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            hintText: 'Search in $name',
            autofocus: true,
            isDense: true,
            prefixIcon: const Icon(LucideIcons.search, size: 16),
            onChanged: _onSearch,
          ),
          if (_searchResults.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _searchResults.length,
                itemBuilder: (_, index) => _buildSearchResultTile(
                    hollow, _searchResults[index], isSavedMessages),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchResultTile(
      HollowTheme hollow, storage_api.StoredMessage msg, bool isSavedMessages) {
    // A DM has exactly two sides, so the sender is a bool: no device to
    // master resolution to do, unlike a channel's result list.
    final mine = msg.isMine || isSavedMessages;
    return ChatSearchResultRow(
      name: mine
          ? 'You'
          : displayNameFor(ref.watch(profileProvider), widget.peerId),
      nameColor: mine ? hollow.accentText : nameColorFor(widget.peerId, hollow),
      time: DateTime.fromMillisecondsSinceEpoch(msg.timestamp.toInt()),
      text: messagePreviewText(msg.text),
      onTap: () => _jumpToSearchResult(msg),
    );
  }
  Widget _buildVoiceCallButton(HollowTheme hollow) {
    final isOnline = identityIsOnline(ref, widget.peerId);
    final isInCall = ref.watch(
        callProvider.select((c) => c.status != CallStatus.idle));
    return HollowIconButton(
      icon: LucideIcons.phone,
      label: 'Start voice call',
      onPressed: isOnline && !isInCall
          ? () => startDmCallFlow(context, ref, widget.peerId)
          : null,
    );
  }

  Widget _buildVideoCallButton(HollowTheme hollow) {
    final isOnline = identityIsOnline(ref, widget.peerId);
    final isInCall = ref.watch(
        callProvider.select((c) => c.status != CallStatus.idle));
    return HollowIconButton(
      icon: LucideIcons.video,
      label: 'Start video call',
      onPressed: isOnline && !isInCall
          ? () => startDmCallFlow(context, ref, widget.peerId, withVideo: true)
          : null,
    );
  }
  /// Opens the GIF picker anchored to the composer button. The pick arrives as
  /// an `[a:g:hash:w:h]` token and stages like an emote.
  /// Opens the sticker picker anchored to the composer button. A pick SENDS
  /// immediately and the panel stays open.
  /// Opens the emoji, GIF and sticker picker over the composer.
  void _openExpressions(BuildContext buttonContext) {
    final box = buttonContext.findRenderObject() as RenderBox?;
    showExpressionPicker(
      context: context,
      anchorPosition: box == null
          ? Offset.zero
          : overlayAnchorOf(buttonContext,
              localOffset: Offset(box.size.width, 0)),
      onEmoji: _insertEmojiAtCursor,
      onAsset: _sendAsset,
      onSharePack: _shareFileToChat,
    );
  }

  /// Send-on-click (issue #36): a sticker or GIF leaves its picker as a MESSAGE
  /// rather than as composer content, with any text already typed riding along
  /// as a caption.
  ///
  /// Focus deliberately stays where it is: pulling it back to the composer
  /// summons the software keyboard over the picker sheet on every pick.
  Future<void> _sendAsset(String token) async {
    _insertEmojiAtCursor(token, refocus: false);
    await _handleSend(refocus: false);
  }

  void _insertEmojiAtCursor(String text, {bool refocus = true}) {
    // Asset tokens become a 1-char placeholder rendered inline as the image;
    // Unicode emoji pass through unchanged.
    text = _controller.displayTextFor(text);
    final sel = _controller.selection;
    final base = sel.isValid ? sel.baseOffset : _controller.text.length;
    final newText = _controller.text.replaceRange(
      base.clamp(0, _controller.text.length),
      (sel.isValid ? sel.extentOffset : base).clamp(0, _controller.text.length),
      text,
    );
    _controller.text = newText;
    _controller.selection = TextSelection.collapsed(offset: base + text.length);
    if (refocus) _focusNode.requestFocus();
  }

  /// The message area, shared by the normal column layout and the screen-share
  /// overlay.
  List<Widget> _buildMessageArea(
    HollowTheme hollow,
    List<ChatMessage> allMessages,
    Set<String> typingPeers,
    Map<String, storage_api.UserProfile> profiles,
    String localPeerId,
  ) {
    // Frozen while reading history, so `allMessages` keeps the true list for
    // mark-seen.
    final messages = _displayMessages(allMessages);
    return [
      Expanded(
        child: Stack(
          children: [
            _buildMessageListLayer(hollow, messages, profiles, localPeerId),
            _buildUnreadPillOverlay(allMessages),
          ],
        ),
      ),

      TypingIndicatorHost(
        names: _typingNames(typingPeers),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
          if (_replyToMessageId != null)
            ChatReplyPreviewBar(
              senderName: _replyToSenderName,
              text: _replyToText,
              imagePath: _replyToImagePath,
              onCancel: _cancelReply,
            ),

          if (_staged.isNotEmpty)
            StagedAttachmentStrip(
              items: _staged,
              onRemove: (i) =>
                  setState(() => _staged = [..._staged]..removeAt(i)),
              onReorder: (from, to) =>
                  setState(() => _staged = reorderStaged(_staged, from, to)),
            ),

          StagedLinkArea(
            hollowLink: _stagedHollowLink,
            previewUrl: _stagedPreviewUrl,
            preview: _stagedPreview,
            previewLoading: _stagedPreviewLoading,
            onDismissHollowLink: _dismissStagedHollowLink,
            onDismissPreview: _dismissStagedPreview,
          ),

          _buildInputBar(hollow),
          ],
        ),
      ),
    ];
  }

  void _cancelReply() {
    setState(() {
      _replyToMessageId = null;
      _replyToText = null;
      _replyToSenderName = null;
      _replyToImagePath = null;
    });
  }

  void _dismissStagedHollowLink() {
    _urlDebounce?.cancel();
    setState(() {
      _stagedPreviewUrl = null;
      _stagedHollowLink = null;
    });
  }

  void _dismissStagedPreview() {
    _urlDebounce?.cancel();
    setState(() {
      _stagedPreviewUrl = null;
      _stagedPreview = null;
      _stagedPreviewLoading = false;
    });
  }

  Widget _buildMessageListLayer(
    HollowTheme hollow,
    List<ChatMessage> messages,
    Map<String, storage_api.UserProfile> profiles,
    String localPeerId,
  ) {
    return MessageActionBarScope(
      child: Builder(
        builder: (scopeContext) => Container(
            color: hollow.background,
            child: messages.isEmpty
                ? _buildConversationStart()
                : _buildMessageList(hollow, messages, profiles, localPeerId),
          ),
      ),
    );
  }

  /// Nothing while the first read runs (it is local and brief), a retry when
  /// it failed, and the start of the conversation when there is none yet.
  Widget _buildConversationStart() {
    if (!_historyLoaded) return const SizedBox.shrink();
    final calls = ref.watch(dmCallRecordsProvider(_callPeer));
    if (!_historyFailed && calls.isNotEmpty) {
      return CallRecordsOnly(records: calls);
    }
    if (_historyFailed) {
      return HollowEmptyState(
        glyph: LucideIcons.circleAlert,
        title: "These messages didn't load",
        action: HollowButton.ghost(
          onPressed: () {
            setState(() {
              _historyStarted = false;
              _historyLoaded = false;
            });
            _loadHistory();
          },
          child: const Text('Try again'),
        ),
      );
    }
    final savedId = ref.watch(savedMessagesPeerIdProvider);
    if (savedId != null &&
        ref.watch(deviceLinkProvider).identityOf(widget.peerId) == savedId) {
      return const HollowEmptyState(
        glyph: LucideIcons.bookmark,
        title: 'Nothing saved yet',
        description: 'Notes and messages you keep for yourself land here.',
      );
    }
    final name = displayNameFor(ref.watch(profileProvider), widget.peerId);
    return HollowEmptyState(
      glyph: LucideIcons.messageCircle,
      title: 'This is the start of your conversation with $name',
    );
  }

  /// The reversed message list plus the per-build row precomputes.
  Widget _buildMessageList(
    HollowTheme hollow,
    List<ChatMessage> messages,
    Map<String, storage_api.UserProfile> profiles,
    String localPeerId,
  ) {
    // One pass per build instead of an O(n) scan per reply row per rebuild.
    final replyIndexById = <String, int>{
      for (var i = 0; i < messages.length; i++)
        if (messages[i].messageId != null) messages[i].messageId!: i,
    };
    // A reply or jump to an album item lands on the album's row.
    for (final e in _albums.anchorIdByItemId.entries) {
      final anchorIndex = replyIndexById[e.value];
      if (anchorIndex != null) replyIndexById.putIfAbsent(e.key, () => anchorIndex);
    }
    // Computed once per build against the list actually on screen, so the
    // reversed index handed to the rail and the chronological one handed to the
    // rows cannot disagree (issue #54).
    final calls = ref.watch(dmCallRecordsProvider(_callPeer));
    final unreadIndex = unreadDividerIndex(
      count: messages.length,
      entrySeenId: _albumRowId(
          ref.watch(unreadMarkerProvider)[dmMarkerKey(widget.peerId)]),
      messageIdAt: (i) => messages[i].messageId,
      isMineAt: (i) => messages[i].isMe,
    );
    return MediaViewerScope(
      mediaContext:
          MediaContext(contextType: 'dm', contextId: widget.peerId),
      actions: _mediaActions(),
      child: reversedChatList(
      context: context,
      listKey: ValueKey('dm-list-${widget.peerId}'),
      itemScrollController: _itemScrollController,
      itemPositionsListener: _itemPositionsListener,
      scrollOffsetController: _scrollOffsetController,
      itemCount: messages.length,
      indexByMessageId: replyIndexById,
      // "Jump to present" goes through the pane because the display list is
      // frozen while reading, so index 0 is not the newest message until the
      // freeze is released (issue #54).
      onJumpToNewest: _scrollToBottom,
      unreadRevIndex:
          unreadIndex == null ? null : messages.length - 1 - unreadIndex,
      itemBuilder: (context, revIndex) => _buildMessageRow(
        context,
        revIndex,
        messages,
        replyIndexById,
        profiles,
        localPeerId,
        unreadIndex,
        calls,
      ),
      ),
    );
  }

  /// The DM's person, whose calls the list places between its rows.
  String get _callPeer => ref.read(deviceLinkProvider).identityOf(widget.peerId);

  /// What the media viewer may do to a message of this conversation.
  MediaViewerActions _mediaActions() => MediaViewerActions(
        onReply: (messageId) {
          final msg = _messageById(messageId);
          if (msg != null) _replyFor(msg)?.call();
        },
        onJumpTo: _jumpToMessageId,
        onDelete: _deleteMessage,
        onReact: (messageId, emoji) async {
          final msg = _messageById(messageId);
          if (msg != null) await _toggleReaction(msg, emoji);
        },
        onSaveAs: _saveFile,
      );

  ChatMessage? _messageById(String messageId) {
    final messages = ref.read(chatProvider)[widget.peerId] ?? const [];
    for (final m in messages) {
      if (m.messageId == messageId) return m;
    }
    return null;
  }

  void _jumpToMessageId(String messageId) {
    final messages =
        _displayMessages(ref.read(chatProvider)[widget.peerId] ?? []);
    final rowId = _albums.anchorIdByItemId[messageId] ?? messageId;
    final index = messages.indexWhere((m) => m.messageId == rowId);
    if (index != -1) _scrollToMessage(index);
  }

  /// One chat row. [revIndex] is the reversed builder index.
  Widget _buildMessageRow(
    BuildContext context,
    int revIndex,
    List<ChatMessage> messages,
    Map<String, int> replyIndexById,
    Map<String, storage_api.UserProfile> profiles,
    String localPeerId,
    int? unreadIndex,
    List<DmCallRecord> callRecords,
  ) {
    // Map the reversed builder index back to chronological order; all row logic
    // below stays in chronological terms.
    final index = messages.length - 1 - revIndex;
    final msg = messages[index];
    final isAlbum = _albums.itemsFor(msg.messageId) != null;
    final calls = callRecordsAround(
      records: callRecords,
      previous: index > 0 ? messages[index - 1].timestamp : null,
      current: msg.timestamp,
      isNewest: index == messages.length - 1,
      historyComplete:
          (ref.read(chatProvider)[widget.peerId]?.length ?? 0) <
              kCallRecordWindow,
    );
    // A call line between two messages breaks the run, like a new sender.
    final showHeader = index == 0 ||
        calls.before.isNotEmpty ||
        !shouldGroup(
          currentIsMe: msg.isMe,
          previousIsMe: messages[index - 1].isMe,
          currentTime: msg.timestamp,
          previousTime: messages[index - 1].timestamp,
        );
    final wrapper = MessageHoverWrapper(
      isMe: msg.isMe,
      messageId: msg.messageId,
      currentText: msg.text,
      isEditing:
          _editingMessageId != null && _editingMessageId == msg.messageId,
      onEditStart: _editStartFor(msg, revIndex),
      onEditSubmit: (newText) {
        setState(() => _editingMessageId = null);
        _submitEdit(msg.messageId!, newText);
      },
      onEditCancel: () => setState(() => _editingMessageId = null),
      onDelete: _deleteFor(msg),
      onReply: _replyFor(msg),
      onReaction: msg.messageId != null
          ? (emoji) => _toggleReaction(msg, emoji)
          : null,
      // An album row's file actions would act on its first item only; the
      // viewer offers them per item instead.
      onDownload: isAlbum ? null : _downloadFor(context, msg),
      // The hover bar and the message menu mirror the card: no Download while
      // nobody can serve the file.
      fileAttachment: isAlbum ? null : msg.fileAttachment,
      onCopy: _copyFor(context, msg),
      onCopyImage: isAlbum ? null : _copyImageFor(context, msg),
      onInfo: _infoFor(context, msg),
      child: _buildBubble(
          msg, index, showHeader, messages, replyIndexById, profiles,
          localPeerId, _tilingAt(messages, index, showHeader)),
    );
    return dateSeparatedChatRow(
      rowKey: msg.messageId ?? index,
      timestamp: msg.timestamp,
      prevTimestamp: index > 0 ? messages[index - 1].timestamp : null,
      showHeader: showHeader,
      // This list carries the scroll rail, so the date rule gives that width
      // back and keeps its two ends level.
      railGutter: true,
      unreadDivider: index == unreadIndex,
      callsBefore: calls.before,
      callsAfter: calls.after,
      child: wrapper,
    );
  }

  /// Sticker tiling for the row at [index]: a continuous seam where it and its
  /// neighbour are both bare stickers and already grouped. `showHeader` IS "not
  /// grouped with the previous".
  ({bool prev, bool next}) _tilingAt(
      List<ChatMessage> messages, int index, bool showHeader) {
    bool candidate(ChatMessage m) => stickerTileCandidate(
          text: m.text,
          hasReply: m.replyToMid != null,
          hasReactions: m.reactions.isNotEmpty,
          hasFile: m.fileAttachment != null,
          isEdited: m.editedAt != null,
        );
    final next = index + 1 < messages.length ? messages[index + 1] : null;
    return stickerTilingFor(
      selfIsSticker: candidate(messages[index]),
      prevIsSticker: index > 0 && candidate(messages[index - 1]),
      groupedWithPrev: !showHeader,
      nextIsSticker: next != null && candidate(next),
      groupedWithNext: next != null &&
          shouldGroup(
            currentIsMe: next.isMe,
            previousIsMe: messages[index].isMe,
            currentTime: next.timestamp,
            previousTime: messages[index].timestamp,
          ),
    );
  }

  Widget _buildBubble(
    ChatMessage msg,
    int index,
    bool showHeader,
    List<ChatMessage> messages,
    Map<String, int> replyIndexById,
    Map<String, storage_api.UserProfile> profiles,
    String localPeerId,
    ({bool prev, bool next}) tiling,
  ) {
    String? replySenderId;
    String? replySender;
    String? replyText;
    String? replyImagePath;
    int? replyIndex;
    if (msg.replyToMid != null) {
      final idx = replyIndexById[msg.replyToMid] ?? -1;
      if (idx != -1) {
        replyIndex = idx;
        final original = _albumItemById(messages[idx], msg.replyToMid!);
        replyText = _messagePreviewText(original);
        final origSenderId = original.isMe ? localPeerId : widget.peerId;
        replySenderId = origSenderId;
        replySender = displayNameFor(profiles, origSenderId);
        if (original.fileAttachment?.isImage == true) {
          replyImagePath = original.fileAttachment?.diskPath;
        }
      }
    }
    final albumMessages = _albums.itemsFor(msg.messageId);
    return MessageBubble(
      message: msg,
      peerId: widget.peerId,
      showHeader: showHeader,
      album: albumMessages == null
          ? null
          : dmAlbumItems(albumMessages,
              localPeerId: localPeerId, peerId: widget.peerId),
      replyToSenderId: replySenderId,
      replyToSenderName: replySender,
      replyToText: replyText,
      replyToImagePath: replyImagePath,
      isHighlighted: _highlightIndex == index,
      onReplyTap:
          replyIndex != null ? () => _scrollToMessage(replyIndex!) : null,
      onToggleReaction: msg.messageId != null
          ? (emoji) => _toggleReaction(msg, emoji)
          : null,
      tileWithPrev: tiling.prev,
      tileWithNext: tiling.next,
    );
  }

  // Row action callbacks. Null hides the affordance for this message, and
  // tap-time reads use ref.read, which is never staler than the build's watch.

  VoidCallback? _editStartFor(ChatMessage msg, int revIndex) {
    final canEdit =
        msg.messageId != null && msg.isMe && msg.fileAttachment == null;
    if (!canEdit) return null;
    return () {
      // Positions and jumpTo live in the REVERSED index space.
      final positions = _itemPositionsListener.itemPositions.value;
      final current = positions.where((p) => p.index == revIndex).firstOrNull;
      final alignment = current?.itemLeadingEdge ?? 0.3;
      setState(() => _editingMessageId = msg.messageId);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_itemScrollController.isAttached) return;
        _itemScrollController.jumpTo(
          index: revIndex,
          alignment: alignment,
        );
      });
    };
  }

  VoidCallback? _deleteFor(ChatMessage msg) {
    if (msg.messageId == null || !msg.isMe) return null;
    final album = _albums.itemsFor(msg.messageId);
    if (album == null) return () => _deleteMessage(msg.messageId!);
    return () async {
      if (!await confirmDeleteAlbum(context, album.length)) return;
      for (final item in album) {
        if (item.messageId != null) await _deleteMessage(item.messageId!);
      }
    };
  }

  Future<void> _deleteMessage(String messageId) async {
    try {
      await ref
          .read(chatProvider.notifier)
          .deleteMessage(widget.peerId, messageId);
    } catch (_) {
      if (!mounted) return;
      HollowToast.show(context, 'Failed to delete message',
          type: HollowToastType.error);
    }
  }

  Future<void> _submitEdit(String messageId, String newText) async {
    try {
      await ref
          .read(chatProvider.notifier)
          .editMessage(widget.peerId, messageId, newText);
    } catch (_) {
      if (!mounted) return;
      HollowToast.show(context, 'Failed to save changes',
          type: HollowToastType.error);
      return;
    }
    if (!mounted) return;
    _resyncPreviewAfterEdit(messageId, newText);
  }

  /// Keeps the card honest after an edit (issue #45): editing the URL out of a
  /// message must not leave its old card under the new text.
  Future<void> _resyncPreviewAfterEdit(String messageId, String newText) async {
    if (!ref.read(linkPreviewsEnabledProvider)) return;
    final msgs = ref.read(chatProvider)[widget.peerId] ?? const <ChatMessage>[];
    final idx = msgs.indexWhere((m) => m.messageId == messageId);
    final oldUrl = idx == -1 ? null : msgs[idx].linkPreview?.url;
    final newUrl = _urlRegex.firstMatch(newText)?.group(0);

    if (newUrl == oldUrl) return;
    if (newUrl == null) {
      _attachPreview(messageId, null);
      return;
    }
    // Hollow deep links render from a locally parsed card, never a fetch.
    if (extractHollowLinks(newUrl).isNotEmpty) {
      if (oldUrl != null) _attachPreview(messageId, null);
      return;
    }
    try {
      final preview = await network_api.fetchLinkPreview(url: newUrl);
      if (!mounted) return;
      _attachPreview(messageId, preview);
    } catch (_) {
      // Leave whatever card the row had rather than blanking it on a transient
      // network failure.
    }
  }

  VoidCallback? _replyFor(ChatMessage msg) {
    if (msg.messageId == null) return null;
    return () {
      final localPeerId = ref.read(identityProvider).peerId ?? '';
      final senderId = msg.isMe ? localPeerId : widget.peerId;
      setState(() {
        _replyToMessageId = msg.messageId;
        _replyToText = _messagePreviewText(msg);
        _replyToSenderName =
            displayNameFor(ref.read(profileProvider), senderId);
        _replyToImagePath = msg.fileAttachment?.isImage == true
            ? msg.fileAttachment?.diskPath
            : null;
      });
      _focusNode.requestFocus();
    };
  }

  Future<void> _toggleReaction(ChatMessage msg, String emoji) async {
    // A click outside the composer drops its focus on desktop; reacting is not
    // leaving the conversation, so the next keystroke still lands in it.
    if (_editingMessageId == null) _focusNode.requestFocus();
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final hasReacted = msg.reactions[emoji]?.contains(localPeerId) ?? false;
    final notifier = ref.read(chatProvider.notifier);
    try {
      if (hasReacted) {
        await notifier.removeReaction(widget.peerId, msg.messageId!, emoji);
      } else {
        await notifier.addReaction(widget.peerId, msg.messageId!, emoji);
      }
    } catch (_) {
      if (!mounted) return;
      HollowToast.show(context, 'Failed to update reaction',
          type: HollowToastType.error);
    }
  }

  VoidCallback? _downloadFor(BuildContext context, ChatMessage msg) {
    final attachment = msg.fileAttachment;
    if (attachment == null) return null;
    return () {
      final transfer = ref.read(fileTransferProvider)[attachment.fileId];
      if (transfer != null && transfer.isDownloading) {
        HollowToast.show(context, 'File is already downloading...',
            type: HollowToastType.info);
        return;
      }
      if (attachment.diskPath != null) {
        _saveFile(attachment);
      } else if (attachment.shareRootHash != null &&
          attachment.shareKeyHex != null) {
        // Share-backed (>34 MB): rejoin the swarm through the persisted ref,
        // because a direct FileRequest response carries no share_ref and our own
        // size cap rejects it (issue #41).
        ref.read(eventStreamProvider.notifier).startManualShareDownload(
              fileId: attachment.fileId,
              rootHash: attachment.shareRootHash!,
              keyHex: attachment.shareKeyHex!,
              serverId: '',
              sequential: false,
            ).catchError((e) {
          if (context.mounted) {
            HollowToast.show(context, friendlyError(e, fallback: "Couldn't download the file. Try again."),
                type: HollowToastType.error);
          }
        });
      } else {
        _requestFileFromPeer(attachment, widget.peerId);
      }
    };
  }

  VoidCallback? _copyFor(BuildContext context, ChatMessage msg) {
    if (msg.text.isEmpty || msg.text.startsWith('[file:')) return null;
    return () {
      Clipboard.setData(ClipboardData(text: msg.text));
      HollowToast.show(context, 'Copied to clipboard',
          type: HollowToastType.success);
    };
  }

  VoidCallback? _copyImageFor(BuildContext context, ChatMessage msg) {
    final attachment = msg.fileAttachment;
    if (attachment == null ||
        attachment.diskPath == null ||
        !attachment.isImage) {
      return null;
    }
    return () async {
      final ok = await copyImageToClipboard(attachment.diskPath!);
      // itemBuilder shadows the State's context, and a list item disposes when
      // scrolled away, so check THIS element.
      if (context.mounted) {
        HollowToast.show(
          context,
          ok ? 'Image copied to clipboard' : 'Failed to copy image',
          type: ok ? HollowToastType.success : HollowToastType.error,
        );
      }
    };
  }

  VoidCallback _infoFor(BuildContext context, ChatMessage msg) {
    return () {
      final localPeerId = ref.read(identityProvider).peerId ?? '';
      final senderPeerId = msg.isMe ? localPeerId : widget.peerId;
      showMessageProofDialog(
        context,
        MessageProofData(
          senderPeerId: senderPeerId,
          senderDisplayName:
              displayNameFor(ref.read(profileProvider), senderPeerId),
          text: msg.text,
          // An edited message's signature covers the edit timestamp and the new
          // text, so the canonical payload must be rebuilt from editedAt.
          timestampMs: (msg.editedAt ?? msg.timestamp).millisecondsSinceEpoch,
          signature: msg.signature,
          publicKey: msg.publicKey,
          messageId: msg.messageId,
          context: msg.isMe ? widget.peerId : localPeerId,
          msgType: 'dm',
          fileAttachment: msg.fileAttachment,
        ),
      );
    };
  }

  /// A row's preview; an album row says what the whole album holds.
  String _messagePreviewText(ChatMessage msg) {
    final album = _albums.itemsFor(msg.messageId);
    if (album != null) {
      return albumPreviewText([for (final m in album) m.fileAttachment],
          caption: albumCaption([for (final m in album) m.text]));
    }
    return messagePreviewText(msg.text, attachment: msg.fileAttachment);
  }

  /// The row a message id renders in: its album's row when it was folded.
  String? _albumRowId(String? messageId) =>
      messageId == null ? null : _albums.anchorIdByItemId[messageId] ?? messageId;

  /// The message [messageId] names inside [row]: the row itself, or the album
  /// item a reply points at.
  ChatMessage _albumItemById(ChatMessage row, String messageId) {
    if (row.messageId == messageId) return row;
    for (final m in _albums.itemsFor(row.messageId) ?? const <ChatMessage>[]) {
      if (m.messageId == messageId) return m;
    }
    return row;
  }

  /// Unread pill, only for messages that arrived while scrolled up.
  Widget _buildUnreadPillOverlay(List<ChatMessage> allMessages) { // design-ignore: places the unread jump pill, not a label
    final unreadCount = ref.watch(
        unreadProvider.select((s) => s.dmUnreadCounts[widget.peerId] ?? 0));
    return Positioned(
      bottom: HollowSpacing.md,
      left: 0,
      right: 0,
      child: Center(
        child: UnreadJumpFade(
          count: _showScrollPill ? unreadCount : 0,
          onTap: () {
            _scrollToBottom();
            // The display list may be frozen, so mark seen against the TRUE
            // newest message.
            ref.read(unreadProvider.notifier).markDmSeen(
                  widget.peerId,
                  allMessages.last.messageId,
                );
          },
        ),
      ),
    );
  }

  List<String> _typingNames(Set<String> typingPeers) => typingPeers
      .map((pid) => displayNameForPeer(
          ref.watch(profileProvider.select((p) => p[pid])), pid))
      .toList();

  Widget _buildInputBar(HollowTheme hollow) {
    return chatInputBarShell(
      hollow,
      flushTop: _replyToMessageId != null ||
          _staged.isNotEmpty ||
          _stagedPreviewUrl != null,
      child: _isRecordingVoice
          ? VoiceRecorderBar(
              onFinished: _stageVoiceMessage,
              onCancelled: () => setState(() => _isRecordingVoice = false),
            )
          : _buildComposerRow(hollow),
    );
  }
  Widget _buildComposerRow(HollowTheme hollow) {
    final savedId = ref.watch(savedMessagesPeerIdProvider);
    final isSaved = savedId != null &&
        ref.watch(deviceLinkProvider).identityOf(widget.peerId) == savedId;
    final localNick =
        ref.watch(localNicknameProvider.select((m) => m[widget.peerId]));
    final name = (localNick?.isNotEmpty ?? false)
        ? localNick!
        : displayNameFor(ref.watch(profileProvider), widget.peerId);
    return ChatComposerRow(
      controller: _controller,
      focusNode: _focusNode,
      layerLink: _composerLayerLink,
      hintText: isSaved ? 'Note to self' : 'Message $name',
      onChanged: _onTextChanged,
      onKey: (event) {
        final r = _emoteAutocomplete.handleKey(event);
        if (r == KeyEventResult.handled) return r;
        return handleChatInputKey(
          event, _controller, _focusNode, _handleSend,
          onPasteImage: _stageClipboardImage,
          formatBindings: ref.read(appShortcutsProvider).valueOrNull,
        );
      },
      onAttach: _pickAndStageFile,
      onRecord: () => setState(() => _isRecordingVoice = true),
      onExpressions: _openExpressions,
      onSend: _handleSend,
      hasStaged: _staged.isNotEmpty || _stagedPreviewUrl != null,
    );
  }
}

/// What the one side panel shows while the call's stage is up.
enum _StagePanel { chat, profile }

/// The conversation beside the call's stage: messages and composer, the same
/// ones the page shows without a call, in chrome at the side.
class _StageChatPanel extends StatelessWidget {
  final List<Widget> children;
  const _StageChatPanel({required this.children});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChatHeaderBar(
          leading:
              Icon(LucideIcons.messageSquare, size: 20, color: hollow.textTertiary),
          title: 'Chat',
        ),
        ...children,
      ],
    );
  }
}

/// After the name while the stage is up: "In a call" and the timer.
class _InCallMark extends ConsumerWidget {
  const _InCallMark();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final startedAt = ref.watch(callProvider.select((c) => c.startedAt));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.phone, size: 14, color: hollow.success),
        const SizedBox(width: HollowSpacing.xs),
        Text('In a call',
            style: HollowTypography.bodySmall.copyWith(color: hollow.success)),
        if (startedAt != null) ...[
          const SizedBox(width: HollowSpacing.sm),
          CallDurationText(
            startedAt: startedAt,
            style: HollowTypography.monoSmall.copyWith(
              color: hollow.textTertiary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}

/// The DM profile panel's place on the right. It shows and hides instantly: a
/// width animation would re-wrap the chat text on every frame.
class _DmProfilePanelSlider extends StatelessWidget {
  final bool visible;
  final String peerId;
  const _DmProfilePanelSlider({required this.visible, required this.peerId});

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    return DmProfilePanel(peerId: peerId);
  }
}
