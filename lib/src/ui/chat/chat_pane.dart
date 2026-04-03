import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/ui/chat/chat_input_shortcuts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/typing_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/message_action_bar.dart';
import 'package:hollow/src/ui/chat/message_bubble.dart';
import 'package:hollow/src/ui/components/connection_progress.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/profile_card_popup.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/ui/dialogs/screen_share_dialog.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// Whether the DM profile panel is visible.
final dmProfilePanelProvider = StateProvider<bool>((ref) => true);

/// Whether two consecutive messages should be grouped (same sender, within 5 min).
bool shouldGroup({
  required bool currentIsMe,
  required bool previousIsMe,
  required DateTime currentTime,
  required DateTime previousTime,
  String? currentSenderId,
  String? previousSenderId,
}) {
  // For DMs: just check isMe flag.
  // For channels: also check senderId.
  if (currentIsMe != previousIsMe) return false;
  if (currentSenderId != null &&
      previousSenderId != null &&
      currentSenderId != previousSenderId) {
    return false;
  }
  return currentTime.difference(previousTime).inMinutes.abs() < 5;
}

/// Whether a date separator should be shown between two timestamps.
bool shouldShowDateSeparator(DateTime current, DateTime? previous) {
  if (previous == null) return true; // First message always gets a date header.
  return current.year != previous.year ||
      current.month != previous.month ||
      current.day != previous.day;
}

/// ASOT-style date separator: ——— February 16, 2026 ———
class DateSeparator extends StatelessWidget {
  final DateTime date;
  const DateSeparator({super.key, required this.date});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDay = DateTime(date.year, date.month, date.day);
    final diff = today.difference(messageDay).inDays;

    final String label;
    if (diff == 0) {
      label = 'Today';
    } else if (diff == 1) {
      label = 'Yesterday';
    } else {
      const months = [
        'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December',
      ];
      label = '${months[date.month - 1]} ${date.day}, ${date.year}';
    }

    return Padding(
      padding: const EdgeInsets.only(
        top: HollowSpacing.md + 2,
        bottom: HollowSpacing.sm,
        left: HollowSpacing.lg,
        right: HollowSpacing.lg,
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              color: hollow.border,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
            child: Text(
              label,
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary.withValues(alpha: 0.6),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 1,
              color: hollow.border,
            ),
          ),
        ],
      ),
    );
  }
}

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

  final _controller = TextEditingController();
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  final _scrollOffsetController = ScrollOffsetController();
  final _focusNode = FocusNode();
  bool _historyLoaded = false;
  bool _isPicking = false;
  int _previousMessageCount = 0;
  String? _editingMessageId;
  String? _replyToMessageId;
  String? _replyToText;
  String? _replyToSenderName;
  String? _replyToImagePath;
  DateTime? _lastTypingSent;
  int? _highlightIndex;
  bool _showScrollPill = false;
  Timer? _overlayHideTimer;
  bool _overlaysVisible = true;
  bool _chatOverlayPinned = false; // User explicitly toggled chat open

  @override
  void initState() {
    super.initState();
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
      final msgs = ref.read(chatProvider)[widget.peerId];
      if (msgs != null && msgs.isNotEmpty) {
        ref.read(unreadProvider.notifier).markDmSeen(
              widget.peerId, msgs.last.messageId);
      }
    }
  }

  Future<void> _loadHistory() async {
    if (_historyLoaded) return;
    _historyLoaded = true;
    await ref.read(chatProvider.notifier).loadHistory(widget.peerId);
    if (mounted) setState(() {});
    // Mark DM as read now that messages are loaded.
    final msgs = ref.read(chatProvider)[widget.peerId];
    final latestId = msgs != null && msgs.isNotEmpty
        ? msgs.last.messageId
        : null;
    ref.read(unreadProvider.notifier).markDmSeen(widget.peerId, latestId);
  }

  void _resetOverlayTimer() {
    _overlayHideTimer?.cancel();
    if (!_overlaysVisible) {
      setState(() => _overlaysVisible = true);
    }
    // Don't start hide timer while user is typing or chat is pinned open.
    if (_focusNode.hasFocus || _chatOverlayPinned) return;
    _overlayHideTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _overlaysVisible = false);
    });
  }

  void _pinOverlays() {
    _overlayHideTimer?.cancel();
    if (!_overlaysVisible) {
      setState(() => _overlaysVisible = true);
    }
  }

  @override
  void dispose() {
    _overlayHideTimer?.cancel();
    _itemPositionsListener.itemPositions.removeListener(_onScrollPositionChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool get _isNearBottom {
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return true;
    final messages = ref.read(chatProvider)[widget.peerId] ?? [];
    if (messages.isEmpty) return true;
    // Check if sentinel (last real message index or beyond) is visible.
    return positions.any((p) => p.index >= messages.length - 1);
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScrollController.isAttached) return;
      final messages = ref.read(chatProvider)[widget.peerId] ?? [];
      if (messages.isEmpty) return;
      // Jump to sentinel item (index == messages.length) at bottom of viewport.
      _itemScrollController.jumpTo(index: messages.length, alignment: 1.0);
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScrollController.isAttached) return;
      // Pixel-level nudge — no crossfade animation.
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

  void _onTextChanged(String text) {
    if (text.isEmpty) return;
    final now = DateTime.now();
    if (_lastTypingSent != null &&
        now.difference(_lastTypingSent!).inSeconds < 3) {
      return;
    }
    _lastTypingSent = now;
    try {
      network_api.sendTypingIndicator(
        serverId: '',
        channelId: widget.peerId,
      );
    } catch (_) {}
  }

  Future<void> _handleSend() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    _lastTypingSent = null;
    _focusNode.requestFocus();
    final replyMid = _replyToMessageId;
    setState(() {
      _replyToMessageId = null;
      _replyToText = null;
      _replyToSenderName = null;
      _replyToImagePath = null;
    });
    await ref
        .read(chatProvider.notifier)
        .sendMessage(widget.peerId, text, replyToMid: replyMid);
    _scrollToBottom();
  }

  Future<void> _pickAndSendFile(WidgetRef ref) async {
    if (_isPicking) return;
    _isPicking = true;
    try {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) { _isPicking = false; return; }
    final file = result.files.first;
    if (file.path == null) { _isPicking = false; return; }

    // Enforce 34 MB limit for DMs (always on default relay).
    const maxDmBytes = 34 * 1024 * 1024;
    if (file.size > maxDmBytes) {
      if (mounted) {
        final fileMb = (file.size / (1024 * 1024)).toStringAsFixed(1);
        HollowToast.show(
          context,
          'File too large (${fileMb}MB). DM limit is 34 MB.',
          type: HollowToastType.error,
          duration: const Duration(seconds: 4),
        );
      }
      _isPicking = false;
      return;
    }

    final messageId = generateMessageId();
    final fileName = file.name;
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';
    final isImage = ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'].contains(ext);

    // Add optimistic message with file attachment placeholder.
    ref.read(chatProvider.notifier).addFileMessage(
          widget.peerId,
          messageId,
          fileName,
          file.size,
          ext,
          isImage,
          file.path!,
        );
    _jumpToBottom();

    await ref.read(fileTransferProvider.notifier).sendFile(
          peerId: widget.peerId,
          filePath: file.path!,
          messageId: messageId,
          messageText: '',
        );
    } finally { _isPicking = false; }
  }

  Future<void> _saveFile(FileAttachment attachment) async {
    if (_isPicking) return;
    _isPicking = true;
    try {
      // Determine allowed extensions for save dialog.
      final isImage = attachment.isImage;
      final isGif = attachment.fileExt.toLowerCase() == 'gif';
      final allowedExtensions = isImage
          ? ['png', 'jpg', 'jpeg', 'webp', 'gif']
          : [attachment.fileExt];

      // Strip extension from filename for the dialog.
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

      // Determine target format from chosen extension.
      final targetExt = savePath.contains('.')
          ? savePath.split('.').last.toLowerCase()
          : attachment.fileExt;

      if (isImage && targetExt != 'webp' && attachment.fileExt == 'webp') {
        // Convert WebP to target format via Rust.
        final converted = await network_api.convertImageFormat(
          sourcePath: attachment.diskPath!,
          targetFormat: targetExt,
        );
        await File(savePath).writeAsBytes(converted);
      } else {
        // Direct copy.
        await File(attachment.diskPath!).copy(savePath);
      }

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
    final chatHistory = ref.watch(chatProvider);
    final messages = chatHistory[widget.peerId] ?? [];

    // Auto-scroll when new messages arrive and user is near the bottom.
    // Skip on initial load (handled by _jumpToBottom in _loadHistory).
    if (_previousMessageCount > 0 &&
        messages.length > _previousMessageCount &&
        _isNearBottom) {
      _scrollToBottom();
    }
    _previousMessageCount = messages.length;

    final typingPeers = ref.watch(typingProvider)[widget.peerId] ?? {};
    final showProfilePanel = ref.watch(dmProfilePanelProvider);

    // Screen share layout only shows in the DM with the call peer.
    final call = ref.watch(callProvider);
    final isCallWithThisPeer = call.peerId == widget.peerId;
    final isScreenShareActive = isCallWithThisPeer &&
        (call.isScreenSharing || call.remoteScreenSharing);

    return Row(
      children: [
        // DM Profile Panel (left side) with slide animation
        _DmProfilePanelSlider(
          visible: showProfilePanel && !isScreenShareActive,
          peerId: widget.peerId,
        ),

        // Chat area
        Expanded(
          child: Column(
      children: [
        // Peer ID header
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.lg,
            vertical: HollowSpacing.sm + 2,
          ),
          decoration: BoxDecoration(
            color: hollow.surface,
            border: Border(
              bottom: BorderSide(color: hollow.border),
            ),
          ),
          child: Row(
            children: [
              HollowAvatar(peerId: widget.peerId, size: 28, imageBytes: ref.watch(profileProvider)[widget.peerId]?.avatarBytes),
              const SizedBox(width: HollowSpacing.sm),
              Builder(builder: (_) {
                final isOnline = ref.watch(peersProvider).containsKey(widget.peerId);
                return StatusDot(
                  color: isOnline ? hollow.success : hollow.textSecondary,
                  size: 8,
                  pulse: isOnline,
                );
              }),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayNameFor(ref.watch(profileProvider), widget.peerId),
                      style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      widget.peerId.length > 16
                          ? '${widget.peerId.substring(0, 16)}...'
                          : widget.peerId,
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              Builder(builder: (_) {
                final peer = ref.watch(peersProvider)[widget.peerId];
                final connStatus = ref.watch(connectionStatusProvider);
                final cs = connStatus.peers[widget.peerId];
                final ConnectionStage stage;
                String? detail;
                if (peer == null) {
                  stage = ConnectionStage.connecting;
                  // Only show detail for meaningful stages (not routine dial failures).
                  if (cs != null &&
                      (cs.stage == PeerConnectionStage.connected ||
                       cs.stage == PeerConnectionStage.keyExchange)) {
                    detail = cs.label;
                  }
                } else if (peer.isEncrypted) {
                  stage = ConnectionStage.encrypted;
                } else {
                  stage = ConnectionStage.encrypting;
                  if (cs != null &&
                      cs.stage == PeerConnectionStage.keyExchange) {
                    detail = cs.label;
                  }
                }
                return ConnectionProgress(
                  key: ValueKey('dm-conn-${widget.peerId}-${stage.index}'),
                  stage: stage,
                  detail: detail,
                );
              }),
              const SizedBox(width: HollowSpacing.sm),
              // Voice call button
              Builder(builder: (_) {
                final call = ref.watch(callProvider);
                final isOnline = ref.watch(peersProvider).containsKey(widget.peerId);
                final isInCall = call.status != CallStatus.idle;
                final isCallWithThisPeer = call.peerId == widget.peerId && isInCall;

                return HollowTooltip(
                  message: isCallWithThisPeer
                      ? 'In call'
                      : (isOnline && !isInCall ? 'Start voice call' : 'Voice call'),
                  child: HollowPressable(
                    onTap: isOnline && !isInCall
                        ? () => ref.read(callProvider.notifier).startCall(widget.peerId)
                        : null,
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    child: Icon(
                      isCallWithThisPeer ? LucideIcons.phoneCall : LucideIcons.phone,
                      size: 16,
                      color: isCallWithThisPeer
                          ? hollow.success
                          : (isOnline && !isInCall
                              ? hollow.textSecondary
                              : hollow.textSecondary.withValues(alpha: 0.3)),
                    ),
                  ),
                );
              }),
              const SizedBox(width: HollowSpacing.xs),
              // Video call button
              Builder(builder: (_) {
                final call = ref.watch(callProvider);
                final isOnline = ref.watch(peersProvider).containsKey(widget.peerId);
                final isInCall = call.status != CallStatus.idle;

                return HollowTooltip(
                  message: 'Start video call',
                  child: HollowPressable(
                    onTap: isOnline && !isInCall
                        ? () => ref.read(callProvider.notifier).startCall(widget.peerId, withVideo: true)
                        : null,
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    child: Icon(
                      LucideIcons.video,
                      size: 16,
                      color: isOnline && !isInCall
                          ? hollow.textSecondary
                          : hollow.textSecondary.withValues(alpha: 0.3),
                    ),
                  ),
                );
              }),
              const SizedBox(width: HollowSpacing.xs),
              HollowTooltip(
                message: showProfilePanel ? 'Hide profile' : 'Show profile',
                child: HollowPressable(
                  onTap: () {
                    ref.read(dmProfilePanelProvider.notifier).state = !showProfilePanel;
                  },
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Icon(LucideIcons.user,
                      size: 16, color: showProfilePanel ? hollow.accent : hollow.textSecondary),
                ),
              ),
              const SizedBox(width: HollowSpacing.xs),
              HollowTooltip(
                message: ref.watch(notificationSettingsProvider
                        .select((s) => s.dmEnabled[widget.peerId] ?? true))
                    ? 'Mute notifications'
                    : 'Unmute notifications',
                child: HollowPressable(
                  onTap: () {
                    final current = ref
                        .read(notificationSettingsProvider.notifier)
                        .isDmEnabled(widget.peerId);
                    ref
                        .read(notificationSettingsProvider.notifier)
                        .setDmEnabled(widget.peerId, !current);
                  },
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Icon(
                    ref.watch(notificationSettingsProvider
                            .select((s) => s.dmEnabled[widget.peerId] ?? true))
                        ? LucideIcons.bell
                        : LucideIcons.bellOff,
                    size: 18,
                    color: ref.watch(notificationSettingsProvider
                            .select((s) => s.dmEnabled[widget.peerId] ?? true))
                        ? hollow.textSecondary
                        : hollow.textSecondary.withValues(alpha: 0.4),
                  ),
                ),
              ),
              // Split view button (dock mode only)
              if ((ref.watch(layoutModeProvider).valueOrNull ?? LayoutMode.dock) == LayoutMode.dock) ...[
                const SizedBox(width: HollowSpacing.xs),
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
                      size: 16,
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

        // Screen share: full-bleed layout with overlay chat + controls.
        // Normal call / no call: standard column layout.
        if (isScreenShareActive)
          Expanded(
            child: MouseRegion(
              onHover: (_) => _resetOverlayTimer(),
              onEnter: (_) => _resetOverlayTimer(),
              child: Stack(
                children: [
                  // Layer 0: full-bleed screen share
                  Positioned.fill(
                    child: _ScreenShareFullView(peerId: widget.peerId),
                  ),

                  // Layer 1: chat overlay (right side) + toggle button
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Toggle button — always visible when overlays are
                        AnimatedOpacity(
                          opacity: _overlaysVisible ? 1.0 : 0.0,
                          duration: HollowDurations.normal,
                          child: IgnorePointer(
                            ignoring: !_overlaysVisible,
                            child: MouseRegion(
                              onEnter: (_) => _pinOverlays(),
                              onExit: (_) => _resetOverlayTimer(),
                              child: GestureDetector(
                                onTap: () => setState(() =>
                                    _chatOverlayPinned = !_chatOverlayPinned),
                                child: Container(
                                  width: 24,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color: hollow.surface.withValues(alpha: 0.88),
                                    borderRadius: const BorderRadius.horizontal(
                                      left: Radius.circular(8),
                                    ),
                                    border: Border(
                                      left: BorderSide(
                                        color: hollow.border.withValues(alpha: 0.5),
                                      ),
                                      top: BorderSide(
                                        color: hollow.border.withValues(alpha: 0.5),
                                      ),
                                      bottom: BorderSide(
                                        color: hollow.border.withValues(alpha: 0.5),
                                      ),
                                    ),
                                  ),
                                  child: Icon(
                                    _chatOverlayPinned
                                        ? LucideIcons.chevronRight
                                        : LucideIcons.chevronLeft,
                                    size: 14,
                                    color: hollow.textSecondary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Chat panel — slides in/out
                        _ChatOverlaySlider(
                          visible: _chatOverlayPinned,
                          onHoverEnter: _pinOverlays,
                          onHoverExit: _resetOverlayTimer,
                          child: Container(
                            width: 360,
                            decoration: BoxDecoration(
                              color: hollow.surface.withValues(alpha: 0.88),
                              border: Border(
                                left: BorderSide(
                                  color: hollow.border.withValues(alpha: 0.5),
                                ),
                              ),
                            ),
                            child: Column(
                              children: _buildMessageArea(
                                hollow, messages, typingPeers),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Layer 2: floating controls pill (bottom center)
                  Positioned(
                    bottom: HollowSpacing.lg,
                    left: 0,
                    right: 0,
                    child: AnimatedOpacity(
                      opacity: _overlaysVisible ? 1.0 : 0.0,
                      duration: HollowDurations.normal,
                      child: IgnorePointer(
                        ignoring: !_overlaysVisible,
                        child: Center(
                          child: _ScreenShareControlsOverlay(
                            peerId: widget.peerId,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
        else ...[
          _InlineCallPanelSlider(peerId: widget.peerId),
          ..._buildMessageArea(hollow, messages, typingPeers),
        ],
      ],
          ), // Column
        ), // Expanded (chat area)
      ],
    ); // Row
  }

  /// Builds the message list + typing + reply bar + input bar.
  /// Used by both the normal column layout and the screen-share overlay.
  List<Widget> _buildMessageArea(
    HollowTheme hollow,
    List<dynamic> messages,
    Set<String> typingPeers,
  ) {
    return [
      // Messages list + unread pill overlay
      Expanded(
        child: Stack(
          children: [
            MessageActionBarScope(
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
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      LucideIcons.messageCircle,
                                      size: 48,
                                      color: hollow.textSecondary
                                          .withValues(alpha: 0.3),
                                    ),
                                    const SizedBox(height: HollowSpacing.md),
                                    Text(
                                      'No messages yet. Say hello!',
                                      style: HollowTypography.body.copyWith(
                                        color: hollow.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : const SizedBox.shrink())
                        : ScrollConfiguration(
                            behavior: ScrollConfiguration.of(context)
                                .copyWith(scrollbars: false),
                            child: ScrollablePositionedList.builder(
                              key: ValueKey('dm-list-${widget.peerId}'),
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
                                if (index >= messages.length) {
                                  return const SizedBox.shrink();
                                }
                                final msg = messages[index];
                                final showHeader = index == 0 ||
                                    !shouldGroup(
                                      currentIsMe: msg.isMe,
                                      previousIsMe: messages[index - 1].isMe,
                                      currentTime: msg.timestamp,
                                      previousTime:
                                          messages[index - 1].timestamp,
                                    );
                                final profiles = ref.watch(profileProvider);
                                final localPeerId =
                                    ref.watch(identityProvider).peerId ?? '';
                                final wrapper = MessageHoverWrapper(
                                  isMe: msg.isMe,
                                  messageId: msg.messageId,
                                  currentText: msg.text,
                                  isEditing: _editingMessageId != null &&
                                      _editingMessageId == msg.messageId,
                                  onEditStart: msg.messageId != null &&
                                          msg.isMe &&
                                          msg.fileAttachment == null
                                      ? () => setState(() =>
                                          _editingMessageId = msg.messageId)
                                      : null,
                                  onEditSubmit: (newText) {
                                    setState(
                                        () => _editingMessageId = null);
                                    ref
                                        .read(chatProvider.notifier)
                                        .editMessage(widget.peerId,
                                            msg.messageId!, newText);
                                  },
                                  onEditCancel: () => setState(
                                      () => _editingMessageId = null),
                                  onDelete: msg.messageId != null && msg.isMe
                                      ? () => ref
                                          .read(chatProvider.notifier)
                                          .deleteMessage(
                                              widget.peerId, msg.messageId!)
                                      : null,
                                  onReply: msg.messageId != null
                                      ? () {
                                          final senderId = msg.isMe
                                              ? localPeerId
                                              : widget.peerId;
                                          setState(() {
                                            _replyToMessageId = msg.messageId;
                                            _replyToText = msg
                                                        .fileAttachment !=
                                                    null
                                                ? (msg.fileAttachment!.isImage
                                                    ? '📷 Image'
                                                    : '📎 ${msg.fileAttachment!.fileName}')
                                                : msg.text;
                                            _replyToSenderName =
                                                displayNameFor(
                                                    profiles, senderId);
                                            _replyToImagePath =
                                                msg.fileAttachment?.isImage ==
                                                        true
                                                    ? msg.fileAttachment
                                                        ?.diskPath
                                                    : null;
                                          });
                                          _focusNode.requestFocus();
                                        }
                                      : null,
                                  onReaction: msg.messageId != null
                                      ? (emoji) {
                                          final hasReacted = msg
                                                  .reactions[emoji]
                                                  ?.contains(localPeerId) ??
                                              false;
                                          final notifier =
                                              ref.read(chatProvider.notifier);
                                          if (hasReacted) {
                                            notifier.removeReaction(
                                                widget.peerId,
                                                msg.messageId!,
                                                emoji);
                                          } else {
                                            notifier.addReaction(
                                                widget.peerId,
                                                msg.messageId!,
                                                emoji);
                                          }
                                        }
                                      : null,
                                  onDownload: msg.fileAttachment != null &&
                                          msg.fileAttachment!.diskPath != null
                                      ? () => _saveFile(msg.fileAttachment!)
                                      : null,
                                  child: Builder(builder: (_) {
                                    String? replySender;
                                    String? replyText;
                                    String? replyImagePath;
                                    int? replyIndex;
                                    if (msg.replyToMid != null) {
                                      final idx = messages.indexWhere(
                                          (m) =>
                                              m.messageId == msg.replyToMid);
                                      if (idx != -1) {
                                        replyIndex = idx;
                                        final original = messages[idx];
                                        replyText =
                                            original.fileAttachment != null
                                                ? (original.fileAttachment!
                                                        .isImage
                                                    ? '📷 Image'
                                                    : '📎 ${original.fileAttachment!.fileName}')
                                                : original.text;
                                        final origSenderId = original.isMe
                                            ? localPeerId
                                            : widget.peerId;
                                        replySender = displayNameFor(
                                            profiles, origSenderId);
                                        if (original
                                                .fileAttachment?.isImage ==
                                            true) {
                                          replyImagePath = original
                                              .fileAttachment?.diskPath;
                                        }
                                      }
                                    }
                                    return MessageBubble(
                                      message: msg,
                                      peerId: widget.peerId,
                                      showHeader: showHeader,
                                      replyToSenderName: replySender,
                                      replyToText: replyText,
                                      replyToImagePath: replyImagePath,
                                      isHighlighted:
                                          _highlightIndex == index,
                                      onReplyTap: replyIndex != null
                                          ? () =>
                                              _scrollToMessage(replyIndex!)
                                          : null,
                                      onToggleReaction:
                                          msg.messageId != null
                                              ? (emoji) {
                                                  final hasReacted = msg
                                                          .reactions[emoji]
                                                          ?.contains(
                                                              localPeerId) ??
                                                      false;
                                                  final notifier = ref.read(
                                                      chatProvider.notifier);
                                                  if (hasReacted) {
                                                    notifier.removeReaction(
                                                        widget.peerId,
                                                        msg.messageId!,
                                                        emoji);
                                                  } else {
                                                    notifier.addReaction(
                                                        widget.peerId,
                                                        msg.messageId!,
                                                        emoji);
                                                  }
                                                }
                                              : null,
                                    );
                                  }),
                                );
                                final showDate = shouldShowDateSeparator(
                                  msg.timestamp,
                                  index > 0
                                      ? messages[index - 1].timestamp
                                      : null,
                                );
                                final messageWidget = showHeader
                                    ? Padding(
                                        padding: const EdgeInsets.only(
                                            top: HollowSpacing.sm + 2),
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
            // Unread pill
            Builder(builder: (context) {
              final unreadCount = ref.watch(unreadProvider)
                      .dmUnreadCounts[widget.peerId] ??
                  0;
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
                        ref.read(unreadProvider.notifier).markDmSeen(
                              widget.peerId,
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
              .map((pid) =>
                  displayNameFor(ref.watch(profileProvider), pid))
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
                        if (_replyToImagePath != null &&
                            File(_replyToImagePath!).existsSync()) ...[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.file(
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

      // Input bar
      Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: hollow.surface,
          border: Border(
            top: _replyToMessageId != null
                ? BorderSide.none
                : BorderSide(color: hollow.border),
          ),
        ),
        child: Row(
          children: [
            HollowPressable(
              onTap: () => _pickAndSendFile(ref),
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              padding: const EdgeInsets.all(HollowSpacing.sm),
              child: Icon(
                LucideIcons.paperclip,
                color: hollow.textSecondary,
                size: 20,
              ),
            ),
            const SizedBox(width: HollowSpacing.xs),
            Expanded(
              child: Focus(
                onKeyEvent: (_, event) => handleChatInputKey(
                  event, _controller, _focusNode, _handleSend,
                ),
                child: HollowTextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  hintText: 'Type a message...',
                  autofocus: true,
                  maxLines: 5,
                  minLines: 1,
                  maxLength: 4000,
                  showCounter: false,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                  ),
                  borderRadius: hollow.radiusLg,
                  onChanged: _onTextChanged,
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
    ];
  }
}

/// Slide animation wrapper for the DM profile panel.
// ---------------------------------------------------------------------------
// Inline call panel — shown under the DM header during a call with this peer.
// ---------------------------------------------------------------------------

/// Animated slider for the inline call panel (slides down from header).
class _InlineCallPanelSlider extends ConsumerStatefulWidget {
  final String peerId;
  const _InlineCallPanelSlider({required this.peerId});

  @override
  ConsumerState<_InlineCallPanelSlider> createState() =>
      _InlineCallPanelSliderState();
}

class _InlineCallPanelSliderState extends ConsumerState<_InlineCallPanelSlider>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curved;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.normal,
      value: 0.0,
    );
    _curved = CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.enter,
      reverseCurve: HollowCurves.exit,
    );
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callProvider);
    final isCallWithThisPeer = call.peerId == widget.peerId &&
        (call.status == CallStatus.active ||
         call.status == CallStatus.connecting);

    // Drive animation.
    if (isCallWithThisPeer) {
      _controller.forward();
    } else {
      _controller.reverse();
    }

    return AnimatedBuilder(
      animation: _curved,
      builder: (context, child) {
        if (_curved.value == 0.0) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: _curved.value,
            child: FadeTransition(
              opacity: _curved,
              child: child,
            ),
          ),
        );
      },
      child: _InlineCallPanel(peerId: widget.peerId),
    );
  }
}

/// The actual call panel content — audio bar or video view + controls.
class _InlineCallPanel extends ConsumerStatefulWidget {
  final String peerId;
  const _InlineCallPanel({required this.peerId});

  @override
  ConsumerState<_InlineCallPanel> createState() => _InlineCallPanelState();
}

class _InlineCallPanelState extends ConsumerState<_InlineCallPanel> {
  Timer? _durationTimer;
  double _remoteVolume = 1.0;
  Duration _duration = Duration.zero;
  double _videoHeight = 200; // Height of the video area (only when video active).
  static const _minVideoHeight = 80.0;
  static const _maxVideoHeight = 500.0;
  String? _expandedRenderer; // null = side-by-side, 'local' or 'remote' = fullscreen

  @override
  void dispose() {
    _durationTimer?.cancel();
    super.dispose();
  }

  void _startTimer(DateTime startedAt) {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _duration = DateTime.now().difference(startedAt);
      });
    });
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callProvider);
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final displayName = displayNameFor(profiles, widget.peerId);
    final remoteAvatar = profiles[widget.peerId]?.avatarBytes;
    final localAvatar = profiles[localPeerId]?.avatarBytes;

    // Start timer.
    if (call.status == CallStatus.active && call.startedAt != null) {
      if (_durationTimer == null) {
        _duration = DateTime.now().difference(call.startedAt!);
        _startTimer(call.startedAt!);
      }
    } else {
      _durationTimer?.cancel();
      _durationTimer = null;
    }

    final hasRemoteVideo = call.remoteVideoEnabled;
    final hasLocalVideo = call.isVideoEnabled;
    final hasAnyVideo = hasRemoteVideo || hasLocalVideo;
    final isScreenShare = call.isScreenSharing || call.remoteScreenSharing;
    final hasVideoArea = hasAnyVideo || isScreenShare;
    final voiceService = ref.read(callProvider.notifier).voiceService;
    final remoteRenderer = voiceService?.remoteRenderer;
    final localRenderer = voiceService?.localRenderer;

    // Reset expanded view when video turns off.
    if (!hasAnyVideo && _expandedRenderer != null) {
      _expandedRenderer = null;
    }

    // Max video height: leave room for controls + input bar.
    final screenHeight = MediaQuery.of(context).size.height;
    final maxH = (screenHeight * 0.7).clamp(_minVideoHeight, _maxVideoHeight);

    return GestureDetector(
      onSecondaryTapUp: (details) {
        if (call.status == CallStatus.active) {
          _showVolumePopup(context, details.globalPosition);
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: hollow.surface,
          border: Border(
            bottom: BorderSide(color: hollow.border),
          ),
        ),
        child: Column(
          mainAxisSize: isScreenShare ? MainAxisSize.max : MainAxisSize.min,
        children: [
          // Video / screen share area
          if (hasVideoArea) ...[
            // Screen share fills available space; camera uses fixed height.
            if (isScreenShare)
              Expanded(
                child: _buildScreenShareView(call, hollow, remoteRenderer),
              )
            else
              SizedBox(
                height: _videoHeight,
                child: _expandedRenderer != null
                    ? _buildFullscreenVideo(
                        hollow, displayName, remoteAvatar, localAvatar,
                        remoteRenderer, localRenderer,
                        hasRemoteVideo, hasLocalVideo)
                    : _buildSideBySideVideo(
                        hollow, displayName, remoteAvatar, localAvatar,
                        remoteRenderer, localRenderer,
                        hasRemoteVideo, hasLocalVideo),
              ),
            // Resize handle for video (not needed during screen share — it fills Expanded)
            if (!isScreenShare)
            MouseRegion(
              cursor: SystemMouseCursors.resizeRow,
              child: GestureDetector(
                onVerticalDragUpdate: (details) {
                  setState(() {
                    _videoHeight = (_videoHeight + details.delta.dy)
                        .clamp(_minVideoHeight, maxH);
                  });
                },
                child: Container(
                  height: 8,
                  color: Colors.transparent,
                  child: Center(
                    child: Container(
                      width: 32,
                      height: 3,
                      decoration: BoxDecoration(
                        color: hollow.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],

          // Control bar: timer (left), avatars (center, audio-only), controls (right)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg,
              vertical: hasAnyVideo ? HollowSpacing.sm : HollowSpacing.md,
            ),
            child: Row(
              children: [
                // Left: timer + status
                StatusDot(color: hollow.success, size: 8, pulse: true),
                const SizedBox(width: HollowSpacing.sm),
                if (call.status == CallStatus.connecting)
                  Text(
                    'Connecting...',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 12,
                    ),
                  )
                else
                  Text(
                    _formatDuration(_duration),
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 12,
                      fontFeatures: [const FontFeature.tabularFigures()],
                    ),
                  ),

                // Center: avatars (audio-only — when video is on, they're in the rectangles)
                if (!hasAnyVideo) ...[
                  const Spacer(),
                  HollowAvatar(
                    peerId: localPeerId,
                    size: 60,
                    imageBytes: localAvatar,
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  HollowAvatar(
                    peerId: widget.peerId,
                    size: 60,
                    imageBytes: remoteAvatar,
                  ),
                ],

                const Spacer(),
                // Right: controls
                _buildControls(call, hollow),
              ],
            ),
          ),

        ],
      ),
      ),
    );
  }

  void _showVolumePopup(BuildContext context, Offset position) {
    final hollow = HollowTheme.of(context);
    final overlay = Overlay.of(context);
    OverlayEntry? entry;

    void remove() {
      entry?.remove();
      entry = null;
    }

    entry = OverlayEntry(
      builder: (ctx) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: remove,
                behavior: HitTestBehavior.opaque,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: position.dx,
              top: position.dy,
              child: Material(
                color: hollow.elevated,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                elevation: 4,
                child: StatefulBuilder(
                  builder: (ctx, setPopupState) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.volume2,
                              size: 12, color: hollow.textSecondary),
                          SizedBox(
                            width: 110,
                            height: 24,
                            child: SliderTheme(
                              data: SliderThemeData(
                                activeTrackColor: hollow.accent,
                                inactiveTrackColor: hollow.border,
                                thumbColor: hollow.accent,
                                overlayColor:
                                    hollow.accent.withValues(alpha: 0.08),
                                trackHeight: 2,
                                thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 4),
                                overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 8),
                              ),
                              child: Slider(
                                value: _remoteVolume,
                                min: 0.0,
                                max: 2.0,
                                onChanged: (v) {
                                  setPopupState(() {});
                                  setState(() => _remoteVolume = v);
                                  ref.read(callProvider.notifier)
                                      .setRemoteVolume(v);
                                },
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 28,
                            child: Text(
                              '${(_remoteVolume * 100).round()}%',
                              style: HollowTypography.caption.copyWith(
                                color: hollow.textSecondary,
                                fontSize: 10,
                              ),
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );

    overlay.insert(entry!);
  }

  /// Default: two equal video rectangles side by side. Click to expand.
  Widget _buildSideBySideVideo(
    HollowTheme hollow,
    String displayName,
    Uint8List? remoteAvatar,
    Uint8List? localAvatar,
    RTCVideoRenderer? remoteRenderer,
    RTCVideoRenderer? localRenderer,
    bool hasRemoteVideo,
    bool hasLocalVideo,
  ) {
    return Row(
      children: [
        // Local camera
        Expanded(
          child: GestureDetector(
            onTap: hasLocalVideo
                ? () => setState(() => _expandedRenderer = 'local')
                : null,
            child: Container(
              margin: const EdgeInsets.only(left: 4, top: 4, bottom: 4, right: 2),
              decoration: BoxDecoration(
                color: hollow.elevated,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
              ),
              clipBehavior: Clip.antiAlias,
              child: hasLocalVideo && localRenderer != null
                  ? RTCVideoView(
                      localRenderer,
                      mirror: true,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                    )
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          HollowAvatar(
                            peerId: ref.read(identityProvider).peerId ?? '',
                            size: 48,
                            imageBytes: localAvatar,
                          ),
                          const SizedBox(height: HollowSpacing.xs),
                          Text(
                            'You',
                            style: HollowTypography.caption.copyWith(
                              color: hollow.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
        // Remote camera
        Expanded(
          child: GestureDetector(
            onTap: hasRemoteVideo
                ? () => setState(() => _expandedRenderer = 'remote')
                : null,
            child: Container(
              margin: const EdgeInsets.only(left: 2, top: 4, bottom: 4, right: 4),
              decoration: BoxDecoration(
                color: hollow.elevated,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
              ),
              clipBehavior: Clip.antiAlias,
              child: hasRemoteVideo && remoteRenderer != null
                  ? RTCVideoView(
                      remoteRenderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                    )
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          HollowAvatar(
                            peerId: widget.peerId,
                            size: 48,
                            imageBytes: remoteAvatar,
                          ),
                          const SizedBox(height: HollowSpacing.xs),
                          Text(
                            displayName,
                            style: HollowTypography.caption.copyWith(
                              color: hollow.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  /// Fullscreen: one video fills the area, the other is PiP. Click to exit.
  Widget _buildFullscreenVideo(
    HollowTheme hollow,
    String displayName,
    Uint8List? remoteAvatar,
    Uint8List? localAvatar,
    RTCVideoRenderer? remoteRenderer,
    RTCVideoRenderer? localRenderer,
    bool hasRemoteVideo,
    bool hasLocalVideo,
  ) {
    final isLocalExpanded = _expandedRenderer == 'local';
    final mainRenderer = isLocalExpanded ? localRenderer : remoteRenderer;
    final pipRenderer = isLocalExpanded ? remoteRenderer : localRenderer;
    final hasPip = isLocalExpanded ? hasRemoteVideo : hasLocalVideo;

    return GestureDetector(
      onTap: () => setState(() {
        _expandedRenderer = null;
      }),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          // Main video (full area)
          Positioned.fill(
            child: mainRenderer != null
                ? RTCVideoView(
                    mainRenderer,
                    mirror: isLocalExpanded,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  )
                : Container(color: hollow.elevated),
          ),

          // PiP (bottom right)
          if (hasPip && pipRenderer != null)
            Positioned(
              right: 8,
              bottom: 8,
              child: Container(
                width: 120,
                height: 90,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: hollow.border, width: 1),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: RTCVideoView(
                    pipRenderer,
                    mirror: !isLocalExpanded,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            ),

          // "Click to exit fullscreen" hint (top left)
          Positioned(
            left: 8,
            top: 8,
            child: AnimatedOpacity(
              opacity: 0.7,
              duration: const Duration(milliseconds: 200),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.sm,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Click to exit',
                  style: HollowTypography.caption.copyWith(
                    color: Colors.white70,
                    fontSize: 10,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Screen share view: handles local sharing, remote sharing, and both sharing.
  Widget _buildScreenShareView(
      CallState call, HollowTheme hollow, RTCVideoRenderer? remoteRenderer) {
    final bothSharing = call.isScreenSharing && call.remoteScreenSharing;

    if (bothSharing) {
      // Both sharing — stacked: remote top, local banner bottom.
      return Column(
        children: [
          // Remote screen (top, takes most space)
          Expanded(
            flex: 3,
            child: Container(
              color: Colors.black,
              child: remoteRenderer != null
                  ? RTCVideoView(
                      remoteRenderer,
                      mirror: false,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          // Local banner (bottom, compact)
          Container(
            padding: const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
            color: hollow.elevated,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(LucideIcons.monitor,
                    size: 16, color: hollow.accent.withValues(alpha: 0.6)),
                const SizedBox(width: HollowSpacing.sm),
                Text(
                  'You are also sharing',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: HollowSpacing.md),
                HollowButton.danger(
                  onPressed: () =>
                      ref.read(callProvider.notifier).stopScreenShare(),
                  compact: true,
                  child: const Text('Stop'),
                ),
              ],
            ),
          ),
        ],
      );
    } else if (call.isScreenSharing) {
      // Only local sharing — show banner.
      return Container(
        color: hollow.elevated,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.monitor,
                size: 40,
                color: hollow.accent.withValues(alpha: 0.6),
              ),
              const SizedBox(height: HollowSpacing.md),
              Text(
                'You are sharing your screen',
                style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: HollowSpacing.md),
              HollowButton.danger(
                onPressed: () =>
                    ref.read(callProvider.notifier).stopScreenShare(),
                compact: true,
                child: const Text('Stop Sharing'),
              ),
            ],
          ),
        ),
      );
    } else {
      // Only remote sharing — show their screen (Contain, never mirror).
      return Container(
        color: Colors.black,
        child: remoteRenderer != null
            ? RTCVideoView(
                remoteRenderer,
                mirror: false,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              )
            : Center(
                child: Text(
                  'Waiting for screen share...',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                  ),
                ),
              ),
      );
    }
  }

  Future<void> _handleScreenShareToggle(CallState call) async {
    if (call.isScreenSharing) {
      ref.read(callProvider.notifier).stopScreenShare();
    } else {
      final selection = await showScreenShareDialog(context);
      if (selection != null && mounted) {
        ref.read(callProvider.notifier).startScreenShare(
              sourceId: selection.sourceId,
              width: selection.width,
              height: selection.height,
              fps: selection.fps,
              shareAudio: selection.shareAudio,
            );
      }
    }
  }

  /// Shared row of call controls: mute, camera, screen share, end call.
  Widget _buildControls(CallState call, HollowTheme hollow) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HollowTooltip(
          message: call.isMuted ? 'Unmute' : 'Mute',
          child: HollowPressable(
            onTap: () => ref.read(callProvider.notifier).toggleMute(),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(HollowSpacing.xs),
            child: Icon(
              call.isMuted ? LucideIcons.micOff : LucideIcons.mic,
              size: 16,
              color: call.isMuted ? hollow.error : hollow.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: HollowSpacing.xs),
        HollowTooltip(
          message: call.isVideoEnabled
              ? 'Turn off camera'
              : 'Turn on camera',
          child: HollowPressable(
            onTap: call.status == CallStatus.active
                ? () => ref.read(callProvider.notifier).toggleVideo()
                : null,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(HollowSpacing.xs),
            child: Icon(
              call.isVideoEnabled
                  ? LucideIcons.video
                  : LucideIcons.videoOff,
              size: 16,
              color: (call.isVideoEnabled
                      ? hollow.accent
                      : hollow.textSecondary),
            ),
          ),
        ),
        // Screen share (desktop only)
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) ...[
          const SizedBox(width: HollowSpacing.xs),
          HollowTooltip(
            message: call.isScreenSharing
                ? 'Stop sharing'
                : 'Share screen',
            child: HollowPressable(
              onTap: call.status == CallStatus.active
                  ? () => _handleScreenShareToggle(call)
                  : null,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child: Icon(
                call.isScreenSharing
                    ? LucideIcons.monitorOff
                    : LucideIcons.monitor,
                size: 16,
                color: call.isScreenSharing
                    ? hollow.accent
                    : hollow.textSecondary,
              ),
            ),
          ),
        ],
        const SizedBox(width: HollowSpacing.sm),
        HollowTooltip(
          message: 'End call',
          child: HollowPressable(
            onTap: () => ref.read(callProvider.notifier).endCall(),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.sm,
              vertical: HollowSpacing.xs,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: hollow.error.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
              ),
              child: Icon(
                LucideIcons.phoneOff,
                size: 14,
                color: hollow.error,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Chat overlay slider — slides the chat panel in/out during screen share.
// ---------------------------------------------------------------------------

class _ChatOverlaySlider extends StatefulWidget {
  final bool visible;
  final Widget child;
  final VoidCallback onHoverEnter;
  final VoidCallback onHoverExit;

  const _ChatOverlaySlider({
    required this.visible,
    required this.child,
    required this.onHoverEnter,
    required this.onHoverExit,
  });

  @override
  State<_ChatOverlaySlider> createState() => _ChatOverlaySliderState();
}

class _ChatOverlaySliderState extends State<_ChatOverlaySlider>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curved;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.normal,
      value: widget.visible ? 1.0 : 0.0,
    );
    _curved = CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.enter,
      reverseCurve: HollowCurves.exit,
    );
  }

  @override
  void didUpdateWidget(covariant _ChatOverlaySlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible != oldWidget.visible) {
      if (widget.visible) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curved,
      builder: (context, child) {
        if (_curved.value == 0.0) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: Alignment.centerRight,
            widthFactor: _curved.value,
            child: FadeTransition(
              opacity: _curved,
              child: MouseRegion(
                onEnter: (_) => widget.onHoverEnter(),
                onExit: (_) => widget.onHoverExit(),
                child: child,
              ),
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

// ---------------------------------------------------------------------------
// Screen share full-bleed view — fills entire chat area as background.
// ---------------------------------------------------------------------------

class _ScreenShareFullView extends ConsumerWidget {
  final String peerId;
  const _ScreenShareFullView({required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callProvider);
    final hollow = HollowTheme.of(context);
    final remoteRenderer = ref.read(callProvider.notifier).screenShareRenderer;
    final bothSharing = call.isScreenSharing && call.remoteScreenSharing;

    if (bothSharing) {
      // Both sharing — remote screen fills area, banner at top.
      return Stack(
        children: [
          Positioned.fill(
            child: Container(
              color: Colors.black,
              child: remoteRenderer != null
                  ? RTCVideoView(
                      remoteRenderer,
                      mirror: false,
                      objectFit: RTCVideoViewObjectFit
                          .RTCVideoViewObjectFitContain,
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          Positioned(
            top: HollowSpacing.md,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg,
                  vertical: HollowSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: hollow.surface.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(HollowRadius.pill),
                  border: Border.all(
                    color: hollow.border.withValues(alpha: 0.5),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.monitor,
                        size: 16,
                        color: hollow.accent.withValues(alpha: 0.6)),
                    const SizedBox(width: HollowSpacing.sm),
                    Text(
                      'You are also sharing',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.md),
                    HollowButton.danger(
                      onPressed: () =>
                          ref.read(callProvider.notifier).stopScreenShare(),
                      compact: true,
                      child: const Text('Stop'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    } else if (call.isScreenSharing) {
      // Only local sharing — centered banner.
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.monitor,
                size: 56,
                color: hollow.accent.withValues(alpha: 0.5),
              ),
              const SizedBox(height: HollowSpacing.lg),
              Text(
                'You are sharing your screen',
                style: HollowTypography.heading.copyWith(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: HollowSpacing.sm),
              Text(
                'Others can see your screen',
                style: HollowTypography.body.copyWith(
                  color: hollow.textSecondary,
                ),
              ),
              const SizedBox(height: HollowSpacing.lg),
              HollowButton.danger(
                onPressed: () =>
                    ref.read(callProvider.notifier).stopScreenShare(),
                child: const Text('Stop Sharing'),
              ),
            ],
          ),
        ),
      );
    } else {
      // Only remote sharing — their screen fills area.
      return Container(
        color: Colors.black,
        child: remoteRenderer != null
            ? RTCVideoView(
                remoteRenderer,
                mirror: false,
                objectFit:
                    RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              )
            : Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      LucideIcons.monitor,
                      size: 48,
                      color: hollow.textSecondary.withValues(alpha: 0.3),
                    ),
                    const SizedBox(height: HollowSpacing.md),
                    Text(
                      'Waiting for screen share...',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Screen share controls overlay — floating pill with call controls.
// ---------------------------------------------------------------------------

class _ScreenShareControlsOverlay extends ConsumerStatefulWidget {
  final String peerId;
  const _ScreenShareControlsOverlay({required this.peerId});

  @override
  ConsumerState<_ScreenShareControlsOverlay> createState() =>
      _ScreenShareControlsOverlayState();
}

class _ScreenShareControlsOverlayState
    extends ConsumerState<_ScreenShareControlsOverlay> {
  Timer? _durationTimer;
  Duration _duration = Duration.zero;

  @override
  void dispose() {
    _durationTimer?.cancel();
    super.dispose();
  }

  void _startTimer(DateTime startedAt) {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _duration = DateTime.now().difference(startedAt);
      });
    });
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _handleScreenShareToggle(CallState call) async {
    if (call.isScreenSharing) {
      ref.read(callProvider.notifier).stopScreenShare();
    } else {
      final selection = await showScreenShareDialog(context);
      if (selection != null && mounted) {
        ref.read(callProvider.notifier).startScreenShare(
              sourceId: selection.sourceId,
              width: selection.width,
              height: selection.height,
              fps: selection.fps,
              shareAudio: selection.shareAudio,
            );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callProvider);
    final hollow = HollowTheme.of(context);

    // Start timer.
    if (call.status == CallStatus.active && call.startedAt != null) {
      if (_durationTimer == null) {
        _duration = DateTime.now().difference(call.startedAt!);
        _startTimer(call.startedAt!);
      }
    } else {
      _durationTimer?.cancel();
      _durationTimer = null;
    }

    final profiles = ref.watch(profileProvider);
    final displayName = displayNameFor(profiles, widget.peerId);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(HollowRadius.pill),
        border: Border.all(
          color: hollow.border.withValues(alpha: 0.5),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(color: hollow.success, size: 8, pulse: true),
          const SizedBox(width: HollowSpacing.sm),
          if (call.status == CallStatus.connecting)
            Text(
              'Connecting...',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 12,
              ),
            )
          else ...[
            Text(
              displayName,
              style: HollowTypography.caption.copyWith(
                color: hollow.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Text(
              _formatDuration(_duration),
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 12,
                fontFeatures: [const FontFeature.tabularFigures()],
              ),
            ),
          ],
          const SizedBox(width: HollowSpacing.lg),
          // Mute
          HollowTooltip(
            message: call.isMuted ? 'Unmute' : 'Mute',
            child: HollowPressable(
              onTap: () => ref.read(callProvider.notifier).toggleMute(),
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child: Icon(
                call.isMuted ? LucideIcons.micOff : LucideIcons.mic,
                size: 16,
                color: call.isMuted ? hollow.error : hollow.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: HollowSpacing.xs),
          // Camera toggle (independent of screen share — separate PCs)
          HollowTooltip(
            message: call.isVideoEnabled
                ? 'Turn off camera'
                : 'Turn on camera',
            child: HollowPressable(
              onTap: call.status == CallStatus.active
                  ? () => ref.read(callProvider.notifier).toggleVideo()
                  : null,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child: Icon(
                call.isVideoEnabled
                    ? LucideIcons.video
                    : LucideIcons.videoOff,
                size: 16,
                color: call.isVideoEnabled
                    ? hollow.accent
                    : hollow.textSecondary,
              ),
            ),
          ),
          // Screen share toggle (desktop only)
          if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) ...[
            const SizedBox(width: HollowSpacing.xs),
            HollowTooltip(
              message:
                  call.isScreenSharing ? 'Stop sharing' : 'Share screen',
              child: HollowPressable(
                onTap: call.status == CallStatus.active
                    ? () => _handleScreenShareToggle(call)
                    : null,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(
                  call.isScreenSharing
                      ? LucideIcons.monitorOff
                      : LucideIcons.monitor,
                  size: 16,
                  color: call.isScreenSharing
                      ? hollow.accent
                      : hollow.textSecondary,
                ),
              ),
            ),
          ],
          const SizedBox(width: HollowSpacing.sm),
          // End call
          HollowTooltip(
            message: 'End call',
            child: HollowPressable(
              onTap: () => ref.read(callProvider.notifier).endCall(),
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm,
                vertical: HollowSpacing.xs,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.sm,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: hollow.error.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                ),
                child: Icon(
                  LucideIcons.phoneOff,
                  size: 14,
                  color: hollow.error,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DmProfilePanelSlider extends StatefulWidget {
  final bool visible;
  final String peerId;
  const _DmProfilePanelSlider({required this.visible, required this.peerId});

  @override
  State<_DmProfilePanelSlider> createState() => _DmProfilePanelSliderState();
}

class _DmProfilePanelSliderState extends State<_DmProfilePanelSlider>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curved;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.normal,
      value: widget.visible ? 1.0 : 0.0,
    );
    _curved = CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.enter,
      reverseCurve: HollowCurves.exit,
    );
  }

  @override
  void didUpdateWidget(_DmProfilePanelSlider old) {
    super.didUpdateWidget(old);
    if (widget.visible != old.visible) {
      widget.visible ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curved,
      builder: (context, child) {
        if (_curved.value == 0.0) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: _curved.value,
            child: FadeTransition(
              opacity: _curved,
              child: child,
            ),
          ),
        );
      },
      child: _DmProfilePanel(peerId: widget.peerId),
    );
  }
}

/// Profile panel shown on the left side of DM chats.
class _DmProfilePanel extends ConsumerWidget {
  final String peerId;
  const _DmProfilePanel({required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final profile = profiles[peerId];
    final localNicknames = ref.watch(localNicknameProvider);
    final localNick = localNicknames[peerId];
    final isOnline = ref.watch(peersProvider).containsKey(peerId);
    final friends = ref.watch(friendsProvider);
    final friendInfo = friends[peerId];

    final displayName = profile?.displayName ?? '';
    final status = profile?.status ?? '';
    final aboutMe = profile?.aboutMe ?? '';
    final bannerBytes = profile?.bannerBytes;
    final avatarBytes = profile?.avatarBytes;

    final shownName = displayName.isNotEmpty
        ? displayName
        : (peerId.length > 8 ? '${peerId.substring(0, 8)}...' : peerId);

    final bannerColor = _bannerColorFromId(peerId);

    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(
          right: BorderSide(color: hollow.border),
        ),
      ),
      child: Column(
        children: [
          // Banner
          SizedBox(
            height: 90,
            width: double.infinity,
            child: bannerBytes != null && bannerBytes.isNotEmpty
                ? AnimatedGifImage(bytes: bannerBytes, height: 90, width: double.infinity, fit: BoxFit.cover,
                    errorWidget: _bannerGradient(bannerColor))
                : _bannerGradient(bannerColor),
          ),

          // Avatar overlapping banner + content
          Transform.translate(
            offset: const Offset(0, -32),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
              child: Column(
                children: [
                  // Avatar with status dot
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(hollow.radiusMd + 2),
                          border: Border.all(color: hollow.surface, width: 3),
                        ),
                        child: HollowAvatar(
                          peerId: peerId,
                          size: 64,
                          imageBytes: avatarBytes,
                          animate: true,
                        ),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          decoration: BoxDecoration(
                            color: hollow.surface,
                            shape: BoxShape.circle,
                          ),
                          padding: const EdgeInsets.all(2),
                          child: StatusDot(
                            color: isOnline ? hollow.success : hollow.textSecondary,
                            size: 10,
                            pulse: isOnline,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: HollowSpacing.sm),

                  // Name(s)
                  if (localNick != null && localNick.isNotEmpty) ...[
                    Text(
                      localNick,
                      style: HollowTypography.subheading.copyWith(
                        color: hollow.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                    Text(
                      shownName,
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ] else
                    Text(
                      shownName,
                      style: HollowTypography.subheading.copyWith(
                        color: hollow.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),

                  // Status
                  if (status.isNotEmpty) ...[
                    const SizedBox(height: HollowSpacing.xxs),
                    Text(
                      status,
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontStyle: FontStyle.italic,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Scrollable content
          Expanded(
            child: Transform.translate(
              offset: const Offset(0, -16),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    // About Me (in quotes, italic)
                    if (aboutMe.isNotEmpty) ...[
                      Container(height: 1, color: hollow.border),
                      const SizedBox(height: HollowSpacing.sm),
                      Text(
                        '"$aboutMe"',
                        style: HollowTypography.body.copyWith(
                          color: hollow.textSecondary,
                          fontStyle: FontStyle.italic,
                          fontSize: 12,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: HollowSpacing.sm),
                      Container(height: 1, color: hollow.border),
                    ],

                    const SizedBox(height: HollowSpacing.sm),

                    // Set/Edit Nickname button (outline, full width, like Edit Profile)
                    SizedBox(
                      width: double.infinity,
                      child: HollowButton.outline(
                        onPressed: () {
                          showLocalNicknameDialog(
                            context, ref, peerId,
                            currentNickname: localNick ?? '',
                          );
                        },
                        compact: true,
                        icon: Icon(
                          localNick != null && localNick.isNotEmpty
                              ? LucideIcons.pencil
                              : LucideIcons.tag,
                        ),
                        child: Text(
                          localNick != null && localNick.isNotEmpty
                              ? 'Edit Nickname'
                              : 'Set Nickname',
                        ),
                      ),
                    ),

                    const SizedBox(height: HollowSpacing.xs),

                    // Friend status
                    if (friendInfo != null && friendInfo.status == 'accepted')
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(LucideIcons.userCheck, size: 14, color: hollow.success),
                          const SizedBox(width: HollowSpacing.xs),
                          Text(
                            'Friends',
                            style: HollowTypography.body.copyWith(
                              color: hollow.success,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),

                    const SizedBox(height: HollowSpacing.sm),
                    Container(height: 1, color: hollow.border),
                    const SizedBox(height: HollowSpacing.sm),

                    // Peer ID (copy on tap)
                    HollowPressable(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: peerId));
                        HollowToast.show(
                          context,
                          'Peer ID copied',
                          type: HollowToastType.success,
                          duration: const Duration(seconds: 1),
                        );
                      },
                      subtle: true,
                      borderRadius: BorderRadius.circular(hollow.radiusSm),
                      padding: const EdgeInsets.symmetric(
                        horizontal: HollowSpacing.sm,
                        vertical: HollowSpacing.xs,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(LucideIcons.copy, size: 10,
                              color: hollow.textSecondary.withValues(alpha: 0.5)),
                          const SizedBox(width: HollowSpacing.xs),
                          Flexible(
                            child: Text(
                              peerId,
                              style: HollowTypography.mono.copyWith(
                                color: hollow.textSecondary.withValues(alpha: 0.5),
                                fontSize: 8,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bannerGradient(Color bannerColor) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [bannerColor, bannerColor.withValues(alpha: 0.7)],
        ),
      ),
    );
  }
}

/// Banner color from peer ID.
Color _bannerColorFromId(String id) {
  final hash = id.hashCode;
  final hue = ((hash % 360).abs() + 40) % 360;
  return HSLColor.fromAHSL(1.0, hue.toDouble(), 0.45, 0.35).toColor();
}

/// Typing indicator bar shown above the input area.
/// Displays up to 3 names, or "Several people are typing..." for 4+.
class TypingIndicatorBar extends StatelessWidget {
  final List<String> names;

  const TypingIndicatorBar({super.key, required this.names});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final String text;
    if (names.length == 1) {
      text = '${names[0]} is typing';
    } else if (names.length == 2) {
      text = '${names[0]} and ${names[1]} are typing';
    } else if (names.length == 3) {
      text = '${names[0]}, ${names[1]}, and ${names[2]} are typing';
    } else {
      text = 'Several people are typing';
    }

    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
      alignment: Alignment.centerLeft,
      color: hollow.surface,
      child: Row(
        children: [
          Text(
            text,
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontStyle: FontStyle.italic,
              fontSize: 11,
            ),
          ),
          const SizedBox(width: HollowSpacing.xs),
          TypingDots(color: hollow.textSecondary),
        ],
      ),
    );
  }
}

/// Animated bouncing dots for typing indicators.
class TypingDots extends StatefulWidget {
  final Color color;

  const TypingDots({super.key, required this.color});

  @override
  State<TypingDots> createState() => TypingDotsState();
}

class TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: null,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final delay = i * 0.2;
            final t = (_controller.value - delay).clamp(0.0, 1.0);
            final bounce = t < 0.5
                ? (t * 2) // 0→1
                : (1 - (t - 0.5) * 2); // 1→0
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 1),
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.4 + bounce * 0.6),
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}

/// Floating pill that appears when scrolled away from the bottom.
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
