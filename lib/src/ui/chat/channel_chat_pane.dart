import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart' show generateMessageId;
import 'package:hollow/src/core/providers/download_manager_provider.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
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
import 'package:hollow/src/ui/chat/chat_pane.dart';
import 'package:hollow/src/ui/chat/message_action_bar.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/connection_progress.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/chat/staged_hollow_link_card.dart';
import 'package:hollow/src/ui/chat/staged_link_preview_card.dart';
import 'package:hollow/src/ui/chat/voice_recorder_bar.dart';
import 'package:hollow/src/core/services/voice_message_recorder.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:lucide_icons/lucide_icons.dart';
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

  final _controller = TextEditingController();
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

  String get _stateKey => '${widget.serverId}:${widget.channelId}';


  @override
  void initState() {
    super.initState();
    // Close search bar when (re-)entering a channel — cannot reset in dispose
    // because Riverpod forbids all ref usage once the element is unmounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(channelSearchOpenProvider.notifier).state = false;
      }
    });
    _loadHistory();
    _itemPositionsListener.itemPositions.addListener(_onScrollPositionChanged);
  }

  void _onScrollPositionChanged() {
    final nearBottom = _isNearBottom;
    if (_showScrollPill == nearBottom) {
      setState(() => _showScrollPill = !nearBottom);
    }
    ref.read(chatAtBottomProvider.notifier).state = nearBottom;
    // Auto-mark as read when user scrolls back to bottom.
    if (nearBottom) {
      final msgs = ref.read(channelChatProvider)[_stateKey];
      if (msgs != null && msgs.isNotEmpty) {
        ref.read(unreadProvider.notifier).markChannelSeen(
              widget.serverId, widget.channelId, msgs.last.messageId);
      }
    }
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
  }

  @override
  void dispose() {
    _dismissMentionOverlay();
    _urlDebounce?.cancel();
    _itemPositionsListener.itemPositions.removeListener(_onScrollPositionChanged);
    _controller.dispose();
    _focusNode.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  bool get _isNearBottom {
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return true;
    final messages = ref.read(channelChatProvider)[_stateKey] ?? [];
    if (messages.isEmpty) return true;
    // Strictly at bottom: sentinel (one past last message) visible.
    return positions.any((p) => p.index >= messages.length - 1);
  }

  /// Auto-scroll capture zone: a bit more forgiving than `_isNearBottom`.
  /// If any of the last ~3 messages are visible we treat the user as
  /// "following along" and auto-scroll on new messages. Outside this
  /// zone the unread pill takes over.
  bool get _isInAutoScrollZone {
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return true;
    final messages = ref.read(channelChatProvider)[_stateKey] ?? [];
    if (messages.isEmpty) return true;
    final threshold = messages.length - 3;
    return positions.any((p) => p.index >= threshold);
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScrollController.isAttached) return;
      final messages = ref.read(channelChatProvider)[_stateKey] ?? [];
      if (messages.isEmpty) return;
      _itemScrollController.jumpTo(index: messages.length, alignment: 1.0);
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScrollController.isAttached) return;
      _scrollOffsetController.animateScroll(
        offset: 100000,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  void _scrollToMessage(int index) {
    if (!_itemScrollController.isAttached) return;
    setState(() => _highlightIndex = index);
    _itemScrollController.scrollTo(
      index: index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: 0.3,
    );
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightIndex = null);
    });
  }

  void _showPinnedMessages(
    BuildContext context,
    HollowTheme hollow,
    List<String> pinnedIds,
  ) {
    final messages = ref.read(channelChatProvider)[_stateKey] ?? [];
    final pinnedMessages = pinnedIds
        .map((id) => messages.where((m) => m.messageId == id).firstOrNull)
        .where((m) => m != null)
        .toList()
      ..sort((a, b) => b!.timestamp.compareTo(a!.timestamp));

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
                      itemBuilder: (_, index) {
                        final msg = pinnedMessages[index]!;
                        final profiles = ref.read(profileProvider);
                        final nicknames =
                            ref.read(serverNicknamesProvider(widget.serverId));
                        final name = serverDisplayNameFor(
                          profiles,
                          msg.senderId,
                          nickname: nicknames[msg.senderId] ?? '',
                        );
                        final time =
                            '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}';

                        // Date separator between pinned messages on different days.
                        final showDate = shouldShowDateSeparator(
                          msg.timestamp,
                          index > 0 ? pinnedMessages[index - 1]!.timestamp : null,
                        );

                        final msgWidget = Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: HollowSpacing.xs),
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
                                      color: hollow.textSecondary
                                          .withValues(alpha: 0.5),
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              if (msg.fileAttachment != null) ...[
                                if (msg.fileAttachment!.isImage &&
                                    msg.fileAttachment!.diskPath != null &&
                                    File(msg.fileAttachment!.diskPath!).existsSync())
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                                    child: msg.fileAttachment!.diskPath!.toLowerCase().endsWith('.gif')
                                        ? GifFileImage(
                                            diskPath: msg.fileAttachment!.diskPath!,
                                            height: 80,
                                            fit: BoxFit.cover,
                                          )
                                        : Image.file(
                                            File(msg.fileAttachment!.diskPath!),
                                            height: 80,
                                            fit: BoxFit.cover,
                                          ),
                                  )
                                else
                                  Text(
                                    msg.fileAttachment!.isImage ? '📷 Image' : '📎 ${msg.fileAttachment!.fileName}',
                                    style: HollowTypography.body.copyWith(
                                      color: hollow.textSecondary,
                                    ),
                                  ),
                              ] else
                              Text(
                                msg.text.startsWith('[file:') ? '📎 File' : msg.text,
                                style: HollowTypography.body.copyWith(
                                  color: hollow.textPrimary,
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
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
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
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
    try {
      network_api.sendTypingIndicator(
        serverId: widget.serverId,
        channelId: widget.channelId,
      );
    } catch (_) {}
  }

  void _updateMentionAutocomplete(String text) {
    final cursor = _controller.selection.baseOffset;
    if (cursor < 0) {
      _dismissMentionOverlay();
      return;
    }

    // Scan backward from cursor to find '@' preceded by space/newline/start.
    int atPos = -1;
    for (int i = cursor - 1; i >= 0; i--) {
      final c = text[i];
      if (c == '@') {
        if (i == 0 || text[i - 1] == ' ' || text[i - 1] == '\n') {
          atPos = i;
        }
        break;
      }
      if (c == ' ' || c == '\n') break;
    }

    if (atPos < 0) {
      _dismissMentionOverlay();
      return;
    }

    final query = text.substring(atPos + 1, cursor).toLowerCase();
    _mentionAtPosition = atPos;

    // Build candidates from server members.
    final membersAsync = ref.read(serverMembersProvider(widget.serverId));
    final profiles = ref.read(profileProvider);
    final nicknames = ref.read(serverNicknamesProvider(widget.serverId));
    final candidates = <_MentionCandidate>[];

    membersAsync.whenData((members) {
      for (final m in members) {
        final displayName = serverDisplayNameFor(
          profiles, m.peerId, nickname: nicknames[m.peerId] ?? '',
        );
        final serverNick = nicknames[m.peerId] ?? '';
        final profileName = profiles[m.peerId]?.displayName ?? '';

        final matchesDisplay =
            displayName.toLowerCase().startsWith(query);
        final matchesNick = serverNick.isNotEmpty &&
            serverNick.toLowerCase().startsWith(query);
        final matchesProfile = profileName.isNotEmpty &&
            profileName.toLowerCase().startsWith(query);

        if (query.isEmpty || matchesDisplay || matchesNick || matchesProfile) {
          final avatar = profiles[m.peerId]?.avatarBytes;
          candidates.add(_MentionCandidate(
            peerId: m.peerId,
            displayName: displayName,
            subtitle: serverNick.isNotEmpty && serverNick != displayName
                ? profileName.isNotEmpty ? profileName : null
                : serverNick.isNotEmpty ? serverNick : null,
            avatarBytes: avatar,
          ));
        }
      }
    });

    // Also add @everyone.
    if (query.isEmpty || 'everyone'.startsWith(query)) {
      candidates.insert(0, _MentionCandidate(
        peerId: '',
        displayName: 'everyone',
        subtitle: 'Notify all members',
        avatarBytes: null,
      ));
    }

    if (candidates.isEmpty) {
      _dismissMentionOverlay();
      return;
    }

    _mentionCandidates = candidates.take(6).toList();
    _mentionSelectedIndex = _mentionSelectedIndex.clamp(
        0, _mentionCandidates.length - 1);
    _showMentionOverlay();
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
                    backgroundColor: selected
                        ? hollow.accent.withValues(alpha: 0.15)
                        : Colors.transparent,
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
                            imageBytes: c.avatarBytes,
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

  Future<void> _handleSend() async {
    _dismissMentionOverlay();
    // If a file is staged, send it (with optional text).
    if (_stagedFilePath != null) {
      await _sendStagedFile();
      return;
    }
    final text = _controller.text.trim();
    if (text.isEmpty) return;
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
    await ref
        .read(channelChatProvider.notifier)
        .sendMessage(widget.serverId, widget.channelId, text,
            replyToMid: replyMid, linkPreview: preview);
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
    if (!mounted) return;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
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
      final result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.isEmpty) { _isPicking = false; return; }
      final file = result.files.first;
      if (file.path == null) { _isPicking = false; return; }

      final ext = file.name.contains('.')
          ? file.name.split('.').last.toLowerCase()
          : '';
      setState(() {
        _stagedFilePath = file.path!;
        _stagedFileName = file.name;
        _stagedFileIsImage = ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'].contains(ext);
      });
      _focusNode.requestFocus();
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
    const maxBytes = 34 * 1024 * 1024;
    if (size > maxBytes) {
      if (mounted) {
        final fileMb = (size / (1024 * 1024)).toStringAsFixed(1);
        HollowToast.show(
          context,
          'Voice message too large (${fileMb}MB). Limit is 34 MB.',
          type: HollowToastType.error,
          duration: const Duration(seconds: 4),
        );
      }
      try { await file.delete(); } catch (_) {}
      setState(() => _isRecordingVoice = false);
      return;
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

    final messageText = _controller.text.trim();
    final messageId = generateMessageId();
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';
    final isImage = _stagedFileIsImage;

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
          ? attachment.fileName.substring(0, attachment.fileName.lastIndexOf('.'))
          : attachment.fileName;

      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save file',
        fileName: isImage ? (isGif ? '$baseName.gif' : '$baseName.png') : attachment.fileName,
        type: FileType.custom,
        allowedExtensions: allowedExtensions,
      );
      if (savePath == null || attachment.diskPath == null) return;

      final targetExt = savePath.contains('.')
          ? savePath.split('.').last.toLowerCase()
          : attachment.fileExt;

      if (isImage && targetExt != 'webp' && attachment.fileExt == 'webp') {
        final converted = await network_api.convertImageFormat(
          sourcePath: attachment.diskPath!,
          targetFormat: targetExt,
        );
        await File(savePath).writeAsBytes(converted);
      } else {
        await File(attachment.diskPath!).copy(savePath);
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

      // 1. Trigger vault download for the underlying video.
      final cachedPath = await crdt_api.vaultDownloadFile(
        serverId: widget.serverId,
        contentId: vthumb.cid,
      );

      if (cachedPath.isNotEmpty) {
        // Cache hit — open Save As immediately.
        if (mounted) {
          await _saveCacheFileWithName(
            cachePath: cachedPath,
            saveFileName: vthumb.name,
            fileExt: vthumb.ext,
          );
        }
        return;
      }

      // 2. Async reconstruction in flight — wait up to 60 seconds for
      // VaultDownloadComplete (lands in fileTransferProvider keyed by contentId).
      for (int i = 0; i < 120; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        final transfers = ref.read(fileTransferProvider);
        final match = transfers.values.where(
          (t) => t.contentId == vthumb.cid && t.diskPath != null && t.diskPath!.isNotEmpty,
        );
        if (match.isNotEmpty) {
          await _saveCacheFileWithName(
            cachePath: match.first.diskPath!,
            saveFileName: vthumb.name,
            fileExt: vthumb.ext,
          );
          return;
        }
      }
      if (mounted) {
        HollowToast.show(context, 'Download timed out — not enough peers online',
            type: HollowToastType.error);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Download failed: $e',
            type: HollowToastType.error);
      }
    }
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
      // 1. Look up vault content_id for this file.
      final contentId = await storage_api.getContentIdForFile(fileId: attachment.fileId);
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

      // 2. Trigger vault download (shard reconstruction).
      final cachedPath = await crdt_api.vaultDownloadFile(
        serverId: widget.serverId,
        contentId: contentId,
      );

      if (cachedPath.isNotEmpty) {
        // Cache hit — file already reconstructed. Open Save As immediately.
        if (mounted) {
          _saveFileFromCachePath(cachedPath, attachment);
        }
      } else {
        // Async reconstruction started — wait for VaultDownloadComplete event.
        // Poll fileTransferProvider for completion (up to 60 seconds).
        for (int i = 0; i < 120; i++) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (!mounted) return;
          final transfers = ref.read(fileTransferProvider);
          // Find any transfer with matching contentId and a diskPath.
          final match = transfers.values.where(
            (t) => t.contentId == contentId && t.diskPath != null && t.diskPath!.isNotEmpty,
          );
          if (match.isNotEmpty) {
            _saveFileFromCachePath(match.first.diskPath!, attachment);
            return;
          }
        }
        if (mounted) {
          HollowToast.show(context, 'Download timed out — not enough peers online',
              type: HollowToastType.error);
        }
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Download failed: $e',
            type: HollowToastType.error);
      }
    }
  }

  /// Open Save As dialog for a file at the given cache path.
  Future<void> _saveFileFromCachePath(String cachePath, FileAttachment attachment) async {
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
          sourcePath: cachePath,
          targetFormat: targetExt,
        );
        await File(savePath).writeAsBytes(converted);
      } else {
        await File(cachePath).copy(savePath);
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

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final chatState = ref.watch(channelChatProvider);
    final messages = chatState[_stateKey] ?? [];

    // If cache was cleared by sync (clearServerCache) and we have no messages,
    // reload from DB. This catches the case where sync completed while we
    // weren't viewing, cache was cleared, and now we need fresh data.
    if (messages.isEmpty && _historyLoaded && !_loadingHistory) {
      _historyLoaded = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadHistory();
      });
    }

    // Auto-scroll on new messages if the user is in the bottom capture zone.
    // Outside the zone (scrolled up meaningfully), the unread pill takes over.
    ref.listen<Map<String, List<ChannelChatMessage>>>(channelChatProvider,
        (prev, next) {
      final prevLen = (prev?[_stateKey] ?? const []).length;
      final nextLen = (next[_stateKey] ?? const []).length;
      if (nextLen > prevLen && _isInAutoScrollZone) {
        _scrollToBottom();
      }
    });

    // Focus search field when opened via global shortcut (Ctrl+K).
    ref.listen(channelSearchOpenProvider, (prev, next) {
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
    });

    final typingPeers = ref.watch(typingProvider)[_stateKey] ?? {};
    final profiles = ref.watch(profileProvider);
    final nicknames = ref.watch(serverNicknamesProvider(widget.serverId));

    return ChatDropZone(
      onFileDropped: _handleDroppedFile,
      child: Column(
      children: [
        // Channel header
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
          decoration: BoxDecoration(
            color: hollow.surface,
            border: Border(bottom: BorderSide(color: hollow.border)),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.hash, size: 20, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                widget.channelName,
                style: HollowTypography.subheading.copyWith(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: HollowSpacing.md),
              _ChannelConnectionStatus(
                serverId: widget.serverId,
                channelId: widget.channelId,
              ),
              const Spacer(),
              Builder(builder: (context) {
                final pinKey = '${widget.serverId}:${widget.channelId}';
                final pinnedIds = ref.watch(pinnedProvider)[pinKey] ?? [];
                if (pinnedIds.isEmpty) return const SizedBox.shrink();
                return HollowTooltip(
                  message: '${pinnedIds.length} pinned message${pinnedIds.length == 1 ? '' : 's'}',
                  child: HollowPressable(
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
              }),
              const SizedBox(width: HollowSpacing.sm),
              HollowTooltip(
                message: 'Search messages',
                child: HollowPressable(
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
                    color: ref.watch(channelSearchOpenProvider) ? hollow.accent : hollow.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowTooltip(
                message: 'Toggle member panel',
                child: HollowPressable(
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
              // Split view toggle (dock mode only)
              if ((ref.watch(layoutModeProvider).valueOrNull ?? LayoutMode.dock) == LayoutMode.dock) ...[
                const SizedBox(width: HollowSpacing.sm),
                HollowTooltip(
                  message: ref.watch(splitViewProvider).isSplit
                      ? 'Close this pane'
                      : 'Split view',
                  child: HollowPressable(
                    onTap: () => _handleSplitToggle(ref),
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    child: Icon(
                      LucideIcons.columns,
                      size: 18,
                      color: ref.watch(splitViewProvider).isSplit
                          ? hollow.accent
                          : hollow.textSecondary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),

        // Search bar
        if (ref.watch(channelSearchOpenProvider))
          Container(
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
                  prefixIcon: Icon(LucideIcons.search, size: 16),
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
                      itemBuilder: (_, index) {
                        final msg = _searchResults[index];
                        final profiles = ref.watch(profileProvider);
                        final nicknames = ref.watch(
                            serverNicknamesProvider(widget.serverId));
                        final name = serverDisplayNameFor(
                          profiles,
                          msg.senderId,
                          nickname: nicknames[msg.senderId] ?? '',
                        );
                        final time = DateTime.fromMillisecondsSinceEpoch(
                            msg.timestamp);
                        final timeStr =
                            '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
                        return Padding(
                          padding: const EdgeInsets.only(
                              top: HollowSpacing.xs),
                          child: HollowPressable(
                            subtle: true,
                            onTap: () {
                              // Scroll to the matched message in the list.
                              final messages = ref.read(channelChatProvider)[_stateKey] ?? [];
                              final idx = messages.indexWhere(
                                  (m) => m.messageId == msg.messageId);
                              ref.read(channelSearchOpenProvider.notifier).state = false;
                              setState(() {
                                _searchController.clear();
                                _searchResults = [];
                              });
                              if (idx != -1) _scrollToMessage(idx);
                            },
                            borderRadius:
                                BorderRadius.circular(hollow.radiusSm),
                            hoverColor: hollow.elevated,
                            padding: const EdgeInsets.symmetric(
                              horizontal: HollowSpacing.sm,
                              vertical: HollowSpacing.xs,
                            ),
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      name,
                                      style: HollowTypography.caption
                                          .copyWith(
                                        color: hollow.accent,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 11,
                                      ),
                                    ),
                                    const SizedBox(
                                        width: HollowSpacing.sm),
                                    Text(
                                      timeStr,
                                      style: HollowTypography.caption
                                          .copyWith(
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
          ),

        // Messages list + unread pill overlay
        if ((ref.watch(myPermissionsProvider(widget.serverId)).valueOrNull ?? Permission.all) & Permission.readMessages == 0)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.eyeOff, size: 48, color: hollow.textSecondary.withValues(alpha: 0.3)),
                  const SizedBox(height: HollowSpacing.md),
                  Text(
                    'You don\'t have permission to read messages in this channel',
                    style: HollowTypography.body.copyWith(color: hollow.textSecondary),
                  ),
                ],
              ),
            ),
          )
        else
        Expanded(
          child: Stack(
            children: [
          MessageActionBarScope(
          child: Builder(builder: (scopeContext) =>
          NotificationListener<ScrollNotification>(
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
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              LucideIcons.hash,
                              size: 64,
                              color:
                                  hollow.textSecondary.withValues(alpha: 0.3),
                            ),
                            const SizedBox(height: HollowSpacing.lg),
                            Text(
                              'Welcome to #${widget.channelName}',
                              style: HollowTypography.heading
                                  .copyWith(color: hollow.textPrimary),
                            ),
                            const SizedBox(height: HollowSpacing.sm),
                            Text(
                              'This is the beginning of the channel.',
                              style: HollowTypography.body
                                  .copyWith(color: hollow.textSecondary),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink())
                : SelectionArea(
                  contextMenuBuilder: (_, __) => const SizedBox.shrink(),
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context)
                        .copyWith(scrollbars: false),
                    child: ScrollablePositionedList.builder(
                    key: ValueKey('ch-list-${widget.serverId}-${widget.channelId}'),
                    itemScrollController: _itemScrollController,
                    itemPositionsListener: _itemPositionsListener,
                    scrollOffsetController: _scrollOffsetController,
                    initialScrollIndex: messages.length,
                    initialAlignment: 1.0,
                    padding: const EdgeInsets.symmetric(
                      vertical: HollowSpacing.sm,
                    ),
                    itemCount: messages.length + 1,
                    itemBuilder: (context, index) {
                      // Sentinel item at the end for bottom anchoring.
                      if (index >= messages.length) {
                        return const SizedBox.shrink();
                      }
                      final msg = messages[index];
                      // Grouping: compare with the previous message in chronological order.
                      final showHeader = index == 0 ||
                          !shouldGroup(
                            currentIsMe: msg.isMe,
                            previousIsMe: messages[index - 1].isMe,
                            currentTime: msg.timestamp,
                            previousTime: messages[index - 1].timestamp,
                            currentSenderId: msg.senderId,
                            previousSenderId: messages[index - 1].senderId,
                          );
                      final wrapper = MessageHoverWrapper(
                        isMe: msg.isMe,
                        messageId: msg.messageId,
                        currentText: msg.text,
                        isEditing: _editingMessageId != null &&
                            _editingMessageId == msg.messageId,
                        onEditStart: msg.messageId != null && msg.isMe && msg.fileAttachment == null
                            ? () => setState(() =>
                                _editingMessageId = msg.messageId)
                            : null,
                        onEditSubmit: (newText) {
                          setState(() => _editingMessageId = null);
                          ref
                              .read(channelChatProvider.notifier)
                              .editMessage(widget.serverId, widget.channelId,
                                  msg.messageId!, newText);
                        },
                        onEditCancel: () =>
                            setState(() => _editingMessageId = null),
                        onDelete: msg.messageId != null && msg.isMe
                            ? () => ref
                                .read(channelChatProvider.notifier)
                                .deleteMessage(widget.serverId,
                                    widget.channelId, msg.messageId!)
                            : null,
                        onReply: msg.messageId != null
                            ? () {
                                final senderName = serverDisplayNameFor(
                                  profiles,
                                  msg.senderId,
                                  nickname: nicknames[msg.senderId] ?? '',
                                );
                                setState(() {
                                  _replyToMessageId = msg.messageId;
                                  _replyToText = msg.fileAttachment != null
                                      ? (msg.fileAttachment!.isImage ? '📷 Image' : '📎 ${msg.fileAttachment!.fileName}')
                                      : msg.text;
                                  _replyToSenderName = senderName;
                                  _replyToImagePath = msg.fileAttachment?.isImage == true
                                      ? msg.fileAttachment?.diskPath
                                      : null;
                                });
                                _focusNode.requestFocus();
                              }
                            : null,
                        onReaction: msg.messageId != null
                            ? (emoji) {
                                final localPeerId =
                                    ref.read(identityProvider).peerId ?? '';
                                final hasReacted =
                                    msg.reactions[emoji]?.contains(localPeerId) ?? false;
                                final notifier = ref.read(channelChatProvider.notifier);
                                if (hasReacted) {
                                  notifier.removeReaction(widget.serverId,
                                      widget.channelId, msg.messageId!, emoji);
                                } else {
                                  notifier.addReaction(widget.serverId,
                                      widget.channelId, msg.messageId!, emoji);
                                }
                              }
                            : null,
                        onPin: msg.messageId != null &&
                                (ref.watch(myPermissionsProvider(widget.serverId)).whenOrNull(
                                    data: (perms) => (perms & Permission.manageChannels) != 0) ?? false)
                            ? () {
                                final pins = ref.read(pinnedProvider)[
                                    '${widget.serverId}:${widget.channelId}'] ?? [];
                                if (pins.contains(msg.messageId)) {
                                  crdt_api.unpinMessage(
                                    serverId: widget.serverId,
                                    channelId: widget.channelId,
                                    messageId: msg.messageId!,
                                  );
                                } else {
                                  crdt_api.pinMessage(
                                    serverId: widget.serverId,
                                    channelId: widget.channelId,
                                    messageId: msg.messageId!,
                                  );
                                }
                              }
                            : null,
                        onDownload: msg.fileAttachment != null
                            ? () {
                                // Don't trigger duplicate downloads during active transfer.
                                final transfer = ref.read(fileTransferProvider)[msg.fileAttachment!.fileId];
                                if (transfer != null && transfer.isDownloading) {
                                  HollowToast.show(context, 'File is already downloading...', type: HollowToastType.info);
                                  return;
                                }

                                // Phase 6.75 video preview: if this is a vault video
                                // thumbnail, save the underlying VIDEO (not the thumbnail
                                // .webp). The link lives in `videoThumb.cid` — fetch from
                                // the vault and save with the original video filename.
                                if (msg.fileAttachment!.videoThumb != null) {
                                  _vaultDownloadAndSaveVideo(msg.fileAttachment!);
                                } else if (msg.fileAttachment!.diskPath != null) {
                                  _saveFile(msg.fileAttachment!);
                                } else {
                                  // For <6 member servers (full replication), request file from
                                  // the sender via P2P stream. For 6+ members, use vault download.
                                  final memberCount = ref.read(serverMembersProvider(widget.serverId)).valueOrNull?.length ?? 0;
                                  if (memberCount >= 6) {
                                    _vaultDownloadAndSave(msg.fileAttachment!);
                                  } else {
                                    _requestFileFromPeer(msg.fileAttachment!, msg.senderId);
                                  }
                                }
                              }
                            : null,
                        onCopy: (msg.text.isNotEmpty && !msg.text.startsWith('[file:'))
                            ? () {
                                Clipboard.setData(ClipboardData(text: msg.text));
                                HollowToast.show(context, 'Copied to clipboard', type: HollowToastType.success);
                              }
                            : null,
                        onCopyImage: (msg.fileAttachment != null &&
                                msg.fileAttachment!.diskPath != null &&
                                msg.fileAttachment!.isImage)
                            ? () async {
                                final ok = await copyImageToClipboard(msg.fileAttachment!.diskPath!);
                                if (mounted) {
                                  HollowToast.show(
                                    context,
                                    ok ? 'Image copied to clipboard' : 'Failed to copy image',
                                    type: ok ? HollowToastType.success : HollowToastType.error,
                                  );
                                }
                              }
                            : null,
                        onInfo: () {
                          final localPeerId =
                              ref.read(identityProvider).peerId ?? '';
                          final senderPeerId =
                              msg.isMe ? localPeerId : msg.senderId;
                          showMessageProofDialog(
                            context,
                            MessageProofData(
                              senderPeerId: senderPeerId,
                              senderDisplayName: serverDisplayNameFor(
                                profiles,
                                senderPeerId,
                                nickname: nicknames[senderPeerId] ?? '',
                              ),
                              senderAvatar:
                                  profiles[senderPeerId]?.avatarBytes,
                              text: msg.text,
                              // If the message has been edited, the signature
                              // was computed over the edit timestamp + new text
                              // — use editedAt to reconstruct the canonical
                              // payload.
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
                        },
                        child: Builder(builder: (_) {
                          final localPeerId =
                              ref.watch(identityProvider).peerId ?? '';
                          String? replySender;
                          String? replyText;
                          String? replyImagePath;
                          int? replyIndex;
                          if (msg.replyToMid != null) {
                            final idx = messages.indexWhere(
                                (m) => m.messageId == msg.replyToMid);
                            if (idx != -1) {
                              replyIndex = idx;
                              final original = messages[idx];
                              replyText = original.fileAttachment != null
                                  ? (original.fileAttachment!.isImage ? '📷 Image' : '📎 ${original.fileAttachment!.fileName}')
                                  : original.text;
                              replySender = serverDisplayNameFor(
                                profiles,
                                original.senderId,
                                nickname: nicknames[original.senderId] ?? '',
                              );
                              if (original.fileAttachment?.isImage == true) {
                                replyImagePath = original.fileAttachment?.diskPath;
                              }
                            }
                          }
                          // Check if this message mentions the local user.
                          final localName = displayNameFor(
                              ref.read(profileProvider), localPeerId);
                          final localNick = ref.read(
                              serverNicknamesProvider(widget.serverId))[localPeerId];
                          final msgMentioned = msg.text.contains('@everyone') ||
                              msg.text.contains('@$localName') ||
                              (localNick != null &&
                                  localNick.isNotEmpty &&
                                  msg.text.contains('@$localNick'));
                          return ChannelMessageBubble(
                            message: msg,
                            serverId: widget.serverId,
                            showHeader: showHeader,
                            replyToSenderName: replySender,
                            replyToText: replyText,
                            replyToImagePath: replyImagePath,
                            isHighlighted: _highlightIndex == index,
                            isMentioned: msgMentioned,
                            onReplyTap: replyIndex != null
                                ? () => _scrollToMessage(replyIndex!)
                                : null,
                            onToggleReaction: msg.messageId != null
                                ? (emoji) {
                                    final hasReacted =
                                        msg.reactions[emoji]?.contains(localPeerId) ?? false;
                                    final notifier = ref.read(channelChatProvider.notifier);
                                    if (hasReacted) {
                                      notifier.removeReaction(widget.serverId,
                                          widget.channelId, msg.messageId!, emoji);
                                    } else {
                                      notifier.addReaction(widget.serverId,
                                          widget.channelId, msg.messageId!, emoji);
                                    }
                                  }
                                : null,
                          );
                        }),
                      );
                      final showDate = shouldShowDateSeparator(
                        msg.timestamp,
                        index > 0 ? messages[index - 1].timestamp : null,
                      );

                      final messageWidget = showHeader
                          ? Padding(
                              padding: const EdgeInsets.only(top: HollowSpacing.sm + 2),
                              child: wrapper,
                            )
                          : wrapper;

                      if (showDate) {
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DateSeparator(date: msg.timestamp),
                            messageWidget,
                          ],
                        );
                      }
                      return messageWidget;
                    },
                  ),
                  ),
                  ),
          ),
          ),
          ),
          ),
              // Unread pill — only when new messages arrived while scrolled up
              Builder(builder: (context) {
                final unreadState = ref.watch(unreadProvider);
                final unreadCount = unreadState
                    .channelUnreadCounts['${widget.serverId}:${widget.channelId}'] ?? 0;
                if (unreadCount > 0 && _showScrollPill) {
                  return Positioned(
                    bottom: HollowSpacing.md,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: _UnreadPill(
                        count: unreadCount,
                        onTap: () {
                          _scrollToBottom();
                          ref.read(unreadProvider.notifier).markChannelSeen(
                                widget.serverId,
                                widget.channelId,
                                messages.last.messageId,
                              );
                        },
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              }),
            ],
          ),
        ),

        // Typing indicator
        if (typingPeers.isNotEmpty)
          TypingIndicatorBar(
            names: typingPeers
                .map((pid) {
                  final nicknames =
                      ref.watch(serverNicknamesProvider(widget.serverId));
                  return serverDisplayNameFor(
                    ref.watch(profileProvider),
                    pid,
                    nickname: nicknames[pid] ?? '',
                  );
                })
                .toList(),
          ),

        // Reply preview bar
        if (_replyToMessageId != null)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.md,
              vertical: HollowSpacing.xs + 2,
            ),
            decoration: BoxDecoration(
              color: hollow.surface,
              border: Border(
                top: BorderSide(color: hollow.border),
                left: BorderSide(color: hollow.accent, width: 3),
              ),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.reply, size: 14, color: hollow.accent),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Replying to ${_replyToSenderName ?? ''}',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.accent,
                          fontWeight: FontWeight.w600,
                          fontSize: 11,
                        ),
                      ),
                      Row(
                        children: [
                          if (_replyToImagePath != null && File(_replyToImagePath!).existsSync()) ...[
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: _replyToImagePath!.toLowerCase().endsWith('.gif')
                                  ? GifFileImage(
                                      diskPath: _replyToImagePath!,
                                      width: 32,
                                      height: 32,
                                      fit: BoxFit.cover,
                                    )
                                  : Image.file(
                                      File(_replyToImagePath!),
                                      width: 32,
                                      height: 32,
                                      fit: BoxFit.cover,
                                    ),
                            ),
                            const SizedBox(width: HollowSpacing.xs),
                          ],
                          Expanded(
                            child: Text(
                              _replyToText ?? '',
                              style: HollowTypography.body.copyWith(
                                color: hollow.textSecondary,
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                HollowPressable(
                  onTap: () => setState(() {
                    _replyToMessageId = null;
                    _replyToText = null;
                    _replyToSenderName = null;
      _replyToImagePath = null;
                  }),
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Icon(LucideIcons.x,
                      size: 16, color: hollow.textSecondary),
                ),
              ],
            ),
          ),

        // Staged file preview
        if (_stagedFilePath != null)
          Container(
            padding: const EdgeInsets.fromLTRB(
              HollowSpacing.md, HollowSpacing.sm, HollowSpacing.md, 0),
            decoration: BoxDecoration(
              color: hollow.surface,
              border: Border(top: BorderSide(color: hollow.border)),
            ),
            child: Row(
              children: [
                if (_stagedFileIsImage)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: _stagedFilePath!.toLowerCase().endsWith('.gif')
                        ? GifFileImage(
                            diskPath: _stagedFilePath!,
                            width: 48, height: 48, fit: BoxFit.cover,
                          )
                        : Image.file(
                            File(_stagedFilePath!),
                            width: 48, height: 48, fit: BoxFit.cover,
                          ),
                  )
                else
                  Container(
                    width: 48, height: 48,
                    decoration: BoxDecoration(
                      color: hollow.elevated,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(LucideIcons.file, color: hollow.textSecondary, size: 20),
                  ),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Text(
                    _stagedFileName ?? '',
                    style: HollowTypography.caption.copyWith(color: hollow.textPrimary),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                  ),
                ),
                HollowPressable(
                  onTap: () => setState(() {
                    _stagedFilePath = null;
                    _stagedFileName = null;
                    _stagedFileIsImage = false;
                  }),
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Icon(LucideIcons.x, size: 16, color: hollow.textSecondary),
                ),
              ],
            ),
          ),

        if (_stagedHollowLink != null)
          StagedHollowLinkCard(
            link: _stagedHollowLink!,
            onDismiss: () {
              _urlDebounce?.cancel();
              setState(() {
                _stagedPreviewUrl = null;
                _stagedHollowLink = null;
              });
            },
          )
        else if (_stagedPreviewUrl != null)
          StagedLinkPreviewCard(
            url: _stagedPreviewUrl!,
            preview: _stagedPreview,
            loading: _stagedPreviewLoading,
            onDismiss: () {
              _urlDebounce?.cancel();
              setState(() {
                _stagedPreviewUrl = null;
                _stagedPreview = null;
                _stagedPreviewLoading = false;
              });
            },
          ),

        // Input bar — hidden if no posting permission
        if (!ref.watch(canPostInChannelProvider((serverId: widget.serverId, channelId: widget.channelId))))
          Container(
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
                'You don\'t have permission to send messages in this channel',
                style: HollowTypography.bodySmall.copyWith(
                  color: hollow.textSecondary,
                ),
              ),
            ),
          )
        else
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.md,
            vertical: HollowSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: hollow.surface,
            border: Border(
              top: (_replyToMessageId != null ||
                      _stagedFilePath != null ||
                      _stagedPreviewUrl != null)
                  ? BorderSide.none
                  : BorderSide(color: hollow.border),
            ),
          ),
          child: _isRecordingVoice
              ? VoiceRecorderBar(
                  onFinished: _stageVoiceMessage,
                  onCancelled: () =>
                      setState(() => _isRecordingVoice = false),
                )
              : Row(
                  children: [
                    // File attachment button
                    HollowPressable(
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
                      onTap: _stagedFilePath != null
                          ? null
                          : () => setState(() => _isRecordingVoice = true),
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
                    Expanded(
                      child: CompositedTransformTarget(
                        link: _mentionLayerLink,
                        child: Focus(
                          onKeyEvent: (_, event) {
                            if (_mentionOverlay != null &&
                                (event is KeyDownEvent ||
                                    event is KeyRepeatEvent)) {
                              if (event.logicalKey ==
                                  LogicalKeyboardKey.arrowDown) {
                                setState(() {
                                  _mentionSelectedIndex =
                                      (_mentionSelectedIndex + 1)
                                          .clamp(0,
                                              _mentionCandidates.length - 1);
                                });
                                _showMentionOverlay();
                                return KeyEventResult.handled;
                              }
                              if (event.logicalKey ==
                                  LogicalKeyboardKey.arrowUp) {
                                setState(() {
                                  _mentionSelectedIndex =
                                      (_mentionSelectedIndex - 1)
                                          .clamp(0,
                                              _mentionCandidates.length - 1);
                                });
                                _showMentionOverlay();
                                return KeyEventResult.handled;
                              }
                              if (event.logicalKey ==
                                      LogicalKeyboardKey.enter ||
                                  event.logicalKey ==
                                      LogicalKeyboardKey.tab) {
                                _acceptMention(
                                    _mentionCandidates[_mentionSelectedIndex]);
                                return KeyEventResult.handled;
                              }
                              if (event.logicalKey ==
                                  LogicalKeyboardKey.escape) {
                                _dismissMentionOverlay();
                                return KeyEventResult.handled;
                              }
                            }
                            return handleChatInputKey(
                              event, _controller, _focusNode, _handleSend,
                              onPasteImage: _stageClipboardImage,
                            );
                          },
                          child: HollowTextField(
                            controller: _controller,
                            focusNode: _focusNode,
                            hintText: 'Message #${widget.channelName}',
                            autofocus: true,
                            maxLines: 5,
                            minLines: 1,
                            maxLength: 4000,
                            showCounter: false,
                            style: HollowTypography.body
                                .copyWith(color: hollow.textPrimary),
                            borderRadius: hollow.radiusLg,
                            onChanged: _onTextChanged,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.sm),
                    HollowPressable(
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
                ),
        ),
      ],
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
    final connectedPeers = ref.watch(peersProvider);
    final membersAsync = ref.watch(serverMembersProvider(serverId));
    final localPeerId = ref.watch(identityProvider).peerId;

    return membersAsync.when(
      data: (members) {
        final otherMembers =
            members.where((m) => m.peerId != localPeerId).toList();

        final onlineMembers = otherMembers
            .where((m) => connectedPeers.containsKey(m.peerId))
            .toList();

        // With MLS, online members in a WS room are already encrypted (MLS group broadcast).
        final stage = onlineMembers.isEmpty
            ? ConnectionStage.offline
            : ConnectionStage.encrypted;

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
      loading: () => ConnectionProgress(
        key: ValueKey('conn-$serverId'),
        stage: ConnectionStage.offline,
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
    try {
      network_api.requestChannelSync(
        serverId: widget.serverId,
        channelId: widget.channelId,
      );
    } catch (_) {}
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
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
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

/// Floating pill that appears when scrolled away from the bottom.
/// Tap to jump to newest messages.
class _UnreadPill extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _UnreadPill({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final label = count == 1 ? '1 new message' : '$count new messages';
    return HollowPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      backgroundColor: hollow.accent,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.xs + 2,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.arrowDown, size: 14, color: hollow.textOnAccent),
          const SizedBox(width: HollowSpacing.xs),
          Text(
            label,
            style: HollowTypography.caption.copyWith(
              color: hollow.textOnAccent,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _MentionCandidate {
  final String peerId;
  final String displayName;
  final String? subtitle;
  final Uint8List? avatarBytes;

  const _MentionCandidate({
    required this.peerId,
    required this.displayName,
    this.subtitle,
    this.avatarBytes,
  });
}

