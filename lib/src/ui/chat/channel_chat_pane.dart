import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/moderation_format.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/app_shortcuts_provider.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/link_preview_settings_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart' show generateMessageId;
import 'package:hollow/src/core/providers/composer_insert_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/download_manager_provider.dart';
import 'package:hollow/src/core/providers/event_provider.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/core/providers/unread_marker_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/sync_progress_provider.dart';
import 'package:hollow/src/core/providers/typing_provider.dart';
import 'package:hollow/src/core/providers/pinned_provider.dart';
import 'package:hollow/src/core/providers/vault_status_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/channel_message_bubble.dart';
import 'package:hollow/src/ui/chat/chat_drop_zone.dart';
import 'package:hollow/src/ui/chat/chat_input_shortcuts.dart';
import 'package:hollow/src/ui/chat/emoji_picker.dart';
import 'package:hollow/src/ui/chat/gif_picker.dart';
import 'package:hollow/src/ui/chat/sticker_picker.dart';
import 'package:hollow/src/ui/chat/emote_composer.dart';
import 'package:hollow/src/ui/chat/emote_image.dart';
import 'package:hollow/src/core/providers/emote_provider.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/chat/message_action_bar.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/connection_progress.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/chat/voice_recorder_bar.dart';
import 'package:hollow/src/core/services/voice_message_recorder.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/large_file_share_dialog.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

class ChannelChatPane extends ConsumerStatefulWidget {
  final String serverId;
  final String channelId;
  final String channelName;
  /// Which split pane this is in: null = not split, 0 = left, 1 = right.
  final int? splitPaneIndex;

  const ChannelChatPane({
    super.key,
    required this.serverId,
    required this.channelId,
    required this.channelName,
    this.splitPaneIndex,
  });

  @override
  ConsumerState<ChannelChatPane> createState() => _ChannelChatPaneState();
}

class _ChannelChatPaneState extends ConsumerState<ChannelChatPane> {
  void _handleSplitToggle() {
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
  bool _historyLoaded = false;
  bool _isPicking = false;
  String? _editingMessageId;
  String? _replyToMessageId;
  String? _replyToText;
  String? _replyToSenderName;
  String? _replyToImagePath;
  DateTime? _lastTypingSent;
  /// Slow mode: earliest time the next send is allowed (null = no cooldown).
  DateTime? _slowModeReadyAt;
  Timer? _slowModeTimer;
  int? _highlightIndex;
  final _searchController = TextEditingController();
  List<dynamic> _searchResults = [];
  final _searchFocusNode = FocusNode();
  bool _showScrollPill = false;
  /// Picked but not yet sent.
  String? _stagedFilePath;
  String? _stagedFileName;
  bool _stagedFileIsImage = false;
  /// True while recording, which swaps the input row for the
  /// [VoiceRecorderBar].
  bool _isRecordingVoice = false;
  String? _stagedPreviewUrl;
  network_api.LinkPreviewRef? _stagedPreview;
  bool _stagedPreviewLoading = false;
  HollowLink? _stagedHollowLink;
  /// Sent-before-the-fetch-landed bookkeeping (issue #45).
  final LatePreviewAttacher _latePreview = LatePreviewAttacher();
  Timer? _urlDebounce;
  static final RegExp _urlRegex = RegExp(r'(?:https?|hollow)://[^\s<>"' "'" r')\]}]+');

  /// Last [ComposerInsert] applied, so a rebuild cannot replay it.
  int _lastComposerInsertSeq = 0;

  /// @mention autocomplete state.
  OverlayEntry? _mentionOverlay;
  final _mentionLayerLink = LayerLink();
  List<_MentionCandidate> _mentionCandidates = [];
  int _mentionSelectedIndex = 0;
  int _mentionAtPosition = -1;

  /// `:` shortcode autocomplete. Shares the mention LayerLink, because the two
  /// triggers are mutually exclusive.
  late final EmoteAutocomplete _emoteAutocomplete = EmoteAutocomplete(
    link: _mentionLayerLink,
    controller: _controller,
    emotesSource: _composerEmotes,
  );

  List<ComposerEmote> _composerEmotes() => [
        for (final e in ref.read(serverEmotesProvider(widget.serverId)).valueOrNull ??
            const [])
          ComposerEmote(e.name, e.hash),
        for (final e in ref.read(personalEmotesProvider).valueOrNull ?? const [])
          ComposerEmote(e.name, e.hash),
      ];

  String get _stateKey => '${widget.serverId}:${widget.channelId}';

  /// Conference chat is a RAM-only text surface: no members or split view, no
  /// CRDT-backed reactions, pins or edits, and no Ed25519 proof affordance,
  /// because MLS authenticates each line instead.
  bool get _isConference => widget.serverId.startsWith('conf:');


  @override
  void initState() {
    super.initState();
    // Close search on entering a channel; it cannot be reset in dispose, where
    // Riverpod forbids all ref usage.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(chatSearchOpenProvider.notifier).state = false;
        // The pane remounts per channel, so the pill state is gone while the
        // message history the cooldown derives from is not.
        _recomputeSlowMode();
      }
    });
    _loadHistory();
    _itemPositionsListener.itemPositions.addListener(_onScrollPositionChanged);
  }

  Timer? _fileRequestDebounce;

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
      final msgs = ref.read(channelChatProvider)[_stateKey];
      // Reached the bottom: release the freeze, and snap to the true newest row
      // if anything was held back.
      if (_frozenLen != null && msgs != null && msgs.length > _frozenLen!) {
        _jumpToBottom();
      } else {
        _frozenLen = null;
      }
      if (msgs != null && msgs.isNotEmpty) {
        ref.read(unreadProvider.notifier).markChannelSeen(
              widget.serverId, widget.channelId, msgs.last.messageId);
      }
    } else if (!nearBottom && _wasNearBottom) {
      // Left the bottom: freeze the display so arrivals cannot shift the
      // reading position.
      _frozenLen ??=
          (ref.read(channelChatProvider)[_stateKey] ?? const []).length;
    }
    _wasNearBottom = nearBottom;
    _requestViewportFiles();
  }

  void _requestViewportFiles() {
    _fileRequestDebounce?.cancel();
    _fileRequestDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      final positions = _itemPositionsListener.itemPositions.value;
      if (positions.isEmpty) return;
      final msgs =
          _displayMessages(ref.read(channelChatProvider)[_stateKey] ?? []);
      if (msgs.isEmpty) return;
      // Positions are in REVERSED index space, so the visible range maps back to
      // chronological indices here.
      final indices = positions.map((p) => p.index);
      final minRev = indices.reduce((a, b) => a < b ? a : b);
      final maxRev = indices.reduce((a, b) => a > b ? a : b);
      final firstVisible = (msgs.length - 1 - maxRev).clamp(0, msgs.length - 1);
      final lastVisible = (msgs.length - 1 - minRev).clamp(0, msgs.length - 1);
      ref.read(channelChatProvider.notifier).requestVisibleFiles(
          widget.serverId, widget.channelId,
          msgs, firstVisible, lastVisible);
    });
  }

  bool _loadingHistory = false;

  Future<void> _loadHistory() async {
    if (_loadingHistory || _historyLoaded) return;
    // Always load from DB on first open: the in-memory cache can hold nothing
    // but late-arriving network messages, which would hide the DB history.
    // `loadHistory` merges, so an optimistic in-flight send survives.
    _loadingHistory = true;
    await ref
        .read(channelChatProvider.notifier)
        .loadHistory(widget.serverId, widget.channelId);
    if (!mounted) return;
    ref.read(pinnedProvider.notifier).loadPins(widget.serverId, widget.channelId);
    _historyLoaded = true;
    _loadingHistory = false;
    setState(() {});
    // ScrollablePositionedList honours `initialScrollIndex` only at first
    // build, so a list grown by loadHistory needs an explicit jump.
    _jumpToBottom();
    final msgs = ref.read(channelChatProvider)['${widget.serverId}:${widget.channelId}'];
    final latestId = msgs != null && msgs.isNotEmpty
        ? msgs.last.messageId
        : null;
    ref.read(unreadProvider.notifier)
        .markChannelSeen(widget.serverId, widget.channelId, latestId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _requestViewportFiles();
    });
  }

  @override
  void dispose() {
    _dismissMentionOverlay();
    _emoteAutocomplete.dismiss();
    _urlDebounce?.cancel();
    _latePreview.disarm();
    _slowModeTimer?.cancel();
    _fileRequestDebounce?.cancel();
    _itemPositionsListener.itemPositions.removeListener(_onScrollPositionChanged);
    _controller.dispose();
    _focusNode.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  // Reversed list, as in chat_pane.dart: newest at index 0 pinned to the
  // bottom, the display FROZEN while the user reads history, and every bottom
  // snap an instant jumpTo.

  /// Non-null while the user is scrolled up: display list capped here.
  int? _frozenLen;

  /// The displayed messages: the frozen prefix, then blocked senders removed.
  ///
  /// The freeze cap applies to the RAW list first, because the freeze length is
  /// captured from raw-list growth. Blocked-sender comparison collapses
  /// device to master through the resolver.
  List<ChannelChatMessage> _displayMessages(List<ChannelChatMessage> messages) {
    final frozen = _frozenLen;
    var visible = (frozen == null || messages.length <= frozen)
        ? messages
        : messages.sublist(0, frozen);
    final blocked = ref.read(blockedUsersProvider);
    if (blocked.isNotEmpty) {
      final links = ref.read(deviceLinkProvider);
      visible = visible
          .where((m) => !blocked.contains(links.identityOf(m.senderId)))
          .toList();
    }
    return visible;
  }

  bool get _isNearBottom {
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return true;
    return positions.any((p) => p.index <= 0);
  }

  void _releaseFreeze() {
    if (_frozenLen != null) setState(() => _frozenLen = null);
  }

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
        _displayMessages(ref.read(channelChatProvider)[_stateKey] ?? []);
    if (index < 0 || index >= messages.length) return;
    setState(() => _highlightIndex = index);
    _itemScrollController.scrollTo(
      index: messages.length - 1 - index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: 0.6,
    );
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightIndex = null);
    });
  }

  /// HH:MM, shared by the search results and the pin dialog.
  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// '📷 Image' or '📎 name' for attachments, else the message text.
  String _messagePreviewText(ChannelChatMessage msg) {
    final f = msg.fileAttachment;
    if (f == null) return msg.text;
    return f.isImage ? '📷 Image' : '📎 ${f.fileName}';
  }

  void _showPinnedMessages(
    BuildContext context,
    HollowTheme hollow,
    List<String> pinnedIds,
  ) {
    final messages = ref.read(channelChatProvider)[_stateKey] ?? [];
    final pinnedMessages = pinnedIds
        .map((id) => messages.where((m) => m.messageId == id).firstOrNull)
        .whereType<ChannelChatMessage>()
        .toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: hollow.elevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(hollow.radiusLg),
          side: BorderSide(color: hollow.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 400),
          child: Padding(
            padding: const EdgeInsets.all(HollowSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(LucideIcons.pin, size: 18, color: hollow.accent),
                    const SizedBox(width: HollowSpacing.sm),
                    Text(
                      'Pinned Messages',
                      style: HollowTypography.subheading.copyWith(
                        color: hollow.textPrimary,
                      ),
                    ),
                    const Spacer(),
                    HollowPressable(
                      semanticLabel: 'Close',
                      onTap: () => Navigator.pop(ctx),
                      padding: const EdgeInsets.all(4),
                      child: Icon(LucideIcons.x, size: 16, color: hollow.textSecondary),
                    ),
                  ],
                ),
                const SizedBox(height: HollowSpacing.md),
                if (pinnedMessages.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xl),
                    child: Center(
                      child: Text(
                        'Pinned messages not loaded in current view.',
                        style: HollowTypography.body.copyWith(
                          color: hollow.textSecondary,
                        ),
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: pinnedMessages.length,
                      itemBuilder: (_, index) =>
                          _buildPinnedItem(hollow, pinnedMessages, index),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// One row of the pinned-messages dialog.
  Widget _buildPinnedItem(
    HollowTheme hollow,
    List<ChannelChatMessage> pinnedMessages,
    int index,
  ) {
    final msg = pinnedMessages[index];
    final profiles = ref.read(profileProvider);
    final nicknames = ref.read(serverNicknamesProvider(widget.serverId));
    // Collapse device to master so a pinned row shows the person, not a raw
    // device id.
    final pinnedMaster =
        ref.read(deviceLinkProvider).identityOf(msg.senderId);
    final name = serverDisplayNameFor(
      profiles,
      pinnedMaster,
      nickname: nicknames[pinnedMaster] ?? '',
    );

    final showDate = shouldShowDateSeparator(
      msg.timestamp,
      index > 0 ? pinnedMessages[index - 1].timestamp : null,
    );

    final msgWidget = Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                name,
                style: HollowTypography.body.copyWith(
                  color: hollow.accent,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                _hhmm(msg.timestamp),
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary.withValues(alpha: 0.5),
                  fontSize: 10,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          _buildPinnedItemBody(hollow, msg),
        ],
      ),
    );

    if (showDate) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DateSeparator(date: msg.timestamp),
          msgWidget,
        ],
      );
    }
    if (index > 0) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(color: hollow.border, height: HollowSpacing.sm),
          msgWidget,
        ],
      );
    }
    return msgWidget;
  }

  Widget _buildPinnedItemBody(HollowTheme hollow, ChannelChatMessage msg) {
    final attachment = msg.fileAttachment;
    if (attachment != null) {
      if (attachment.isImage &&
          attachment.diskPath != null &&
          File(attachment.diskPath!).existsSync()) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          child: gifAwareImage(attachment.diskPath!, height: 80),
        );
      }
      return Text(
        _messagePreviewText(msg),
        style: HollowTypography.body.copyWith(
          color: hollow.textSecondary,
        ),
      );
    }
    return Text(
      msg.text.startsWith('[file:') ? '📎 File' : msg.text,
      style: HollowTypography.body.copyWith(
        color: hollow.textPrimary,
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }

  Future<void> _onSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    try {
      final results = await storage_api.searchChannelMessages(
        serverId: widget.serverId,
        channelId: widget.channelId,
        query: query.trim(),
        limit: 20,
      );
      if (mounted) setState(() => _searchResults = results);
    } catch (_) {}
  }

  void _onTextChanged(String text) {
    _urlDebounce?.cancel();
    _urlDebounce = Timer(const Duration(milliseconds: 600), _detectUrl);

    _updateMentionAutocomplete(text);
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
      serverId: widget.serverId,
      channelId: widget.channelId,
    ).catchError((_) {});
  }

  void _updateMentionAutocomplete(String text) {
    final cursor = _controller.selection.baseOffset;
    final atPos = cursor < 0 ? -1 : _mentionTriggerIndex(text, cursor);
    if (atPos < 0) {
      _dismissMentionOverlay();
      return;
    }

    final query = text.substring(atPos + 1, cursor).toLowerCase();
    _mentionAtPosition = atPos;

    final candidates = _mentionCandidatesFor(query);
    if (candidates.isEmpty) {
      _dismissMentionOverlay();
      return;
    }

    _mentionCandidates = candidates.take(6).toList();
    _mentionSelectedIndex = _mentionSelectedIndex.clamp(
        0, _mentionCandidates.length - 1);
    _showMentionOverlay();
  }

  /// Scans back from [cursor] for an '@' that starts a mention, meaning one
  /// preceded by start-of-text, a space or a newline. -1 when there is none.
  int _mentionTriggerIndex(String text, int cursor) {
    for (int i = cursor - 1; i >= 0; i--) {
      final c = text[i];
      if (c == '@') {
        final startsWord = i == 0 || text[i - 1] == ' ' || text[i - 1] == '\n';
        return startsWord ? i : -1;
      }
      if (c == ' ' || c == '\n') return -1;
    }
    return -1;
  }

  /// Server members matching the query by any of their names, plus @everyone.
  List<_MentionCandidate> _mentionCandidatesFor(String query) {
    final membersAsync = ref.read(serverMembersProvider(widget.serverId));
    final profiles = ref.read(profileProvider);
    final nicknames = ref.read(serverNicknamesProvider(widget.serverId));
    final candidates = <_MentionCandidate>[];

    membersAsync.whenData((members) {
      for (final m in members) {
        final candidate = _mentionCandidateFor(m, query, profiles, nicknames);
        if (candidate != null) candidates.add(candidate);
      }
    });

    if (query.isEmpty || 'everyone'.startsWith(query)) {
      candidates.insert(0, const _MentionCandidate(
        peerId: '',
        displayName: 'everyone',
        subtitle: 'Notify all members',
      ));
    }
    return candidates;
  }

  _MentionCandidate? _mentionCandidateFor(
    crdt_api.MemberFfi m,
    String query,
    Map<String, storage_api.UserProfile> profiles,
    Map<String, String> nicknames,
  ) {
    final displayName = serverDisplayNameFor(
      profiles, m.peerId, nickname: nicknames[m.peerId] ?? '',
    );
    final serverNick = nicknames[m.peerId] ?? '';
    final profileName = profiles[m.peerId]?.displayName ?? '';

    final matches = query.isEmpty ||
        displayName.toLowerCase().startsWith(query) ||
        (serverNick.isNotEmpty && serverNick.toLowerCase().startsWith(query)) ||
        (profileName.isNotEmpty && profileName.toLowerCase().startsWith(query));
    if (!matches) return null;

    final String? subtitle;
    if (serverNick.isNotEmpty && serverNick != displayName) {
      subtitle = profileName.isNotEmpty ? profileName : null;
    } else {
      subtitle = serverNick.isNotEmpty ? serverNick : null;
    }
    return _MentionCandidate(
      peerId: m.peerId,
      displayName: displayName,
      subtitle: subtitle,
    );
  }

  void _showMentionOverlay() {
    _mentionOverlay?.remove();
    _mentionOverlay = OverlayEntry(builder: (_) => _buildMentionOverlay());
    Overlay.of(context).insert(_mentionOverlay!);
  }

  void _dismissMentionOverlay() {
    _mentionOverlay?.remove();
    _mentionOverlay = null;
    _mentionCandidates = [];
    _mentionSelectedIndex = 0;
    _mentionAtPosition = -1;
  }

  void _acceptMention(_MentionCandidate candidate) {
    final text = _controller.text;
    final cursor = _controller.selection.baseOffset;
    final replacement = '@${candidate.displayName} ';
    final newText = text.replaceRange(_mentionAtPosition, cursor, replacement);
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        offset: _mentionAtPosition + replacement.length,
      ),
    );
    _dismissMentionOverlay();
  }

  Widget _buildMentionOverlay() {
    final hollow = HollowTheme.of(context);
    return Positioned(
      width: 260,
      child: CompositedTransformFollower(
        link: _mentionLayerLink,
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomLeft,
        offset: const Offset(0, -4),
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxHeight: 220),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              border: Border.all(color: hollow.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 12,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: _mentionCandidates.length,
                itemBuilder: (ctx, i) {
                  final c = _mentionCandidates[i];
                  final selected = i == _mentionSelectedIndex;
                  return HollowPressable(
                    onTap: () => _acceptMention(c),
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    backgroundColor: selected
                        ? hollow.accent.withValues(alpha: 0.15)
                        : null,
                    padding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.sm,
                      vertical: HollowSpacing.xs,
                    ),
                    child: Row(
                      children: [
                        if (c.peerId.isNotEmpty)
                          HollowAvatar(
                            peerId: c.peerId,
                            size: 24,
                          )
                        else
                          Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: hollow.accent.withValues(alpha: 0.2),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(LucideIcons.atSign,
                                size: 14, color: hollow.accent),
                          ),
                        const SizedBox(width: HollowSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                c.displayName,
                                style: HollowTypography.bodySmall.copyWith(
                                  color: hollow.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (c.subtitle != null)
                                Text(
                                  c.subtitle!,
                                  style: HollowTypography.caption.copyWith(
                                    color: hollow.textSecondary,
                                    fontSize: 11,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Kicks off a background OG fetch for the first URL in the compose text when
  /// it differs from the staged one, and clears the staged preview when the URL
  /// is removed.
  void _detectUrl() {
    if (!mounted) return;
    // Previews off: never touch the pasted URL at all (issue #45).
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
      if (_stagedPreviewUrl != url) return;
      setState(() {
        _stagedPreview = preview;
        _stagedPreviewLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      _latePreview.claim(url);
      if (_stagedPreviewUrl != url) return;
      setState(() {
        _stagedPreviewUrl = null;
        _stagedPreview = null;
        _stagedPreviewLoading = false;
      });
    }
  }

  /// Lands a card on an already-sent message. Quiet on failure: the send already
  /// succeeded on screen and a missing card is cosmetic.
  void _attachPreview(String messageId, network_api.LinkPreviewRef? preview) {
    ref
        .read(channelChatProvider.notifier)
        .attachLinkPreview(
            widget.serverId, widget.channelId, messageId, preview)
        .catchError((Object e) {
      debugPrint('[HOLLOW] Late link preview attach failed: $e');
    });
  }

  /// Extensions the chat renders inline, which are the only types a media-only
  /// channel accepts. Mirrors the Rust-side ingest gate.
  static const _mediaExtensions = kMediaOnlyExtensions;

  /// The channel's slow-mode interval, or 0 when it is off or the local user is
  /// Moderator or above. Mirrors the Rust rule.
  int get _effectiveSlowModeSecs {
    final slow = ref
            .read(channelListProvider)[widget.channelId]?.slowModeSecs ?? 0;
    if (slow == 0) return 0;
    final role =
        ref.read(myRoleProvider(widget.serverId)).valueOrNull ?? 'member';
    const exempt = {'owner', 'admin', 'moderator'};
    return exempt.contains(role) ? 0 : slow;
  }

  bool get _channelMediaOnly =>
      ref.read(channelListProvider)[widget.channelId]?.mediaOnly ?? false;

  /// Banner text when the local user is muted (null = not muted / expired).
  String? _muteBannerText(crdt_api.MutedMemberFfi? mute) =>
      muteBannerText(mute);

  /// The slow-mode cooldown DERIVED from the loaded list, never widget state,
  /// so it survives a channel switch and always matches the Rust gate.
  DateTime? _derivedSlowModeReadyAt() {
    final msgs = ref.read(channelChatProvider)[_stateKey] ?? const [];
    return slowModeReadyAtFrom(msgs, _effectiveSlowModeSecs);
  }

  /// True (and toasts) when the slow-mode cooldown blocks a send right now.
  bool _blockedBySlowMode() {
    final readyAt = _derivedSlowModeReadyAt();
    if (readyAt == null) return false;
    final remaining = readyAt.difference(DateTime.now());
    HollowToast.show(
      context,
      'Slow mode: wait ${remaining.inSeconds + 1}s before sending again',
      type: HollowToastType.info,
    );
    return true;
  }

  /// Re-derives the cooldown and keeps a 1s ticker running while it is active.
  /// Called on mount, on every message-list change and by the ticker itself.
  void _recomputeSlowMode() {
    if (!mounted) return;
    final ready = _derivedSlowModeReadyAt();
    if (ready != _slowModeReadyAt) {
      setState(() => _slowModeReadyAt = ready);
    }
    _slowModeTimer?.cancel();
    if (ready != null) {
      _slowModeTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        if (!DateTime.now().isBefore(_slowModeReadyAt ?? DateTime.now())) {
          t.cancel();
          _recomputeSlowMode();
        } else {
          setState(() {});
        }
      });
    }
  }

  Future<void> _handleSend({bool refocus = true}) async {
    _dismissMentionOverlay();
    _emoteAutocomplete.dismiss();
    if (_blockedBySlowMode()) return;
    if (_stagedFilePath != null) {
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
      await _sendStagedFile();
      return;
    }
    // Expand inline-emote placeholders to [e:name:hash] wire tokens.
    final text = _controller.expandedText().trim();
    if (text.isEmpty) return;
    if (_channelMediaOnly) {
      HollowToast.show(
        context,
        'This is a media-only channel. Attach an image, GIF, or video',
        type: HollowToastType.info,
      );
      return;
    }
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
          .read(channelChatProvider.notifier)
          .sendMessage(widget.serverId, widget.channelId, text,
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
    _recomputeSlowMode();
    _scrollToBottom();
  }

  void _stageClipboardImage(String path, String name) {
    if (!mounted) return;
    setState(() {
      _stagedFilePath = path;
      _stagedFileName = name;
      _stagedFileIsImage = true;
    });
    _focusNode.requestFocus();
  }

  /// Stages a file dropped from the OS.
  Future<void> _handleDroppedFile(String path, String name, int sizeBytes) async {
    if (!mounted) return;
    // Over 34 MB: confirm hosting it as a Hollow Share rather than converting
    // silently, which left receivers behind symmetric NATs unable to download.
    if (sizeBytes > kLargeFileThresholdBytes) {
      final ok = await confirmLargeFileShare(context,
          fileName: name, sizeBytes: sizeBytes);
      if (!ok || !mounted) return;
    }
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (_channelMediaOnly && !_mediaExtensions.contains(ext)) {
      HollowToast.show(
        context,
        'This is a media-only channel. Only images, GIFs, and videos can be posted',
        type: HollowToastType.info,
      );
      return;
    }
    setState(() {
      _stagedFilePath = path;
      _stagedFileName = name;
      _stagedFileIsImage =
          ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'].contains(ext);
    });
    _focusNode.requestFocus();
  }

  Future<void> _pickAndStageFile() async {
    if (_isPicking) return;
    _isPicking = true;
    try {
      // Restrict the native picker to what a media-only channel accepts, rather
      // than failing after the selection.
      final result = _channelMediaOnly
          ? await FilePicker.platform.pickFiles(
              type: FileType.custom,
              allowedExtensions: _mediaExtensions.toList(),
            )
          : await FilePicker.platform.pickFiles();
      if (result == null || result.files.isEmpty) { _isPicking = false; return; }
      final file = result.files.first;
      if (file.path == null) { _isPicking = false; return; }

      // Over 34 MB: confirm hosting it as a Hollow Share.
      if (file.size > kLargeFileThresholdBytes) {
        final ok = mounted &&
            await confirmLargeFileShare(context,
                fileName: file.name, sizeBytes: file.size);
        if (!ok) {
          _isPicking = false;
          return;
        }
      }

      final ext = file.name.contains('.')
          ? file.name.split('.').last.toLowerCase()
          : '';
      setState(() {
        _stagedFilePath = file.path!;
        _stagedFileName = file.name;
        _stagedFileIsImage = ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'].contains(ext);
      });
      // Defer the re-focus until the OS has returned window focus from the
      // native file dialog: a synchronous requestFocus() marks the node focused
      // while keystrokes still go nowhere.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    } finally { _isPicking = false; }
  }

  /// Stages the recorder's `.ogg` and sends it immediately.
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

    setState(() {
      _isRecordingVoice = false;
      _stagedFilePath = result.filePath;
      _stagedFileName = 'Voice message.ogg';
      _stagedFileIsImage = false;
    });
    await _sendStagedFile();
  }

  /// Sends an already-written file straight into this channel with no save
  /// dialog, the "Share pack to this chat" path (issue #36).
  ///
  /// The file is NOT deleted afterwards: our own bubble keeps pointing at it,
  /// so it lives out its life in the temp directory the OS sweeps.
  Future<void> _shareFileToChat(String path, String fileName) async {
    if (!mounted) return;
    setState(() {
      _stagedFilePath = path;
      _stagedFileName = fileName;
      _stagedFileIsImage = false;
    });
    await _sendStagedFile();
  }

  Future<void> _sendStagedFile() async {
    final filePath = _stagedFilePath;
    final fileName = _stagedFileName;
    if (filePath == null || fileName == null) return;

    final messageText = _controller.expandedText().trim();
    final messageId = generateMessageId();
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';
    final isImage = _stagedFileIsImage;

    if (_channelMediaOnly && !_mediaExtensions.contains(ext)) {
      HollowToast.show(
        context,
        'This is a media-only channel. Only images, GIFs, and videos can be posted',
        type: HollowToastType.info,
      );
      return;
    }

    setState(() {
      _stagedFilePath = null;
      _stagedFileName = null;
      _stagedFileIsImage = false;
    });
    _controller.clear();

    ref.read(channelChatProvider.notifier).addFileMessage(
          widget.serverId,
          widget.channelId,
          messageId,
          fileName,
          File(filePath).lengthSync(),
          ext,
          isImage,
          filePath,
          text: messageText,
        );
    _jumpToBottom();

    final members = ref.read(serverMembersProvider(widget.serverId)).valueOrNull;
    await ref.read(fileTransferProvider.notifier).sendFile(
          serverId: widget.serverId,
          channelId: widget.channelId,
          filePath: filePath,
          messageId: messageId,
          messageText: messageText,
          memberCount: members?.length ?? 0,
          // The display name is the voice-recorder signal; the wire carries a
          // dedicated flag (auto-download gate exemption, issue #41).
          isVoice: fileName == 'Voice message.ogg',
        );
    _recomputeSlowMode();

    if (fileName.endsWith('.ogg') && filePath.contains('temp')) {
      try { await File(filePath).delete(); } catch (_) {}
    }
  }

  Future<void> _saveFile(FileAttachment attachment) async {
    if (attachment.diskPath == null) return;
    await _saveAttachmentAs(attachment.diskPath!, attachment);
  }

  /// Requests a file from its original sender over a P2P stream.
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
        HollowToast.show(context, 'File request failed: $e', type: HollowToastType.error);
      }
    }
  }

  /// Downloads the vault video behind a thumbnail message and saves it under
  /// the original video's name, both of which ride [attachment.videoThumb].
  Future<void> _vaultDownloadAndSaveVideo(FileAttachment attachment) async {
    final vthumb = attachment.videoThumb;
    if (vthumb == null) return;
    if (_isPicking) return;
    try {
      if (mounted) {
        HollowToast.show(context, 'Reconstructing video from shards...',
            type: HollowToastType.info);
      }
      final cachePath = await _vaultFetchToCache(vthumb.cid);
      if (cachePath == null || !mounted) return;
      await _saveCacheFileWithName(
        cachePath: cachePath,
        saveFileName: vthumb.name,
        fileExt: vthumb.ext,
      );
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Download failed: $e',
            type: HollowToastType.error);
      }
    }
  }

  /// Reconstructs vault content into the local cache and returns its path,
  /// polling the async shard reconstruction for up to 60 seconds. Null means it
  /// timed out, which is toasted here, or the widget is gone.
  Future<String?> _vaultFetchToCache(String contentId) async {
    final cachedPath = await crdt_api.vaultDownloadFile(
      serverId: widget.serverId,
      contentId: contentId,
    );
    if (cachedPath.isNotEmpty) return cachedPath;

    for (int i = 0; i < 120; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return null;
      final transfers = ref.read(fileTransferProvider);
      final match = transfers.values.where(
        (t) =>
            t.contentId == contentId &&
            t.diskPath != null &&
            t.diskPath!.isNotEmpty,
      );
      if (match.isNotEmpty) return match.first.diskPath!;
    }
    if (mounted) {
      HollowToast.show(context, 'Download timed out: not enough peers online',
          type: HollowToastType.error);
    }
    return null;
  }

  /// Saves [cachePath] under a supplied default name, for the vault video flow
  /// where the thumbnail's name and extension are not the video's.
  Future<void> _saveCacheFileWithName({
    required String cachePath,
    required String saveFileName,
    required String fileExt,
  }) async {
    if (_isPicking) return;
    _isPicking = true;
    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save video',
        fileName: saveFileName,
        type: FileType.custom,
        allowedExtensions: [fileExt],
      );
      if (savePath == null) return;
      await File(cachePath).copy(savePath);

      ref.read(downloadManagerStateProvider.notifier).recordSavedFile(
            savedPath: savePath,
            isVideo: true,
          );

      if (mounted) {
        HollowToast.show(context, 'Video saved', type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Save failed: $e', type: HollowToastType.error);
      }
    } finally {
      _isPicking = false;
    }
  }

  /// Reconstructs a vault file from its shards, then offers Save As.
  Future<void> _vaultDownloadAndSave(FileAttachment attachment) async {
    if (_isPicking) return;
    try {
      final contentId =
          await storage_api.getContentIdForFile(fileId: attachment.fileId);
      if (contentId == null || contentId.isEmpty) {
        if (mounted) {
          HollowToast.show(context, 'File not available for vault download',
              type: HollowToastType.error);
        }
        return;
      }

      if (mounted) {
        HollowToast.show(context, 'Reconstructing file from shards...',
            type: HollowToastType.info);
      }

      final cachePath = await _vaultFetchToCache(contentId);
      if (cachePath == null || !mounted) return;
      await _saveAttachmentAs(cachePath, attachment);
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Download failed: $e',
            type: HollowToastType.error);
      }
    }
  }

  /// Offers Save As for [attachment], copying or format-converting from
  /// [sourcePath], which is its own disk path or a vault cache path.
  Future<void> _saveAttachmentAs(
      String sourcePath, FileAttachment attachment) async {
    if (_isPicking) return;
    _isPicking = true;
    try {
      final isImage = attachment.isImage;
      final isGif = attachment.fileExt.toLowerCase() == 'gif';
      final allowedExtensions = isImage
          ? ['png', 'jpg', 'jpeg', 'webp', 'gif']
          : [attachment.fileExt];

      final baseName = attachment.fileName.contains('.')
          ? attachment.fileName.substring(0, attachment.fileName.lastIndexOf('.'))
          : attachment.fileName;

      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save file',
        fileName: isImage ? (isGif ? '$baseName.gif' : '$baseName.png') : attachment.fileName,
        type: FileType.custom,
        allowedExtensions: allowedExtensions,
      );
      if (savePath == null) return;

      final targetExt = savePath.contains('.')
          ? savePath.split('.').last.toLowerCase()
          : attachment.fileExt;

      if (isImage && targetExt != 'webp' && attachment.fileExt == 'webp') {
        final converted = await network_api.convertImageFormat(
          sourcePath: sourcePath,
          targetFormat: targetExt,
        );
        await File(savePath).writeAsBytes(converted);
      } else {
        await File(sourcePath).copy(savePath);
      }

      ref.read(downloadManagerStateProvider.notifier).recordSavedFile(
            savedPath: savePath,
            isImage: isImage,
            isVideo: attachment.videoThumb != null,
          );

      if (mounted) {
        HollowToast.show(context, 'File saved', type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Save failed: $e', type: HollowToastType.error);
      }
    } finally {
      _isPicking = false;
    }
  }

  /// Opens the emoji and emote picker anchored to the composer button, and
  /// inserts the selection at the cursor.
  void _openComposerEmojiPicker(BuildContext btnCtx) {
    final box = btnCtx.findRenderObject() as RenderBox?;
    final anchor = box == null
        ? Offset.zero
        : overlayAnchorOf(btnCtx, localOffset: Offset(box.size.width, 0));
    showEmojiPicker(
      context: context,
      anchorPosition: anchor,
      serverId: widget.serverId,
      onSelect: _insertEmojiAtCursor,
    );
  }

  /// Opens the GIF picker anchored to the composer button. The pick arrives as
  /// an `[a:g:hash:w:h]` token and stages like an emote.
  void _openComposerGifPicker(BuildContext btnCtx) {
    final box = btnCtx.findRenderObject() as RenderBox?;
    final anchor = box == null
        ? Offset.zero
        : overlayAnchorOf(btnCtx, localOffset: Offset(box.size.width, 0));
    showGifPicker(
      context: context,
      anchorPosition: anchor,
      onSelect: _sendAsset,
      // A conference has no CRDT NSFW flag: it is the participants' own room,
      // so it uses the user's rating like a DM.
      serverId: _isConference ? null : widget.serverId,
    );
  }

  /// Opens the sticker picker anchored to the composer button. A pick SENDS
  /// immediately and the panel stays open.
  void _openComposerStickerPicker(BuildContext btnCtx) {
    final box = btnCtx.findRenderObject() as RenderBox?;
    final anchor = box == null
        ? Offset.zero
        : overlayAnchorOf(btnCtx, localOffset: Offset(box.size.width, 0));
    showStickerPicker(
      context: context,
      anchorPosition: anchor,
      onSelect: _sendAsset,
      onSharePack: _shareFileToChat,
      serverId: _isConference ? null : widget.serverId,
    );
  }

  /// Send-on-click (issue #36): text already in the composer rides along as a
  /// caption, the picker stays open, and focus stays put so mobile does not
  /// raise the keyboard over the sheet on every pick.
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

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // Per-channel select: the map is replaced wholesale on every insert, so
    // watching it rebuilds this pane for activity in any channel.
    final allMessages =
        ref.watch(channelChatProvider.select((m) => m[_stateKey])) ?? [];
    // Watched so _displayMessages' blocked-sender filter re-runs when the block
    // list or the device-to-master links change.
    ref.watch(blockedUsersProvider);
    ref.watch(deviceLinkProvider);
    final messages = _displayMessages(allMessages);

    _registerBuildListeners();

    // Sync can clear the cache while this channel is not being viewed, which
    // leaves nothing to render until the DB is read again.
    if (allMessages.isEmpty && _historyLoaded && !_loadingHistory) {
      _historyLoaded = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadHistory();
      });
    }

    final typingPeers =
        ref.watch(typingProvider.select((t) => t[_stateKey])) ?? {};

    // Custom-emote pull source for every token and reaction in this channel:
    // one online member of the server room.
    return EmoteScope(
      serverId: widget.serverId,
      child: ChatDropZone(
        onFileDropped: _handleDroppedFile,
        child: Column(
          children: [
            _buildHeader(hollow),

            if (ref.watch(chatSearchOpenProvider)) _buildSearchBar(hollow),

            _buildMessageArea(hollow, messages, allMessages),

            if (typingPeers.isNotEmpty) _buildTypingBar(typingPeers),

            if (_replyToMessageId != null) _buildReplyPreviewBar(),
            if (_stagedFilePath != null) _buildStagedFilePreview(),
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
    );
  }

  /// All build-time ref.listen registrations. MUST be invoked from build():
  /// Riverpod re-registers listeners per build and silently no-ops a
  /// registration made anywhere else.
  void _registerBuildListeners() {
    // The cooldown derives from my newest message in this list, which counts a
    // history load, an optimistic send and a sibling device's send alike.
    ref.listen<List<ChannelChatMessage>?>(
        channelChatProvider.select((m) => m[_stateKey]),
        (_, _) => _recomputeSlowMode());
    // Following re-pins to the newest row; reading history freezes the display
    // so the view never shifts mid-read.
    ref.listen<Map<String, List<ChannelChatMessage>>>(
        channelChatProvider, _onMessageListGrowth);
    // A message arriving while the window is unfocused counts as unread, and if
    // this channel was already open at the bottom nothing else clears it: the
    // scroll handler only marks seen on a bottom re-ENTRY.
    ref.listen<bool>(windowFocusedProvider, _onWindowFocusChanged);
    // Opened by the global shortcut, which cannot focus the field itself.
    ref.listen<bool>(chatSearchOpenProvider, _onSearchOpenChanged);
    // "Mention", posted from a surface that has no reference to this composer.
    ref.listen<ComposerInsert?>(composerInsertProvider, _onComposerInsert);
  }

  /// Appends the text of a [ComposerInsert] addressed to THIS channel.
  ///
  /// The scope check keeps a mention out of the other pane in split view, and
  /// the sequence check stops an unrelated rebuild applying it twice.
  void _onComposerInsert(ComposerInsert? prev, ComposerInsert? next) {
    if (next == null) return;
    if (next.scope != ComposerInsert.channelScope(
        widget.serverId, widget.channelId)) {
      return;
    }
    if (next.seq == _lastComposerInsertSeq) return;
    _lastComposerInsertSeq = next.seq;
    _appendToComposer(next.text);
  }

  /// Appends [text] at the end, with the space that separates it from whatever
  /// was already typed.
  void _appendToComposer(String text) {
    final current = _controller.text;
    final needsGap = current.isNotEmpty && !current.endsWith(' ');
    final combined = '$current${needsGap ? ' ' : ''}$text';
    _controller.value = TextEditingValue(
      text: combined,
      selection: TextSelection.collapsed(offset: combined.length),
    );
    _focusNode.requestFocus();
  }

  void _onMessageListGrowth(Map<String, List<ChannelChatMessage>>? prev,
      Map<String, List<ChannelChatMessage>> next) {
    final prevLen = (prev?[_stateKey] ?? const []).length;
    final nextLen = (next[_stateKey] ?? const []).length;
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
    final msgs = ref.read(channelChatProvider)[_stateKey];
    if (msgs == null || msgs.isEmpty) return;
    ref.read(unreadProvider.notifier).markChannelSeen(
        widget.serverId, widget.channelId, msgs.last.messageId);
  }

  void _onSearchOpenChanged(bool? prev, bool next) {
    if (next && !(prev ?? false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _searchFocusNode.requestFocus();
      });
    }
    if (!next && (prev ?? false)) {
      _searchController.clear();
      setState(() => _searchResults = []);
    }
  }

  /// Channel header: name, badges, connection status and pane actions.
  ///
  /// A narrow window can leave this only a couple of hundred pixels, so it sheds
  /// its non-controls first: losing the members toggle behind an overflow would
  /// strand the panel open with no way back.
  Widget _buildHeader(HollowTheme hollow) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth;
        final showStatus = width >= 280;
        final showSplit = width >= 200;
        return Row(
        children: [
          Icon(_isConference ? LucideIcons.video : LucideIcons.hash,
              size: 20, color: hollow.textSecondary),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              widget.channelName,
              style: HollowTypography.subheading.copyWith(
                color: hollow.textPrimary,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_isConference) ...[
            const SizedBox(width: HollowSpacing.sm),
            HollowTooltip(
              message:
                  "Meeting chat isn't stored. It disappears when the meeting ends",
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.sm,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: hollow.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                ),
                child: Text(
                  'Ephemeral',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.accentText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
          if (ref.watch(serverIsNsfwProvider(widget.serverId)).valueOrNull ??
              false) ...[
            const SizedBox(width: HollowSpacing.sm),
            const _NsfwBadge(),
          ],
          if (showStatus) ...[
            const SizedBox(width: HollowSpacing.md),
            _ChannelConnectionStatus(
              serverId: widget.serverId,
              channelId: widget.channelId,
            ),
          ],
          _buildPinnedHeaderButton(hollow),
          const SizedBox(width: HollowSpacing.sm),
          _buildSearchToggleButton(hollow),
          // Members and split view are server concepts; a conference shows its
          // participants in the call area instead.
          if (!_isConference) ...[
            const SizedBox(width: HollowSpacing.sm),
            HollowTooltip(
              message: 'Toggle member panel',
              child: HollowPressable(
                semanticLabel: 'Toggle member panel',
                onTap: () => ref.read(memberPanelProvider.notifier).state =
                    !ref.read(memberPanelProvider),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(
                  LucideIcons.users,
                  size: 20,
                  color: ref.watch(memberPanelProvider)
                      ? hollow.accent
                      : hollow.textSecondary,
                ),
              ),
            ),
          ],
          if (showSplit &&
              !_isConference &&
              ref.watch(layoutModeProvider) == LayoutMode.dock) ...[
            const SizedBox(width: HollowSpacing.sm),
            _buildSplitToggleButton(hollow),
          ],
        ],
        );
      }),
    );
  }

  /// Pin-count button, hidden while nothing is pinned in this channel.
  Widget _buildPinnedHeaderButton(HollowTheme hollow) {
    final pinKey = '${widget.serverId}:${widget.channelId}';
    final pinnedIds = ref.watch(pinnedProvider)[pinKey] ?? [];
    if (pinnedIds.isEmpty) return const SizedBox.shrink();
    final label =
        '${pinnedIds.length} pinned message${pinnedIds.length == 1 ? '' : 's'}';
    return HollowTooltip(
      message: label,
      child: HollowPressable(
        semanticLabel: label,
        onTap: () => _showPinnedMessages(context, hollow, pinnedIds),
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        padding: const EdgeInsets.all(HollowSpacing.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.pin, size: 16, color: hollow.accent),
            const SizedBox(width: 2),
            Text(
              '${pinnedIds.length}',
              style: HollowTypography.caption.copyWith(
                color: hollow.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchToggleButton(HollowTheme hollow) {
    return HollowTooltip(
      message: 'Search messages',
      child: HollowPressable(
        semanticLabel: 'Search messages',
        onTap: () {
          final current = ref.read(chatSearchOpenProvider);
          ref.read(chatSearchOpenProvider.notifier).state = !current;
          if (!current) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _searchFocusNode.requestFocus();
            });
          }
        },
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        padding: const EdgeInsets.all(HollowSpacing.xs),
        child: Icon(
          LucideIcons.search,
          size: 18,
          color: ref.watch(chatSearchOpenProvider)
              ? hollow.accent
              : hollow.textSecondary,
        ),
      ),
    );
  }

  Widget _buildSplitToggleButton(HollowTheme hollow) {
    final isSplit = ref.watch(splitViewProvider).isSplit;
    final label = isSplit ? 'Close this pane' : 'Split view';
    return HollowTooltip(
      message: label,
      child: HollowPressable(
        semanticLabel: label,
        onTap: _handleSplitToggle,
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        padding: const EdgeInsets.all(HollowSpacing.xs),
        child: Icon(
          LucideIcons.columns,
          size: 18,
          color: isSplit ? hollow.accent : hollow.textSecondary,
        ),
      ),
    );
  }

  /// In-channel message search: query field + up to 20 tappable results.
  Widget _buildSearchBar(HollowTheme hollow) {
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
            hintText: 'Search in #${widget.channelName}...',
            autofocus: true,
            isDense: true,
            prefixIcon: const Icon(LucideIcons.search, size: 16),
            onChanged: _onSearch,
            style: HollowTypography.body.copyWith(
              color: hollow.textPrimary,
              fontSize: 13,
            ),
          ),
          if (_searchResults.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _searchResults.length,
                itemBuilder: (_, index) =>
                    _buildSearchResultTile(hollow, _searchResults[index]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchResultTile(HollowTheme hollow, dynamic msg) {
    // Collapse device to master so a result shows the person, not a raw device
    // id.
    final searchMaster =
        ref.watch(deviceLinkProvider).identityOf(msg.senderId);
    final senderProfile =
        ref.watch(profileProvider.select((p) => p[searchMaster]));
    final senderNickname = ref.watch(serverNicknamesProvider(widget.serverId)
        .select((n) => n[searchMaster]));
    final name = serverDisplayNameForPeer(
      senderProfile,
      searchMaster,
      nickname: senderNickname ?? '',
    );
    final time = DateTime.fromMillisecondsSinceEpoch(msg.timestamp);
    return Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.xs),
      child: HollowPressable(
        subtle: true,
        onTap: () => _jumpToSearchResult(msg),
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        hoverColor: hollow.elevated,
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm,
          vertical: HollowSpacing.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  name,
                  style: HollowTypography.caption.copyWith(
                    color: hollow.accent,
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                Text(
                  _hhmm(time),
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary.withValues(alpha: 0.5),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              msg.text,
              style: HollowTypography.body.copyWith(
                color: hollow.textPrimary,
                fontSize: 12,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  /// Closes search and scrolls to the tapped result. The index is against the
  /// DISPLAY list, possibly frozen, which is what [_scrollToMessage] takes.
  void _jumpToSearchResult(dynamic msg) {
    final messages =
        _displayMessages(ref.read(channelChatProvider)[_stateKey] ?? []);
    final idx = messages.indexWhere((m) => m.messageId == msg.messageId);
    ref.read(chatSearchOpenProvider.notifier).state = false;
    setState(() {
      _searchController.clear();
      _searchResults = [];
    });
    if (idx != -1) _scrollToMessage(idx);
  }

  /// The message list area: permission gate, empty state, list and unread pill.
  Widget _buildMessageArea(
    HollowTheme hollow,
    List<ChannelChatMessage> messages,
    List<ChannelChatMessage> allMessages,
  ) {
    final perms =
        ref.watch(myPermissionsProvider(widget.serverId)).valueOrNull ??
            Permission.all;
    if (perms & Permission.readMessages == 0) {
      return Expanded(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.eyeOff,
                  size: 48, color: hollow.textSecondary.withValues(alpha: 0.3)),
              const SizedBox(height: HollowSpacing.md),
              Text(
                'You don\'t have permission to read messages in this channel',
                style:
                    HollowTypography.body.copyWith(color: hollow.textSecondary),
              ),
            ],
          ),
        ),
      );
    }
    return Expanded(
      child: Stack(
        children: [
          _buildMessageListLayer(hollow, messages),
          _buildUnreadPillOverlay(allMessages),
        ],
      ),
    );
  }

  Widget _buildMessageListLayer(
      HollowTheme hollow, List<ChannelChatMessage> messages) {
    return MessageActionBarScope(
      child: Builder(
        builder: (scopeContext) => NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollUpdateNotification) {
              MessageActionBarScope.of(scopeContext)?.dismissAll();
            }
            return false;
          },
          child: Container(
            color: hollow.background,
            child: messages.isEmpty
                ? (_historyLoaded
                    ? _buildEmptyChannelState(hollow)
                    : const SizedBox.shrink())
                : _buildMessageList(hollow, messages),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyChannelState(HollowTheme hollow) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.hash,
            size: 64,
            color: hollow.textSecondary.withValues(alpha: 0.3),
          ),
          const SizedBox(height: HollowSpacing.lg),
          Text(
            'Welcome to #${widget.channelName}',
            style: HollowTypography.heading.copyWith(color: hollow.textPrimary),
          ),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            'This is the beginning of the channel.',
            style: HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
        ],
      ),
    );
  }

  /// The reversed message list plus the per-build row precomputes.
  Widget _buildMessageList(
      HollowTheme hollow, List<ChannelChatMessage> messages) {
    // Once per build rather than per ROW per rebuild: an O(n) scan for the
    // reply target, and a provider read for the mention needles.
    final profiles = ref.watch(profileProvider);
    final nicknames = ref.watch(serverNicknamesProvider(widget.serverId));
    final replyIndexById = <String, int>{
      for (var i = 0; i < messages.length; i++)
        if (messages[i].messageId != null) messages[i].messageId!: i,
    };
    final localPeerIdForMentions = ref.read(identityProvider).peerId ?? '';
    final localMentionName =
        '@${displayNameFor(profiles, localPeerIdForMentions)}';
    final localNickRaw = nicknames[localPeerIdForMentions];
    final String? localMentionNick =
        (localNickRaw != null && localNickRaw.isNotEmpty)
            ? '@$localNickRaw'
            : null;
    // One computation per build feeds both the rail's mark and the row that
    // carries the line (issue #54).
    final unreadIndex = unreadDividerIndex(
      count: messages.length,
      entrySeenId: ref.watch(unreadMarkerProvider)[
          channelMarkerKey(widget.serverId, widget.channelId)],
      messageIdAt: (i) => messages[i].messageId,
      isMineAt: (i) => messages[i].isMe,
    );
    return reversedChatList(
      context: context,
      listKey: ValueKey('ch-list-${widget.serverId}-${widget.channelId}'),
      itemScrollController: _itemScrollController,
      itemPositionsListener: _itemPositionsListener,
      scrollOffsetController: _scrollOffsetController,
      itemCount: messages.length,
      indexByMessageId: replyIndexById,
      // Through the pane, not the raw controller: the display list is frozen
      // while reading, so index 0 is not the newest message until the freeze is
      // released (issue #54).
      onJumpToNewest: _scrollToBottom,
      unreadRevIndex:
          unreadIndex == null ? null : messages.length - 1 - unreadIndex,
      itemBuilder: (context, revIndex) => _buildMessageRow(
        context,
        revIndex,
        messages,
        replyIndexById,
        localMentionName,
        localMentionNick,
        unreadIndex,
      ),
    );
  }

  /// One chat row. [revIndex] is the reversed builder index.
  Widget _buildMessageRow(
    BuildContext context,
    int revIndex,
    List<ChannelChatMessage> messages,
    Map<String, int> replyIndexById,
    String localMentionName,
    String? localMentionNick,
    int? unreadIndex,
  ) {
    // Map the reversed builder index back to chronological order; all row logic
    // below stays in chronological terms.
    final index = messages.length - 1 - revIndex;
    final msg = messages[index];
    // Grouping collapses each sender to its MASTER, or a person writing from
    // two devices reads as two people; `isMe` folds into the same-master test.
    final links = ref.watch(deviceLinkProvider);
    final showHeader = index == 0 ||
        !shouldGroup(
          currentIsMe: false,
          previousIsMe: false,
          currentTime: msg.timestamp,
          previousTime: messages[index - 1].timestamp,
          currentSenderId: links.identityOf(msg.senderId),
          previousSenderId: links.identityOf(messages[index - 1].senderId),
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
      onReaction: !_isConference && msg.messageId != null
          ? (emoji) => _toggleReaction(msg, emoji)
          : null,
      onPin: _pinFor(msg),
      isPinned: _isPinned(msg),
      onDownload: _downloadFor(context, msg),
      // The hover bar and the message menu mirror the card: no Download while
      // nobody can serve the file.
      fileAttachment: msg.fileAttachment,
      onCopy: _copyFor(context, msg),
      onCopyImage: _copyImageFor(context, msg),
      onInfo: _infoFor(context, msg),
      child: _buildBubble(msg, index, showHeader, messages, replyIndexById,
          localMentionName, localMentionNick,
          _tilingAt(messages, index, showHeader, links)),
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
      child: wrapper,
    );
  }

  /// Sticker tiling for the row at [index]. `showHeader` IS "not grouped with
  /// the previous", and grouping compares MASTER identities.
  ({bool prev, bool next}) _tilingAt(
    List<ChannelChatMessage> messages,
    int index,
    bool showHeader,
    DeviceLinkState links,
  ) {
    bool candidate(ChannelChatMessage m) => stickerTileCandidate(
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
            currentIsMe: false,
            previousIsMe: false,
            currentTime: next.timestamp,
            previousTime: messages[index].timestamp,
            currentSenderId: links.identityOf(next.senderId),
            previousSenderId: links.identityOf(messages[index].senderId),
          ),
    );
  }

  Widget _buildBubble(
    ChannelChatMessage msg,
    int index,
    bool showHeader,
    List<ChannelChatMessage> messages,
    Map<String, int> replyIndexById,
    String localMentionName,
    String? localMentionNick,
    ({bool prev, bool next}) tiling,
  ) {
    String? replySender;
    String? replyText;
    String? replyImagePath;
    int? replyIndex;
    if (msg.replyToMid != null) {
      final idx = replyIndexById[msg.replyToMid] ?? -1;
      if (idx != -1) {
        replyIndex = idx;
        final original = messages[idx];
        replyText = _messagePreviewText(original);
        // Collapse device to master so the reply preview shows the sender, not
        // a device id.
        final origMaster =
            ref.watch(deviceLinkProvider).identityOf(original.senderId);
        replySender = serverDisplayNameFor(
          ref.watch(profileProvider),
          origMaster,
          nickname:
              ref.watch(serverNicknamesProvider(widget.serverId))[origMaster] ??
                  '',
        );
        if (original.fileAttachment?.isImage == true) {
          replyImagePath = original.fileAttachment?.diskPath;
        }
      }
    }
    final msgMentioned = msg.text.contains('@everyone') ||
        msg.text.contains(localMentionName) ||
        (localMentionNick != null && msg.text.contains(localMentionNick));
    return ChannelMessageBubble(
      message: msg,
      serverId: widget.serverId,
      showHeader: showHeader,
      replyToSenderName: replySender,
      replyToText: replyText,
      replyToImagePath: replyImagePath,
      isHighlighted: _highlightIndex == index,
      isMentioned: msgMentioned,
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
  // conference chat is RAM-only MLS text: no CRDT-backed edit, delete, reply or
  // pin, and no Ed25519 proof.

  VoidCallback? _editStartFor(ChannelChatMessage msg, int revIndex) {
    final canEdit = !_isConference &&
        msg.messageId != null &&
        msg.isMe &&
        msg.fileAttachment == null;
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

  VoidCallback? _deleteFor(ChannelChatMessage msg) {
    if (_isConference || msg.messageId == null || !msg.isMe) return null;
    return () => _deleteMessage(msg.messageId!);
  }

  Future<void> _deleteMessage(String messageId) async {
    try {
      await ref.read(channelChatProvider.notifier).deleteMessage(
          widget.serverId, widget.channelId, messageId);
    } catch (_) {
      if (!mounted) return;
      HollowToast.show(context, 'Failed to delete message',
          type: HollowToastType.error);
    }
  }

  Future<void> _submitEdit(String messageId, String newText) async {
    try {
      await ref.read(channelChatProvider.notifier).editMessage(
          widget.serverId, widget.channelId, messageId, newText);
    } catch (_) {
      if (!mounted) return;
      HollowToast.show(context, 'Failed to save changes',
          type: HollowToastType.error);
      return;
    }
    if (!mounted) return;
    _resyncPreviewAfterEdit(messageId, newText);
  }

  /// Keeps the card honest after an edit (issue #45), like the DM twin.
  Future<void> _resyncPreviewAfterEdit(String messageId, String newText) async {
    if (!ref.read(linkPreviewsEnabledProvider)) return;
    final key = '${widget.serverId}:${widget.channelId}';
    final msgs =
        ref.read(channelChatProvider)[key] ?? const <ChannelChatMessage>[];
    final idx = msgs.indexWhere((m) => m.messageId == messageId);
    final oldUrl = idx == -1 ? null : msgs[idx].linkPreview?.url;
    final newUrl = _urlRegex.firstMatch(newText)?.group(0);

    if (newUrl == oldUrl) return;
    if (newUrl == null) {
      _attachPreview(messageId, null);
      return;
    }
    if (extractHollowLinks(newUrl).isNotEmpty) {
      if (oldUrl != null) _attachPreview(messageId, null);
      return;
    }
    try {
      final preview = await network_api.fetchLinkPreview(url: newUrl);
      if (!mounted) return;
      _attachPreview(messageId, preview);
    } catch (_) {
      // Leave the existing card rather than blanking it on a transient failure.
    }
  }

  VoidCallback? _replyFor(ChannelChatMessage msg) {
    if (_isConference || msg.messageId == null) return null;
    return () {
      // Collapse device to master so the reply banner shows the person, not a
      // raw device id.
      final replyMaster =
          ref.read(deviceLinkProvider).identityOf(msg.senderId);
      final senderName = serverDisplayNameFor(
        ref.read(profileProvider),
        replyMaster,
        nickname:
            ref.read(serverNicknamesProvider(widget.serverId))[replyMaster] ??
                '',
      );
      setState(() {
        _replyToMessageId = msg.messageId;
        _replyToText = _messagePreviewText(msg);
        _replyToSenderName = senderName;
        _replyToImagePath = msg.fileAttachment?.isImage == true
            ? msg.fileAttachment?.diskPath
            : null;
      });
      _focusNode.requestFocus();
    };
  }

  Future<void> _toggleReaction(ChannelChatMessage msg, String emoji) async {
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final hasReacted = msg.reactions[emoji]?.contains(localPeerId) ?? false;
    final notifier = ref.read(channelChatProvider.notifier);
    try {
      if (hasReacted) {
        await notifier.removeReaction(
            widget.serverId, widget.channelId, msg.messageId!, emoji);
      } else {
        await notifier.addReaction(
            widget.serverId, widget.channelId, msg.messageId!, emoji);
      }
    } catch (_) {
      if (!mounted) return;
      HollowToast.show(context, 'Failed to update reaction',
          type: HollowToastType.error);
    }
  }

  /// Whether [msg] is pinned. Reads the same `pinnedProvider` entry the
  /// pin-count button watches, so the row is already rebuilding when one flips.
  bool _isPinned(ChannelChatMessage msg) {
    final mid = msg.messageId;
    if (mid == null) return false;
    final pinKey = '${widget.serverId}:${widget.channelId}';
    return (ref.watch(pinnedProvider)[pinKey] ?? const <String>[]).contains(mid);
  }

  VoidCallback? _pinFor(ChannelChatMessage msg) {
    if (_isConference || msg.messageId == null) return null;
    final canPin = ref.watch(myPermissionsProvider(widget.serverId)).whenOrNull(
            data: (perms) => (perms & Permission.manageChannels) != 0) ??
        false;
    if (!canPin) return null;
    return () => _togglePin(msg.messageId!);
  }

  Future<void> _togglePin(String messageId) async {
    final pins = ref.read(
            pinnedProvider)['${widget.serverId}:${widget.channelId}'] ??
        [];
    final isPinned = pins.contains(messageId);
    try {
      if (isPinned) {
        await crdt_api.unpinMessage(
          serverId: widget.serverId,
          channelId: widget.channelId,
          messageId: messageId,
        );
      } else {
        await crdt_api.pinMessage(
          serverId: widget.serverId,
          channelId: widget.channelId,
          messageId: messageId,
        );
      }
    } catch (_) {
      if (!mounted) return;
      HollowToast.show(
          context,
          isPinned ? 'Failed to unpin message' : 'Failed to pin message',
          type: HollowToastType.error);
    }
  }

  VoidCallback? _downloadFor(BuildContext context, ChannelChatMessage msg) {
    final attachment = msg.fileAttachment;
    if (attachment == null) return null;
    return () {
      final transfer = ref.read(fileTransferProvider)[attachment.fileId];
      if (transfer != null && transfer.isDownloading) {
        HollowToast.show(context, 'File is already downloading...',
            type: HollowToastType.info);
        return;
      }

      // A vault video thumbnail saves the underlying VIDEO, not the .webp; the
      // link rides `videoThumb.cid`.
      if (attachment.videoThumb != null) {
        _vaultDownloadAndSaveVideo(attachment);
      } else if (attachment.diskPath != null) {
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
              serverId: widget.serverId,
              sequential: false,
            ).catchError((e) {
          if (context.mounted) {
            HollowToast.show(context, 'Download failed: $e',
                type: HollowToastType.error);
          }
        });
      } else {
        // Under 6 members the server replicates fully, so the sender still has
        // the bytes; above that they come from the vault.
        final memberCount = ref
                .read(serverMembersProvider(widget.serverId))
                .valueOrNull
                ?.length ??
            0;
        if (memberCount >= 6) {
          _vaultDownloadAndSave(attachment);
        } else {
          _requestFileFromPeer(attachment, msg.senderId);
        }
      }
    };
  }

  VoidCallback? _copyFor(BuildContext context, ChannelChatMessage msg) {
    if (msg.text.isEmpty || msg.text.startsWith('[file:')) return null;
    return () {
      Clipboard.setData(ClipboardData(text: msg.text));
      HollowToast.show(context, 'Copied to clipboard',
          type: HollowToastType.success);
    };
  }

  VoidCallback? _copyImageFor(BuildContext context, ChannelChatMessage msg) {
    final attachment = msg.fileAttachment;
    if (attachment == null || attachment.diskPath == null || !attachment.isImage) {
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

  // MLS authenticates conference lines per message, so the Ed25519 proof dialog
  // would only ever read "UNSIGNED".
  VoidCallback? _infoFor(BuildContext context, ChannelChatMessage msg) {
    if (_isConference) return null;
    return () {
      final localPeerId = ref.read(identityProvider).peerId ?? '';
      // The send side signs with the MASTER id, so the proof must verify
      // against the master or a multi-device sender reads as invalid.
      final senderPeerId = msg.isMe
          ? localPeerId
          : ref.read(deviceLinkProvider).identityOf(msg.senderId);
      showMessageProofDialog(
        context,
        MessageProofData(
          senderPeerId: senderPeerId,
          senderDisplayName: serverDisplayNameFor(
            ref.read(profileProvider),
            senderPeerId,
            nickname: ref.read(
                    serverNicknamesProvider(widget.serverId))[senderPeerId] ??
                '',
          ),
          text: msg.text,
          // An edited message's signature covers the edit timestamp and the new
          // text, so the canonical payload must be rebuilt from editedAt.
          timestampMs: (msg.editedAt ?? msg.timestamp).millisecondsSinceEpoch,
          signature: msg.signature,
          publicKey: msg.publicKey,
          messageId: msg.messageId,
          context: '${widget.serverId}:${widget.channelId}',
          msgType: 'ch',
          fileAttachment: msg.fileAttachment,
        ),
      );
    };
  }

  /// Unread pill, only for messages that arrived while scrolled up.
  Widget _buildUnreadPillOverlay(List<ChannelChatMessage> allMessages) {
    final unreadCount = ref.watch(unreadProvider.select((s) =>
        s.channelUnreadCounts['${widget.serverId}:${widget.channelId}'] ?? 0));
    if (unreadCount <= 0 || !_showScrollPill) return const SizedBox.shrink();
    return Positioned(
      bottom: HollowSpacing.md,
      left: 0,
      right: 0,
      child: Center(
        child: UnreadJumpPill(
          count: unreadCount,
          onTap: () {
            _scrollToBottom();
            // The display list may be frozen, so mark seen against the TRUE
            // newest message.
            ref.read(unreadProvider.notifier).markChannelSeen(
                  widget.serverId,
                  widget.channelId,
                  allMessages.last.messageId,
                );
          },
        ),
      ),
    );
  }

  /// Typing indicator. Typing peers are DEVICE ids, collapsed to their master so
  /// the master-keyed name lookup hits and one person shows once; our own
  /// identity is excluded so a sibling never reads as "you are typing" (see
  /// [typingMastersFor]).
  Widget _buildTypingBar(Set<String> typingPeers) {
    final masters = typingMastersFor(ref, typingPeers);
    final nicknames = ref.watch(serverNicknamesProvider(widget.serverId));
    final profiles = ref.watch(profileProvider);
    if (masters.isEmpty) return const SizedBox.shrink();
    return TypingIndicatorBar(
      names: masters
          .map((master) => serverDisplayNameFor(
                profiles,
                master,
                nickname: nicknames[master] ?? '',
              ))
          .toList(),
    );
  }

  Widget _buildReplyPreviewBar() {
    return ChatReplyPreviewBar(
      senderName: _replyToSenderName,
      text: _replyToText,
      imagePath: _replyToImagePath,
      onCancel: _cancelReply,
    );
  }

  void _cancelReply() {
    setState(() {
      _replyToMessageId = null;
      _replyToText = null;
      _replyToSenderName = null;
      _replyToImagePath = null;
    });
  }

  Widget _buildStagedFilePreview() {
    return StagedFilePreviewBar(
      filePath: _stagedFilePath!,
      fileName: _stagedFileName,
      isImage: _stagedFileIsImage,
      onRemove: _removeStagedFile,
    );
  }

  void _removeStagedFile() {
    setState(() {
      _stagedFilePath = null;
      _stagedFileName = null;
      _stagedFileIsImage = false;
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

  /// Input bar: a blocked banner when posting is not allowed, else the voice
  /// recorder or the composer row.
  Widget _buildInputBar(HollowTheme hollow) {
    final mute = ref.watch(myMuteStatusProvider(widget.serverId)).valueOrNull;
    final canPost = ref.watch(canPostInChannelProvider(
        (serverId: widget.serverId, channelId: widget.channelId)));
    // Keeps the grant-expiry timer alive while this channel is open: a lapsed
    // temporary grant emits no network event, so this timer is what evicts us.
    ref.watch(myChannelGrantProvider(
        (serverId: widget.serverId, channelId: widget.channelId)));
    if (!canPost || mute != null) {
      return Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.lg,
        ),
        decoration: BoxDecoration(
          color: hollow.surface,
          border: Border(top: BorderSide(color: hollow.border)),
        ),
        child: Center(
          child: Text(
            _muteBannerText(mute) ??
                'You don\'t have permission to send messages in this channel',
            style: HollowTypography.bodySmall.copyWith(
              color: hollow.textSecondary,
            ),
          ),
        ),
      );
    }
    return chatInputBarShell(
      hollow,
      flushTop: _replyToMessageId != null ||
          _stagedFilePath != null ||
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
    return Row(
      children: [
        // Conference chat is RAM-only text, so a file or voice send would ride
        // the persisting channel pipeline. Hidden, not disabled.
        if (!_isConference) ...[
          HollowPressable(
            semanticLabel: 'Attach file',
            onTap: _pickAndStageFile,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            padding: const EdgeInsets.all(HollowSpacing.sm),
            child: Icon(
              LucideIcons.paperclip,
              color: hollow.textSecondary,
              size: 20,
            ),
          ),
          const SizedBox(width: HollowSpacing.xs),
          HollowPressable(
            semanticLabel: 'Record voice message',
            onTap: _stagedFilePath != null ? null : _startVoiceRecording,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            padding: const EdgeInsets.all(HollowSpacing.sm),
            child: Icon(
              LucideIcons.mic,
              color: _stagedFilePath != null
                  ? hollow.textSecondary.withValues(alpha: 0.4)
                  : hollow.textSecondary,
              size: 20,
            ),
          ),
          const SizedBox(width: HollowSpacing.xs),
        ],
        Expanded(
          child: CompositedTransformTarget(
            link: _mentionLayerLink,
            child: Focus(
              onKeyEvent: (_, event) => _handleComposerKey(event),
              child: chatComposerField(
                hollow,
                controller: _controller,
                focusNode: _focusNode,
                hintText: 'Message #${widget.channelName}',
                onChanged: _onTextChanged,
              ),
            ),
          ),
        ),
        const SizedBox(width: HollowSpacing.xs),
        composerGifButton(hollow, onOpen: _openComposerGifPicker),
        composerStickerButton(hollow,
            onOpen: _openComposerStickerPicker),
        const SizedBox(width: HollowSpacing.xs),
        composerEmojiButton(hollow, onOpen: _openComposerEmojiPicker),
        const SizedBox(width: HollowSpacing.sm),
        if (_slowModeReadyAt != null) ...[
          _buildSlowModePill(hollow),
          const SizedBox(width: HollowSpacing.xs),
        ],
        HollowPressable(
          semanticLabel: 'Send message',
          onTap: _handleSend,
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          backgroundColor: hollow.accent,
          padding: const EdgeInsets.all(HollowSpacing.sm),
          child: Icon(
            LucideIcons.send,
            color: hollow.textOnAccent,
            size: 20,
          ),
        ),
      ],
    );
  }

  void _startVoiceRecording() {
    // A voice note is audio, not media, so a media-only channel refuses it
    // before recording rather than after.
    if (_channelMediaOnly) {
      HollowToast.show(
        context,
        'This is a media-only channel. Voice messages can\'t be posted here',
        type: HollowToastType.info,
      );
      return;
    }
    setState(() => _isRecordingVoice = true);
  }

  Widget _buildSlowModePill(HollowTheme hollow) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: hollow.warning.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(hollow.radiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.timer, size: 12, color: hollow.warning),
          const SizedBox(width: 3),
          Text(
            '${(_slowModeReadyAt!.difference(DateTime.now()).inSeconds + 1).clamp(1, 3600)}s',
            style: HollowTypography.caption.copyWith(
              color: hollow.warning,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  KeyEventResult _handleComposerKey(KeyEvent event) {
    final mentionResult = _handleMentionOverlayKey(event);
    if (mentionResult != null) return mentionResult;
    final emoteResult = _emoteAutocomplete.handleKey(event);
    if (emoteResult == KeyEventResult.handled) return emoteResult;
    return handleChatInputKey(
      event, _controller, _focusNode, _handleSend,
      onPasteImage: _stageClipboardImage,
      formatBindings: ref.read(appShortcutsProvider).valueOrNull,
    );
  }

  /// Navigation keys while the @mention overlay is open. Null means this was not
  /// one, so the next handler gets it.
  KeyEventResult? _handleMentionOverlayKey(KeyEvent event) {
    if (_mentionOverlay == null ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return null;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveMentionSelection(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveMentionSelection(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.tab) {
      _acceptMention(_mentionCandidates[_mentionSelectedIndex]);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _dismissMentionOverlay();
      return KeyEventResult.handled;
    }
    return null;
  }

  void _moveMentionSelection(int delta) {
    setState(() {
      _mentionSelectedIndex = (_mentionSelectedIndex + delta)
          .clamp(0, _mentionCandidates.length - 1);
    });
    _showMentionOverlay();
  }
}

/// Small "NSFW" pill shown beside the channel name for NSFW-flagged servers.
class _NsfwBadge extends StatelessWidget {
  const _NsfwBadge();

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: hollow.error.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(hollow.radiusSm),
      ),
      child: Text(
        'NSFW',
        style: HollowTypography.caption.copyWith(
          color: hollow.error,
          fontWeight: FontWeight.w700,
          fontSize: 10,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Connection, encryption and sync status for a channel header.
class _ChannelConnectionStatus extends ConsumerWidget {
  final String serverId;
  final String channelId;

  const _ChannelConnectionStatus({
    required this.serverId,
    required this.channelId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Presence is device-keyed while server members are master-keyed, so this
    // collapses through the master or a multi-device member reads as Offline.
    final online = ref.watch(onlineIdentitiesProvider);
    final membersAsync = ref.watch(serverMembersProvider(serverId));
    final localPeerId = ref.watch(identityProvider).peerId;
    // "Offline" is about US, not about an empty room (issue #23): with the relay
    // link up this header must never claim we are offline.
    final amOnline = ref.watch(overallConnectionProvider).isOnline;
    final isCustomRelay =
        ref.watch(relayDomainProvider) != kDefaultRelayDomain;

    ConnectionStage stageFor(bool anyOnline) {
      if (!amOnline) return ConnectionStage.offline;
      // Online members in a WS room are already inside the MLS group.
      if (anyOnline) return ConnectionStage.encrypted;
      if (isCustomRelay) return ConnectionStage.customNetwork;
      return ConnectionStage.alone;
    }

    return membersAsync.when(
      data: (members) {
        final anyOnline = members
            .any((m) => m.peerId != localPeerId && online.contains(m.peerId));
        final stage = stageFor(anyOnline);

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConnectionProgress(
              key: ValueKey('conn-$serverId'),
              stage: stage,
            ),
            if (stage == ConnectionStage.encrypted) ...[
              const SizedBox(width: HollowSpacing.md),
              _SyncIndicator(serverId: serverId, channelId: channelId),
              _VaultHealthIndicator(serverId: serverId),
            ],
          ],
        );
      },
      // Members not loaded yet, so report our own link, which we do know.
      loading: () => ConnectionProgress(
        key: ValueKey('conn-$serverId'),
        stage: stageFor(false),
      ),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

/// Sync status, shown once encryption is established.
class _SyncIndicator extends ConsumerStatefulWidget {
  final String serverId;
  final String channelId;

  const _SyncIndicator({required this.serverId, required this.channelId});

  @override
  ConsumerState<_SyncIndicator> createState() => _SyncIndicatorState();
}

class _SyncIndicatorState extends ConsumerState<_SyncIndicator> {
  DateTime? _lastRetry;

  void _retry() {
    final now = DateTime.now();
    if (_lastRetry != null && now.difference(_lastRetry!).inSeconds < 3) {
      return;
    }
    _lastRetry = now;
    network_api.requestChannelSync(
      serverId: widget.serverId,
      channelId: widget.channelId,
    ).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final syncStatus = ref.watch(serverSyncStatusProvider(widget.serverId));
    final progress = ref.watch(syncProgressProvider)[widget.serverId];

    if (syncStatus == ServerSyncStatus.idle ||
        syncStatus == ServerSyncStatus.connecting) {
      return const SizedBox.shrink();
    }

    final Color dotColor;
    final bool useSpinning;
    final String label;
    final bool showRetry;

    switch (syncStatus) {
      case ServerSyncStatus.syncing:
        dotColor = hollow.accent;
        useSpinning = true;
        label = progress != null && progress.totalCount > 0
            ? 'Syncing ${progress.receivedCount}/${progress.totalCount}...'
            : 'Syncing...';
        showRetry = false;
      case ServerSyncStatus.synced:
        dotColor = hollow.success;
        useSpinning = false;
        label = 'Synced';
        showRetry = false;
      case ServerSyncStatus.retrying:
        dotColor = hollow.warning;
        useSpinning = true;
        label = 'Retrying...';
        showRetry = false;
      case ServerSyncStatus.failed:
        dotColor = hollow.error;
        useSpinning = false;
        label = 'Sync failed';
        showRetry = true;
      default:
        return const SizedBox.shrink();
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (useSpinning)
          _SpinningRefreshIcon(size: 10, color: dotColor)
        else
          StatusDot(color: dotColor),
        const SizedBox(width: HollowSpacing.xs),
        Text(
          label,
          style: HollowTypography.caption.copyWith(color: dotColor),
        ),
        if (showRetry) ...[
          const SizedBox(width: HollowSpacing.xs),
          HollowPressable(
            semanticLabel: 'Retry sync',
            onTap: _retry,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(2),
            child: Icon(
              LucideIcons.refreshCw,
              size: 12,
              color: hollow.error,
            ),
          ),
        ],
      ],
    );
  }
}

/// A continuously spinning refresh icon.
class _SpinningRefreshIcon extends StatefulWidget {
  final double size;
  final Color color;

  const _SpinningRefreshIcon({required this.size, required this.color});

  @override
  State<_SpinningRefreshIcon> createState() => _SpinningRefreshIconState();
}

class _SpinningRefreshIconState extends State<_SpinningRefreshIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    final reduce = ReduceMotionController.instance.isReduced;
    _controller = AnimationController(
      vsync: this,
      duration:
          reduce ? Duration.zero : const Duration(milliseconds: 1500),
    );
    if (!reduce) _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child:
          Icon(LucideIcons.refreshCw, size: widget.size, color: widget.color),
    );
  }
}

/// Vault distribution health, as a coloured dot.
class _VaultHealthIndicator extends ConsumerWidget {
  final String serverId;
  const _VaultHealthIndicator({required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    // Erasure coding only starts at 6 members.
    final memberCount = ref.watch(serverMembersProvider(serverId))
        .valueOrNull?.length ?? 0;
    if (memberCount < 6) return const SizedBox.shrink();

    final status = ref.watch(
      vaultStatusProvider.select((s) => s[serverId]),
    );

    final activeUploads = status?.activeUploads.values
        .where((u) => u.phase != 'complete' && u.phase != 'failed')
        .length ?? 0;
    final activeDownloads = status?.activeDownloads.length ?? 0;
    final totalActive = activeUploads + activeDownloads;
    if (totalActive == 0) return const SizedBox.shrink();

    final tooltip = activeUploads > 0 && activeDownloads > 0
        ? '$activeUploads uploading, $activeDownloads downloading'
        : activeUploads > 0
            ? '$activeUploads file${activeUploads > 1 ? 's' : ''} distributing'
            : '$activeDownloads file${activeDownloads > 1 ? 's' : ''} downloading';

    return HollowTooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.only(left: HollowSpacing.sm),
        child: Icon(LucideIcons.database, size: 13, color: hollow.accent),
      ),
    );
  }
}

class _MentionCandidate {
  final String peerId;
  final String displayName;
  final String? subtitle;

  const _MentionCandidate({
    required this.peerId,
    required this.displayName,
    this.subtitle,
  });
}

