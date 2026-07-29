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
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart' show generateMessageId;
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/download_manager_provider.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
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
  /// Staged file attachment (user picked but hasn't sent yet).
  String? _stagedFilePath;
  String? _stagedFileName;
  bool _stagedFileIsImage = false;
  /// True while the user is recording a voice message — swaps the text
  /// input row for the [VoiceRecorderBar].
  bool _isRecordingVoice = false;
  /// Staged link preview (Phase 6.75).
  String? _stagedPreviewUrl;
  network_api.LinkPreviewRef? _stagedPreview;
  bool _stagedPreviewLoading = false;
  HollowLink? _stagedHollowLink;
  Timer? _urlDebounce;
  static final RegExp _urlRegex = RegExp(r'(?:https?|hollow)://[^\s<>"' "'" r')\]}]+');

  /// @mention autocomplete state.
  OverlayEntry? _mentionOverlay;
  final _mentionLayerLink = LayerLink();
  List<_MentionCandidate> _mentionCandidates = [];
  int _mentionSelectedIndex = 0;
  int _mentionAtPosition = -1;

  /// `:` shortcode autocomplete (emotes + Unicode emoji). Shares the mention
  /// LayerLink — the two triggers are mutually exclusive.
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

  /// Conference chat ('conf:' virtual servers) is a RAM-only text surface:
  /// no server members/split view, no CRDT-backed reactions/pins/edits, no
  /// Ed25519 proof affordance (MLS authenticates each line instead).
  bool get _isConference => widget.serverId.startsWith('conf:');


  @override
  void initState() {
    super.initState();
    // Close search bar when (re-)entering a channel — cannot reset in dispose
    // because Riverpod forbids all ref usage once the element is unmounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(channelSearchOpenProvider.notifier).state = false;
        // Re-derive the slow-mode cooldown for THIS channel (the pane remounts
        // per channel — the previous pane's ephemeral pill state is gone, but
        // the message history isn't).
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
    // Edge-triggered mark-seen (mobile-style) — this used to run a map-clone
    // + FFI settings write per scroll frame while sitting at the bottom.
    if (nearBottom && !_wasNearBottom) {
      final msgs = ref.read(channelChatProvider)[_stateKey];
      // Reached the bottom: release the freeze. If messages were held back
      // while reading, snap to the true newest row.
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
      // Left the bottom: freeze the display so arrivals can't shift the
      // reading position (see chat_pane.dart's reversed-list scroll model).
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
      // Positions are in REVERSED index space (newest = 0) — map the visible
      // range back to chronological indices for requestVisibleFiles.
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
    // Always load from DB on first open — the in-memory cache may contain only
    // late-arriving network messages (e.g. a push while the server wasn't yet
    // selected), which would hide full DB history if we skipped the load.
    // `loadHistory` merges DB results with any in-memory messages not yet
    // persisted, so this is safe for optimistic in-flight sends.
    _loadingHistory = true;
    await ref
        .read(channelChatProvider.notifier)
        .loadHistory(widget.serverId, widget.channelId);
    if (!mounted) return;
    ref.read(pinnedProvider.notifier).loadPins(widget.serverId, widget.channelId);
    _historyLoaded = true;
    _loadingHistory = false;
    setState(() {});
    // Pin to the latest message. ScrollablePositionedList only honors
    // `initialScrollIndex` at first build; when loadHistory grows the list
    // from its initial (possibly 1-message) state, we need an explicit jump.
    _jumpToBottom();
    // Mark channel as read now that messages are loaded.
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
    _slowModeTimer?.cancel();
    _fileRequestDebounce?.cancel();
    _itemPositionsListener.itemPositions.removeListener(_onScrollPositionChanged);
    _controller.dispose();
    _focusNode.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  // ── Reversed-list scroll model — see chat_pane.dart for the rationale ──
  // reverse:true, newest message at index 0 pinned to the bottom; while the
  // user reads history the display is FROZEN (arrivals held back, pill takes
  // over); all bottom snaps are instant jumpTo — never animated.

  /// Non-null while the user is scrolled up: display list capped here.
  int? _frozenLen;

  /// The messages currently displayed (frozen prefix while scrolled up),
  /// minus messages from blocked senders. The freeze cap is applied to the
  /// RAW list first (the freeze length is captured from raw-list growth in
  /// the channelChatProvider listener), then blocked senders are filtered —
  /// blocked-sender comparison collapses device→master via the resolver.
  /// build() watches blockedUsersProvider so the pane rebuilds on changes.
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

  /// [index] is CHRONOLOGICAL (0 = oldest) — converted to the reversed
  /// builder index here, in one place.
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
      // Reversed alignment measures from the BOTTOM edge.
      alignment: 0.6,
    );
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightIndex = null);
    });
  }

  /// HH:MM (24h, zero-padded) — shared by the search results and pin dialog.
  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// The chat's standard inline thumbnail: [GifFileImage] for .gif paths
  /// (animated), [Image.file] otherwise.
  /// '📷 Image' / '📎 name' for attachments, else the message text.
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

  /// One row of the pinned-messages dialog: sender + time header, then the
  /// attachment thumbnail or text, with date/divider separators between rows.
  Widget _buildPinnedItem(
    HollowTheme hollow,
    List<ChannelChatMessage> pinnedMessages,
    int index,
  ) {
    final msg = pinnedMessages[index];
    final profiles = ref.read(profileProvider);
    final nicknames = ref.read(serverNicknamesProvider(widget.serverId));
    // Collapse device→master so pinned rows show the person's
    // name (not a raw device id). Single-device → no-op.
    final pinnedMaster =
        ref.read(deviceLinkProvider).identityOf(msg.senderId);
    final name = serverDisplayNameFor(
      profiles,
      pinnedMaster,
      nickname: nicknames[pinnedMaster] ?? '',
    );

    // Date separator between pinned messages on different days.
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
    // Debounced URL detection for link previews (Phase 6.75).
    _urlDebounce?.cancel();
    _urlDebounce = Timer(const Duration(milliseconds: 600), _detectUrl);

    // @mention autocomplete detection.
    _updateMentionAutocomplete(text);
    // `:` emote shortcode autocomplete.
    _emoteAutocomplete.update(context, text);

    if (text.isEmpty) return;
    // Don't send typing indicators when invisible.
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

  /// Scan backward from [cursor] for an '@' that starts a mention (preceded
  /// by start-of-text, space, or newline). -1 = no active mention trigger.
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

  /// Candidates for the mention query: matching server members (by display
  /// name, server nickname, or profile name) plus @everyone.
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

    // Also add @everyone.
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

  /// Extract the first URL from the current compose text and, if it
  /// differs from what's staged, kick off a background OG fetch. If the
  /// URL was removed, clear the staged preview.
  void _detectUrl() {
    if (!mounted) return;
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
      if (!mounted || _stagedPreviewUrl != url) return;
      setState(() {
        _stagedPreview = preview;
        _stagedPreviewLoading = false;
      });
    } catch (_) {
      if (!mounted || _stagedPreviewUrl != url) return;
      setState(() {
        _stagedPreviewUrl = null;
        _stagedPreview = null;
        _stagedPreviewLoading = false;
      });
    }
  }

  /// Extensions the chat renders inline — the only types a media-only
  /// channel accepts (matches the Rust-side ingest gate).
  static const _mediaExtensions = kMediaOnlyExtensions;

  /// The channel's slow-mode interval, or 0 when off / when the local user
  /// is Moderator+ (exempt — mirrors the Rust rule).
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

  /// The DERIVED slow-mode cooldown for this channel right now — my newest
  /// message's timestamp + the interval, straight from the loaded list. Never
  /// widget state: survives channel switches and always matches the Rust gate.
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
      'Slow mode — wait ${remaining.inSeconds + 1}s before sending again',
      type: HollowToastType.info,
    );
    return true;
  }

  /// Re-derives the cooldown (pill state) and keeps a 1s ticker running while
  /// it's active. Called on mount, on every message-list change (my optimistic
  /// send lands there too), and by the ticker itself until expiry.
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
          _recomputeSlowMode(); // derives null → clears the pill
        } else {
          setState(() {}); // tick the countdown pill
        }
      });
    }
  }

  Future<void> _handleSend() async {
    _dismissMentionOverlay();
    _emoteAutocomplete.dismiss();
    if (_blockedBySlowMode()) return;
    // If a file is staged, send it (with optional text).
    if (_stagedFilePath != null) {
      await _sendStagedFile();
      return;
    }
    // Expand inline-emote placeholders to [e:name:hash] wire tokens.
    final text = _controller.expandedText().trim();
    if (text.isEmpty) return;
    if (_channelMediaOnly) {
      HollowToast.show(
        context,
        'This is a media-only channel — attach an image, GIF, or video',
        type: HollowToastType.info,
      );
      return;
    }
    _controller.clear();
    _lastTypingSent = null;
    _focusNode.requestFocus();
    final replyMid = _replyToMessageId;
    // Capture staged preview BEFORE clearing state.
    final preview = _stagedPreview;
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
      await ref
          .read(channelChatProvider.notifier)
          .sendMessage(widget.serverId, widget.channelId, text,
              replyToMid: replyMid, linkPreview: preview);
    } catch (_) {
      // The provider only adds the bubble AFTER the network send, so a
      // failure here would otherwise vanish silently (composer already
      // cleared, no bubble).
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

  /// Stages a file dropped from the OS via desktop_drop.
  Future<void> _handleDroppedFile(String path, String name, int sizeBytes) async {
    if (!mounted) return;
    // Over 34 MB: confirm hosting it as a Hollow Share rather than silently
    // auto-converting (the old behavior — receivers could never download it
    // across symmetric NATs with no warning).
    if (sizeBytes > kLargeFileThresholdBytes) {
      final ok = await confirmLargeFileShare(context,
          fileName: name, sizeBytes: sizeBytes);
      if (!ok || !mounted) return;
    }
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (_channelMediaOnly && !_mediaExtensions.contains(ext)) {
      HollowToast.show(
        context,
        'This is a media-only channel — only images, GIFs, and videos can be posted',
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
      // Media-only channels: restrict the native picker to what the channel
      // accepts (images/GIFs/videos) instead of failing after selection.
      final result = _channelMediaOnly
          ? await FilePicker.platform.pickFiles(
              type: FileType.custom,
              allowedExtensions: _mediaExtensions.toList(),
            )
          : await FilePicker.platform.pickFiles();
      if (result == null || result.files.isEmpty) { _isPicking = false; return; }
      final file = result.files.first;
      if (file.path == null) { _isPicking = false; return; }

      // Over 34 MB: confirm hosting it as a Hollow Share (no silent convert).
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
      // Defer the re-focus past the OS window-focus restoration after the native
      // file dialog closes (a synchronous requestFocus races it → keystrokes
      // don't land until the user clicks the field again). See chat_pane.dart.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    } finally { _isPicking = false; }
  }

  /// Called by [VoiceRecorderBar] when the user taps send. Stages the
  /// `.ogg` voice file and sends it immediately.
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
        'This is a media-only channel — only images, GIFs, and videos can be posted',
        type: HollowToastType.info,
      );
      return;
    }

    // Clear staged state + input.
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
        );
    _recomputeSlowMode();

    // Clean up voice recording temp files after successful send.
    if (fileName.endsWith('.ogg') && filePath.contains('temp')) {
      try { await File(filePath).delete(); } catch (_) {}
    }
  }

  Future<void> _saveFile(FileAttachment attachment) async {
    if (attachment.diskPath == null) return;
    await _saveAttachmentAs(attachment.diskPath!, attachment);
  }

  /// Request a file from the original sender via P2P stream (for <6 member servers).
  Future<void> _requestFileFromPeer(FileAttachment attachment, String senderId) async {
    if (senderId.isEmpty) {
      if (mounted) {
        HollowToast.show(context, 'Cannot download: unknown sender', type: HollowToastType.error);
      }
      return;
    }
    try {
      if (mounted) {
        HollowToast.show(context, 'Requesting file from peer...', type: HollowToastType.info);
      }
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

  /// Phase 6.75 video preview: download the underlying vault video for a
  /// thumbnail message, then open Save As dialog with the original video's
  /// filename. The link lives in [attachment.videoThumb] — we use `cid` to
  /// fetch from the vault and `name`/`ext` for the save dialog defaults.
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

  /// Reconstruct vault content into the local cache and return its path —
  /// immediate on cache hit, else polls the async shard reconstruction
  /// (VaultDownloadComplete lands in fileTransferProvider keyed by contentId)
  /// for up to 60 seconds. Null = timed out (toasted here) or unmounted.
  Future<String?> _vaultFetchToCache(String contentId) async {
    // Trigger vault download (shard reconstruction).
    final cachedPath = await crdt_api.vaultDownloadFile(
      serverId: widget.serverId,
      contentId: contentId,
    );
    if (cachedPath.isNotEmpty) return cachedPath;

    // Async reconstruction in flight — poll for completion.
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
      HollowToast.show(context, 'Download timed out — not enough peers online',
          type: HollowToastType.error);
    }
    return null;
  }

  /// Open Save As dialog with the supplied default filename + extension,
  /// then copy from [cachePath] to the user-chosen destination. Used by the
  /// vault video save flow where the thumbnail's filename/ext don't match
  /// the underlying video's filename/ext.
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

  /// Download a vault file (reconstruct from shards), then open Save As dialog.
  Future<void> _vaultDownloadAndSave(FileAttachment attachment) async {
    if (_isPicking) return;
    try {
      // Look up vault content_id for this file.
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

  /// Open Save As for [attachment], copying (or format-converting) from
  /// [sourcePath] — the attachment's own disk path or a vault cache path.
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

  /// Open the unified emoji/emote picker anchored to the composer button and
  /// insert the selection (Unicode emoji or emote token) at the cursor.
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

  /// Open the GIF picker anchored to the composer button; the picked GIF
  /// arrives as an `[a:g:hash:w:h]` token and stages like an emote.
  void _openComposerGifPicker(BuildContext btnCtx) {
    final box = btnCtx.findRenderObject() as RenderBox?;
    final anchor = box == null
        ? Offset.zero
        : overlayAnchorOf(btnCtx, localOffset: Offset(box.size.width, 0));
    showGifPicker(
      context: context,
      anchorPosition: anchor,
      onSelect: _insertEmojiAtCursor,
    );
  }

  void _insertEmojiAtCursor(String text) {
    // Custom-emote/asset tokens become a 1-char placeholder rendered inline
    // as the actual image; Unicode emoji pass through unchanged.
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
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // Per-channel select: a message in ANY other channel/server used to
    // rebuild this whole pane (the map is replaced wholesale per insert).
    final allMessages =
        ref.watch(channelChatProvider.select((m) => m[_stateKey])) ?? [];
    // While the user reads history the display is frozen — arrivals are held
    // back (see the reversed-list scroll model above).
    // Rebuild when the block list (or device→master links) change so
    // _displayMessages' blocked-sender filter re-runs.
    ref.watch(blockedUsersProvider);
    ref.watch(deviceLinkProvider);
    final messages = _displayMessages(allMessages);

    _registerBuildListeners();

    // If cache was cleared by sync (clearServerCache) and we have no messages,
    // reload from DB. This catches the case where sync completed while we
    // weren't viewing, cache was cleared, and now we need fresh data.
    if (allMessages.isEmpty && _historyLoaded && !_loadingHistory) {
      _historyLoaded = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadHistory();
      });
    }

    final typingPeers =
        ref.watch(typingProvider.select((t) => t[_stateKey])) ?? {};

    // Custom-emote pull source for every token/reaction in this channel:
    // ask one online member of the server room.
    return EmoteScope(
      serverId: widget.serverId,
      child: ChatDropZone(
        onFileDropped: _handleDroppedFile,
        child: Column(
          children: [
            _buildHeader(hollow),

            if (ref.watch(channelSearchOpenProvider)) _buildSearchBar(hollow),

            _buildMessageArea(hollow, messages, allMessages),

            if (typingPeers.isNotEmpty) _buildTypingBar(typingPeers),

            if (_replyToMessageId != null) _buildReplyPreviewBar(),
            if (_stagedFilePath != null) _buildStagedFilePreview(),
            // Staged link card (hollow invite or OG preview)
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
    ); // EmoteScope
  }

  /// All build-time ref.listen registrations. Must be invoked from build()
  /// every frame — Riverpod re-registers listeners per build and silently
  /// no-ops registrations made anywhere else (e.g. initState).
  void _registerBuildListeners() {
    // Slow mode: the cooldown is derived from my newest message in this list
    // (history load, my optimistic send, sibling-device sends all count).
    ref.listen<List<ChannelChatMessage>?>(
        channelChatProvider.select((m) => m[_stateKey]),
        (_, _) => _recomputeSlowMode());
    // New-message handling under the reversed list: following (at bottom) →
    // instant re-pin to the newest row; reading history → freeze the display
    // (the unread pill takes over) so the view never shifts mid-read.
    ref.listen<Map<String, List<ChannelChatMessage>>>(
        channelChatProvider, _onMessageListGrowth);
    // Focus-return mark-seen: a message arriving while the window is
    // unfocused counts as unread (the isViewingChannel gate requires focus),
    // and if this channel was ALREADY open at the bottom nothing else clears
    // it — the scroll handler only marks seen on a bottom re-ENTRY. See the
    // matching listener in chat_pane.dart.
    ref.listen<bool>(windowFocusedProvider, _onWindowFocusChanged);
    // Focus search field when opened via global shortcut (Ctrl+K).
    ref.listen<bool>(channelSearchOpenProvider, _onSearchOpenChanged);
  }

  void _onMessageListGrowth(Map<String, List<ChannelChatMessage>>? prev,
      Map<String, List<ChannelChatMessage>> next) {
    final prevLen = (prev?[_stateKey] ?? const []).length;
    final nextLen = (next[_stateKey] ?? const []).length;
    if (nextLen <= prevLen) return;
    if (_frozenLen != null) return; // already frozen — held back + pill
    if (!_isNearBottom) {
      // Scroll-away raced the freeze transition — freeze at the pre-growth
      // length so this arrival is held back too.
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
      // Closing — clear search state.
      _searchController.clear();
      setState(() => _searchResults = []);
    }
  }

  /// Channel header: name, badges, connection status, and pane actions.
  ///
  /// Opening the member panel in a narrow window (or at a high interface
  /// scale) can leave this header only a couple hundred pixels. It sheds its
  /// non-controls first — the status pill, then the split toggle — because the
  /// buttons are the only way back out: losing the members toggle behind an
  /// overflow would strand the panel open.
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
                  "Meeting chat isn't stored — it disappears when the meeting ends",
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
          // Members + split view are server concepts — a conference has
          // neither (participants show in the call area).
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
          // Split view toggle (dock mode only)
          if (showSplit &&
              !_isConference &&
              (ref.watch(layoutModeProvider).valueOrNull ?? LayoutMode.dock) ==
                  LayoutMode.dock) ...[
            const SizedBox(width: HollowSpacing.sm),
            _buildSplitToggleButton(hollow),
          ],
        ],
        );
      }),
    );
  }

  /// Pin-count button — hidden while nothing is pinned in this channel.
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
          final current = ref.read(channelSearchOpenProvider);
          ref.read(channelSearchOpenProvider.notifier).state = !current;
          if (!current) {
            // Opening — focus the search field after build.
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
          color: ref.watch(channelSearchOpenProvider)
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
    // Collapse device→master so search results show the person's
    // name (not a raw device id). Single-device → no-op.
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

  /// Close search and scroll the list to the tapped result — index against
  /// the DISPLAY (possibly frozen) list, which _scrollToMessage also uses.
  void _jumpToSearchResult(dynamic msg) {
    final messages =
        _displayMessages(ref.read(channelChatProvider)[_stateKey] ?? []);
    final idx = messages.indexWhere((m) => m.messageId == msg.messageId);
    ref.read(channelSearchOpenProvider.notifier).state = false;
    setState(() {
      _searchController.clear();
      _searchResults = [];
    });
    if (idx != -1) _scrollToMessage(idx);
  }

  /// Message list area: permission gate, empty state, the reversed list, and
  /// the unread-pill overlay.
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

  /// The reversed message list (see the scroll-model comment above
  /// [_frozenLen]) plus the per-build row precomputes.
  Widget _buildMessageList(
      HollowTheme hollow, List<ChannelChatMessage> messages) {
    // Precomputed once per build instead of per ROW per rebuild:
    // reply-target index (was an O(n) indexWhere scan per reply row) and the
    // local mention needles (was a profile+nickname provider read per row).
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
    return reversedChatList(
      context: context,
      listKey: ValueKey('ch-list-${widget.serverId}-${widget.channelId}'),
      itemScrollController: _itemScrollController,
      itemPositionsListener: _itemPositionsListener,
      scrollOffsetController: _scrollOffsetController,
      itemCount: messages.length,
      indexByMessageId: replyIndexById,
      itemBuilder: (context, revIndex) => _buildMessageRow(
        context,
        revIndex,
        messages,
        replyIndexById,
        localMentionName,
        localMentionNick,
      ),
    );
  }

  /// One chat row: grouping-header decision, hover-action wrapper, bubble,
  /// and date separator — [revIndex] is the reversed builder index.
  Widget _buildMessageRow(
    BuildContext context,
    int revIndex,
    List<ChannelChatMessage> messages,
    Map<String, int> replyIndexById,
    String localMentionName,
    String? localMentionNick,
  ) {
    // Map the reversed builder index back to chronological
    // order — all row logic below stays chronological.
    final index = messages.length - 1 - revIndex;
    final msg = messages[index];
    // Grouping: compare with the previous message in chronological
    // order. Multi-device: collapse each sender to its MASTER so a
    // person's messages from different devices (e.g. our own master
    // + sibling) group as ONE sender — otherwise a subdevice sees
    // two "Pixel" blocks for the same identity. `isMe` is folded
    // into the same-master test (own master == own sibling = us).
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
      onDownload: _downloadFor(context, msg),
      onCopy: _copyFor(context, msg),
      onCopyImage: _copyImageFor(context, msg),
      onInfo: _infoFor(context, msg),
      child: _buildBubble(msg, index, showHeader, messages, replyIndexById,
          localMentionName, localMentionNick),
    );
    return dateSeparatedChatRow(
      rowKey: msg.messageId ?? index,
      timestamp: msg.timestamp,
      prevTimestamp: index > 0 ? messages[index - 1].timestamp : null,
      showHeader: showHeader,
      child: wrapper,
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
        // Collapse device→master so the reply-preview header
        // shows the original sender's name, not a device id.
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
    // Check if this message mentions the local user
    // (needles precomputed once per build above).
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
    );
  }

  // ── Row action callbacks ──────────────────────────────────────────────
  // Null hides the affordance for this message. Conference chat is RAM-only
  // MLS text: no CRDT-backed edit/delete/reply/pin and no Ed25519 proof.

  VoidCallback? _editStartFor(ChannelChatMessage msg, int revIndex) {
    final canEdit = !_isConference &&
        msg.messageId != null &&
        msg.isMe &&
        msg.fileAttachment == null;
    if (!canEdit) return null;
    return () {
      // Positions + jumpTo are in the REVERSED index space.
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
    }
  }

  VoidCallback? _replyFor(ChannelChatMessage msg) {
    if (_isConference || msg.messageId == null) return null;
    return () {
      // Collapse device→master so the reply banner shows
      // the person's name, not a raw device id.
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
      // Don't trigger duplicate downloads during active transfer.
      final transfer = ref.read(fileTransferProvider)[attachment.fileId];
      if (transfer != null && transfer.isDownloading) {
        HollowToast.show(context, 'File is already downloading...',
            type: HollowToastType.info);
        return;
      }

      // Phase 6.75 video preview: if this is a vault video
      // thumbnail, save the underlying VIDEO (not the thumbnail
      // .webp). The link lives in `videoThumb.cid` — fetch from
      // the vault and save with the original video filename.
      if (attachment.videoThumb != null) {
        _vaultDownloadAndSaveVideo(attachment);
      } else if (attachment.diskPath != null) {
        _saveFile(attachment);
      } else {
        // For <6 member servers (full replication), request file from
        // the sender via P2P stream. For 6+ members, use vault download.
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
      // itemBuilder shadows the State's context — list items
      // dispose when scrolled away, so check THIS element.
      if (context.mounted) {
        HollowToast.show(
          context,
          ok ? 'Image copied to clipboard' : 'Failed to copy image',
          type: ok ? HollowToastType.success : HollowToastType.error,
        );
      }
    };
  }

  // MLS authenticates conference lines per message — the
  // Ed25519 proof dialog would just read "UNSIGNED".
  VoidCallback? _infoFor(BuildContext context, ChannelChatMessage msg) {
    if (_isConference) return null;
    return () {
      final localPeerId = ref.read(identityProvider).peerId ?? '';
      // The signature is computed over the sender's MASTER id
      // (the send side signs with the master), so the proof must
      // verify against the master — resolve device→master here or
      // a multi-device sender's signature reads as invalid.
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
          // If the message has been edited, the signature
          // was computed over the edit timestamp + new text
          // — use editedAt to reconstruct the canonical
          // payload.
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

  /// Unread pill — only when new messages arrived while scrolled up.
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
            // The display list may be frozen — mark seen against
            // the TRUE newest message.
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

  /// Typing indicator. Multi-device: typing peers are DEVICE ids; collapse
  /// each to its master so the profile/nickname lookup (master-keyed) hits
  /// and two devices of one person show as a single name. Also EXCLUDE our
  /// OWN identity — a sibling device (e.g. the master) typing must not show
  /// "you are typing" to its other device (the "Pixel sees Pixel typing" leak)
  /// — see [typingMastersFor] for the robust self-filter rationale.
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

  /// Input bar — a blocked banner when posting isn't allowed (no permission
  /// or muted), else the voice recorder or the composer row.
  Widget _buildInputBar(HollowTheme hollow) {
    final mute = ref.watch(myMuteStatusProvider(widget.serverId)).valueOrNull;
    final canPost = ref.watch(canPostInChannelProvider(
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
        // Conference chat ('conf:' virtual servers) is RAM-only
        // text — no file/voice sends (they'd ride the persisting
        // channel pipeline). Buttons hidden, not disabled.
        if (!_isConference) ...[
          // File attachment button
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
    // Voice notes are audio, not media — blocked in
    // media-only channels (toast, don't record).
    if (_channelMediaOnly) {
      HollowToast.show(
        context,
        'This is a media-only channel — voice messages can\'t be posted here',
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
    );
  }

  /// Arrow/enter/tab/escape navigation while the @mention overlay is open.
  /// Null = not a mention-overlay key — fall through to the next handler.
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

/// Unified connection + encryption + sync status for channel headers.
/// Shows: progress bar (Connecting → Encrypting) → lock + "Encrypted" + sync status.
class _ChannelConnectionStatus extends ConsumerWidget {
  final String serverId;
  final String channelId;

  const _ChannelConnectionStatus({
    required this.serverId,
    required this.channelId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Presence is device-keyed (peersProvider), but server members are
    // master-keyed (ServerState.members). Use the master-collapsing
    // onlineIdentitiesProvider so a multi-device member counts as online via
    // any of their devices — otherwise the header is stuck on "Offline".
    final online = ref.watch(onlineIdentitiesProvider);
    final membersAsync = ref.watch(serverMembersProvider(serverId));
    final localPeerId = ref.watch(identityProvider).peerId;
    // "Offline" is about US, not about the room being empty (issue #23): while
    // the relay link is up this header must never claim we're offline just
    // because we're the only one here.
    final amOnline = ref.watch(overallConnectionProvider).isOnline;
    final isCustomRelay =
        ref.watch(relayDomainProvider) != kDefaultRelayDomain;

    ConnectionStage stageFor(bool anyOnline) {
      if (!amOnline) return ConnectionStage.offline;
      // With MLS, online members in a WS room are already encrypted (MLS group
      // broadcast).
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
      // Members not loaded yet — report our own link, which we already know.
      loading: () => ConnectionProgress(
        key: ValueKey('conn-$serverId'),
        stage: stageFor(false),
      ),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

/// Sync status indicator (Syncing, Synced, Failed, Retrying).
/// Shown after encryption is established.
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

    // Only show sync-related statuses (not idle/connecting).
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

/// A small continuously spinning refresh icon for sync indication.
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

/// Vault health indicator — green/yellow/red dot showing vault distribution status.
class _VaultHealthIndicator extends ConsumerWidget {
  final String serverId;
  const _VaultHealthIndicator({required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    // Only relevant for 6+ member servers (erasure coding).
    final memberCount = ref.watch(serverMembersProvider(serverId))
        .valueOrNull?.length ?? 0;
    if (memberCount < 6) return const SizedBox.shrink();

    final status = ref.watch(
      vaultStatusProvider.select((s) => s[serverId]),
    );

    // Only show when there are active transfers (uploads or downloads).
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

