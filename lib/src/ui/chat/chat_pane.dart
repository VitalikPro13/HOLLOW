import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/ui/chat/chat_drop_zone.dart';
import 'package:hollow/src/ui/chat/chat_input_shortcuts.dart';
import 'package:hollow/src/ui/chat/emoji_picker.dart';
import 'package:hollow/src/ui/chat/gif_picker.dart';
import 'package:hollow/src/ui/chat/sticker_picker.dart';
import 'package:hollow/src/ui/chat/emote_composer.dart';
import 'package:hollow/src/ui/chat/emote_image.dart';
import 'package:hollow/src/core/providers/emote_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/providers/banner_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/event_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/download_manager_provider.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/speaking_provider.dart';
import 'package:hollow/src/ui/components/call_duration_text.dart';
import 'package:hollow/src/core/providers/recording_provider.dart';
import 'package:hollow/src/ui/components/recording_indicator.dart';
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
import 'package:hollow/src/ui/components/connection_progress.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/speaking_border.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/chat/voice_recorder_bar.dart';
import 'package:hollow/src/core/services/voice_message_recorder.dart';
import 'package:hollow/src/core/services/macos_version.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/profile_card_popup.dart';
import 'package:hollow/src/ui/components/saved_messages_avatar.dart';
import 'package:hollow/src/ui/components/share_volume_control.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/large_file_share_dialog.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/core/providers/verified_peers_provider.dart';
import 'package:hollow/src/ui/components/security_alert_banner.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/dialogs/verify_contact_dialog.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:hollow/src/ui/dialogs/report_user_dialog.dart';
import 'package:hollow/src/ui/dialogs/screen_share_dialog.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:hollow/src/ui/chat/chat_pane_shared.dart';

// The twins' shared building blocks (grouping/date helpers, DateSeparator,
// typing bar, unread pill, reply/staged bars, reversed-list shell) live in
// chat_pane_shared.dart; re-exported here for the existing consumers
// (mobile routes, archive viewers).
export 'package:hollow/src/ui/chat/chat_pane_shared.dart'
    show
        shouldGroup,
        shouldShowDateSeparator,
        DateSeparator,
        TypingIndicatorBar,
        TypingDots,
        chatSelectionArea,
        selectionMustBeScopedToRows;

/// Whether the DM profile panel is visible.
final dmProfilePanelProvider = StateProvider<bool>((ref) => true);

// ---------------------------------------------------------------------------
// Shared DM call helpers — used by the pane, the inline call panel, and the
// screen-share overlays. Kept top-level so the former per-class twins can't
// drift apart again.
// ---------------------------------------------------------------------------

/// Count active video sources (cameras + screens, both sides) in a DM call.
/// Used to decide whether to show the source-switcher pill (2+ sources).
int _countActiveDmSources(CallState call) {
  int count = 0;
  if (call.isVideoEnabled) count++;
  if (call.remoteVideoEnabled) count++;
  if (call.isScreenSharing) count++;
  if (call.remoteScreenSharing) count++;
  return count;
}

/// Ordered source list for the switcher pills: screens first, then cameras —
/// matches voice_channel_pane's _buildSharerSwitcher order.
List<({String peerId, String type})> _dmActiveSources(
    CallState call, String localPeerId, String remotePeerId) {
  return [
    if (call.isScreenSharing) (peerId: localPeerId, type: 'screen'),
    if (call.remoteScreenSharing) (peerId: remotePeerId, type: 'screen'),
    if (call.isVideoEnabled) (peerId: localPeerId, type: 'camera'),
    if (call.remoteVideoEnabled) (peerId: remotePeerId, type: 'camera'),
  ];
}

/// The source-switcher pill shell: one tab per active source (icon + avatar +
/// name) with focus highlighting. Shared by the full-bleed screen-share pill
/// and the inline call panel pill — only focus derivation and tap handling
/// differ between the two.
Widget _dmSourcePill({
  required HollowTheme hollow,
  required Map<String, storage_api.UserProfile> profiles,
  required List<({String peerId, String type})> sources,
  required String localPeerId,
  required String? focusedPeerId,
  required String? focusedType,
  required void Function(String peerId, String type) onTapSource,
}) {
  return Container(
    padding: const EdgeInsets.symmetric(
      horizontal: HollowSpacing.sm,
      vertical: HollowSpacing.xs,
    ),
    decoration: BoxDecoration(
      color: hollow.surface.withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(HollowRadius.pill),
      border: Border.all(color: hollow.border.withValues(alpha: 0.5)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: sources.map((source) {
        final name = displayNameFor(profiles, source.peerId);
        final isFocused =
            source.peerId == focusedPeerId && source.type == focusedType;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xs),
          child: HollowPressable(
            onTap: () => onTapSource(source.peerId, source.type),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            backgroundColor: isFocused ? hollow.accentMuted : null,
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.sm,
              vertical: HollowSpacing.xs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  source.type == 'screen'
                      ? LucideIcons.monitor
                      : LucideIcons.video,
                  size: 12,
                  color: isFocused ? hollow.accent : hollow.textSecondary,
                ),
                const SizedBox(width: HollowSpacing.xs),
                HollowAvatar(
                  peerId: source.peerId,
                  size: 18,
                ),
                const SizedBox(width: HollowSpacing.xs),
                Text(
                  source.peerId == localPeerId ? 'You' : name,
                  style: HollowTypography.caption.copyWith(
                    color: isFocused ? hollow.textPrimary : hollow.textSecondary,
                    fontWeight: isFocused ? FontWeight.w600 : FontWeight.w400,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    ),
  );
}

/// Screen-share quality/source label chip shown on the corner of share tiles.
Widget _shareLabelChip(HollowTheme hollow, String label) {
  return Container(
    padding: const EdgeInsets.symmetric(
      horizontal: HollowSpacing.sm,
      vertical: HollowSpacing.xs,
    ),
    decoration: BoxDecoration(
      color: hollow.surface.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      border: Border.all(color: hollow.border),
    ),
    child: Text(
      label,
      style: HollowTypography.caption.copyWith(
        color: hollow.textSecondary,
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

/// Toggle screen share: stop if sharing, else pick a source and start.
/// Shared by the inline call panel and the screen-share controls overlay.
Future<void> _toggleScreenShare(
    BuildContext context, WidgetRef ref, CallState call) async {
  if (call.isScreenSharing) {
    ref.read(callProvider.notifier).stopScreenShare();
  } else {
    final selection = await showScreenShareDialog(context);
    if (selection != null && context.mounted) {
      ref.read(callProvider.notifier).startScreenShare(
            sourceId: selection.sourceId,
            width: selection.width,
            height: selection.height,
            fps: selection.fps,
            shareAudio: selection.shareAudio,
            pid: selection.pid,
            windowHwnd: selection.windowHwnd,
            profile: selection.profile,
          );
    }
  }
}

// Call-control buttons shared by the inline call panel (20px icons, sm
// padding) and the screen-share controls overlay (smaller icons, xs padding).

Widget _muteCallButton(WidgetRef ref, HollowTheme hollow, CallState call,
    {required double iconSize, required EdgeInsetsGeometry padding}) {
  final label = call.isMuted ? 'Unmute' : 'Mute';
  return HollowTooltip(
    message: label,
    child: HollowPressable(
      semanticLabel: label,
      onTap: () => ref.read(callProvider.notifier).toggleMute(),
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: padding,
      child: Icon(
        call.isMuted ? LucideIcons.micOff : LucideIcons.mic,
        size: iconSize,
        color: call.isMuted ? hollow.error : hollow.textSecondary,
      ),
    ),
  );
}

Widget _cameraCallButton(WidgetRef ref, HollowTheme hollow, CallState call,
    {required double iconSize, required EdgeInsetsGeometry padding}) {
  final label = call.isVideoEnabled ? 'Turn off camera' : 'Turn on camera';
  return HollowTooltip(
    message: label,
    child: HollowPressable(
      semanticLabel: label,
      onTap: call.status == CallStatus.active
          ? () => ref.read(callProvider.notifier).toggleVideo()
          : null,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: padding,
      child: Icon(
        call.isVideoEnabled ? LucideIcons.video : LucideIcons.videoOff,
        size: iconSize,
        color: call.isVideoEnabled ? hollow.accent : hollow.textSecondary,
      ),
    ),
  );
}

Widget _screenShareCallButton(
    BuildContext context, WidgetRef ref, HollowTheme hollow, CallState call,
    {required double iconSize, required EdgeInsetsGeometry padding}) {
  return HollowTooltip(
    message: call.isScreenSharing ? 'Stop sharing' : 'Share screen',
    child: HollowPressable(
      semanticLabel:
          call.isScreenSharing ? 'Stop sharing screen' : 'Share screen',
      onTap: call.status == CallStatus.active
          ? () => _toggleScreenShare(context, ref, call)
          : null,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: padding,
      child: Icon(
        call.isScreenSharing ? LucideIcons.monitorOff : LucideIcons.monitor,
        size: iconSize,
        color: call.isScreenSharing ? hollow.accent : hollow.textSecondary,
      ),
    ),
  );
}

Widget _endCallButton(WidgetRef ref, HollowTheme hollow,
    {required double iconSize, required EdgeInsetsGeometry innerPadding}) {
  return HollowTooltip(
    message: 'End call',
    child: HollowPressable(
      semanticLabel: 'End call',
      onTap: () => ref.read(callProvider.notifier).endCall(),
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xs,
      ),
      child: Container(
        padding: innerPadding,
        decoration: BoxDecoration(
          color: hollow.error.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(hollow.radiusSm),
        ),
        child: Icon(
          LucideIcons.phoneOff,
          size: iconSize,
          color: hollow.error,
        ),
      ),
    ),
  );
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
  bool _isPicking = false;
  String? _editingMessageId;
  String? _replyToMessageId;
  String? _replyToText;
  String? _replyToSenderName;
  String? _replyToImagePath;
  DateTime? _lastTypingSent;
  int? _highlightIndex;
  bool _showScrollPill = false;
  /// Staged file attachment (user picked but hasn't sent yet).
  String? _stagedFilePath;
  String? _stagedFileName;
  bool _stagedFileIsImage = false;
  /// True while the user is recording a voice message — swaps the text
  /// input row for the [VoiceRecorderBar].
  bool _isRecordingVoice = false;
  /// Staged link preview (Phase 6.75). Set while the user is typing a URL
  /// and Hollow is fetching its OG metadata in the background.
  String? _stagedPreviewUrl;
  network_api.LinkPreviewRef? _stagedPreview;
  bool _stagedPreviewLoading = false;
  HollowLink? _stagedHollowLink;
  Timer? _urlDebounce;
  static final RegExp _urlRegex = RegExp(r'(?:https?|hollow)://[^\s<>"' "'" r')\]}]+');
  Timer? _overlayHideTimer;
  bool _overlaysVisible = true;
  bool _chatOverlayPinned = false; // User explicitly toggled chat open

  @override
  void initState() {
    super.initState();
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
    // Auto-mark as read when the user ARRIVES at the bottom. Edge-triggered
    // (mobile-style) — this used to run per scroll frame while at the bottom,
    // i.e. a map-clone + FFI settings write on every scroll tick.
    if (nearBottom && !_wasNearBottom) {
      final msgs = ref.read(chatProvider)[widget.peerId];
      // Reached the bottom: release the freeze. If messages were held back
      // while reading, snap to the true newest row.
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
      // Left the bottom: freeze the display so arrivals can't shift the
      // reading position. (No setState — the display is unchanged until a
      // message actually arrives, and that arrival rebuilds via the watch.)
      _frozenLen ??= (ref.read(chatProvider)[widget.peerId] ?? const []).length;
    }
    _wasNearBottom = nearBottom;
  }

  Future<void> _loadHistory() async {
    if (_historyLoaded) return;
    _historyLoaded = true;
    await ref.read(chatProvider.notifier).loadHistory(widget.peerId);
    if (!mounted) return;
    setState(() {});
    // Pin to the latest message. ScrollablePositionedList only honors
    // `initialScrollIndex` at first build; when loadHistory grows the list
    // from its initial (possibly 1-message) state, we need an explicit jump.
    _jumpToBottom();
    // Mark DM as read now that messages are loaded.
    final msgs = ref.read(chatProvider)[widget.peerId];
    final latestId = msgs != null && msgs.isNotEmpty
        ? msgs.last.messageId
        : null;
    ref.read(unreadProvider.notifier).markDmSeen(widget.peerId, latestId);
    // Re-request any file whose bytes never arrived (live WebRTC transfer failed)
    // from the friend or an online sibling that has them — so an image stuck as a
    // metadata-only bubble fills in when you open the thread.
    ref.read(eventStreamProvider.notifier)
        .requestMissingDmFilesOnOpen(widget.peerId);
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

  /// Source switcher pill for the full-bleed screen share view. Shows one
  /// tab per active source (camera or screen, local or remote). ALL tabs
  /// are clickable — tapping a tab sets [focusedDmSourceProvider] to that
  /// (peerId, type) pair, and the screen-share view's big tile updates to
  /// show that source.
  Widget _buildScreenShareSourcePill(
    HollowTheme hollow,
    CallState call,
    String localPeerId,
    String remotePeerId,
  ) {
    final profiles = ref.watch(profileProvider);
    final focused = ref.watch(focusedDmSourceProvider);
    return MouseRegion(
      onEnter: (_) => _pinOverlays(),
      onExit: (_) => _resetOverlayTimer(),
      child: _dmSourcePill(
        hollow: hollow,
        profiles: profiles,
        sources: _dmActiveSources(call, localPeerId, remotePeerId),
        localPeerId: localPeerId,
        focusedPeerId: focused.peerId,
        focusedType: focused.type,
        onTapSource: (peerId, type) {
          ref.read(focusedDmSourceProvider.notifier).state =
              DmFocusedSource(peerId: peerId, type: type);
        },
      ),
    );
  }

  @override
  void dispose() {
    _overlayHideTimer?.cancel();
    _urlDebounce?.cancel();
    _emoteAutocomplete.dismiss();
    _itemPositionsListener.itemPositions.removeListener(_onScrollPositionChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ── Reversed-list scroll model ────────────────────────────────────────
  // The list renders `reverse: true` with the NEWEST message at index 0
  // pinned to the bottom, so "at bottom" is simply "index 0 visible" —
  // length-independent and immune to burst growth (the old sentinel model
  // compared stale positions against a moving length and disengaged under
  // fast flow). While the user reads history the display list is FROZEN
  // (_frozenLen): arrivals are held out of the list so the view can never
  // shift under them — the unread pill takes over. Reaching the bottom,
  // tapping the pill, or sending releases the freeze and snaps (jumpTo,
  // never animated) to the newest message.

  /// Non-null while the user is scrolled up: display list capped here.
  int? _frozenLen;

  /// The messages currently displayed (frozen prefix while scrolled up).
  List<ChatMessage> _displayMessages(List<ChatMessage> messages) {
    final frozen = _frozenLen;
    if (frozen == null || messages.length <= frozen) return messages;
    return messages.sublist(0, frozen);
  }

  bool get _isNearBottom {
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return true;
    return positions.any((p) => p.index <= 0);
  }

  void _releaseFreeze() {
    if (_frozenLen != null) setState(() => _frozenLen = null);
  }

  /// Snap to the newest message — INSTANT. The old animated 150ms scroll on
  /// receive rendered the new row first and then glided to it (a visible
  /// jump-then-move); sends always used the instant jump and felt right.
  /// One motion, no animation, everywhere.
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
        _displayMessages(ref.read(chatProvider)[widget.peerId] ?? []);
    if (index < 0 || index >= messages.length) return;
    setState(() => _highlightIndex = index);
    _itemScrollController.scrollTo(
      index: messages.length - 1 - index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      // Reversed alignment measures from the BOTTOM edge — 0.6 lands the
      // target in the upper-middle area like the old 0.3-from-top did.
      alignment: 0.6,
    );
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightIndex = null);
    });
  }

  void _onTextChanged(String text) {
    // Debounced URL detection for link previews (Phase 6.75).
    _urlDebounce?.cancel();
    _urlDebounce = Timer(const Duration(milliseconds: 600), _detectUrl);

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
      serverId: '',
      channelId: widget.peerId,
    ).catchError((_) {});
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
      // Bail out if the user changed the URL (or dismissed it) while we
      // were fetching.
      if (!mounted || _stagedPreviewUrl != url) return;
      setState(() {
        _stagedPreview = preview;
        _stagedPreviewLoading = false;
      });
    } catch (_) {
      if (!mounted || _stagedPreviewUrl != url) return;
      // Failed silently — keep the URL but drop the staged card entirely.
      setState(() {
        _stagedPreviewUrl = null;
        _stagedPreview = null;
        _stagedPreviewLoading = false;
      });
    }
  }

  Future<void> _handleSend() async {
    _emoteAutocomplete.dismiss();
    if (_stagedFilePath != null) {
      await _sendStagedFile();
      return;
    }
    // Expand inline-emote placeholders to [e:name:hash] wire tokens.
    final text = _controller.expandedText().trim();
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
    try {
      await ref
          .read(chatProvider.notifier)
          .sendMessage(widget.peerId, text,
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
  /// Files over 34 MB prompt to host as a Hollow Share (see [_pickAndStageFile]).
  Future<void> _handleDroppedFile(String path, String name, int sizeBytes) async {
    if (!mounted) return;

    // Over 34 MB: confirm hosting it as a Hollow Share rather than rejecting.
    if (sizeBytes > kLargeFileThresholdBytes) {
      final ok = await confirmLargeFileShare(context,
          fileName: name, sizeBytes: sizeBytes);
      if (!ok || !mounted) return;
    }

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

      // Over 34 MB: confirm hosting it as a Hollow Share rather than rejecting.
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
      // Defer the re-focus to after the OS returns window focus from the native
      // file dialog. A synchronous requestFocus() here races that restoration —
      // Flutter marks the node focused but keystrokes don't land, so the user has
      // to click the field a few times. A post-frame callback runs after the
      // window-focus event settles.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    } finally { _isPicking = false; }
  }

  /// Called by [VoiceRecorderBar] when the user taps send. Stages the
  /// `.ogg` file produced by the recorder and kicks off send immediately —
  /// voice messages shouldn't need a confirmation click.
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

    setState(() {
      _stagedFilePath = null;
      _stagedFileName = null;
      _stagedFileIsImage = false;
    });
    _controller.clear();

    ref.read(chatProvider.notifier).addFileMessage(
          widget.peerId,
          messageId,
          fileName,
          File(filePath).lengthSync(),
          ext,
          isImage,
          filePath,
          text: messageText,
        );
    _jumpToBottom();

    await ref.read(fileTransferProvider.notifier).sendFile(
          peerId: widget.peerId,
          filePath: filePath,
          messageId: messageId,
          messageText: messageText,
        );

    // Clean up voice recording temp files after successful send.
    if (fileName.endsWith('.ogg') && filePath.contains('temp')) {
      try { await File(filePath).delete(); } catch (_) {}
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

  /// Default filename for the save dialog: images normalize to .png
  /// (gifs stay .gif); everything else keeps its original name.
  String _saveDialogFileName(FileAttachment attachment) {
    if (!attachment.isImage) return attachment.fileName;
    // Strip extension from filename for the dialog.
    final baseName = attachment.fileName.contains('.')
        ? attachment.fileName.substring(0, attachment.fileName.lastIndexOf('.'))
        : attachment.fileName;
    return attachment.fileExt.toLowerCase() == 'gif'
        ? '$baseName.gif'
        : '$baseName.png';
  }

  /// Write the attachment to [savePath], converting stored WebP images when
  /// the user chose a different format.
  Future<void> _writeSavedFile(String savePath, FileAttachment attachment) async {
    // Determine target format from chosen extension.
    final targetExt = savePath.contains('.')
        ? savePath.split('.').last.toLowerCase()
        : attachment.fileExt;

    if (attachment.isImage && targetExt != 'webp' && attachment.fileExt == 'webp') {
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
  }

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

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // Per-conversation select: a message/reaction/edit in ANY other
    // conversation used to rebuild this whole pane (the map is replaced
    // wholesale on every insert; this conversation's list identity only
    // changes when IT changes).
    final messages =
        ref.watch(chatProvider.select((m) => m[widget.peerId])) ?? [];

    _registerBuildListeners();

    final typingPeers =
        ref.watch(typingProvider.select((t) => t[widget.peerId])) ?? {};
    final showProfilePanel = ref.watch(dmProfilePanelProvider);
    final profiles = ref.watch(profileProvider);
    final localPeerId = ref.watch(identityProvider).peerId ?? '';

    // Screen share layout only shows in the DM with the call peer.
    // Named-record select: this build only reads these four call fields, so
    // video toggles / labels / renderer seq bumps no longer rebuild the pane.
    final call = ref.watch(callProvider.select((c) => (
          peerId: c.peerId,
          status: c.status,
          isScreenSharing: c.isScreenSharing,
          remoteScreenSharing: c.remoteScreenSharing,
        )));
    final isCallWithThisPeer = call.peerId == widget.peerId;
    final isScreenShareActive = isCallWithThisPeer &&
        (call.isScreenSharing || call.remoteScreenSharing);

    // Saved messages: this DM is with our OWN master identity. The header shows
    // "Saved messages" + a bookmark instead of the peer avatar/name/presence,
    // and the call buttons are hidden (can't call yourself). Everything below
    // the header (messages, search, files) works like any other DM.
    final savedId = ref.watch(savedMessagesPeerIdProvider);
    final isSavedMessages = savedId != null &&
        ref.watch(deviceLinkProvider).identityOf(widget.peerId) == savedId;

    // Custom-emote pull source for every token/reaction in this DM: ask the
    // conversation counterpart's devices.
    return EmoteScope(
      peerHint: widget.peerId,
      child: Row(
      children: [
        // DM Profile Panel (left side) with slide animation
        _DmProfilePanelSlider(
          visible: showProfilePanel && !isScreenShareActive,
          peerId: widget.peerId,
        ),

        // Chat area
        Expanded(
          child: ChatDropZone(
            onFileDropped: _handleDroppedFile,
            child: Column(
      children: [
        _buildHeader(hollow,
            isSavedMessages: isSavedMessages,
            showProfilePanel: showProfilePanel),

        // Issue 1-C: pinned above the message list, not a toast — the warning
        // has to survive scrollback and restarts. Renders nothing when clear.
        if (!isSavedMessages) SecurityAlertBanner(peerId: widget.peerId),

        // Screen share: full-bleed layout with overlay chat + controls.
        // Normal call / no call: standard column layout.
        if (isScreenShareActive)
          _buildScreenShareLayout(
              hollow, messages, typingPeers, profiles, localPeerId,
              anyScreenSharing:
                  call.isScreenSharing || call.remoteScreenSharing)
        else ...[
          _InlineCallPanelSlider(peerId: widget.peerId),
          ..._buildMessageArea(hollow, messages, typingPeers, profiles, localPeerId),
        ],
      ],
          ), // Column
          ), // ChatDropZone
        ), // Expanded (chat area)
      ],
      ), // Row
    ); // EmoteScope
  }

  /// All build-time ref.listen registrations. Must be invoked from build()
  /// every frame — Riverpod re-registers listeners per build and silently
  /// no-ops registrations made anywhere else (e.g. initState).
  void _registerBuildListeners() {
    // New-message handling under the reversed list: following (at bottom) →
    // instant re-pin to the newest row; reading history → freeze the display
    // (the unread pill takes over) so the view never shifts mid-read.
    ref.listen<Map<String, List<ChatMessage>>>(
        chatProvider, _onMessageListGrowth);
    // Focus-return mark-seen: a message arriving while the window is
    // unfocused counts as unread (the isViewingDm gate requires focus), and
    // if this chat was ALREADY open at the bottom nothing else clears it —
    // the scroll handler only marks seen on a bottom re-ENTRY transition.
    // The user is now looking straight at the message; retire the unread.
    ref.listen<bool>(windowFocusedProvider, _onWindowFocusChanged);
  }

  void _onMessageListGrowth(Map<String, List<ChatMessage>>? prev,
      Map<String, List<ChatMessage>> next) {
    final prevLen = (prev?[widget.peerId] ?? const []).length;
    final nextLen = (next[widget.peerId] ?? const []).length;
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
    final msgs = ref.read(chatProvider)[widget.peerId];
    if (msgs == null || msgs.isEmpty) return;
    ref
        .read(unreadProvider.notifier)
        .markDmSeen(widget.peerId, msgs.last.messageId);
  }

  /// DM header: avatar, name(s), connection status, and pane actions.
  Widget _buildHeader(HollowTheme hollow,
      {required bool isSavedMessages, required bool showProfilePanel}) {
    return Container(
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
          if (isSavedMessages)
            const SavedMessagesAvatar(size: 28)
          else
            HollowAvatar(peerId: widget.peerId, size: 28),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(child: _buildHeaderTitle(hollow, isSavedMessages)),
          if (!isSavedMessages) _buildConnectionStatus(),
          const SizedBox(width: HollowSpacing.sm),
          // Voice + video call buttons (hidden for Saved messages — you
          // can't call yourself).
          if (!isSavedMessages) ...[
            _buildVoiceCallButton(hollow),
            const SizedBox(width: HollowSpacing.xs),
            _buildVideoCallButton(hollow),
          ],
          const SizedBox(width: HollowSpacing.xs),
          _buildProfileToggleButton(hollow, showProfilePanel),
          // Notification mute toggle — hidden for Saved Messages (you
          // never get notified about your own self-DM).
          if (!isSavedMessages) ...[
            const SizedBox(width: HollowSpacing.xs),
            _buildMuteToggleButton(hollow),
          ],
          // Split view button (dock mode only)
          if ((ref.watch(layoutModeProvider).valueOrNull ?? LayoutMode.dock) ==
              LayoutMode.dock) ...[
            const SizedBox(width: HollowSpacing.xs),
            _buildSplitToggleButton(hollow),
          ],
        ],
      ),
    );
  }

  /// Header names (status dot dropped — the ConnectionProgress on the right
  /// already conveys online/offline):
  ///  • local nickname set  → local nickname on top, the friend's own profile
  ///    name (their "real nickname") below — falling back to the short peer
  ///    ID if they set no profile name.
  ///  • no local nickname   → just the profile name (or short peer ID), no
  ///    subline.
  Widget _buildHeaderTitle(HollowTheme hollow, bool isSavedMessages) {
    if (isSavedMessages) {
      return Text(
        'Saved messages',
        style: HollowTypography.body.copyWith(
          color: hollow.textPrimary,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
        overflow: TextOverflow.ellipsis,
      );
    }
    final profile =
        ref.watch(profileProvider.select((p) => p[widget.peerId]));
    final localNick =
        ref.watch(localNicknameProvider.select((m) => m[widget.peerId]));
    final shortId = widget.peerId.length > 16
        ? '${widget.peerId.substring(0, 16)}...'
        : widget.peerId;
    final realName = (profile != null && profile.displayName.isNotEmpty)
        ? profile.displayName
        : shortId;
    final hasLocalNick = localNick != null && localNick.isNotEmpty;
    final topLine = hasLocalNick ? localNick : realName;
    final subLine = hasLocalNick ? realName : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          topLine,
          style: HollowTypography.body.copyWith(
            color: hollow.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        if (subLine != null)
          Text(
            subLine,
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 10,
            ),
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }

  /// Multi-device: `widget.peerId` is the friend's MASTER id, but
  /// `peersProvider` is keyed by the DEVICE peer_ids the relay reports. A
  /// direct `peers[master]` lookup is always null for a multi-device /
  /// keystone-rotated friend, so the header showed Offline while the
  /// dots/call-buttons (which collapse by master) showed online. Scan for ANY
  /// device of this master with an encrypted session (same pattern as the
  /// Home network column). Single-device: the device id IS the master →
  /// direct lookup.
  Widget _buildConnectionStatus() {
    final links = ref.watch(deviceLinkProvider);
    final peers = ref.watch(peersProvider);
    final isEncryptedViaAnyDevice = peers.entries.any((e) =>
        links.identityOf(e.key) == widget.peerId && e.value.isEncrypted);
    final isInvisible =
        ref.watch(invisiblePeersProvider).contains(widget.peerId);
    final isCustomRelay =
        ref.watch(relayDomainProvider) != kDefaultRelayDomain;
    final ConnectionStage stage;
    if (isEncryptedViaAnyDevice && !isInvisible) {
      stage = ConnectionStage.encrypted;
    } else if (isCustomRelay) {
      stage = ConnectionStage.customNetwork;
    } else {
      stage = ConnectionStage.offline;
    }
    return ConnectionProgress(
      key: ValueKey('dm-conn-${widget.peerId}-${stage.index}'),
      stage: stage,
      // In a DM header the stage describes THE OTHER PERSON, not our own relay
      // link — say so, so it can't be read as "you are offline".
      tooltip: stage == ConnectionStage.offline
          ? "This person isn't reachable right now"
          : null,
    );
  }

  Widget _buildVoiceCallButton(HollowTheme hollow) {
    final call = ref.watch(callProvider);
    final isOnline = identityIsOnline(ref, widget.peerId);
    final isInCall = call.status != CallStatus.idle;
    final isCallWithThisPeer = call.peerId == widget.peerId && isInCall;

    return HollowTooltip(
      message: isCallWithThisPeer
          ? 'In call'
          : (isOnline && !isInCall ? 'Start voice call' : 'Voice call'),
      child: HollowPressable(
        semanticLabel: isCallWithThisPeer ? 'In call' : 'Start voice call',
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
  }

  Widget _buildVideoCallButton(HollowTheme hollow) {
    final call = ref.watch(callProvider);
    final isOnline = identityIsOnline(ref, widget.peerId);
    final isInCall = call.status != CallStatus.idle;

    return HollowTooltip(
      message: 'Start video call',
      child: HollowPressable(
        semanticLabel: 'Start video call',
        onTap: isOnline && !isInCall
            ? () => ref
                .read(callProvider.notifier)
                .startCall(widget.peerId, withVideo: true)
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
  }

  Widget _buildProfileToggleButton(HollowTheme hollow, bool showProfilePanel) {
    final label = showProfilePanel ? 'Hide profile' : 'Show profile';
    return HollowTooltip(
      message: label,
      child: HollowPressable(
        semanticLabel: label,
        onTap: () {
          ref.read(dmProfilePanelProvider.notifier).state = !showProfilePanel;
        },
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        padding: const EdgeInsets.all(HollowSpacing.xs),
        child: Icon(LucideIcons.user,
            size: 16,
            color: showProfilePanel ? hollow.accent : hollow.textSecondary),
      ),
    );
  }

  Widget _buildMuteToggleButton(HollowTheme hollow) {
    final dmNotifEnabled = ref.watch(notificationSettingsProvider
        .select((s) => s.dmEnabled[widget.peerId] ?? true));
    final label = dmNotifEnabled ? 'Mute notifications' : 'Unmute notifications';
    return HollowTooltip(
      message: label,
      child: HollowPressable(
        semanticLabel: label,
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
          dmNotifEnabled ? LucideIcons.bell : LucideIcons.bellOff,
          size: 18,
          color: dmNotifEnabled
              ? hollow.textSecondary
              : hollow.textSecondary.withValues(alpha: 0.4),
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
        onTap: () => _handleSplitToggle(ref),
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        padding: const EdgeInsets.all(HollowSpacing.xs),
        child: Icon(
          LucideIcons.columns,
          size: 16,
          color: isSplit ? hollow.accent : hollow.textSecondary,
        ),
      ),
    );
  }

  /// Full-bleed screen-share layout: the share view fills the pane, with the
  /// source pill (top), chat overlay (right), and controls pill (bottom)
  /// floating above it — all auto-hiding via [_overlaysVisible].
  Widget _buildScreenShareLayout(
    HollowTheme hollow,
    List<ChatMessage> messages,
    Set<String> typingPeers,
    Map<String, storage_api.UserProfile> profiles,
    String localPeerId, {
    required bool anyScreenSharing,
  }) {
    return Expanded(
      child: MouseRegion(
        onHover: (_) => _resetOverlayTimer(),
        onEnter: (_) => _resetOverlayTimer(),
        child: Stack(
          children: [
            // Layer 0: full-bleed screen share
            Positioned.fill(
              child: _ScreenShareFullView(peerId: widget.peerId),
            ),
            // Layer 0.5: source switcher pill (top-center) — only when at
            // least one screen share is active AND there are 2+ sources to
            // switch between. Camera-only DMs don't need a switcher.
            if (anyScreenSharing) _buildSourcePillOverlay(hollow),
            // Layer 1: chat overlay (right side) + toggle button
            _buildChatOverlay(
                hollow, messages, typingPeers, profiles, localPeerId),
            // Layer 2: floating controls pill (bottom center)
            _buildControlsPillOverlay(),
          ],
        ),
      ),
    );
  }

  /// Scoped Consumer: the pill needs the FULL call state (video-enabled
  /// fields) — watch it here, not pane-wide.
  Widget _buildSourcePillOverlay(HollowTheme hollow) {
    return Consumer(builder: (context, ref, _) {
      final fullCall = ref.watch(callProvider);
      if (_countActiveDmSources(fullCall) < 2) {
        // MUST stay Positioned: a bare (non-positioned) child
        // makes the Stack size to IT (0x0) instead of
        // expanding — which blanked the whole share view.
        return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
      }
      return Positioned(
        top: HollowSpacing.md,
        left: 0,
        right: 0,
        child: AnimatedOpacity(
          opacity: _overlaysVisible ? 1.0 : 0.0,
          duration: HollowDurations.normal,
          child: IgnorePointer(
            ignoring: !_overlaysVisible,
            child: Center(
              child: _buildScreenShareSourcePill(
                hollow,
                fullCall,
                ref.read(identityProvider).peerId ?? '',
                widget.peerId,
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _buildChatOverlay(
    HollowTheme hollow,
    List<ChatMessage> messages,
    Set<String> typingPeers,
    Map<String, storage_api.UserProfile> profiles,
    String localPeerId,
  ) {
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Pin toggle — always visible while overlays are.
          ChatOverlayToggleButton(
            overlaysVisible: _overlaysVisible,
            pinned: _chatOverlayPinned,
            onTap: () =>
                setState(() => _chatOverlayPinned = !_chatOverlayPinned),
            onHoverEnter: _pinOverlays,
            onHoverExit: _resetOverlayTimer,
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
                    hollow, messages, typingPeers, profiles, localPeerId),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlsPillOverlay() {
    return Positioned(
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
    );
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

  /// Open the sticker picker anchored to the composer button; the pick
  /// arrives as an `[a:s:hash:w:h]` token and stages like an emote. Several
  /// in a row tile into a mosaic once sent.
  void _openComposerStickerPicker(BuildContext btnCtx) {
    final box = btnCtx.findRenderObject() as RenderBox?;
    final anchor = box == null
        ? Offset.zero
        : overlayAnchorOf(btnCtx, localOffset: Offset(box.size.width, 0));
    showStickerPicker(
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

  /// Builds the message list + typing + reply bar + input bar.
  /// Used by both the normal column layout and the screen-share overlay.
  List<Widget> _buildMessageArea(
    HollowTheme hollow,
    List<ChatMessage> allMessages,
    Set<String> typingPeers,
    Map<String, storage_api.UserProfile> profiles,
    String localPeerId,
  ) {
    // While the user reads history the display is frozen — arrivals are held
    // back (see _frozenLen). `allMessages` keeps the true list for mark-seen.
    final messages = _displayMessages(allMessages);
    return [
      // Messages list + unread pill overlay
      Expanded(
        child: Stack(
          children: [
            _buildMessageListLayer(hollow, messages, profiles, localPeerId),
            _buildUnreadPillOverlay(allMessages),
          ],
        ),
      ),

      // Typing indicator
      if (typingPeers.isNotEmpty) _buildTypingBar(typingPeers),

      // Reply preview bar
      if (_replyToMessageId != null)
        ChatReplyPreviewBar(
          senderName: _replyToSenderName,
          text: _replyToText,
          imagePath: _replyToImagePath,
          onCancel: _cancelReply,
        ),

      // Staged file preview
      if (_stagedFilePath != null)
        StagedFilePreviewBar(
          filePath: _stagedFilePath!,
          fileName: _stagedFileName,
          isImage: _stagedFileIsImage,
          onRemove: _removeStagedFile,
        ),

      // Staged link card (hollow invite or OG preview)
      StagedLinkArea(
        hollowLink: _stagedHollowLink,
        previewUrl: _stagedPreviewUrl,
        preview: _stagedPreview,
        previewLoading: _stagedPreviewLoading,
        onDismissHollowLink: _dismissStagedHollowLink,
        onDismissPreview: _dismissStagedPreview,
      ),

      // Input bar
      _buildInputBar(hollow),
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

  Widget _buildMessageListLayer(
    HollowTheme hollow,
    List<ChatMessage> messages,
    Map<String, storage_api.UserProfile> profiles,
    String localPeerId,
  ) {
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
                    ? _buildEmptyDmState(hollow)
                    : const SizedBox.shrink())
                : _buildMessageList(hollow, messages, profiles, localPeerId),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyDmState(HollowTheme hollow) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.messageCircle,
            size: 48,
            color: hollow.textSecondary.withValues(alpha: 0.3),
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
    );
  }

  /// The reversed message list (see the scroll-model comment above
  /// [_frozenLen]) plus the per-build row precomputes.
  Widget _buildMessageList(
    HollowTheme hollow,
    List<ChatMessage> messages,
    Map<String, storage_api.UserProfile> profiles,
    String localPeerId,
  ) {
    // Reply-target lookup: one pass per build instead of an O(n) indexWhere
    // scan per reply row per rebuild.
    final replyIndexById = <String, int>{
      for (var i = 0; i < messages.length; i++)
        if (messages[i].messageId != null) messages[i].messageId!: i,
    };
    return reversedChatList(
      context: context,
      listKey: ValueKey('dm-list-${widget.peerId}'),
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
        profiles,
        localPeerId,
      ),
    );
  }

  /// One chat row: grouping-header decision, hover-action wrapper, bubble,
  /// and date separator — [revIndex] is the reversed builder index.
  Widget _buildMessageRow(
    BuildContext context,
    int revIndex,
    List<ChatMessage> messages,
    Map<String, int> replyIndexById,
    Map<String, storage_api.UserProfile> profiles,
    String localPeerId,
  ) {
    // Map the reversed builder index back to chronological order — all row
    // logic below (grouping, separators, highlight, reply) stays in
    // chronological terms.
    final index = messages.length - 1 - revIndex;
    final msg = messages[index];
    // Grouping: compare with the previous message in chronological order.
    final showHeader = index == 0 ||
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
      onDownload: _downloadFor(context, msg),
      onCopy: _copyFor(context, msg),
      onCopyImage: _copyImageFor(context, msg),
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
      child: wrapper,
    );
  }

  /// Sticker tiling for the row at [index]: it and its neighbour are both
  /// nothing-but-stickers and already grouped, so the seam between them is
  /// drawn continuous. `showHeader` IS "not grouped with the previous".
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
        final origSenderId = original.isMe ? localPeerId : widget.peerId;
        replySender = displayNameFor(profiles, origSenderId);
        if (original.fileAttachment?.isImage == true) {
          replyImagePath = original.fileAttachment?.diskPath;
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

  // ── Row action callbacks ──────────────────────────────────────────────
  // Null hides the affordance for this message. Tap-time reads use ref.read
  // (equal or fresher than the build-captured watch values at tap time).

  VoidCallback? _editStartFor(ChatMessage msg, int revIndex) {
    final canEdit =
        msg.messageId != null && msg.isMe && msg.fileAttachment == null;
    if (!canEdit) return null;
    return () {
      // Positions + jumpTo live in the REVERSED index space.
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
    return () => _deleteMessage(msg.messageId!);
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
      // Guard against duplicate downloads.
      final transfer = ref.read(fileTransferProvider)[attachment.fileId];
      if (transfer != null && transfer.isDownloading) {
        HollowToast.show(context, 'File is already downloading...',
            type: HollowToastType.info);
        return;
      }
      if (attachment.diskPath != null) {
        _saveFile(attachment);
      } else {
        // DM: request from the peer we're chatting with.
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
          // If the message has been edited, the signature was computed over
          // the edit timestamp + new text — use editedAt to reconstruct the
          // canonical payload.
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

  /// '📷 Image' / '📎 name' for attachments, else the message text.
  String _messagePreviewText(ChatMessage msg) {
    final att = msg.fileAttachment;
    if (att == null) return msg.text;
    return att.isImage ? '📷 Image' : '📎 ${att.fileName}';
  }

  /// Unread pill — only when new messages arrived while scrolled up.
  Widget _buildUnreadPillOverlay(List<ChatMessage> allMessages) {
    final unreadCount = ref.watch(
        unreadProvider.select((s) => s.dmUnreadCounts[widget.peerId] ?? 0));
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
            ref.read(unreadProvider.notifier).markDmSeen(
                  widget.peerId,
                  allMessages.last.messageId,
                );
          },
        ),
      ),
    );
  }

  Widget _buildTypingBar(Set<String> typingPeers) {
    return TypingIndicatorBar(
      names: typingPeers
          .map((pid) => displayNameForPeer(
              ref.watch(profileProvider.select((p) => p[pid])), pid))
          .toList(),
    );
  }

  Widget _buildInputBar(HollowTheme hollow) {
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
            link: _composerLayerLink,
            child: Focus(
              onKeyEvent: (_, event) {
                final r = _emoteAutocomplete.handleKey(event);
                if (r == KeyEventResult.handled) return r;
                return handleChatInputKey(
                  event, _controller, _focusNode, _handleSend,
                  onPasteImage: _stageClipboardImage,
                );
              },
              child: chatComposerField(
                hollow,
                controller: _controller,
                focusNode: _focusNode,
                hintText: 'Type a message...',
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

    // Drive animation (duration re-evaluated for disable toggle).
    _controller.duration = HollowDurations.normal;
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
  double _remoteVolume = 1.0;
  double _videoHeight = 200; // Height of the video area (only when video active).
  static const _minVideoHeight = 80.0;
  static const _maxVideoHeight = 2000.0;
  String? _expandedRenderer; // null = side-by-side, 'local' or 'remote' = fullscreen

  /// Handle a tap on a source switcher tab. For cameras, this sets
  /// _expandedRenderer to show the camera fullscreen with the other
  /// side as PiP. For screens, this is a no-op in the inline panel
  /// (the full-bleed screen share view takes over automatically via
  /// isScreenShareActive).
  void _onDmSourceTapped(String peerId, String type, String localPeerId) {
    if (type != 'camera') return;
    setState(() {
      _expandedRenderer = peerId == localPeerId ? 'local' : 'remote';
    });
  }

  /// Source switcher pill for DM calls. Shows one tab per active video
  /// source (camera or screen) with highlighting on the currently focused
  /// one. Focus highlight: cameras via [_expandedRenderer]; screens are not
  /// interactive in the inline panel, so nothing is highlighted for them.
  Widget _buildDmSourceSwitcher(
    HollowTheme hollow,
    CallState call,
    String localPeerId,
    String remotePeerId,
  ) {
    final profiles = ref.watch(profileProvider);
    String? focusedPeerId;
    if (_expandedRenderer == 'local') {
      focusedPeerId = localPeerId;
    } else if (_expandedRenderer == 'remote') {
      focusedPeerId = remotePeerId;
    }
    return _dmSourcePill(
      hollow: hollow,
      profiles: profiles,
      sources: _dmActiveSources(call, localPeerId, remotePeerId),
      localPeerId: localPeerId,
      focusedPeerId: focusedPeerId,
      focusedType: focusedPeerId != null ? 'camera' : null,
      onTapSource: (peerId, type) =>
          _onDmSourceTapped(peerId, type, localPeerId),
    );
  }

  // Call duration is rendered by CallDurationText (self-ticking leaf) — the
  // old per-second setState rebuilt the ENTIRE inline call panel (video
  // views, drag-resize, tabs, controls) every second of every call.

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callProvider);
    final hollow = HollowTheme.of(context);
    final peerProfile = ref.watch(profileProvider.select((p) => p[widget.peerId]));
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final displayName = displayNameForPeer(peerProfile, widget.peerId);

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

    // Max video height: leave just enough room for controls + input bar
    // (~140 px). The user wants to be able to drag the video panel up to
    // nearly the full window height when focusing on one participant.
    final screenHeight = MediaQuery.of(context).size.height;
    final maxH = (screenHeight * 0.8).clamp(_minVideoHeight, _maxVideoHeight);

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
            // Video / screen share area — screen share fills available
            // space; camera uses fixed (drag-resizable) height.
            if (hasVideoArea) ...[
              if (isScreenShare)
                Expanded(
                  child: _buildScreenShareView(call, hollow, remoteRenderer),
                )
              else
                _buildCameraArea(call, hollow, displayName, remoteRenderer,
                    localRenderer, hasRemoteVideo, hasLocalVideo, localPeerId),
              // Resize handle (not needed during screen share — it fills
              // Expanded).
              if (!isScreenShare) _buildResizeHandle(hollow, maxH),
            ],
            _buildControlBar(call, hollow, hasAnyVideo, localPeerId),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraArea(
    CallState call,
    HollowTheme hollow,
    String displayName,
    RTCVideoRenderer? remoteRenderer,
    RTCVideoRenderer? localRenderer,
    bool hasRemoteVideo,
    bool hasLocalVideo,
    String localPeerId,
  ) {
    return SizedBox(
      height: _videoHeight,
      child: Stack(
        children: [
          Positioned.fill(
            child: _expandedRenderer != null
                ? _buildFullscreenVideo(hollow, displayName, remoteRenderer,
                    localRenderer, hasRemoteVideo, hasLocalVideo)
                : _buildSideBySideVideo(hollow, displayName, remoteRenderer,
                    localRenderer, hasRemoteVideo, hasLocalVideo),
          ),
          // Source switcher pill (top-center) — only when at least one
          // screen share is active AND there are 2+ sources. Camera-only
          // DMs don't need a switcher.
          if ((call.isScreenSharing || call.remoteScreenSharing) &&
              _countActiveDmSources(call) >= 2)
            Positioned(
              top: HollowSpacing.sm,
              left: 0,
              right: 0,
              child: Center(
                child: _buildDmSourceSwitcher(
                    hollow, call, localPeerId, widget.peerId),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildResizeHandle(HollowTheme hollow, double maxH) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        onVerticalDragUpdate: (details) {
          setState(() {
            _videoHeight =
                (_videoHeight + details.delta.dy).clamp(_minVideoHeight, maxH);
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
    );
  }

  /// Control bar: timer (left), avatars (center, audio-only), controls
  /// (right).
  Widget _buildControlBar(
      CallState call, HollowTheme hollow, bool hasAnyVideo, String localPeerId) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: hasAnyVideo ? HollowSpacing.sm : HollowSpacing.md,
      ),
      child: Row(
        children: [
          // Left: timer + status
          StatusDot(color: hollow.success, size: 8, pulse: true),
          const SizedBox(width: HollowSpacing.sm),
          if (call.status == CallStatus.connecting || call.startedAt == null)
            Text(
              'Connecting...',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 12,
              ),
            )
          else
            CallDurationText(
              startedAt: call.startedAt!,
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 12,
                fontFeatures: [const FontFeature.tabularFigures()],
              ),
            ),
          // Center: avatars (audio-only — when video is on, they're in the
          // rectangles).
          if (!hasAnyVideo) ...[
            const Spacer(),
            _buildAudioAvatars(call, hollow, localPeerId),
          ],
          const Spacer(),
          // Right: controls
          _buildControls(call, hollow),
        ],
      ),
    );
  }

  /// Speaking state comes from callSpeakingProvider via a scoped Consumer so
  /// VAD flips rebuild ONLY these two avatars, not the whole inline call
  /// panel.
  Widget _buildAudioAvatars(
      CallState call, HollowTheme hollow, String localPeerId) {
    return Consumer(builder: (context, ref, _) {
      final speaking = ref.watch(callSpeakingProvider);
      return Row(children: [
        SpeakingBorder(
          isSpeaking: speaking.local,
          child: _badgedCallAvatar(
            hollow: hollow,
            peerId: localPeerId,
            muted: call.isMuted,
            deafened: call.isDeafened,
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        SpeakingBorder(
          isSpeaking: speaking.remote,
          child: _badgedCallAvatar(
            hollow: hollow,
            peerId: widget.peerId,
            muted: call.remoteMuted,
            deafened: call.remoteDeafened,
          ),
        ),
      ]);
    });
  }

  void _showVolumePopup(BuildContext context, Offset globalPosition) {
    final position = overlayPositionOf(context, globalPosition);
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

  /// Puts the speaking ring on a call video tile (issue #37). The ring is an
  /// overlay INSIDE the tile's clip, so it lights the rectangle the camera
  /// occupies without changing the layout — the video texture is never
  /// resized by a VAD flip. The scoped [Consumer] + `.select` keeps a flip to
  /// this one layer instead of rebuilding the whole call panel 1-4x/second.
  Widget _speakingWrapped({
    required bool local,
    required BorderRadius radius,
    required Widget child,
    double borderWidth = 2.5,
  }) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Consumer(builder: (context, ref, _) {
          final speaking = ref.watch(callSpeakingProvider
              .select((s) => local ? s.local : s.remote));
          return SpeakingRing(
            isSpeaking: speaking,
            borderRadius: radius,
            borderWidth: borderWidth,
          );
        }),
      ],
    );
  }

  /// Default: two equal video rectangles side by side. Click to expand.
  Widget _buildSideBySideVideo(
    HollowTheme hollow,
    String displayName,
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
              child: _speakingWrapped(
                local: true,
                radius: BorderRadius.circular(hollow.radiusSm),
                child: hasLocalVideo && localRenderer != null
                    ? RepaintBoundary(
                        child: RTCVideoView(
                          localRenderer,
                          mirror: true,
                          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                        ),
                      )
                    : Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            HollowAvatar(
                              peerId: ref.read(identityProvider).peerId ?? '',
                              size: 48,
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
              child: _speakingWrapped(
                local: false,
                radius: BorderRadius.circular(hollow.radiusSm),
                child: hasRemoteVideo && remoteRenderer != null
                    ? RepaintBoundary(
                        child: RTCVideoView(
                          remoteRenderer,
                          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                        ),
                      )
                    : Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            HollowAvatar(
                              peerId: widget.peerId,
                              size: 48,
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
        ),
      ],
    );
  }

  /// Fullscreen: one video fills the area, the other is PiP. Click to exit.
  Widget _buildFullscreenVideo(
    HollowTheme hollow,
    String displayName,
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
          // Main video (full area) — Contain so the entire frame is visible
          // when the user expands; letterbox bars are preferable to cropping
          // someone's face/body out of the recording.
          Positioned.fill(
            child: _speakingWrapped(
              local: isLocalExpanded,
              radius: BorderRadius.zero,
              child: mainRenderer != null
                  ? RepaintBoundary(
                      child: RTCVideoView(
                        mainRenderer,
                        mirror: isLocalExpanded,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                      ),
                    )
                  : Container(color: hollow.elevated),
            ),
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
                  child: _speakingWrapped(
                    local: !isLocalExpanded,
                    radius: BorderRadius.circular(7),
                    borderWidth: 2,
                    child: RepaintBoundary(
                      child: RTCVideoView(
                        pipRenderer,
                        mirror: !isLocalExpanded,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      ),
                    ),
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
    if (call.isScreenSharing && call.remoteScreenSharing) {
      return _buildBothSharingView(call, hollow, remoteRenderer);
    }
    if (call.isScreenSharing) {
      return _buildLocalShareBanner(call, hollow);
    }
    return _buildRemoteShareView(call, hollow, remoteRenderer);
  }

  /// Both sharing — stacked: remote top, local banner bottom.
  Widget _buildBothSharingView(
      CallState call, HollowTheme hollow, RTCVideoRenderer? remoteRenderer) {
    return Column(
      children: [
        // Remote screen (top, takes most space)
        Expanded(
          flex: 3,
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  color: Colors.black,
                  child: remoteRenderer != null
                      ? RepaintBoundary(
                          child: RTCVideoView(
                            remoteRenderer,
                            mirror: false,
                            objectFit: RTCVideoViewObjectFit
                                .RTCVideoViewObjectFitContain,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
              if (call.remoteScreenShareLabel != null)
                Positioned(
                  top: HollowSpacing.md,
                  right: HollowSpacing.md,
                  child: _shareLabelChip(hollow, call.remoteScreenShareLabel!),
                ),
            ],
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
              if (call.screenShareLabel != null) ...[
                const SizedBox(width: HollowSpacing.sm),
                _shareLabelChip(hollow, call.screenShareLabel!),
              ],
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
  }

  /// Only local sharing — show banner.
  Widget _buildLocalShareBanner(CallState call, HollowTheme hollow) {
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
            if (call.screenShareLabel != null) ...[
              const SizedBox(height: HollowSpacing.sm),
              _shareLabelChip(hollow, call.screenShareLabel!),
            ],
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
  }

  /// Only remote sharing — show their screen (Contain, never mirror).
  Widget _buildRemoteShareView(
      CallState call, HollowTheme hollow, RTCVideoRenderer? remoteRenderer) {
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            color: Colors.black,
            child: remoteRenderer != null
                ? RepaintBoundary(
                    child: RTCVideoView(
                      remoteRenderer,
                      mirror: false,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                    ),
                  )
                : Center(
                    child: Text(
                      'Waiting for screen share...',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                      ),
                    ),
                  ),
          ),
        ),
        if (call.remoteScreenShareLabel != null)
          Positioned(
            top: HollowSpacing.md,
            right: HollowSpacing.md,
            child: _shareLabelChip(hollow, call.remoteScreenShareLabel!),
          ),
      ],
    );
  }

  /// Call avatar with muted (bottom-left) / deafened (bottom-right) badges —
  /// same convention as the mobile voice avatars.
  Widget _badgedCallAvatar({
    required HollowTheme hollow,
    required String peerId,
    required bool muted,
    required bool deafened,
  }) {
    Widget badge(IconData icon) => Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: hollow.error,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            border: Border.all(color: hollow.background, width: 1.5),
          ),
          child: Icon(icon, size: 10, color: Colors.white),
        );

    return Stack(
      children: [
        HollowAvatar(peerId: peerId, size: 60),
        if (muted)
          Positioned(left: 0, bottom: 0, child: badge(LucideIcons.micOff)),
        if (deafened)
          Positioned(
              right: 0, bottom: 0, child: badge(LucideIcons.headphoneOff)),
      ],
    );
  }

  /// Shared row of call controls: mute, deafen, camera, screen share,
  /// record, end call.
  Widget _buildControls(CallState call, HollowTheme hollow) {
    final rec = ref.watch(recordingProvider);
    const iconSize = 20.0;
    const buttonPadding = EdgeInsets.all(HollowSpacing.sm);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (rec.isMyRecording) ...[
          RecordingIndicator(startedAt: rec.myStartedAt),
          const SizedBox(width: HollowSpacing.sm),
        ] else if (rec.remoteRecorders.isNotEmpty) ...[
          const RecordingIndicator(),
          const SizedBox(width: HollowSpacing.sm),
        ],
        _muteCallButton(ref, hollow, call,
            iconSize: iconSize, padding: buttonPadding),
        const SizedBox(width: HollowSpacing.xs),
        _buildDeafenButton(call, hollow, iconSize, buttonPadding),
        const SizedBox(width: HollowSpacing.xs),
        _cameraCallButton(ref, hollow, call,
            iconSize: iconSize, padding: buttonPadding),
        // Screen share (desktop only)
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) ...[
          const SizedBox(width: HollowSpacing.xs),
          _screenShareCallButton(context, ref, hollow, call,
              iconSize: iconSize, padding: buttonPadding),
        ],
        // Record (Windows + macOS only). On macOS < 13.0 the native recorder
        // doesn't exist, so the button is disabled with an explanatory tooltip.
        // Hidden on Linux — no working native recorder there yet.
        if (Platform.isWindows || Platform.isMacOS) ...[
          const SizedBox(width: HollowSpacing.xs),
          _buildRecordButton(rec, hollow, iconSize, buttonPadding),
        ],
        const SizedBox(width: HollowSpacing.sm),
        _endCallButton(ref, hollow,
            iconSize: iconSize,
            innerPadding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.md,
              vertical: HollowSpacing.sm,
            )),
      ],
    );
  }

  Widget _buildDeafenButton(CallState call, HollowTheme hollow,
      double iconSize, EdgeInsetsGeometry padding) {
    final label = call.isDeafened ? 'Undeafen' : 'Deafen';
    return HollowTooltip(
      message: label,
      child: HollowPressable(
        semanticLabel: label,
        onTap: call.status == CallStatus.active
            ? () => ref.read(callProvider.notifier).toggleDeafen()
            : null,
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        padding: padding,
        child: Icon(
          LucideIcons.headphones,
          size: iconSize,
          color: call.isDeafened ? hollow.error : hollow.textSecondary,
        ),
      ),
    );
  }

  Widget _buildRecordButton(RecordingState rec, HollowTheme hollow,
      double iconSize, EdgeInsetsGeometry padding) {
    return HollowTooltip(
      message: MacOsScreenAudioSupport.recordBlockedByOldOs
          ? 'Recording needs macOS 13.0 or later'
          : (rec.isMyRecording ? 'Stop recording' : 'Record this call'),
      child: HollowPressable(
        disabled: MacOsScreenAudioSupport.recordBlockedByOldOs,
        semanticLabel:
            rec.isMyRecording ? 'Stop recording' : 'Record this call',
        onTap: () {
          final notifier = ref.read(recordingProvider.notifier);
          if (rec.isMyRecording) {
            notifier.stopRecording();
          } else {
            notifier.startRecording();
          }
        },
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        padding: padding,
        child: Icon(
          rec.isMyRecording ? LucideIcons.stopCircle : LucideIcons.circle,
          size: iconSize,
          color:
              rec.isMyRecording ? const Color(0xFFE53935) : hollow.textSecondary,
        ),
      ),
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
      _controller.duration = HollowDurations.normal;
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

  /// Mirror semantics for a renderer: cameras are mirrored when local,
  /// screens are never mirrored.
  Widget _renderTile(RTCVideoRenderer? renderer,
      {required bool isCamera, required bool isLocal}) {
    if (renderer == null) return const SizedBox.shrink();
    return RepaintBoundary(
      child: RTCVideoView(
        renderer,
        mirror: isCamera && isLocal,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callProvider);
    final hollow = HollowTheme.of(context);
    final notifier = ref.read(callProvider.notifier);
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final voice = notifier.voiceService;
    final remoteScreen = notifier.screenShareRenderer;
    final localScreen = notifier.localScreenShareRenderer;
    final remoteCamera = voice?.remoteRenderer;
    final localCamera = voice?.localRenderer;
    final bothSharing = call.isScreenSharing && call.remoteScreenSharing;

    // Resolve the focused source. Falls back to a sensible default if the
    // focused source isn't currently active.
    final focused = ref.watch(focusedDmSourceProvider);
    final ({RTCVideoRenderer? renderer, bool isCamera, bool isLocal})
        bigChoice = _resolveBig(
      focused: focused,
      call: call,
      localPeerId: localPeerId,
      remotePeerId: peerId,
      remoteScreen: remoteScreen,
      localScreen: localScreen,
      remoteCamera: remoteCamera,
      localCamera: localCamera,
    );

    // (Auto-focus-on-build was reverted — caused issues during the
    // screen-share toggling dance. The pill simply won't highlight any tab
    // until the user explicitly taps one. The big tile still uses
    // _resolveBig's fallback so it shows the right thing.)

    if (bothSharing) {
      return _buildBothSharingStack(
          ref, call, hollow, bigChoice, remoteScreen, localScreen, localPeerId);
    }
    return _buildSingleSourceStack(call, hollow, notifier, bigChoice);
  }

  /// Both sharing: big tile = focused source, PiP = the OTHER screen.
  Widget _buildBothSharingStack(
    WidgetRef ref,
    CallState call,
    HollowTheme hollow,
    ({RTCVideoRenderer? renderer, bool isCamera, bool isLocal}) bigChoice,
    RTCVideoRenderer? remoteScreen,
    RTCVideoRenderer? localScreen,
    String localPeerId,
  ) {
    // PiP shows the OTHER screen (the one that isn't the big tile).
    final isLocalBig = bigChoice.isLocal && !bigChoice.isCamera;
    final pipRenderer = isLocalBig ? remoteScreen : localScreen;
    final bigLabel = bigChoice.isLocal
        ? call.screenShareLabel
        : call.remoteScreenShareLabel;

    return Stack(
      children: [
        // Big tile — focused source (could be a camera or a screen).
        Positioned.fill(
          child: Container(
            color: Colors.black,
            child: _renderTile(
              bigChoice.renderer,
              isCamera: bigChoice.isCamera,
              isLocal: bigChoice.isLocal,
            ),
          ),
        ),
        // PiP tile — the other screen. Tap to swap focus.
        Positioned(
          right: HollowSpacing.md,
          bottom: HollowSpacing.md,
          child: _buildPipTile(ref, hollow, pipRenderer,
              pipIsLocal: !isLocalBig, localPeerId: localPeerId),
        ),
        // Quality label for the big tile (top-left).
        if (!bigChoice.isCamera && bigLabel != null)
          Positioned(
            top: HollowSpacing.md,
            left: HollowSpacing.md,
            child: _shareLabelChip(hollow, bigLabel),
          ),
        // Small "Stop sharing" affordance, top-right.
        Positioned(
          top: HollowSpacing.md,
          right: HollowSpacing.md,
          child: HollowButton.danger(
            onPressed: () => ref.read(callProvider.notifier).stopScreenShare(),
            compact: true,
            icon: const Icon(LucideIcons.monitorOff, size: 14),
            child: const Text('Stop sharing'),
          ),
        ),
      ],
    );
  }

  Widget _buildPipTile(
    WidgetRef ref,
    HollowTheme hollow,
    RTCVideoRenderer? pipRenderer, {
    required bool pipIsLocal,
    required String localPeerId,
  }) {
    return GestureDetector(
      onTap: () {
        ref.read(focusedDmSourceProvider.notifier).state = DmFocusedSource(
          peerId: pipIsLocal ? localPeerId : peerId,
          type: 'screen',
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(HollowRadius.md),
        child: Container(
          width: 220,
          height: 132,
          decoration: BoxDecoration(
            color: Colors.black,
            border: Border.all(
              color: hollow.border.withValues(alpha: 0.6),
              width: 1,
            ),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: _renderTile(
                  pipRenderer,
                  isCamera: false,
                  isLocal: pipIsLocal,
                ),
              ),
              // Small label so the user knows which screen this is.
              Positioned(
                left: HollowSpacing.xs,
                bottom: HollowSpacing.xs,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.xs,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    pipIsLocal ? 'You' : 'Them',
                    style: HollowTypography.caption.copyWith(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Only one peer is sharing a screen (or only cameras are present because
  /// we got opened in this view from a camera focus tap). Show whatever the
  /// focus resolved to in the big tile.
  Widget _buildSingleSourceStack(
    CallState call,
    HollowTheme hollow,
    CallNotifier notifier,
    ({RTCVideoRenderer? renderer, bool isCamera, bool isLocal}) bigChoice,
  ) {
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            color: Colors.black,
            child: bigChoice.renderer != null
                ? _renderTile(
                    bigChoice.renderer,
                    isCamera: bigChoice.isCamera,
                    isLocal: bigChoice.isLocal,
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
                          call.isScreenSharing
                              ? 'You are sharing your screen'
                              : 'Waiting for screen share...',
                          style: HollowTypography.caption.copyWith(
                            color: hollow.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        // Quality label + stop button (local sharing) or just quality label
        // (remote sharing).
        if (call.isScreenSharing)
          Positioned(
            top: HollowSpacing.md,
            right: HollowSpacing.md,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (call.screenShareLabel != null)
                  _shareLabelChip(hollow, call.screenShareLabel!),
                if (call.screenShareLabel != null)
                  const SizedBox(width: HollowSpacing.sm),
                HollowButton.danger(
                  onPressed: () => notifier.stopScreenShare(),
                  compact: true,
                  icon: const Icon(LucideIcons.monitorOff, size: 14),
                  child: const Text('Stop sharing'),
                ),
              ],
            ),
          )
        else if (call.remoteScreenSharing &&
            call.remoteScreenShareLabel != null)
          Positioned(
            top: HollowSpacing.md,
            right: HollowSpacing.md,
            child: _shareLabelChip(hollow, call.remoteScreenShareLabel!),
          ),
      ],
    );
  }

  /// Resolve which renderer to show in the big tile based on the focus state
  /// and what's actually active. Falls back to a sensible default if the
  /// focused source isn't currently sharing.
  ({RTCVideoRenderer? renderer, bool isCamera, bool isLocal}) _resolveBig({
    required DmFocusedSource focused,
    required CallState call,
    required String localPeerId,
    required String remotePeerId,
    required RTCVideoRenderer? remoteScreen,
    required RTCVideoRenderer? localScreen,
    required RTCVideoRenderer? remoteCamera,
    required RTCVideoRenderer? localCamera,
  }) {
    final fromFocus = _resolveFocusedSource(
      focused: focused,
      call: call,
      localPeerId: localPeerId,
      remoteScreen: remoteScreen,
      localScreen: localScreen,
      remoteCamera: remoteCamera,
      localCamera: localCamera,
    );
    if (fromFocus != null) return fromFocus;

    // Fallback priority: remote screen → local screen → remote camera → local camera.
    if (call.remoteScreenSharing && remoteScreen != null) {
      return (renderer: remoteScreen, isCamera: false, isLocal: false);
    }
    if (call.isScreenSharing && localScreen != null) {
      return (renderer: localScreen, isCamera: false, isLocal: true);
    }
    if (call.remoteVideoEnabled && remoteCamera != null) {
      return (renderer: remoteCamera, isCamera: true, isLocal: false);
    }
    if (call.isVideoEnabled && localCamera != null) {
      return (renderer: localCamera, isCamera: true, isLocal: true);
    }
    return (renderer: null, isCamera: false, isLocal: false);
  }

  /// The focused source, or null when nothing is focused / the focused
  /// source isn't currently active.
  ({RTCVideoRenderer? renderer, bool isCamera, bool isLocal})?
      _resolveFocusedSource({
    required DmFocusedSource focused,
    required CallState call,
    required String localPeerId,
    required RTCVideoRenderer? remoteScreen,
    required RTCVideoRenderer? localScreen,
    required RTCVideoRenderer? remoteCamera,
    required RTCVideoRenderer? localCamera,
  }) {
    if (focused.peerId == null || focused.type == null) return null;
    final isLocal = focused.peerId == localPeerId;
    if (focused.type == 'screen') {
      return _sourceIfActive(
        isLocal ? localScreen : remoteScreen,
        isLocal ? call.isScreenSharing : call.remoteScreenSharing,
        isCamera: false,
        isLocal: isLocal,
      );
    }
    if (focused.type == 'camera') {
      return _sourceIfActive(
        isLocal ? localCamera : remoteCamera,
        isLocal ? call.isVideoEnabled : call.remoteVideoEnabled,
        isCamera: true,
        isLocal: isLocal,
      );
    }
    return null;
  }

  ({RTCVideoRenderer? renderer, bool isCamera, bool isLocal})? _sourceIfActive(
    RTCVideoRenderer? renderer,
    bool active, {
    required bool isCamera,
    required bool isLocal,
  }) {
    if (!active || renderer == null) return null;
    return (renderer: renderer, isCamera: isCamera, isLocal: isLocal);
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
  // Duration rendered by CallDurationText — the old per-second setState
  // rebuilt the whole controls overlay (over a live screen-share video).

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callProvider);
    final hollow = HollowTheme.of(context);

    final peerProfile = ref.watch(profileProvider.select((p) => p[widget.peerId]));
    final displayName = displayNameForPeer(peerProfile, widget.peerId);

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
            CallDurationText(
              startedAt: call.startedAt ?? DateTime.now(),
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 12,
                fontFeatures: [const FontFeature.tabularFigures()],
              ),
            ),
          ],
          const SizedBox(width: HollowSpacing.lg),
          // Mute
          _muteCallButton(ref, hollow, call,
              iconSize: 16, padding: const EdgeInsets.all(HollowSpacing.xs)),
          const SizedBox(width: HollowSpacing.xs),
          // Camera toggle (independent of screen share — separate PCs)
          _cameraCallButton(ref, hollow, call,
              iconSize: 16, padding: const EdgeInsets.all(HollowSpacing.xs)),
          // Screen share toggle (desktop only)
          if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) ...[
            const SizedBox(width: HollowSpacing.xs),
            _screenShareCallButton(context, ref, hollow, call,
                iconSize: 16, padding: const EdgeInsets.all(HollowSpacing.xs)),
          ],
          // Received share audio: volume + duck controls.
          if (call.remoteScreenSharing) ...[
            const SizedBox(width: HollowSpacing.xs),
            const ShareVolumeButton(),
          ],
          const SizedBox(width: HollowSpacing.sm),
          // End call
          _endCallButton(ref, hollow,
              iconSize: 14,
              innerPadding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm,
                vertical: 4,
              )),
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
      _controller.duration = HollowDurations.normal;
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
    final profile = ref.watch(profileProvider.select((p) => p[peerId]));
    final localNicknames = ref.watch(localNicknameProvider);
    final localNick = localNicknames[peerId];
    final isOnline = identityIsOnline(ref, peerId);
    final friends = ref.watch(friendsProvider);
    final friendInfo = friends[peerId];

    // Block/Report key on the MASTER identity (device→master collapse).
    final master = ref.watch(deviceLinkProvider).identityOf(peerId);
    final isBlocked = ref.watch(blockedUsersProvider).contains(master);

    // Saved Messages (self-DM): no nickname/block/report actions — you can't
    // block or report yourself.
    final savedId = ref.watch(savedMessagesPeerIdProvider);
    final isSavedMessages = savedId != null && master == savedId;

    final displayName = profile?.displayName ?? '';
    final status = profile?.status ?? '';
    final aboutMe = profile?.aboutMe ?? '';
    final bannerBytes = ref.watch(bannerProvider(peerId)).valueOrNull;

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
                  _buildAvatarWithStatus(hollow, isOnline),
                  const SizedBox(height: HollowSpacing.sm),
                  ..._buildNameLines(hollow, localNick, shownName),
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
                  // Twitch badge
                  if (profile != null && profile.twitchUsername.isNotEmpty) ...[
                    const SizedBox(height: HollowSpacing.xs),
                    _buildTwitchBadge(hollow, profile.twitchUsername),
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

                    // Action buttons — hidden for Saved Messages (self-DM: no
                    // nickname/block/report on yourself). All outline styled
                    // (like Edit Profile); Block/Report use the red outline
                    // (danger tint). Blocking and reporting key on the MASTER
                    // identity, not the device.
                    if (!isSavedMessages)
                      ..._buildDmActions(context, ref, hollow,
                          master: master,
                          isBlocked: isBlocked,
                          shownName: shownName,
                          localNick: localNick),

                    // Friend status — shown at the end.
                    if (friendInfo != null && friendInfo.status == 'accepted') ...[
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
                    ],
                    Container(height: 1, color: hollow.border),
                    const SizedBox(height: HollowSpacing.sm),

                    _buildPeerIdChip(context, hollow),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatarWithStatus(HollowTheme hollow, bool isOnline) {
    return Stack(
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
              filled: isOnline,
              semanticLabel: isOnline ? 'Online' : 'Offline',
            ),
          ),
        ),
      ],
    );
  }

  /// Local nickname on top with the profile name below, or just the profile
  /// name when no local nickname is set.
  List<Widget> _buildNameLines(
      HollowTheme hollow, String? localNick, String shownName) {
    final nameStyle = HollowTypography.subheading.copyWith(
      color: hollow.textPrimary,
      fontWeight: FontWeight.w700,
      fontSize: 15,
    );
    if (localNick != null && localNick.isNotEmpty) {
      return [
        Text(
          localNick,
          style: nameStyle,
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
      ];
    }
    return [
      Text(
        shownName,
        style: nameStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      ),
    ];
  }

  Widget _buildTwitchBadge(HollowTheme hollow, String twitchUsername) {
    return GestureDetector(
      onTap: () => launchUrl(
        Uri.parse('https://twitch.tv/$twitchUsername'),
        mode: LaunchMode.externalApplication,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm,
          vertical: 3,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF9146FF).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(hollow.radiusSm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(BrandIcons.twitch, size: 11, color: Color(0xFF9146FF)),
            const SizedBox(width: 4),
            Text(
              twitchUsername,
              style: HollowTypography.caption.copyWith(
                color: const Color(0xFF9146FF),
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Nickname button + Block/Report row (each half, red outline).
  List<Widget> _buildDmActions(
    BuildContext context,
    WidgetRef ref,
    HollowTheme hollow, {
    required String master,
    required bool isBlocked,
    required String shownName,
    required String? localNick,
  }) {
    final hasNick = localNick != null && localNick.isNotEmpty;
    final isVerified = ref.watch(isPeerVerifiedProvider(master));
    return [
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
          icon: Icon(hasNick ? LucideIcons.pencil : LucideIcons.tag),
          child: Text(hasNick ? 'Edit Nickname' : 'Set Nickname'),
        ),
      ),
      const SizedBox(height: HollowSpacing.xs),
      // Verify — same action and ordering as the profile card, so the DM panel
      // is not a place where verification is quietly unavailable.
      SizedBox(
        width: double.infinity,
        child: HollowButton.outline(
          onPressed: () => showVerifyContactDialog(context, peerId: master),
          compact: true,
          icon: Icon(isVerified ? LucideIcons.shieldCheck : LucideIcons.shield),
          child: Text(isVerified ? 'Verified — view number' : 'Verify contact'),
        ),
      ),
      const SizedBox(height: HollowSpacing.xs),
      Row(
        children: [
          Expanded(
            child: HollowButton.outline(
              danger: true,
              onPressed: isBlocked
                  ? () => unblockUser(context, masterId: master)
                  : () => confirmAndBlockUser(
                        context,
                        masterId: master,
                        displayName: shownName,
                      ),
              compact: true,
              expand: true,
              icon: const Icon(LucideIcons.ban),
              child: Text(isBlocked ? 'Unblock' : 'Block'),
            ),
          ),
          const SizedBox(width: HollowSpacing.xs),
          Expanded(
            child: HollowButton.outline(
              danger: true,
              onPressed: () => showReportUserDialog(
                context,
                masterId: master,
                displayName: shownName,
              ),
              compact: true,
              expand: true,
              icon: const Icon(LucideIcons.flag),
              child: const Text('Report'),
            ),
          ),
        ],
      ),
      const SizedBox(height: HollowSpacing.sm),
    ];
  }

  /// Peer ID (copy on tap).
  Widget _buildPeerIdChip(BuildContext context, HollowTheme hollow) {
    return HollowPressable(
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

