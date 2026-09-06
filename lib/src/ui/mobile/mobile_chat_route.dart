import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/core/services/channel_topic_service.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/moderation_format.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/event_provider.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/saved_messages_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/typing_provider.dart';
import 'package:hollow/src/core/providers/unread_marker_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/core/providers/link_preview_settings_provider.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/chat/message_bubble.dart';
import 'package:hollow/src/ui/chat/channel_message_bubble.dart';
import 'package:hollow/src/ui/chat/emoji_picker.dart';
import 'package:hollow/src/ui/chat/file_card_status.dart';
import 'package:hollow/src/ui/chat/gif_picker.dart';
import 'package:hollow/src/ui/chat/sticker_picker.dart';
import 'package:hollow/src/ui/chat/emote_composer.dart';
import 'package:hollow/src/ui/chat/emote_image.dart';
import 'package:hollow/src/core/providers/emote_provider.dart';
import 'package:hollow/src/ui/components/connection_progress.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/long_press_message.dart';
import 'package:hollow/src/ui/components/saved_messages_avatar.dart';
import 'package:hollow/src/ui/chat/voice_recorder_bar.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/large_file_share_dialog.dart';
import 'package:hollow/src/ui/components/security_alert_banner.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/components/ui_scale.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_active_call_pill.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/mobile_call_video_view.dart';
import 'package:hollow/src/ui/mobile/mobile_member_panel.dart';
import 'package:hollow/src/ui/mobile/mobile_notification_banner.dart';
import 'package:hollow/src/ui/mobile/mobile_voice_channel_pill.dart';
import 'package:hollow/src/ui/mobile/mobile_message_actions.dart';
import 'package:hollow/src/ui/mobile/mobile_profile_sheet.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/pinned_provider.dart';
import 'package:hollow/src/core/providers/system_notification_provider.dart';
import 'package:hollow/src/core/services/push_notification_service.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/ui/mobile/mobile_voice_channel_route.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';
import 'package:hollow/src/core/services/voice_message_recorder.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// Wire prefix marking a message whose text is a file token (no copyable text).
const String _kFilePrefix = '[file:';

/// Display name given to recorded voice notes.
const String _kVoiceMessageName = 'Voice message.ogg';

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class MobileChatRoute extends ConsumerStatefulWidget {
  /// The RouteSettings name every push site tags its route with. A notification
  /// tap popUntils past any chat route already on the stack, so chats never
  /// stack on each other.
  static const String routeName = 'mobile-chat';

  final String? peerId;
  final String? serverId;
  final String? channelId;
  final String? channelName;

  const MobileChatRoute({
    super.key,
    this.peerId,
    this.serverId,
    this.channelId,
    this.channelName,
  });

  bool get isDm => peerId != null;

  @override
  ConsumerState<MobileChatRoute> createState() => _MobileChatRouteState();
}

class _MobileChatRouteState extends ConsumerState<MobileChatRoute> {
  final _controller = EmoteComposerController();
  final _focusNode = FocusNode();
  final _scrollController = ItemScrollController();
  final _positionsListener = ItemPositionsListener.create();

  String? _replyToMessageId;
  String? _replyToText;
  String? _replyToSenderName;
  String? _editingMessageId;
  final _editController = TextEditingController();
  final _editFocusNode = FocusNode();
  DateTime? _lastTypingSent;
  /// Slow mode: earliest time the next send is allowed (null = no cooldown).
  DateTime? _slowModeReadyAt;
  Timer? _slowModeTimer;
  bool _isInAutoScrollZone = true;
  String? _stagedFilePath;
  String? _stagedFileName;
  bool _stagedFileIsImage = false;
  static final RegExp _urlRegex = RegExp(r'(?:https?|hollow)://[^\s<>"' "'" r')\]}]+');
  String? _stagedPreviewUrl;
  network_api.LinkPreviewRef? _stagedPreview;
  bool _stagedPreviewLoading = false;
  HollowLink? _stagedHollowLink;
  /// Sent-before-the-fetch-landed bookkeeping (issue #45).
  final LatePreviewAttacher _latePreview = LatePreviewAttacher();
  Timer? _urlDebounce;
  bool _isRecordingVoice = false;
  bool _searchOpen = false;

  // @mention autocomplete, server channels only.
  List<_MobileMentionCandidate> _mentionCandidates = [];
  int _mentionAtPosition = -1;

  // `:` shortcode autocomplete, in the same panel pattern as mentions.
  List<EmoteSuggestion> _emoteCandidates = [];
  int _emoteColonPos = -1;

  String get _channelKey => '${widget.serverId}:${widget.channelId}';
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  List<storage_api.StoredChannelMessage> _searchResults = [];
  int? _highlightIndex;

  /// True between deactivate() and activate() or unmount. A popped route's
  /// callbacks still fire during the pop frame, and `mounted` stays true on a
  /// deactivated element while `ref.read` there throws, so callbacks bail on
  /// this flag instead.
  bool _routeDeactivated = false;

  @override
  void deactivate() {
    _routeDeactivated = true;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _routeDeactivated = false;
  }

  @override
  void initState() {
    super.initState();
    _positionsListener.itemPositions.addListener(_checkAutoScroll);
    if (widget.isDm) {
      _initDmOpen();
    } else {
      _initChannelOpen();
    }
  }

  void _initDmOpen() {
    // Clear the stacked push lines so the next message starts a fresh stack.
    clearNotificationLines(widget.peerId!);
    // Takes the group summary with it when this was the last one; a bare
    // cancel() would leave an empty "Hollow" group header.
    dismissPeerNotification(widget.peerId!);
    // A lingering in-app card would replay in the next chat opened. Post-frame,
    // because dismissing it writes provider state and this route is pushed
    // during a tap-handler frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(systemNotificationProvider.notifier).dismissDm(widget.peerId!);
    });
    ref.read(chatProvider.notifier).loadHistory(widget.peerId!).then((_) {
      if (mounted) {
        setState(() {});
        _jumpToBottom();
        _markSeen();
      }
    });
    // Re-request files whose bytes never arrived, from the friend or an online
    // sibling.
    ref.read(eventStreamProvider.notifier)
        .requestMissingDmFilesOnOpen(widget.peerId!);
  }

  void _initChannelOpen() {
    // Clear the accumulated push lines and the OS banner, group summary
    // included when this was the last one.
    dismissChannelNotification(widget.serverId!, widget.channelId!);
    // Post-frame, because dismissing the in-app card writes provider state.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(systemNotificationProvider.notifier)
          .dismissChannel(widget.serverId!, widget.channelId!);
    });
    // The Chats tab often has NO selected server, so `channelListProvider` can
    // be stale and a re-opened chat would read an old posting or visibility
    // value. Desktop never hits this: its shell keeps these providers live.
    // `ref.invalidate` touches the ProviderScope inherited widget, which is not
    // available until AFTER initState, so it is deferred one frame.
    ref.read(channelListProvider.notifier).loadForServer(widget.serverId!);
    ref.read(channelLayoutProvider.notifier).loadForServer(widget.serverId!);
    // On EVERY open, at route level, so no entry point is missed: without a
    // subscription the channel receives no live topic broadcast and messages
    // appear only on the next sync. The helper is node-safe, because a
    // cold-start push tap opens this route before start_node() completes.
    subscribeChannelTopics(
        serverId: widget.serverId!, channelIds: [widget.channelId!]);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.invalidate(myRoleProvider(widget.serverId!));
      ref.invalidate(myPermissionsProvider(widget.serverId!));
    });
    ref.read(channelChatProvider.notifier).loadHistory(
          widget.serverId!,
          widget.channelId!,
        ).then((_) {
      if (mounted) {
        ref
            .read(pinnedProvider.notifier)
            .loadPins(widget.serverId!, widget.channelId!);
        setState(() {});
        _jumpToBottom();
        _markSeen();
        // The route remounts per open, so the pill state is gone while the
        // history the cooldown derives from is not.
        _recomputeSlowMode();
      }
    });
  }

  @override
  void dispose() {
    _urlDebounce?.cancel();
    _latePreview.disarm();
    _slowModeTimer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    _editController.dispose();
    _editFocusNode.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _checkAutoScroll() {
    // The positions notifier stays attached until dispose and can fire during
    // the pop frame, where the ref.reads below would crash.
    if (!mounted || _routeDeactivated) return;
    // Reversed list: "at bottom" is "index 0 visible", which no burst of
    // arrivals can change.
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    final minIndex =
        positions.map((p) => p.index).reduce((a, b) => a < b ? a : b);
    final wasInZone = _isInAutoScrollZone;
    _isInAutoScrollZone = minIndex <= 0;
    if (wasInZone != _isInAutoScrollZone) {
      setState(() {});
      if (_isInAutoScrollZone) {
        // Reached the bottom: release the freeze, and snap to the true newest
        // row if anything was held back.
        final count = _conversationLength();
        if (_frozenLen != null && count > _frozenLen!) {
          _jumpToBottom();
        } else {
          _frozenLen = null;
        }
        _markSeen();
      } else {
        // Left the bottom: freeze the display so arrivals cannot shift the
        // reading position.
        _frozenLen ??= _conversationLength();
      }
    }
  }

  /// Non-null while the user is scrolled up: display list capped here.
  int? _frozenLen;

  /// The messages currently displayed (frozen prefix while scrolled up).
  List<T> _displayMessages<T>(List<T> messages) {
    final frozen = _frozenLen;
    if (frozen == null || messages.length <= frozen) return messages;
    return messages.sublist(0, frozen);
  }

  int _conversationLength() => widget.isDm
      ? (ref.read(chatProvider)[widget.peerId!]?.length ?? 0)
      : (ref.read(channelChatProvider)[_channelKey]?.length ?? 0);

  void _markSeen() {
    if (widget.isDm) {
      final msgs = ref.read(chatProvider)[widget.peerId!];
      final latestId = msgs != null && msgs.isNotEmpty ? msgs.last.messageId : null;
      ref.read(unreadProvider.notifier).markDmSeen(widget.peerId!, latestId);
    } else {
      final msgs = ref.read(channelChatProvider)[_channelKey];
      final latestId = msgs != null && msgs.isNotEmpty ? msgs.last.messageId : null;
      ref.read(unreadProvider.notifier).markChannelSeen(
          widget.serverId!, widget.channelId!, latestId);
    }
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return _hhmm(dt);
    }
    return '${dt.month}/${dt.day}';
  }

  void _jumpToBottom() {
    if (_frozenLen != null) setState(() => _frozenLen = null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.isAttached) return;
      _scrollController.jumpTo(index: 0, alignment: 0.0);
    });
  }

  /// [index] is CHRONOLOGICAL (0 = oldest); the conversion to the reversed
  /// builder index happens here, in one place.
  void _scrollToMessage(int index) {
    if (!_scrollController.isAttached) return;
    final count = _displayLength();
    if (index < 0 || index >= count) return;
    setState(() => _highlightIndex = index);
    _scrollController.scrollTo(
      index: count - 1 - index,
      duration: ReduceMotionController.instance.isReduced
          ? Duration.zero
          : const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: 0.6,
    );
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightIndex = null);
    });
  }

  int _displayLength() {
    final frozen = _frozenLen;
    final len = _conversationLength();
    return frozen != null && frozen < len ? frozen : len;
  }

  Future<void> _onSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    try {
      final results = await storage_api.searchChannelMessages(
        serverId: widget.serverId!,
        channelId: widget.channelId!,
        query: query.trim(),
        limit: 20,
      );
      if (mounted) setState(() => _searchResults = results);
    } catch (_) {}
  }

  /// Bottom snap, INSTANT: an animated scroll renders the new row and then
  /// glides to it, which reads as a jump followed by a move.
  void _scrollToBottom() {
    _jumpToBottom();
    _markSeen();
  }

  void _startEditing(String messageId) {
    setState(() => _editingMessageId = messageId);
    // After the keyboard has animated in, or the editor sits behind it.
    Future.delayed(const Duration(milliseconds: 300), () {
      if (!mounted || !_scrollController.isAttached) return;
      int index = -1;
      if (widget.isDm) {
        final msgs = _displayMessages(
            ref.read(chatProvider)[widget.peerId!] ?? const <ChatMessage>[]);
        index = msgs.indexWhere((m) => m.messageId == messageId);
      } else {
        final msgs = _displayMessages(
            ref.read(channelChatProvider)[_channelKey] ??
                const <ChannelChatMessage>[]);
        index = msgs.indexWhere((m) => m.messageId == messageId);
      }
      if (index >= 0) {
        _scrollController.scrollTo(
          // Chronological to reversed builder index; alignment measures from
          // the BOTTOM edge under reverse:true.
          index: _displayLength() - 1 - index,
          alignment: 0.7,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _onTextChanged(String text) {
    _urlDebounce?.cancel();
    _urlDebounce = Timer(const Duration(milliseconds: 600), _detectUrl);

    // Channels only: a DM has a single recipient.
    if (!widget.isDm) _updateMentionAutocomplete(text);
    _updateEmoteAutocomplete(text);

    if (text.isEmpty) return;
    final now = DateTime.now();
    if (_lastTypingSent != null && now.difference(_lastTypingSent!).inSeconds < 3) return;
    _lastTypingSent = now;
    if (widget.isDm) {
      network_api
          .sendTypingIndicator(serverId: '', channelId: widget.peerId!)
          .catchError((_) {});
    } else {
      // The same path the desktop pane uses, so a phone shows as typing in a
      // server channel too.
      network_api.sendTypingIndicator(
        serverId: widget.serverId!,
        channelId: widget.channelId!,
      ).catchError((_) {});
    }
  }

  /// Rebuilds the mention panel from the token the cursor sits in: server
  /// members plus @everyone, matching the desktop pane.
  void _updateMentionAutocomplete(String text) {
    final cursor = _controller.selection.baseOffset;
    if (cursor < 0 || widget.serverId == null) {
      _dismissMention();
      return;
    }
    final atPos = _mentionAtPosFor(text, cursor);
    if (atPos < 0) {
      _dismissMention();
      return;
    }

    final query = text.substring(atPos + 1, cursor).toLowerCase();
    setState(() {
      _mentionAtPosition = atPos;
      _mentionCandidates = _mentionCandidatesFor(query).take(6).toList();
    });
  }

  /// Position of the '@' opening the mention token the cursor sits in, or -1.
  /// The '@' must start the text or follow whitespace, and the token itself may
  /// not contain any.
  int _mentionAtPosFor(String text, int cursor) {
    for (int i = cursor - 1; i >= 0; i--) {
      final c = text[i];
      if (c == '@') {
        final boundary = i == 0 || text[i - 1] == ' ' || text[i - 1] == '\n';
        return boundary ? i : -1;
      }
      if (c == ' ' || c == '\n') return -1;
    }
    return -1;
  }

  List<_MobileMentionCandidate> _mentionCandidatesFor(String query) {
    final membersAsync = ref.read(serverMembersProvider(widget.serverId!));
    final profiles = ref.read(profileProvider);
    final nicknames = ref.read(serverNicknamesProvider(widget.serverId!));
    final candidates = <_MobileMentionCandidate>[];

    membersAsync.whenData((members) {
      for (final m in members) {
        final displayName = serverDisplayNameFor(
          profiles, m.peerId, nickname: nicknames[m.peerId] ?? '',
        );
        final serverNick = nicknames[m.peerId] ?? '';
        final profileName = profiles[m.peerId]?.displayName ?? '';
        final matches = query.isEmpty ||
            displayName.toLowerCase().startsWith(query) ||
            (serverNick.isNotEmpty &&
                serverNick.toLowerCase().startsWith(query)) ||
            (profileName.isNotEmpty &&
                profileName.toLowerCase().startsWith(query));
        if (matches) {
          candidates.add(_MobileMentionCandidate(
            peerId: m.peerId,
            displayName: displayName,
          ));
        }
      }
    });

    if (query.isEmpty || 'everyone'.startsWith(query)) {
      candidates.insert(0,
          const _MobileMentionCandidate(peerId: '', displayName: 'everyone'));
    }
    return candidates;
  }

  void _dismissMention() {
    if (_mentionCandidates.isEmpty && _mentionAtPosition < 0) return;
    setState(() {
      _mentionCandidates = [];
      _mentionAtPosition = -1;
    });
  }

  void _acceptMention(_MobileMentionCandidate candidate) {
    final text = _controller.text;
    final cursor = _controller.selection.baseOffset;
    if (_mentionAtPosition < 0 || cursor < _mentionAtPosition) {
      _dismissMention();
      return;
    }
    final replacement = '@${candidate.displayName} ';
    final newText = text.replaceRange(_mentionAtPosition, cursor, replacement);
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        offset: _mentionAtPosition + replacement.length,
      ),
    );
    _dismissMention();
  }

  /// Compact mention-candidate panel rendered just above the input bar.
  Widget _buildMentionPanel(HollowTheme hollow) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      margin: const EdgeInsets.fromLTRB(
          HollowSpacing.sm, 0, HollowSpacing.sm, HollowSpacing.xs),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, -2),
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
            return HollowPressable(
              onTap: () => _acceptMention(c),
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm,
                vertical: HollowSpacing.xs + 2,
              ),
              child: Row(
                children: [
                  if (c.peerId.isNotEmpty)
                    HollowAvatar(peerId: c.peerId, size: 26)
                  else
                    Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: hollow.accent.withValues(alpha: 0.2),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(LucideIcons.atSign,
                          size: 15, color: hollow.accent),
                    ),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Text(
                      c.displayName,
                      style: HollowTypography.bodySmall.copyWith(
                        color: hollow.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  List<ComposerEmote> _composerEmotes() => [
        if (widget.serverId != null)
          for (final e in ref
                  .read(serverEmotesProvider(widget.serverId!))
                  .valueOrNull ??
              const [])
            ComposerEmote(e.name, e.hash),
        for (final e in ref.read(personalEmotesProvider).valueOrNull ?? const [])
          ComposerEmote(e.name, e.hash),
      ];

  void _updateEmoteAutocomplete(String text) {
    final scan = scanEmoteShortcode(
      text: text,
      cursor: _controller.selection.baseOffset,
      emotes: _composerEmotes(),
    );
    if (scan == null) {
      _dismissEmotePanel();
      return;
    }
    setState(() {
      _emoteColonPos = scan.colonPos;
      _emoteCandidates = scan.suggestions;
    });
  }

  void _dismissEmotePanel() {
    if (_emoteCandidates.isEmpty && _emoteColonPos < 0) return;
    setState(() {
      _emoteCandidates = [];
      _emoteColonPos = -1;
    });
  }

  void _acceptEmote(EmoteSuggestion suggestion) {
    acceptEmoteSuggestion(
      controller: _controller,
      colonPos: _emoteColonPos,
      suggestion: suggestion,
    );
    _dismissEmotePanel();
  }

  /// Compact emote-candidate panel above the input bar.
  Widget _buildEmotePanel(HollowTheme hollow) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      margin: const EdgeInsets.fromLTRB(
          HollowSpacing.sm, 0, HollowSpacing.sm, HollowSpacing.xs),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: _emoteCandidates.length,
          itemBuilder: (ctx, i) {
            final c = _emoteCandidates[i];
            return HollowPressable(
              onTap: () => _acceptEmote(c),
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm,
                vertical: HollowSpacing.xs + 2,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 26,
                    height: 26,
                    child: Center(
                      child: c.hash != null
                          ? EmoteImage(name: c.name, hash: c.hash!, size: 24)
                          : Text(c.char!,
                              style: const TextStyle(fontSize: 20)),
                    ),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Text(
                      c.hash != null ? ':${c.name}:' : c.name,
                      style: HollowTypography.bodySmall.copyWith(
                        color: hollow.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// The channel's slow-mode interval, or 0 in a DM, when it is off, or for a
  /// Moderator and above.
  int get _effectiveSlowModeSecs {
    if (widget.isDm) return 0;
    final slow = ref
            .read(channelListProvider)[widget.channelId!]?.slowModeSecs ?? 0;
    if (slow == 0) return 0;
    final role =
        ref.read(myRoleProvider(widget.serverId!)).valueOrNull ?? 'member';
    const exempt = {'owner', 'admin', 'moderator'};
    return exempt.contains(role) ? 0 : slow;
  }

  bool get _channelMediaOnly => !widget.isDm &&
      (ref.read(channelListProvider)[widget.channelId!]?.mediaOnly ?? false);

  /// The slow-mode cooldown DERIVED from the loaded list, never widget state,
  /// so it survives a route re-open and always matches the Rust gate.
  DateTime? _derivedSlowModeReadyAt() {
    if (widget.isDm) return null;
    final msgs = ref.read(channelChatProvider)[_channelKey] ?? const [];
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
    _dismissEmotePanel();
    // Expand inline-emote placeholders to [e:name:hash] wire tokens.
    final text = _controller.expandedText().trim();
    final filePath = _stagedFilePath;
    final fileName = _stagedFileName;
    final fileIsImage = _stagedFileIsImage;
    final preview = _stagedPreview;
    // The card has to land after the send when the fetch is still running or
    // never started (issue #45); a file send has no preview slot on the wire.
    final wasLoading = _stagedPreviewLoading;
    final pendingUrl = filePath != null
        ? null
        : pendingPreviewUrl(
            previewsEnabled: ref.read(linkPreviewsEnabledProvider),
            alreadyStaged: preview != null,
            stagedLoading: wasLoading,
            stagedUrl: _stagedPreviewUrl,
            text: text,
            urlRegex: _urlRegex,
          );

    if (text.isEmpty && filePath == null) return;
    if (_blockedBySlowMode()) return;
    if (!_passesMediaOnlyGate(filePath, fileName)) return;
    if (exceedsAssetLimit(text)) {
      HollowToast.show(context, kAssetLimitMessage,
          type: HollowToastType.error);
      return;
    }
    _controller.clear();
    _lastTypingSent = null;
    if (refocus) _focusNode.requestFocus();
    final replyMid = _replyToMessageId;
    _urlDebounce?.cancel();
    _clearComposerState();

    if (filePath != null) {
      final name = fileName ?? filePath.replaceAll('\\', '/').split('/').last;
      await _sendFileMessage(
        filePath: filePath,
        fileName: name,
        sizeBytes: File(filePath).lengthSync(),
        isImage: fileIsImage,
        text: text,
        errorToast: 'Failed to send file',
      );
    } else {
      // The provider adds the bubble only AFTER the network send, so a failure
      // here would vanish silently: composer cleared, no bubble.
      try {
        final String sentMid;
        if (widget.isDm) {
          sentMid = await ref.read(chatProvider.notifier).sendMessage(
                widget.peerId!,
                text,
                replyToMid: replyMid,
                linkPreview: preview,
              );
        } else {
          sentMid = await ref.read(channelChatProvider.notifier).sendMessage(
                widget.serverId!,
                widget.channelId!,
                text,
                replyToMid: replyMid,
                linkPreview: preview,
              );
        }
        if (pendingUrl != null) {
          _latePreview.arm(pendingUrl, sentMid);
          // Nothing is in flight when the debounce never fired.
          if (!wasLoading) _fetchPreview(pendingUrl);
        }
      } catch (_) {
        if (!mounted || _routeDeactivated) return;
        HollowToast.show(context, 'Failed to send message',
            type: HollowToastType.error);
        return;
      }
    }
    // Instant, not animated: the sender is already at the bottom, and animating
    // races the auto-scroll and the input bar collapsing after clear(), which
    // is the iOS "jump for a second" after sending.
    _jumpToBottom();
    _markSeen();
  }

  /// Media-only channel gate: false, and toasts, unless the staged send is an
  /// accepted image, GIF or video.
  bool _passesMediaOnlyGate(String? filePath, String? fileName) {
    if (!_channelMediaOnly) return true;
    if (filePath == null) {
      HollowToast.show(
        context,
        'This is a media-only channel. Attach an image, GIF, or video',
        type: HollowToastType.info,
      );
      return false;
    }
    final stagedExt = (fileName ?? '').contains('.')
        ? fileName!.split('.').last.toLowerCase()
        : '';
    if (!kMediaOnlyExtensions.contains(stagedExt)) {
      HollowToast.show(
        context,
        'This is a media-only channel. Only images, GIFs, and videos can be posted',
        type: HollowToastType.info,
      );
      return false;
    }
    return true;
  }

  /// Reset reply/staged-file/staged-link/mention state after a send.
  void _clearComposerState() {
    setState(() {
      _replyToMessageId = null;
      _replyToText = null;
      _replyToSenderName = null;
      _stagedFilePath = null;
      _stagedFileName = null;
      _stagedFileIsImage = false;
      _stagedPreviewUrl = null;
      _stagedPreview = null;
      _stagedPreviewLoading = false;
      _stagedHollowLink = null;
      _mentionCandidates = [];
      _mentionAtPosition = -1;
    });
  }

  /// The optimistic insert and send pipeline shared by staged files and voice
  /// messages. The insert comes BEFORE the network send so the bubble renders
  /// from the local path; the sender's FileCompleted reload then replaces it,
  /// and dedup by message_id prevents a second bubble.
  Future<void> _sendFileMessage({
    required String filePath,
    required String fileName,
    required int sizeBytes,
    required bool isImage,
    required String text,
    required String errorToast,
  }) async {
    final messageId = generateMessageId();
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';
    if (widget.isDm) {
      ref.read(chatProvider.notifier).addFileMessage(
            widget.peerId!,
            messageId,
            fileName,
            sizeBytes,
            ext,
            isImage,
            filePath,
            text: text,
          );
    } else {
      ref.read(channelChatProvider.notifier).addFileMessage(
            widget.serverId!,
            widget.channelId!,
            messageId,
            fileName,
            sizeBytes,
            ext,
            isImage,
            filePath,
            text: text,
          );
    }
    _jumpToBottom();
    try {
      // The full pipeline rather than raw sendFile: transfer progress, video
      // thumbnail pre-extraction and >34 MB share-backed routing.
      final members = widget.isDm
          ? null
          : ref.read(serverMembersProvider(widget.serverId!)).valueOrNull;
      await ref.read(fileTransferProvider.notifier).sendFile(
            peerId: widget.isDm ? widget.peerId : null,
            serverId: widget.isDm ? null : widget.serverId,
            channelId: widget.isDm ? null : widget.channelId,
            filePath: filePath,
            messageId: messageId,
            messageText: text,
            memberCount: members?.length ?? 0,
            // The display name is the voice-recorder signal; the wire carries a
            // dedicated flag (auto-download gate exemption, issue #41).
            isVoice: fileName == _kVoiceMessageName,
          );
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, errorToast, type: HollowToastType.error);
      }
    }
  }

  Future<void> _pickFile({bool imagesOnly = false}) async {
    // Restrict the picker to what a media-only channel accepts.
    final FileType pickerType;
    if (imagesOnly) {
      pickerType = FileType.image;
    } else if (_channelMediaOnly) {
      pickerType = FileType.custom;
    } else {
      pickerType = FileType.any;
    }
    final result = await FilePicker.platform.pickFiles(
      type: pickerType,
      allowedExtensions: !imagesOnly && _channelMediaOnly
          ? kMediaOnlyExtensions.toList()
          : null,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.path == null) return;

    // Over 34 MB: confirm hosting it as a Hollow Share rather than rejecting or
    // converting silently.
    if (file.size > kLargeFileThresholdBytes) {
      final ok = mounted &&
          await confirmLargeFileShare(context,
              fileName: file.name, sizeBytes: file.size);
      if (!ok) return;
    }

    // STAGED rather than auto-sent, so a caption can be added and `_handleSend`
    // bundles the two. The re-focus waits for the OS to return window focus from
    // the file dialog, which a synchronous requestFocus would race.
    final ext = file.name.contains('.')
        ? file.name.split('.').last.toLowerCase()
        : '';
    setState(() {
      _stagedFilePath = file.path!;
      _stagedFileName = file.name;
      _stagedFileIsImage =
          ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'].contains(ext);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _showEmojiSheet() {
    // The software keyboard otherwise stays up under the sheet and covers half
    // the picker.
    _focusNode.unfocus();
    final hollow = HollowTheme.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: hollow.surface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(hollow.radiusLg)),
      ),
      builder: (_) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.55,
          child: EmojiPickerBody(
            serverId: widget.serverId,
            onSelect: (emoji) {
              Navigator.pop(context);
              // Emote tokens become 1-char placeholders rendered inline as the
              // image.
              _insertAtCursor(_controller.displayTextFor(emoji));
            },
          ),
        ),
      ),
    );
  }

  /// GIF picker as a bottom sheet; the pick arrives as an `[a:g:hash:w:h]`
  /// token and stages in the composer like an emote.
  void _showGifSheet() {
    _focusNode.unfocus();
    final hollow = HollowTheme.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: hollow.surface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(hollow.radiusLg)),
      ),
      builder: (_) => SafeArea(
        child: SizedBox(
          // Taller than the sticker sheet: the Popular row costs a line of
          // chrome and the grid still needs two full rows.
          height: MediaQuery.sizeOf(context).height * 0.62,
          child: GifPickerBody(
            // Sends and stays open, mirroring the sticker sheet (issue #36).
            onSelect: _sendAsset,
            // Null in a DM or a conference: the rating clamp only applies to
            // real servers.
            serverId: (widget.serverId?.startsWith('conf:') ?? true)
                ? null
                : widget.serverId,
          ),
        ),
      ),
    );
  }

  /// Inserts [text] at the composer's cursor, replacing any selection.
  void _insertAtCursor(String text, {bool refocus = true}) {
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

  /// Send-on-click (issue #36). Focus stays put: the sheet is open over the
  /// composer, and refocusing would raise the keyboard on top of it on every
  /// pick.
  Future<void> _sendAsset(String token) async {
    _insertAtCursor(_controller.displayTextFor(token), refocus: false);
    await _handleSend(refocus: false);
  }

  /// Sends an already-written file straight into this conversation with no save
  /// dialog, the "Share pack to this chat" path (issue #36).
  ///
  /// The file is NOT deleted afterwards: our own bubble keeps pointing at it,
  /// so it lives out its life in the temp directory the OS sweeps.
  Future<void> _shareFileToChat(String path, String fileName) async {
    if (!mounted) return;
    await _sendFileMessage(
      filePath: path,
      fileName: fileName,
      sizeBytes: File(path).lengthSync(),
      isImage: false,
      text: '',
      errorToast: 'Failed to share pack',
    );
  }

  /// Sticker picker as a bottom sheet. A pick SENDS immediately and the sheet
  /// stays OPEN, unlike the GIF sheet, so sending several is repeated taps.
  void _showStickerSheet() {
    _focusNode.unfocus();
    final hollow = HollowTheme.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: hollow.surface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(hollow.radiusLg)),
      ),
      builder: (_) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.62,
          child: StickerPickerBody(
            onSelect: _sendAsset,
            onSharePack: _shareFileToChat,
            // Null in a DM or a conference: the rating clamp and the Server tab
            // only apply to real servers.
            serverId: (widget.serverId?.startsWith('conf:') ?? true)
                ? null
                : widget.serverId,
          ),
        ),
      ),
    );
  }

  void _showAttachSheet() {
    final hollow = HollowTheme.of(context);
    Widget row({
      required IconData icon,
      required String label,
      required VoidCallback onTap,
    }) {
      return HollowPressable(
        onTap: () {
          Navigator.pop(context);
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.lg,
            vertical: HollowSpacing.md,
          ),
          child: Row(
            children: [
              Icon(icon, size: 22, color: hollow.accent),
              const SizedBox(width: HollowSpacing.md),
              Text(
                label,
                style: HollowTypography.body.copyWith(color: hollow.textPrimary),
              ),
            ],
          ),
        ),
      );
    }

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: hollow.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(hollow.radiusLg)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: HollowSpacing.sm),
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: hollow.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: HollowSpacing.sm),
            row(
              icon: LucideIcons.image,
              label: 'Photo',
              onTap: () => _pickFile(imagesOnly: true),
            ),
            row(
              icon: Icons.gif_box_outlined,
              label: 'GIF',
              onTap: _showGifSheet,
            ),
            row(
              icon: LucideIcons.sticker,
              label: 'Sticker',
              onTap: _showStickerSheet,
            ),
            row(
              icon: LucideIcons.paperclip,
              label: 'File',
              onTap: _pickFile,
            ),
            const SizedBox(height: HollowSpacing.sm),
          ],
        ),
      ),
    );
  }

  Future<void> _stageVoiceMessage(VoiceRecordingResult result) async {
    setState(() => _isRecordingVoice = false);
    final file = File(result.filePath);
    if (!await file.exists()) return;
    final size = await file.length();
    if (size > kLargeFileThresholdBytes) {
      final ok = mounted &&
          await confirmLargeFileShare(context,
              fileName: _kVoiceMessageName, sizeBytes: size);
      if (!ok) {
        try { await file.delete(); } catch (_) {}
        return;
      }
    }
    // Optimistic insert first, so the FileCompleted reload repoints diskPath to
    // the files/ copy before the temp file below is deleted.
    await _sendFileMessage(
      filePath: result.filePath,
      fileName: _kVoiceMessageName,
      sizeBytes: size,
      isImage: false,
      text: '',
      errorToast: 'Failed to send voice message',
    );
    try { await file.delete(); } catch (_) {}
  }

  void _setReply(String messageId, String senderName, String text) {
    setState(() {
      _replyToMessageId = messageId;
      _replyToSenderName = senderName;
      _replyToText = text;
    });
    _focusNode.requestFocus();
  }

  Future<void> _saveFile(FileAttachment attachment) async {
    if (attachment.diskPath == null) return;

    try {
      Uint8List bytes;
      String fileName = attachment.fileName;
      if (attachment.isImage && attachment.fileExt == 'webp') {
        bytes = await network_api.convertImageFormat(
          sourcePath: attachment.diskPath!,
          targetFormat: 'png',
        );
        final base = fileName.contains('.')
            ? fileName.substring(0, fileName.lastIndexOf('.'))
            : fileName;
        fileName = '$base.png';
      } else {
        bytes = await File(attachment.diskPath!).readAsBytes();
      }

      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save file',
        fileName: fileName,
        bytes: bytes,
      );
      if (savePath == null) return;

      if (mounted) {
        HollowToast.show(context, 'File saved', type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Save failed: $e', type: HollowToastType.error);
      }
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
        HollowToast.show(context, 'File request failed: $e', type: HollowToastType.error);
      }
    }
  }

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
    final future = widget.isDm
        ? ref
            .read(chatProvider.notifier)
            .attachLinkPreview(widget.peerId!, messageId, preview)
        : ref.read(channelChatProvider.notifier).attachLinkPreview(
            widget.serverId!, widget.channelId!, messageId, preview);
    future.catchError((Object e) {
      debugPrint('[HOLLOW] Late link preview attach failed: $e');
    });
  }

  /// Keeps the card honest after an edit (issue #45), like the desktop twin.
  Future<void> _resyncPreviewAfterEdit(String messageId, String newText) async {
    if (!ref.read(linkPreviewsEnabledProvider)) return;
    final String? oldUrl;
    if (widget.isDm) {
      final msgs = ref.read(chatProvider)[widget.peerId!] ?? const [];
      final idx = msgs.indexWhere((m) => m.messageId == messageId);
      oldUrl = idx == -1 ? null : msgs[idx].linkPreview?.url;
    } else {
      final key = '${widget.serverId}:${widget.channelId}';
      final msgs = ref.read(channelChatProvider)[key] ?? const [];
      final idx = msgs.indexWhere((m) => m.messageId == messageId);
      oldUrl = idx == -1 ? null : msgs[idx].linkPreview?.url;
    }
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
      if (!mounted || _routeDeactivated) return;
      _attachPreview(messageId, preview);
    } catch (_) {
      // Leave the existing card rather than blanking it on a transient failure.
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final bg = ref.watch(backgroundProvider);
    _registerBuildListeners();

    Widget scaffold = Scaffold(
      backgroundColor:
          bg.hasBackground ? Colors.transparent : hollow.background,
      // Custom-emote pull source for every token and reaction: a DM asks the
      // counterpart's devices, a channel asks a room member.
      body: EmoteScope(
        serverId: widget.serverId,
        peerHint: widget.peerId,
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              // Pinned above the message list so the warning survives
              // scrollback and restarts, and self-hiding when clear.
              if (widget.isDm) SecurityAlertBanner(peerId: widget.peerId!),
              if (widget.isDm) MobileCallStatusStrip(peerId: widget.peerId!),
              const _VoiceChannelStatusStrip(),
              if (_searchOpen) _buildSearchBar(hollow),
              if (!widget.isDm) _buildSyncIndicator(hollow),
              if (!widget.isDm && !_canReadChannel)
                _buildNoReadPermission(hollow)
              else
                _buildMessageArea(),
              // Just above the input cluster, where the thumb already rests.
              const SystemStatusBanner(anchor: StatusBannerAnchor.bottom),
              _TypingBar(
                contextKey: widget.isDm ? widget.peerId! : _channelKey,
              ),
              if (_mentionCandidates.isNotEmpty) _buildMentionPanel(hollow),
              if (_emoteCandidates.isNotEmpty) _buildEmotePanel(hollow),
              if (_replyToMessageId != null)
                ChatReplyPreviewBar(
                  senderName: _replyToSenderName ?? '',
                  text: _replyToText ?? '',
                  imagePath: null,
                  onCancel: _cancelReply,
                ),
              StagedLinkArea(
                hollowLink: _stagedHollowLink,
                previewUrl: _stagedPreviewUrl,
                preview: _stagedPreview,
                previewLoading: _stagedPreviewLoading,
                onDismissHollowLink: _dismissStagedHollowLink,
                onDismissPreview: _dismissStagedPreview,
              ),
              if (_stagedFilePath != null)
                StagedFilePreviewBar(
                  filePath: _stagedFilePath!,
                  fileName: _stagedFileName ?? '',
                  isImage: _stagedFileIsImage,
                  onRemove: _clearStagedFile,
                ),
              if (!widget.isDm && _slowModeReadyAt != null)
                _buildSlowModePill(hollow),
              _buildComposerOrBanner(hollow),
            ],
          ),
        ),
      ),
    );

    if (bg.hasBackground) {
      scaffold = _wrapWithBackground(scaffold, bg, hollow);
    }

    return Stack(
      children: [
        scaffold,
        // For messages arriving in OTHER conversations. Offset below the status
        // bar and chat header so it cannot cover the header controls.
        MobileInChatBanner(
          currentPeerId: widget.peerId,
          currentServerId: widget.serverId,
          currentChannelId: widget.channelId,
          topOffset: MediaQuery.paddingOf(context).top + 64,
        ),
        const MobileActiveCallPill(),
        const MobileVoiceChannelPill(),
      ],
    );
  }

  /// ref.listen registrations, called unconditionally from build(), which is all
  /// Riverpod requires. The message-list growth listeners stay inside the list
  /// builders so they register only while a list actually shows.
  void _registerBuildListeners() {
    // The channel being viewed can stop being visible in real time (tier raised,
    // or a demotion); the CRDT already propagated, so this only pops the route.
    if (!widget.isDm && widget.serverId != null && widget.channelId != null) {
      ref.listen(visibleChannelsProvider, _onVisibleChannelsChanged);
    }
  }

  void _onVisibleChannelsChanged(
      Map<String, ChannelInfo>? prev, Map<String, ChannelInfo> next) {
    // A popped route's listener still fires during the pop frame, where ref.read
    // on the deactivated element crashes.
    if (!mounted || _routeDeactivated) return;
    // visibleChannels tracks the SELECTED server, so any other one is not about
    // this route.
    if (ref.read(selectedServerProvider) != widget.serverId) return;
    if (next.containsKey(widget.channelId)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_routeDeactivated && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  /// Whether this channel grants us Permission.readMessages.
  bool get _canReadChannel =>
      (ref.watch(myPermissionsProvider(widget.serverId!)).valueOrNull ??
              Permission.all) &
          Permission.readMessages !=
      0;

  Widget _buildHeader() {
    return _MobileChatHeader(
      peerId: widget.peerId,
      serverId: widget.serverId,
      channelId: widget.channelId,
      channelName: widget.channelName,
      searchOpen: _searchOpen,
      onSearchToggle: widget.isDm ? null : _toggleSearch,
    );
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _searchController.clear();
        _searchResults = [];
      }
    });
    if (_searchOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _searchFocusNode.requestFocus();
      });
    }
  }

  Widget _buildNoReadPermission(HollowTheme hollow) {
    return Expanded(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.eyeOff, size: 48,
                color: hollow.textSecondary.withValues(alpha: 0.3)),
            const SizedBox(height: HollowSpacing.md),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: HollowSpacing.xl),
              child: Text(
                'You don\'t have permission to read messages in this channel',
                textAlign: TextAlign.center,
                style:
                    HollowTypography.body.copyWith(color: hollow.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageArea() {
    return Expanded(
      child: Stack(
        children: [
          widget.isDm ? _buildDmMessages() : _buildChannelMessages(),
          _buildUnreadPillOverlay(),
        ],
      ),
    );
  }

  Widget _buildUnreadPillOverlay() {
    final unreadCount = widget.isDm
        ? ref.watch(unreadProvider
            .select((s) => s.dmUnreadCounts[widget.peerId!] ?? 0))
        : ref.watch(unreadProvider
            .select((s) => s.channelUnreadCounts[_channelKey] ?? 0));
    if (unreadCount <= 0 || _isInAutoScrollZone) {
      return const SizedBox.shrink();
    }
    return Positioned(
      bottom: HollowSpacing.md,
      left: 0,
      right: 0,
      child: Center(
        child: UnreadJumpPill(count: unreadCount, onTap: _scrollToBottom),
      ),
    );
  }

  void _cancelReply() {
    setState(() {
      _replyToMessageId = null;
      _replyToText = null;
      _replyToSenderName = null;
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

  void _clearStagedFile() {
    setState(() {
      _stagedFilePath = null;
      _stagedFileName = null;
      _stagedFileIsImage = false;
    });
  }

  /// Slow-mode countdown pill.
  Widget _buildSlowModePill(HollowTheme hollow) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.xs,
      ),
      color: hollow.surface,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.timer, size: 12, color: hollow.warning),
          const SizedBox(width: 4),
          Text(
            'Slow mode: ${(_slowModeReadyAt!.difference(DateTime.now()).inSeconds + 1).clamp(1, 3600)}s',
            style: HollowTypography.caption.copyWith(
              color: hollow.warning,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// The input bar, or the explanatory banner where posting is blocked.
  Widget _buildComposerOrBanner(HollowTheme hollow) {
    if (!widget.isDm) {
      final canPost = ref.watch(canPostInChannelProvider((
        serverId: widget.serverId!,
        channelId: widget.channelId!,
      )));
      // Keeps the grant-expiry timer alive while this channel is open: a lapsed
      // temporary grant emits no network event.
      ref.watch(myChannelGrantProvider((
        serverId: widget.serverId!,
        channelId: widget.channelId!,
      )));
      final muteText = muteBannerText(
          ref.watch(myMuteStatusProvider(widget.serverId!)).valueOrNull);
      if (!canPost || muteText != null) {
        return _buildBlockedBanner(hollow, muteText);
      }
    }
    return _buildInputArea();
  }

  Widget _buildBlockedBanner(HollowTheme hollow, String? muteText) {
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
          muteText ??
              'You don\'t have permission to send messages in this channel',
          style: HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    if (_isRecordingVoice) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm,
          vertical: HollowSpacing.sm,
        ),
        child: VoiceRecorderBar(
          onFinished: _stageVoiceMessage,
          onCancelled: () => setState(() => _isRecordingVoice = false),
        ),
      );
    }
    // The chat text scale rides the composer too: reading at 150% and typing at
    // 100% helps nobody.
    return ChatTextScale(
      child: _MobileInputBar(
        controller: _controller,
        focusNode: _focusNode,
        onSend: _handleSend,
        onAttach: _showAttachSheet,
        onMic: _stagedFilePath != null ? null : _startVoiceRecording,
        onEmoji: _showEmojiSheet,
        onChanged: _onTextChanged,
        hasStagedFile: _stagedFilePath != null,
      ),
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

  Widget _wrapWithBackground(
      Widget scaffold, BackgroundState bg, HollowTheme hollow) {
    final darkenAlpha = bg.panelOpacity.clamp(0.0, 0.92);
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            color: Colors.black,
            child: Image.memory(
              bg.imageBytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              width: double.infinity,
              height: double.infinity,
            ),
          ),
        ),
        Positioned.fill(
          child: Container(
            color: hollow.background.withValues(alpha: darkenAlpha),
          ),
        ),
        scaffold,
      ],
    );
  }

  Widget _buildSyncIndicator(HollowTheme hollow) {
    final status = ref.watch(serverSyncStatusProvider(widget.serverId!));
    switch (status) {
      case ServerSyncStatus.syncing:
      case ServerSyncStatus.retrying:
        final isRetrying = status == ServerSyncStatus.retrying;
        return Container(
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.md,
            vertical: HollowSpacing.xs,
          ),
          color: hollow.surface,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: isRetrying ? hollow.warning : hollow.accent,
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                isRetrying ? 'Retrying sync...' : 'Syncing...',
                style: HollowTypography.caption.copyWith(
                  color: isRetrying ? hollow.warning : hollow.textSecondary,
                ),
              ),
            ],
          ),
        );
      case ServerSyncStatus.failed:
        return Container(
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.md,
            vertical: HollowSpacing.xs,
          ),
          color: hollow.surface,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StatusDot(color: hollow.error, size: 8),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                'Sync failed',
                style: HollowTypography.caption.copyWith(color: hollow.error),
              ),
              const SizedBox(width: HollowSpacing.sm),
              GestureDetector(
                onTap: () => network_api.requestChannelSync(
                  serverId: widget.serverId!,
                  channelId: widget.channelId!,
                ).catchError((_) {}),
                child: Text(
                  'Retry',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      case ServerSyncStatus.synced:
      case ServerSyncStatus.idle:
      case ServerSyncStatus.connecting:
        return const SizedBox.shrink();
    }
  }

  /// Shared shell for both message lists: the freeze-aware display slice, the
  /// reversed-list plumbing and the empty state.
  Widget _buildMessageListShell<T>({
    required List<T> messages,
    required String? Function(T msg) messageIdOf,
    // The conversation's key in `unreadMarkerProvider`, so mobile draws the same
    // "new messages" line the desktop panes do (issue #54).
    required String markerKey,
    required bool Function(T msg) isMine,
    required Widget Function(List<T> messages, int revIndex,
            Map<String, int> indexById, int? unreadIndex)
        rowBuilder,
  }) {
    if (messages.isEmpty) {
      return Center(
        child: Text('No messages yet', style: HollowTypography.body.copyWith(
          color: HollowTheme.of(context).textSecondary,
        )),
      );
    }

    // Message id to chronological index, for findChildIndexCallback.
    final indexById = <String, int>{
      for (var i = 0; i < messages.length; i++)
        if (messageIdOf(messages[i]) != null) messageIdOf(messages[i])!: i,
    };

    final unreadIndex = unreadDividerIndex(
      count: messages.length,
      entrySeenId: ref.watch(unreadMarkerProvider)[markerKey],
      messageIdAt: (i) => messageIdOf(messages[i]),
      isMineAt: (i) => isMine(messages[i]),
    );

    return reversedChatList(
      context: context,
      itemScrollController: _scrollController,
      itemPositionsListener: _positionsListener,
      itemCount: messages.length,
      indexByMessageId: indexById,
      // No SelectionArea on mobile: it would fight LongPressMessage.
      selectionArea: false,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.sm,
      ),
      // Touch keeps the jump buttons, never the drag track (issue #54).
      onJumpToNewest: _scrollToBottom,
      itemBuilder: (context, revIndex) =>
          rowBuilder(messages, revIndex, indexById, unreadIndex),
    );
  }

  Widget _buildDmMessages() {
    // Per-conversation select: the map is replaced wholesale on every insert, so
    // watching it rebuilds this list for activity in any conversation.
    final allMessages =
        ref.watch(chatProvider.select((m) => m[widget.peerId!])) ?? [];
    final messages = _displayMessages(allMessages);

    // Following re-pins to the newest row; reading history freezes the display.
    ref.listen<Map<String, List<ChatMessage>>>(
        chatProvider, _onDmMessagesChanged);

    return _buildMessageListShell<ChatMessage>(
      messages: messages,
      messageIdOf: (m) => m.messageId,
      markerKey: dmMarkerKey(widget.peerId!),
      isMine: (m) => m.isMe,
      rowBuilder: _buildDmRow,
    );
  }

  void _onDmMessagesChanged(
      Map<String, List<ChatMessage>>? prev, Map<String, List<ChatMessage>> next) {
    if (!mounted || _routeDeactivated) return;
    final prevLen = (prev?[widget.peerId!] ?? const []).length;
    final nextLen = (next[widget.peerId!] ?? const []).length;
    if (nextLen <= prevLen) return;
    if (_frozenLen != null) return;
    if (!_isInAutoScrollZone) {
      _frozenLen = prevLen;
      return;
    }
    // Not the bare jump: this also marks the arrival seen, which is right
    // because the user is following at the bottom.
    _scrollToBottom();
  }

  /// Sticker-run tiling candidates. The two message types carry the same fields
  /// under different classes, so the predicate is written twice rather than made
  /// generic over an interface neither model has.
  bool _dmTileCandidate(ChatMessage m) => stickerTileCandidate(
        text: m.text,
        hasReply: m.replyToMid != null,
        hasReactions: m.reactions.isNotEmpty,
        hasFile: m.fileAttachment != null,
        isEdited: m.editedAt != null,
      );

  bool _channelTileCandidate(ChannelChatMessage m) => stickerTileCandidate(
        text: m.text,
        hasReply: m.replyToMid != null,
        hasReactions: m.reactions.isNotEmpty,
        hasFile: m.fileAttachment != null,
        isEdited: m.editedAt != null,
      );

  Widget _buildDmRow(List<ChatMessage> messages, int revIndex,
      Map<String, int> indexById, int? unreadIndex) {
    // Map the reversed builder index back to chronological order; all row logic
    // below stays in chronological terms.
    final index = messages.length - 1 - revIndex;
    final msg = messages[index];
    final prev = index > 0 ? messages[index - 1] : null;
    final profiles = ref.watch(profileProvider);

    final showHeader = prev == null ||
        !shouldGroup(
          currentIsMe: msg.isMe,
          previousIsMe: prev.isMe,
          currentTime: msg.timestamp,
          previousTime: prev.timestamp,
        );

    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final senderName =
        msg.isMe ? 'You' : displayNameFor(profiles, widget.peerId!);

    // Edit mode: show inline editor instead of bubble.
    if (_editingMessageId != null && _editingMessageId == msg.messageId) {
      return _editRow(
        showDate: shouldShowDateSeparator(msg.timestamp, prev?.timestamp),
        timestamp: msg.timestamp,
        originalText: msg.text,
        onSave: (newText) {
          _submitEdit(msg.messageId!, newText);
          setState(() => _editingMessageId = null);
        },
      );
    }

    // The linear scan runs only for rows that ARE replies, and only when the
    // per-conversation list itself changed.
    String? replySender;
    String? replyText;
    if (msg.replyToMid != null) {
      final idx = indexById[msg.replyToMid] ?? -1;
      if (idx != -1) {
        final original = messages[idx];
        replyText =
            _attachmentPreviewText(original.fileAttachment, original.text);
        final origSenderId = original.isMe ? localPeerId : widget.peerId!;
        replySender = displayNameFor(profiles, origSenderId);
      }
    }

    final next = index + 1 < messages.length ? messages[index + 1] : null;
    final tiling = stickerTilingFor(
      selfIsSticker: _dmTileCandidate(msg),
      prevIsSticker: prev != null && _dmTileCandidate(prev),
      groupedWithPrev: !showHeader,
      nextIsSticker: next != null && _dmTileCandidate(next),
      groupedWithNext: next != null &&
          shouldGroup(
            currentIsMe: next.isMe,
            previousIsMe: msg.isMe,
            currentTime: next.timestamp,
            previousTime: msg.timestamp,
          ),
    );

    final bubble = LongPressMessage(
      onLongPress: () => _showDmActions(msg, senderName, localPeerId),
      child: MessageBubble(
        message: msg,
        peerId: widget.peerId!,
        showHeader: showHeader,
        replyToSenderName: replySender,
        replyToText: replyText,
        onToggleReaction: msg.messageId != null
            ? (emoji) => _toggleDmReaction(msg, emoji)
            : null,
        tileWithPrev: tiling.prev,
        tileWithNext: tiling.next,
      ),
    );

    return dateSeparatedChatRow(
      rowKey: msg.messageId ?? index,
      timestamp: msg.timestamp,
      prevTimestamp: prev?.timestamp,
      showHeader: showHeader,
      unreadDivider: index == unreadIndex,
      child: bubble,
    );
  }

  /// The inline editor as a list row, with the date separator preserved.
  Widget _editRow({
    required bool showDate,
    required DateTime timestamp,
    required String originalText,
    required void Function(String) onSave,
  }) {
    final editWidget = _buildEditView(
      originalText: originalText,
      onSave: onSave,
      onCancel: () => setState(() => _editingMessageId = null),
    );
    return showDate
        ? Column(mainAxisSize: MainAxisSize.min, children: [
            DateSeparator(date: timestamp),
            editWidget,
          ])
        : editWidget;
  }

  /// Preview line for a reply target: a file token, or the raw text.
  String _attachmentPreviewText(FileAttachment? att, String text) {
    if (att == null) return text;
    return att.isImage ? '📷 Image' : '📎 ${att.fileName}';
  }

  Future<void> _toggleDmReaction(ChatMessage msg, String emoji) async {
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final hasReacted = msg.reactions[emoji]?.contains(localPeerId) ?? false;
    final notifier = ref.read(chatProvider.notifier);
    try {
      if (hasReacted) {
        await notifier.removeReaction(widget.peerId!, msg.messageId!, emoji);
      } else {
        await notifier.addReaction(widget.peerId!, msg.messageId!, emoji);
      }
    } catch (_) {
      if (!mounted || _routeDeactivated) return;
      HollowToast.show(context, 'Failed to update reaction',
          type: HollowToastType.error);
    }
  }

  Future<void> _toggleChannelReaction(ChannelChatMessage msg, String emoji) async {
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final hasReacted = msg.reactions[emoji]?.contains(localPeerId) ?? false;
    final notifier = ref.read(channelChatProvider.notifier);
    try {
      if (hasReacted) {
        await notifier.removeReaction(
            widget.serverId!, widget.channelId!, msg.messageId!, emoji);
      } else {
        await notifier.addReaction(
            widget.serverId!, widget.channelId!, msg.messageId!, emoji);
      }
    } catch (_) {
      if (!mounted || _routeDeactivated) return;
      HollowToast.show(context, 'Failed to update reaction',
          type: HollowToastType.error);
    }
  }

  Widget _buildChannelMessages() {
    // Per-channel select: the map is replaced wholesale on every insert, so
    // watching it rebuilds this list for activity in any channel.
    final allMessages =
        ref.watch(channelChatProvider.select((m) => m[_channelKey])) ?? [];
    final messages = _displayMessages(allMessages);

    ref.listen(channelChatProvider, _onChannelMessagesChanged);

    return _buildMessageListShell<ChannelChatMessage>(
      messages: messages,
      messageIdOf: (m) => m.messageId,
      markerKey: channelMarkerKey(widget.serverId!, widget.channelId!),
      isMine: (m) => m.isMe,
      rowBuilder: _buildChannelRow,
    );
  }

  void _onChannelMessagesChanged(
      Map<String, List<ChannelChatMessage>>? prev,
      Map<String, List<ChannelChatMessage>> next) {
    if (!mounted || _routeDeactivated) return;
    final prevLen = (prev?[_channelKey] ?? const []).length;
    final nextLen = (next[_channelKey] ?? const []).length;
    if (nextLen <= prevLen) return;
    // My optimistic send and a sibling's both land here, so the cooldown pill is
    // re-derived from the list rather than from send-time state.
    _recomputeSlowMode();
    if (_frozenLen != null) return;
    if (!_isInAutoScrollZone) {
      _frozenLen = prevLen;
      return;
    }
    // Not the bare jump: this also marks the arrival seen.
    _scrollToBottom();
  }

  Widget _buildChannelRow(List<ChannelChatMessage> messages, int revIndex,
      Map<String, int> indexById, int? unreadIndex) {
    // Map the reversed builder index back to chronological order.
    final index = messages.length - 1 - revIndex;
    final msg = messages[index];
    final prev = index > 0 ? messages[index - 1] : null;
    final profiles = ref.watch(profileProvider);

    // Grouping collapses each sender to its MASTER, or a person writing from two
    // devices reads as two people under a raw device id.
    final links = ref.watch(deviceLinkProvider);
    final curSender = links.identityOf(msg.senderId);

    final showHeader = prev == null ||
        !shouldGroup(
          currentIsMe: msg.isMe,
          previousIsMe: prev.isMe,
          currentTime: msg.timestamp,
          previousTime: prev.timestamp,
          currentSenderId: curSender,
          previousSenderId: links.identityOf(prev.senderId),
        );

    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final senderName = displayNameFor(profiles, curSender);

    // Edit mode: show inline editor instead of bubble.
    if (_editingMessageId != null && _editingMessageId == msg.messageId) {
      return _editRow(
        showDate: shouldShowDateSeparator(msg.timestamp, prev?.timestamp),
        timestamp: msg.timestamp,
        originalText: msg.text,
        onSave: (newText) {
          _submitEdit(msg.messageId!, newText);
          setState(() => _editingMessageId = null);
        },
      );
    }

    // Look up reply target for this message.
    String? replySender;
    String? replyText;
    if (msg.replyToMid != null) {
      final idx = indexById[msg.replyToMid] ?? -1;
      if (idx != -1) {
        final original = messages[idx];
        replyText =
            _attachmentPreviewText(original.fileAttachment, original.text);
        replySender =
            displayNameFor(profiles, links.identityOf(original.senderId));
      }
    }

    final next = index + 1 < messages.length ? messages[index + 1] : null;
    final tiling = stickerTilingFor(
      selfIsSticker: _channelTileCandidate(msg),
      prevIsSticker: prev != null && _channelTileCandidate(prev),
      groupedWithPrev: !showHeader,
      nextIsSticker: next != null && _channelTileCandidate(next),
      groupedWithNext: next != null &&
          shouldGroup(
            currentIsMe: next.isMe,
            previousIsMe: msg.isMe,
            currentTime: next.timestamp,
            previousTime: msg.timestamp,
            currentSenderId: links.identityOf(next.senderId),
            previousSenderId: curSender,
          ),
    );

    final bubble = LongPressMessage(
      onLongPress: () => _showChannelActions(msg, senderName, localPeerId),
      child: ChannelMessageBubble(
        message: msg,
        serverId: widget.serverId!,
        showHeader: showHeader,
        isHighlighted: _highlightIndex == index,
        replyToSenderName: replySender,
        replyToText: replyText,
        onToggleReaction: msg.messageId != null
            ? (emoji) => _toggleChannelReaction(msg, emoji)
            : null,
        tileWithPrev: tiling.prev,
        tileWithNext: tiling.next,
      ),
    );

    return dateSeparatedChatRow(
      rowKey: msg.messageId ?? index,
      timestamp: msg.timestamp,
      prevTimestamp: prev?.timestamp,
      showHeader: showHeader,
      unreadDivider: index == unreadIndex,
      child: bubble,
    );
  }

  void _showDmActions(ChatMessage msg, String senderName, String localPeerId) {
    showMobileMessageActions(
      context: context,
      messageText: msg.text,
      senderName: senderName,
      timestamp: _formatTime(msg.timestamp),
      isMe: msg.isMe,
      serverId: widget.serverId,
      onReply: _replyActionFor(msg.messageId, senderName, msg.text),
      onEdit: _editActionFor(msg.messageId, msg.isMe, msg.fileAttachment),
      onDelete: msg.messageId != null && msg.isMe
          ? () => _deleteMessage(msg.messageId!)
          : null,
      onCopy: _copyActionFor(msg.text),
      onDownload: _downloadActionFor(msg.fileAttachment, widget.peerId!),
      fileAction: _fileActionFor(msg.fileAttachment),
      onStopWaiting: _stopWaitingActionFor(msg.fileAttachment),
      onReaction: msg.messageId != null
          ? (emoji) => _toggleDmReaction(msg, emoji)
          : null,
      onInfo: msg.messageId != null
          ? () => _showDmProof(msg, senderName, localPeerId)
          : null,
    );
  }

  void _showDmProof(ChatMessage msg, String senderName, String localPeerId) {
    final senderId = msg.isMe ? localPeerId : widget.peerId!;
    showMessageProofDialog(
      context,
      MessageProofData(
        senderPeerId: senderId,
        senderDisplayName: senderName,
        text: msg.text,
        timestampMs: (msg.editedAt ?? msg.timestamp).millisecondsSinceEpoch,
        signature: msg.signature,
        publicKey: msg.publicKey,
        messageId: msg.messageId,
        context: msg.isMe ? widget.peerId! : localPeerId,
        msgType: 'dm',
        fileAttachment: msg.fileAttachment,
      ),
    );
  }

  void _showChannelActions(
      ChannelChatMessage msg, String senderName, String localPeerId) {
    showMobileMessageActions(
      context: context,
      messageText: msg.text,
      senderName: senderName,
      timestamp: _formatTime(msg.timestamp),
      isMe: msg.isMe,
      serverId: widget.serverId,
      onReply: _replyActionFor(msg.messageId, senderName, msg.text),
      onEdit: _editActionFor(msg.messageId, msg.isMe, msg.fileAttachment),
      onDelete: msg.messageId != null && msg.isMe
          ? () => _deleteMessage(msg.messageId!)
          : null,
      onCopy: _copyActionFor(msg.text),
      onDownload: _downloadActionFor(msg.fileAttachment, msg.senderId),
      fileAction: _fileActionFor(msg.fileAttachment),
      onStopWaiting: _stopWaitingActionFor(msg.fileAttachment),
      onReaction: msg.messageId != null
          ? (emoji) => _toggleChannelReaction(msg, emoji)
          : null,
      onInfo: msg.messageId != null
          ? () => _showChannelProof(msg, senderName)
          : null,
      onPin: _pinActionFor(msg.messageId),
      isPinned: msg.messageId != null &&
          (ref.read(pinnedProvider)[_channelKey] ?? [])
              .contains(msg.messageId),
    );
  }

  void _showChannelProof(ChannelChatMessage msg, String senderName) {
    showMessageProofDialog(
      context,
      MessageProofData(
        // The send side signs with the MASTER id, so the proof must verify
        // against the master or a multi-device sender reads as invalid.
        senderPeerId: ref.read(deviceLinkProvider).identityOf(msg.senderId),
        senderDisplayName: senderName,
        text: msg.text,
        timestampMs: (msg.editedAt ?? msg.timestamp).millisecondsSinceEpoch,
        signature: msg.signature,
        publicKey: msg.publicKey,
        messageId: msg.messageId,
        context: '${widget.serverId!}:${widget.channelId!}',
        msgType: 'ch',
        fileAttachment: msg.fileAttachment,
      ),
    );
  }

  // Action-sheet callback factories; null hides the affordance.

  VoidCallback? _replyActionFor(String? messageId, String senderName,
      String text) =>
      messageId != null ? () => _setReply(messageId, senderName, text) : null;

  VoidCallback? _editActionFor(
          String? messageId, bool isMe, FileAttachment? attachment) =>
      messageId != null && isMe && attachment == null
          ? () => _startEditing(messageId)
          : null;

  VoidCallback? _copyActionFor(String text) =>
      text.isNotEmpty && !text.startsWith(_kFilePrefix)
          ? () {
              Clipboard.setData(ClipboardData(text: text));
              HollowToast.show(context, 'Copied to clipboard',
                  type: HollowToastType.success);
            }
          : null;

  /// What the sheet's file row offers, mirroring the card. Read as the sheet
  /// opens, because the sheet is a snapshot rather than a live surface.
  FileBarAction _fileActionFor(FileAttachment? attachment) {
    if (attachment == null) return FileBarAction.download;
    return fileBarAction(
      attachment: attachment,
      transfer: ref.read(fileTransferProvider)[attachment.fileId],
    );
  }

  /// Cancels the outstanding ask and lets the card fall back to its plain
  /// Download button without waiting for the next event.
  VoidCallback? _stopWaitingActionFor(FileAttachment? attachment) {
    if (attachment == null) return null;
    return () async {
      try {
        await ref
            .read(fileTransferProvider.notifier)
            .stopWaitingForFile(attachment.fileId);
      } catch (e) {
        if (!mounted) return;
        HollowToast.show(context, 'Could not stop the request: $e',
            type: HollowToastType.error);
      }
    };
  }

  VoidCallback? _downloadActionFor(FileAttachment? attachment,
      String senderId) {
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
              serverId: widget.serverId ?? '',
              sequential: false,
            ).catchError((e) {
          if (mounted) {
            HollowToast.show(context, 'Download failed: $e',
                type: HollowToastType.error);
          }
        });
      } else {
        _requestFileFromPeer(attachment, senderId);
      }
    };
  }

  VoidCallback? _pinActionFor(String? messageId) {
    // messageId first, THEN the permission read.
    if (messageId == null) return null;
    final canPin = ref.read(myPermissionsProvider(widget.serverId!)).whenOrNull(
            data: (perms) => (perms & Permission.manageChannels) != 0) ??
        false;
    if (!canPin) return null;
    return () => _togglePin(messageId);
  }

  Future<void> _togglePin(String messageId) async {
    final pins = ref.read(pinnedProvider)[_channelKey] ?? [];
    final isPinned = pins.contains(messageId);
    try {
      if (isPinned) {
        await crdt_api.unpinMessage(
          serverId: widget.serverId!,
          channelId: widget.channelId!,
          messageId: messageId,
        );
      } else {
        await crdt_api.pinMessage(
          serverId: widget.serverId!,
          channelId: widget.channelId!,
          messageId: messageId,
        );
      }
    } catch (_) {
      if (!mounted || _routeDeactivated) return;
      HollowToast.show(
          context,
          isPinned ? 'Failed to unpin message' : 'Failed to pin message',
          type: HollowToastType.error);
    }
  }

  /// Deletes a message and toasts on failure. The action sheet is already popped
  /// by the time the await completes, so the toast uses this State's context.
  Future<void> _deleteMessage(String messageId) async {
    try {
      if (widget.isDm) {
        await ref
            .read(chatProvider.notifier)
            .deleteMessage(widget.peerId!, messageId);
      } else {
        await ref.read(channelChatProvider.notifier).deleteMessage(
            widget.serverId!, widget.channelId!, messageId);
      }
    } catch (_) {
      if (!mounted || _routeDeactivated) return;
      HollowToast.show(context, 'Failed to delete message',
          type: HollowToastType.error);
    }
  }

  /// Saves an edit and toasts on failure.
  Future<void> _submitEdit(String messageId, String newText) async {
    try {
      if (widget.isDm) {
        await ref
            .read(chatProvider.notifier)
            .editMessage(widget.peerId!, messageId, newText);
      } else {
        await ref.read(channelChatProvider.notifier).editMessage(
            widget.serverId!, widget.channelId!, messageId, newText);
      }
    } catch (_) {
      if (!mounted || _routeDeactivated) return;
      HollowToast.show(context, 'Failed to save changes',
          type: HollowToastType.error);
      return;
    }
    if (!mounted || _routeDeactivated) return;
    _resyncPreviewAfterEdit(messageId, newText);
  }

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
          TextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            autofocus: true,
            style: HollowTypography.body.copyWith(
              color: hollow.textPrimary,
              fontSize: 13,
            ),
            decoration: InputDecoration(
              hintText: 'Search in #${widget.channelName}...',
              hintStyle: HollowTypography.body.copyWith(
                color: hollow.textSecondary,
                fontSize: 13,
              ),
              prefixIcon: Icon(LucideIcons.search,
                  size: 16, color: hollow.textSecondary),
              filled: true,
              fillColor: hollow.background,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.md,
                vertical: HollowSpacing.sm,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(hollow.radiusLg),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: _onSearch,
          ),
          if (_searchResults.isNotEmpty)
            ConstrainedBox(
              // Sized to the space left above the keyboard, or a small phone
              // shows two results while typing.
              constraints: BoxConstraints(
                maxHeight: ((MediaQuery.sizeOf(context).height -
                            MediaQuery.viewInsetsOf(context).bottom) *
                        0.35)
                    .clamp(120.0, 360.0),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _searchResults.length,
                itemBuilder: (_, index) {
                  final msg = _searchResults[index];
                  final profiles = ref.watch(profileProvider);
                  // Collapse device to master so a result shows the person.
                  final name = displayNameFor(profiles,
                      ref.watch(deviceLinkProvider).identityOf(msg.senderId));
                  final time = DateTime.fromMillisecondsSinceEpoch(
                      msg.timestamp.toInt());
                  final timeStr = _hhmm(time);
                  return Padding(
                    padding: const EdgeInsets.only(top: HollowSpacing.xs),
                    child: HollowPressable(
                      subtle: true,
                      onTap: () {
                        // Against the DISPLAY list, possibly frozen;
                        // _scrollToMessage converts to the reversed index.
                        final messages = _displayMessages(
                            ref.read(channelChatProvider)[_channelKey] ??
                                const <ChannelChatMessage>[]);
                        final idx = messages.indexWhere(
                            (m) => m.messageId == msg.messageId);
                        setState(() {
                          _searchOpen = false;
                          _searchController.clear();
                          _searchResults = [];
                        });
                        if (idx != -1) _scrollToMessage(idx);
                      },
                      borderRadius: BorderRadius.circular(hollow.radiusSm),
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
                                timeStr,
                                style: HollowTypography.caption.copyWith(
                                  color: hollow.textSecondary
                                      .withValues(alpha: 0.5),
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
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEditView({
    required String originalText,
    required void Function(String) onSave,
    required VoidCallback onCancel,
  }) {
    final hollow = HollowTheme.of(context);

    _editController.text = originalText;
    _editController.selection = TextSelection.fromPosition(
      TextPosition(offset: originalText.length),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _editFocusNode.requestFocus();
    });

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xs,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: hollow.accent),
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              color: hollow.elevated,
            ),
            child: TextField(
              controller: _editController,
              focusNode: _editFocusNode,
              maxLines: 5,
              minLines: 1,
              textInputAction: TextInputAction.newline,
              style: HollowTypography.body.copyWith(color: hollow.textPrimary),
              decoration: InputDecoration(
                contentPadding: const EdgeInsets.all(HollowSpacing.sm),
                border: InputBorder.none,
                hintText: 'Edit your message...',
                hintStyle: HollowTypography.body.copyWith(
                  color: hollow.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(height: HollowSpacing.xs),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              HollowPressable(
                onTap: onCancel,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.sm,
                    vertical: HollowSpacing.xs,
                  ),
                  child: Text('Cancel',
                      style: HollowTypography.caption
                          .copyWith(color: hollow.textSecondary)),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowPressable(
                onTap: () {
                  final newText = _editController.text.trim();
                  if (newText.isNotEmpty && newText != originalText) {
                    onSave(newText);
                  } else {
                    onCancel();
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.md,
                    vertical: HollowSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: hollow.accent,
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                  ),
                  child: Text('Save',
                      style: HollowTypography.caption.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      )),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

}

class _MobileChatHeader extends ConsumerWidget {
  final String? peerId;
  final String? serverId;
  final String? channelId;
  final String? channelName;
  final VoidCallback? onSearchToggle;
  final bool searchOpen;

  const _MobileChatHeader({
    this.peerId,
    this.serverId,
    this.channelId,
    this.channelName,
    this.onSearchToggle,
    this.searchOpen = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    // Watched because displayNameFor reads a static cache that triggers no
    // rebuild of its own.
    ref.watch(localNicknameProvider);
    final isDm = peerId != null;

    // Saved messages is a DM with our OWN master identity: a bookmark header, no
    // presence line and no call buttons.
    final savedId = ref.watch(savedMessagesPeerIdProvider);
    final isSaved = isDm &&
        savedId != null &&
        ref.watch(deviceLinkProvider).identityOf(peerId!) == savedId;

    final isOnline = isDm && !isSaved && identityIsOnline(ref, peerId!);

    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xs),
      child: Row(
        children: [
          HollowPressable(
            onTap: () => Navigator.of(context).pop(),
            semanticLabel: 'Back',
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(HollowSpacing.sm),
            child: Icon(LucideIcons.arrowLeft, size: 22, color: hollow.textPrimary),
          ),
          const SizedBox(width: HollowSpacing.xs),
          ..._leadingAvatar(hollow, isDm: isDm, isSaved: isSaved, isOnline: isOnline),
          Expanded(
            child: _titleBlock(context, ref, hollow,
                isDm: isDm, isSaved: isSaved, isOnline: isOnline),
          ),
          ..._trailingActions(context, ref, hollow, isDm: isDm, isSaved: isSaved),
        ],
      ),
    );
  }

  /// The saved-messages bookmark or the DM avatar with its presence dot; empty
  /// for a channel.
  List<Widget> _leadingAvatar(HollowTheme hollow,
      {required bool isDm, required bool isSaved, required bool isOnline}) {
    if (isSaved) {
      return const [
        SavedMessagesAvatar(size: 32),
        SizedBox(width: HollowSpacing.sm),
      ];
    }
    if (!isDm) return const [];
    return [
      SizedBox(
        width: 32, height: 32,
        child: Stack(
                 clipBehavior: Clip.none,
          children: [
            HollowAvatar(peerId: peerId!, size: 32),
            Positioned(
              right: 0, bottom: 0,
              child: Container(
                decoration: BoxDecoration(
                  color: hollow.surface, shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(1),
                child: StatusDot(
                  color: isOnline ? hollow.success : hollow.textSecondary,
                  size: 8, 
                  filled: isOnline,
                  semanticLabel: isOnline ? 'Online' : 'Offline',
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(width: HollowSpacing.sm),
    ];
  }

  /// Title and subtitle column, tappable for the DM profile sheet.
  Widget _titleBlock(BuildContext context, WidgetRef ref, HollowTheme hollow,
      {required bool isDm, required bool isSaved, required bool isOnline}) {
    final profiles = ref.watch(profileProvider);
    String title;
    if (isSaved) {
      title = 'Saved messages';
    } else if (isDm) {
      title = displayNameFor(profiles, peerId!);
    } else {
      title = '# ${channelName ?? 'Channel'}';
    }

    final subtitle = _subtitleText(ref, hollow,
        isDm: isDm, isSaved: isSaved, isOnline: isOnline);

    return HollowPressable(
      onTap: isDm ? () => _showProfileSheet(context, ref, peerId!) : null,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  title,
                  style: HollowTypography.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: hollow.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!isDm &&
                  serverId != null &&
                  (ref.watch(serverIsNsfwProvider(serverId!)).valueOrNull ??
                      false)) ...[
                const SizedBox(width: HollowSpacing.sm),
                const _MobileNsfwBadge(),
              ],
            ],
          ),
          ?subtitle,
        ],
      ),
    );
  }

  /// Header subtitle: the DM presence line, or the channel's server name so it
  /// is clear which server it belongs to. Null when neither applies.
  Widget? _subtitleText(WidgetRef ref, HollowTheme hollow,
      {required bool isDm, required bool isSaved, required bool isOnline}) {
    if (isDm && !isSaved) {
      return Text(
        isOnline ? 'Online' : 'Offline',
        style: HollowTypography.caption.copyWith(
          color: isOnline ? hollow.success : hollow.textSecondary,
        ),
      );
    }
    final serverName = (!isDm && serverId != null)
        ? ref.watch(serverListProvider.select((m) => m[serverId]?.name))
        : null;
    if (serverName == null || serverName.isEmpty) return null;
    return Text(
      serverName,
      style: HollowTypography.caption.copyWith(
        color: hollow.textSecondary,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// Right-edge header actions: the DM call and mute buttons, or the channel
  /// cluster.
  List<Widget> _trailingActions(
      BuildContext context, WidgetRef ref, HollowTheme hollow,
      {required bool isDm, required bool isSaved}) {
    if (isDm) {
      return [
        // Saved messages hides the call buttons: you cannot call yourself.
        if (!isSaved) _DmCallButtons(peerId: peerId!),
        _DmMuteButton(peerId: peerId!),
      ];
    }
    return [
      if (serverId != null) ...[
        _MobileChannelStatus(serverId: serverId!),
        const SizedBox(width: HollowSpacing.xs),
      ],
      if (serverId != null)
        HollowPressable(
          onTap: () => showMobileMemberPanel(context, serverId!),
          semanticLabel: 'Members',
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: const EdgeInsets.all(HollowSpacing.sm),
          child: Icon(LucideIcons.users, size: 20, color: hollow.textSecondary),
        ),
      if (serverId != null && channelId != null)
        _pinnedButton(context, ref, hollow),
      if (onSearchToggle != null)
        HollowPressable(
          onTap: onSearchToggle,
          semanticLabel: 'Search messages',
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: const EdgeInsets.all(HollowSpacing.sm),
          child: Icon(
            LucideIcons.search,
            size: 20,
            color: searchOpen ? hollow.accent : hollow.textSecondary,
          ),
        ),
    ];
  }

  Widget _pinnedButton(BuildContext context, WidgetRef ref, HollowTheme hollow) {
    final pinKey = '$serverId:$channelId';
    final pinnedIds = ref.watch(pinnedProvider)[pinKey] ?? [];
    if (pinnedIds.isEmpty) return const SizedBox.shrink();
    return HollowPressable(
      onTap: () => _showPinnedMessagesSheet(
          context, ref, serverId!, channelId!, pinnedIds),
      semanticLabel: 'Pinned messages',
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.all(HollowSpacing.sm),
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
    );
  }

  void _showProfileSheet(BuildContext context, WidgetRef ref, String peerId) {
    showMobileProfileSheet(context, peerId: peerId);
  }

  void _showPinnedMessagesSheet(
    BuildContext context,
    WidgetRef ref,
    String serverId,
    String channelId,
    List<String> pinnedIds,
  ) {
    final hollow = HollowTheme.of(context);
    final messages =
        ref.read(channelChatProvider)['$serverId:$channelId'] ?? [];
    final profiles = ref.read(profileProvider);
    final nicknames = ref.read(serverNicknamesProvider(serverId));

    final pinnedMessages = pinnedIds
        .map((id) => messages.where((m) => m.messageId == id).firstOrNull)
        .where((m) => m != null)
        .toList()
      ..sort((a, b) => b!.timestamp.compareTo(a!.timestamp));

    showModalBottomSheet(
      context: context,
      backgroundColor: hollow.surface,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: HollowSpacing.sm),
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: hollow.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(HollowSpacing.md),
              child: Row(
                children: [
                  Icon(LucideIcons.pin, size: 18, color: hollow.accent),
                  const SizedBox(width: HollowSpacing.sm),
                  Text(
                    'Pinned Messages',
                    style: HollowTypography.subheading.copyWith(
                      color: hollow.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            if (pinnedMessages.isEmpty)
              Padding(
                padding: const EdgeInsets.all(HollowSpacing.xl),
                child: Text(
                  'Pinned messages not loaded in current view.',
                  style: HollowTypography.body
                      .copyWith(color: hollow.textSecondary),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: pinnedMessages.length,
                  separatorBuilder: (_, _) =>
                      Divider(color: hollow.border, height: 1),
                  itemBuilder: (_, index) {
                    final msg = pinnedMessages[index]!;
                    // Collapse device to master so a pinned row shows the
                    // person.
                    final pinnedMaster = ref
                        .read(deviceLinkProvider)
                        .identityOf(msg.senderId);
                    final name = serverDisplayNameFor(
                      profiles,
                      pinnedMaster,
                      nickname: nicknames[pinnedMaster] ?? '',
                    );
                    final time = _hhmm(msg.timestamp);
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: HollowSpacing.md,
                        vertical: HollowSpacing.sm,
                      ),
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
                                time,
                                style: HollowTypography.caption.copyWith(
                                  color: hollow.textSecondary,
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            msg.text.startsWith(_kFilePrefix)
                                ? '📎 File'
                                : msg.text,
                            style: HollowTypography.body
                                .copyWith(color: hollow.textPrimary),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: HollowSpacing.sm),
          ],
        ),
      ),
    );
  }
}

/// Small "NSFW" pill for the mobile channel header.
class _MobileNsfwBadge extends StatelessWidget {
  const _MobileNsfwBadge();

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
          fontSize: 9,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Encrypted or Offline status for the mobile channel header: a server channel
/// is Encrypted once any other member is online, since they are already inside
/// the MLS group. Members are master-keyed, so devices collapse to their master.
class _MobileChannelStatus extends ConsumerWidget {
  final String serverId;

  const _MobileChannelStatus({required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(onlineIdentitiesProvider);
    final membersAsync = ref.watch(serverMembersProvider(serverId));
    final localPeerId = ref.watch(identityProvider).peerId;
    // "Offline" describes OUR link, never an empty room.
    final amOnline = ref.watch(overallConnectionProvider).isOnline;

    return membersAsync.when(
      data: (members) {
        final anyOnline = members.any((m) =>
            m.peerId != localPeerId && online.contains(m.peerId));
        final isCustomRelay =
            ref.watch(relayDomainProvider) != kDefaultRelayDomain;
        final ConnectionStage stage;
        if (!amOnline) {
          stage = ConnectionStage.offline;
        } else if (anyOnline) {
          stage = ConnectionStage.encrypted;
        } else if (isCustomRelay) {
          stage = ConnectionStage.customNetwork;
        } else {
          stage = ConnectionStage.alone;
        }
        return ConnectionProgress(
          key: ValueKey('mob-chan-conn-$serverId-${stage.index}'),
          stage: stage,
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

class _MobileInputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback? onMic;
  final VoidCallback onEmoji;
  final ValueChanged<String> onChanged;
  final bool hasStagedFile;

  const _MobileInputBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onAttach,
    this.onMic,
    required this.onEmoji,
    required this.onChanged,
    this.hasStagedFile = false,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(top: BorderSide(color: hollow.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // One attach button rather than two icons, which crowd the row on a
          // small phone.
          HollowPressable(
            onTap: onAttach,
            semanticLabel: 'Attach photo or file',
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            padding: const EdgeInsets.all(HollowSpacing.sm),
            child: Icon(LucideIcons.plus, color: hollow.textSecondary, size: 24),
          ),
          const SizedBox(width: HollowSpacing.xs),
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 120),
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                maxLines: 5,
                minLines: 1,
                textInputAction: TextInputAction.newline,
                style: HollowTypography.body.copyWith(color: hollow.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Type a message...',
                  hintStyle: HollowTypography.body.copyWith(color: hollow.textSecondary),
                  filled: true,
                  fillColor: hollow.background,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.md,
                    vertical: HollowSpacing.md,
                  ),
                  // Inside the field, so the row has room for the text field to
                  // breathe.
                  suffixIcon: HollowPressable(
                    onTap: onEmoji,
                    semanticLabel: 'Emoji',
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                    padding: const EdgeInsets.all(HollowSpacing.sm),
                    child: Icon(LucideIcons.smile,
                        color: hollow.textSecondary, size: 22),
                  ),
                  suffixIconConstraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(hollow.radiusXl),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: onChanged,
              ),
            ),
          ),
          const SizedBox(width: HollowSpacing.xs),
          HollowPressable(
            onTap: onMic,
            semanticLabel: 'Record voice message',
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            padding: const EdgeInsets.all(HollowSpacing.sm),
            child: Icon(
              LucideIcons.mic,
              color: onMic != null
                  ? hollow.textSecondary
                  : hollow.textSecondary.withValues(alpha: 0.3),
              size: 22,
            ),
          ),
          const SizedBox(width: HollowSpacing.xs),
          HollowPressable(
            onTap: onSend,
            semanticLabel: 'Send',
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            backgroundColor: hollow.accent,
            padding: const EdgeInsets.all(HollowSpacing.sm + 2),
            child: Icon(LucideIcons.send, color: hollow.textOnAccent, size: 20),
          ),
        ],
      ),
    );
  }
}

class _DmMuteButton extends ConsumerWidget {
  final String peerId;
  const _DmMuteButton({required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final enabled = ref.watch(notificationSettingsProvider
        .select((s) => s.isDmEnabled(peerId)));
    return HollowPressable(
      onTap: () {
        ref.read(notificationSettingsProvider.notifier)
            .setDmEnabled(peerId, !enabled);
        HollowToast.show(
          context,
          enabled ? 'Notifications muted' : 'Notifications unmuted',
          type: HollowToastType.info,
        );
      },
      semanticLabel: enabled ? 'Mute notifications' : 'Unmute notifications',
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.all(HollowSpacing.sm),
      child: Icon(
        enabled ? LucideIcons.bell : LucideIcons.bellOff,
        size: 20,
        color: enabled
            ? hollow.textSecondary
            : hollow.textSecondary.withValues(alpha: 0.4),
      ),
    );
  }
}

class _DmCallButtons extends ConsumerWidget {
  final String peerId;
  const _DmCallButtons({required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final isOnline = identityIsOnline(ref, peerId);
    final call = ref.watch(callProvider);
    final isInCall = call.status != CallStatus.idle;
    final isCallWithThisPeer = isInCall && call.peerId == peerId;
    final canCall = isOnline && !isInCall;

    Future<void> startAndOpen({bool withVideo = false}) async {
      // Starting a DM call disconnects a server voice channel, so it is
      // confirmed first (issue #49).
      final vc = ref.read(voiceChannelProvider);
      if (vc.isInVoiceChannel) {
        final channelName = vc.currentChannelName ?? 'voice';
        final confirmed = await showHollowDialog<bool>(
          context: context,
          builder: (ctx) {
            final h = HollowTheme.of(ctx);
            return HollowDialog(
              title: 'Start Call?',
              content: Text(
                'Starting this call will disconnect you from #$channelName.',
                style: HollowTypography.body.copyWith(color: h.textSecondary),
              ),
              actions: [
                HollowButton.ghost(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                HollowButton.filled(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Start Call'),
                ),
              ],
            );
          },
        );
        if (confirmed != true || !context.mounted) return;
      }
      await ref
          .read(callProvider.notifier)
          .startCall(peerId, withVideo: withVideo);
      if (!context.mounted) return;
      Navigator.of(context).push(
        hollowMobileRoute(
          settings: const RouteSettings(name: 'call-screen'),
          transition: HollowRouteTransition.slideUp,
          builder: (_) => MobileCallScreen(peerId: peerId),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HollowPressable(
          onTap: canCall
              ? () => startAndOpen()
              : isCallWithThisPeer
                  ? () => Navigator.of(context).push(
                        hollowMobileRoute(
                          settings:
                              const RouteSettings(name: 'call-screen'),
                          transition: HollowRouteTransition.slideUp,
                          builder: (_) => MobileCallScreen(peerId: peerId),
                        ),
                      )
                  : null,
          semanticLabel: 'Voice call',
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: const EdgeInsets.all(HollowSpacing.sm),
          child: Icon(
            isCallWithThisPeer ? LucideIcons.phoneCall : LucideIcons.phone,
            size: 20,
            color: isCallWithThisPeer
                ? hollow.success
                : canCall
                    ? hollow.textSecondary
                    : hollow.textSecondary.withValues(alpha: 0.3),
          ),
        ),
        HollowPressable(
          onTap: canCall
              ? () => startAndOpen(withVideo: true)
              : null,
          semanticLabel: 'Video call',
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: const EdgeInsets.all(HollowSpacing.sm),
          child: Icon(
            LucideIcons.video,
            size: 20,
            color: canCall
                ? hollow.textSecondary
                : hollow.textSecondary.withValues(alpha: 0.3),
          ),
        ),
      ],
    );
  }
}

class _TypingBar extends ConsumerWidget {
  final String contextKey;

  const _TypingBar({required this.contextKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typingPeers = ref.watch(typingProvider)[contextKey] ?? {};
    if (typingPeers.isEmpty) return const SizedBox.shrink();

    // Collapses devices to their master and excludes every device of ours; see
    // [typingMastersFor].
    final masters = typingMastersFor(ref, typingPeers);
    final profiles = ref.watch(profileProvider);
    final names = masters
        .map((master) => displayNameFor(profiles, master))
        .toSet()
        .toList();
    if (names.isEmpty) return const SizedBox.shrink();

    return TypingIndicatorBar(names: names);
  }
}

// The green strip shown cross-server while in a voice channel.

class _VoiceChannelStatusStrip extends ConsumerWidget {
  const _VoiceChannelStatusStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vcState = ref.watch(voiceChannelProvider);
    if (!vcState.isInVoiceChannel) return const SizedBox.shrink();

    final hollow = HollowTheme.of(context);
    final channelName = vcState.currentChannelName ?? 'Voice Channel';

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          hollowMobileRoute(
            transition: HollowRouteTransition.slideUp,
            builder: (_) => MobileVoiceChannelRoute(
              serverId: vcState.currentServerId!,
              channelId: vcState.currentChannelId!,
              channelName: channelName,
            ),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: hollow.success.withValues(alpha: 0.1),
          border: Border(
            bottom: BorderSide(
              color: hollow.success.withValues(alpha: 0.3),
            ),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: hollow.success,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Text(
                'In voice: #$channelName',
                style: HollowTypography.caption.copyWith(
                  color: hollow.success,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              'Tap to return',
              style: HollowTypography.caption.copyWith(
                color: hollow.success.withValues(alpha: 0.7),
                fontSize: 11,
              ),
            ),
            const SizedBox(width: HollowSpacing.xs),
            Icon(
              LucideIcons.chevronUp,
              size: 14,
              color: hollow.success.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single @mention autocomplete candidate (server member or @everyone).
class _MobileMentionCandidate {
  final String peerId; // empty for @everyone
  final String displayName;
  const _MobileMentionCandidate({
    required this.peerId,
    required this.displayName,
  });
}

