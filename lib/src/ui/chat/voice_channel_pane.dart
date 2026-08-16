import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/providers/speaking_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/chat/channel_chat_pane.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/ptt_mic_visual.dart';
import 'package:hollow/src/ui/components/share_quality_chip.dart';
import 'package:hollow/src/ui/components/share_volume_control.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/dialogs/screen_share_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Voice channel pane — shows channel text chat with an inline call strip
/// showing connected participants and voice controls. When screen sharing
/// is active, switches to a full-bleed screen share view with a chat overlay.
class VoiceChannelPane extends ConsumerStatefulWidget {
  final String serverId;
  final String channelId;
  final String channelName;

  /// Hide the floating bottom controls pill. The conference surface embeds
  /// this pane with its own STATIC controls bar below (the pill's Disconnect
  /// tears down only the voice leg, stranding the meeting state).
  final bool hideControlsPill;

  const VoiceChannelPane({
    super.key,
    required this.serverId,
    required this.channelId,
    required this.channelName,
    this.hideControlsPill = false,
  });

  @override
  ConsumerState<VoiceChannelPane> createState() => _VoiceChannelPaneState();
}

class _VoiceChannelPaneState extends ConsumerState<VoiceChannelPane> {
  Timer? _overlayHideTimer;
  bool _overlaysVisible = true;
  bool _chatOverlayPinned = false;

  /// Which video tile is fullscreen (null = grid view).
  String? _focusedVideoPeerId;

  /// Sharers whose "X is sharing — Watch" banner was dismissed this session.
  /// Cleared per-peer when their share ends (a re-share banners again).
  final Set<String> _dismissedShareBanners = {};

  void _resetOverlayTimer() {
    _overlayHideTimer?.cancel();
    if (!_overlaysVisible) {
      setState(() => _overlaysVisible = true);
    }
    if (_chatOverlayPinned) return;
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
  void didUpdateWidget(covariant VoiceChannelPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Fresh channel = fresh banner state (re-opening a channel must offer
    // Watch again even if it was dismissed last time).
    if (oldWidget.channelId != widget.channelId ||
        oldWidget.serverId != widget.serverId) {
      _dismissedShareBanners.clear();
    }
  }

  @override
  void dispose() {
    _overlayHideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final vcState = ref.watch(voiceChannelProvider);
    final isInThisChannel = vcState.currentServerId == widget.serverId &&
        vcState.currentChannelId == widget.channelId;

    // A dismissed "Watch" banner returns if that peer stops and re-shares.
    _dismissedShareBanners
        .removeWhere((p) => vcState.peerScreenSharing[p] != true);

    // Not in this voice channel — show channel text chat (no join prompt).
    if (!isInThisChannel) {
      return ChannelChatPane(
        serverId: widget.serverId,
        channelId: widget.channelId,
        channelName: widget.channelName,
      );
    }

    // Share surface — we're sharing ourselves or WATCHING someone (opt-in,
    // issue #38). A remote share we haven't opted into never flips the view.
    if (vcState.showsShareSurface) {
      return _buildScreenShareView(hollow, vcState);
    }

    // Camera video active — grid view.
    if (vcState.isCameraActive) {
      return _buildCameraGridView(hollow, vcState);
    }

    // Normal: channel text chat, with a floating "X is sharing — Watch"
    // banner when someone shares and we haven't opted in.
    final chat = ChannelChatPane(
      serverId: widget.serverId,
      channelId: widget.channelId,
      channelName: widget.channelName,
    );
    final allUnwatched = vcState.unwatchedRemoteShares;
    final unwatched = allUnwatched
        .where((p) => !_dismissedShareBanners.contains(p))
        .toList();
    if (allUnwatched.isEmpty) return chat;
    return Stack(
      children: [
        Positioned.fill(child: chat),
        Positioned(
          top: 12,
          left: 0,
          right: 0,
          child: Center(
            // Dismissal is never a dead end: the banner collapses to a
            // compact chip that re-expands on tap.
            child: unwatched.isNotEmpty
                ? _UnwatchedShareBanner(
                    sharerIds: unwatched,
                    labels: vcState.peerScreenShareLabels,
                    onWatch: (peerId) => ref
                        .read(voiceChannelProvider.notifier)
                        .watchScreenShare(peerId),
                    onDismiss: (peerId) =>
                        setState(() => _dismissedShareBanners.add(peerId)),
                  )
                : HollowTooltip(
                    message: 'Show screen share notification',
                    child: HollowPressable(
                      onTap: () =>
                          setState(_dismissedShareBanners.clear),
                      semanticLabel: 'Show screen share notification',
                      borderRadius:
                          BorderRadius.circular(HollowRadius.pill),
                      backgroundColor:
                          hollow.surface.withValues(alpha: 0.9),
                      padding: const EdgeInsets.symmetric(
                        horizontal: HollowSpacing.sm,
                        vertical: HollowSpacing.xs,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.monitor,
                              size: 13, color: hollow.accentText),
                          const SizedBox(width: HollowSpacing.xs),
                          Text(
                            allUnwatched.length == 1
                                ? '1 screen share'
                                : '${allUnwatched.length} screen shares',
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

  // ---------------------------------------------------------------------------
  // Camera grid view
  // ---------------------------------------------------------------------------

  Widget _buildCameraGridView(HollowTheme hollow, VoiceChannelState vcState) {
    final localPeerId = ref.read(identityProvider).peerId ?? '';

    // Build list of peers with cameras on.
    final cameraPeers = <String>[];
    if (vcState.isCameraOn) cameraPeers.add(localPeerId);
    for (final entry in vcState.peerCameraOn.entries) {
      if (entry.value) cameraPeers.add(entry.key);
    }

    // If focused peer no longer has camera on, clear focus.
    if (_focusedVideoPeerId != null &&
        !cameraPeers.contains(_focusedVideoPeerId)) {
      _focusedVideoPeerId = null;
    }

    return MouseRegion(
      onHover: (_) => _resetOverlayTimer(),
      onEnter: (_) => _resetOverlayTimer(),
      child: Stack(
        children: [
          // Layer 0: video grid or fullscreen
          Positioned.fill(
            child: Container(
              color: Colors.black,
              child: _focusedVideoPeerId != null
                  ? _buildFullscreenCamera(
                      hollow, vcState, cameraPeers, localPeerId)
                  : _buildVideoGrid(
                      hollow, vcState, cameraPeers, localPeerId),
            ),
          ),

          // Layer 1 (right): chat overlay
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Toggle button
                ChatOverlayToggleButton(
                  overlaysVisible: _overlaysVisible,
                  pinned: _chatOverlayPinned,
                  onTap: () => setState(
                      () => _chatOverlayPinned = !_chatOverlayPinned),
                  onHoverEnter: _pinOverlays,
                  onHoverExit: _resetOverlayTimer,
                ),
                // Chat panel — slides in/out
                _OverlaySlider(
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
                    child: ChannelChatPane(
                      serverId: widget.serverId,
                      channelId: widget.channelId,
                      channelName: widget.channelName,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Layer 2 (bottom center): floating controls pill
          if (!widget.hideControlsPill)
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
                    child: _VoiceControlsPill(
                      serverId: widget.serverId,
                      channelId: widget.channelId,
                      onHoverEnter: _pinOverlays,
                      onHoverExit: _resetOverlayTimer,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Build the N-tile camera grid layout (delegates to the shared grid).
  Widget _buildVideoGrid(
    HollowTheme hollow,
    VoiceChannelState vcState,
    List<String> cameraPeers,
    String localPeerId,
  ) {
    return _buildTileGrid([
      for (final peerId in cameraPeers)
        _buildVideoTile(hollow, vcState, peerId, localPeerId,
            canTap: cameraPeers.length > 1),
    ]);
  }

  /// Single video tile in the grid.
  Widget _buildVideoTile(
    HollowTheme hollow,
    VoiceChannelState vcState,
    String peerId,
    String localPeerId, {
    bool canTap = true,
    VoidCallback? onTapOverride,
  }) {
    final isLocal = peerId == localPeerId;
    final renderer = ref.read(voiceChannelProvider.notifier)
        .getCameraRenderer(peerId);
    // Remote camera keys are ROUTABLE device ids — collapse to the MASTER
    // for the profile/avatar lookups (both are master-keyed).
    final displayId = ref.watch(deviceLinkProvider).identityOf(peerId);
    final peerProfile =
        ref.watch(profileProvider.select((p) => p[displayId]));
    final name = isLocal ? 'You' : displayNameForPeer(peerProfile, displayId);
    // Our own tile reads the dedicated local flag; remote tiles membership-
    // select so a tile only rebuilds when ITS peer's bit flips. Testing the
    // set for OURSELVES silently missed — it is keyed by routable device ids
    // while this tile may hold the master id.
    final isSpeaking = isLocal
        ? ref.watch(vcLocalSpeakingProvider)
        : ref.watch(vcSpeakingProvider.select((s) => s.contains(peerId)));

    return GestureDetector(
      onTap: onTapOverride ??
          (canTap
              ? () => setState(() => _focusedVideoPeerId = peerId)
              : null),
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: hollow.elevated,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          border: isSpeaking
              ? Border.all(color: hollow.accent, width: 2)
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video or avatar fallback
            if (renderer != null)
              RepaintBoundary(
                child: RTCVideoView(
                  renderer,
                  mirror: isLocal,
                  objectFit:
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                ),
              )
            else
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HollowAvatar(
                      peerId: displayId,
                      size: 48,
                    ),
                    const SizedBox(height: HollowSpacing.xs),
                    Text(
                      name,
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),

            // Name label overlay (bottom-left)
            if (renderer != null)
              Positioned(
                left: 6,
                bottom: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    name,
                    style: HollowTypography.caption.copyWith(
                      color: Colors.white,
                      fontSize: 10,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Fullscreen view: one tile full-bleed, others as PiP thumbnails.
  Widget _buildFullscreenCamera(
    HollowTheme hollow,
    VoiceChannelState vcState,
    List<String> cameraPeers,
    String localPeerId,
  ) {
    final focusedPeerId = _focusedVideoPeerId!;
    final isLocal = focusedPeerId == localPeerId;
    final renderer = ref.read(voiceChannelProvider.notifier)
        .getCameraRenderer(focusedPeerId);
    final others = cameraPeers.where((p) => p != focusedPeerId).toList();

    return GestureDetector(
      onTap: () => setState(() => _focusedVideoPeerId = null),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          // Main video (full area) — Contain to show the whole frame
          // letterboxed rather than cropping the subject.
          Positioned.fill(
            child: renderer != null
                ? RepaintBoundary(
                    child: RTCVideoView(
                      renderer,
                      mirror: isLocal,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                    ),
                  )
                : Container(color: hollow.elevated),
          ),

          // "Click to exit" hint (top-left)
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

          // PiP thumbnails (bottom center)
          if (others.isNotEmpty)
            Positioned(
              bottom: 64,
              left: 0,
              right: 0,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: others.map((peerId) {
                    final pipRenderer = ref
                        .read(voiceChannelProvider.notifier)
                        .getCameraRenderer(peerId);
                    final pipIsLocal = peerId == localPeerId;

                    return GestureDetector(
                      onTap: () =>
                          setState(() => _focusedVideoPeerId = peerId),
                      child: Container(
                        width: 120,
                        height: 90,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: hollow.border,
                            width: 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: pipRenderer != null
                            ? RepaintBoundary(
                                child: RTCVideoView(
                                  pipRenderer,
                                  mirror: pipIsLocal,
                                  objectFit: RTCVideoViewObjectFit
                                      .RTCVideoViewObjectFitCover,
                                ),
                              )
                            : Container(
                                color: hollow.elevated,
                                child: Center(
                                  child: HollowAvatar(
                                    // Master-keyed avatar (routable id no-ops
                                    // for single-device peers).
                                    peerId: ref
                                        .watch(deviceLinkProvider)
                                        .identityOf(peerId),
                                    size: 28,
                                  ),
                                ),
                              ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Screen share full-bleed view
  // ---------------------------------------------------------------------------

  Widget _buildScreenShareView(HollowTheme hollow, VoiceChannelState vcState) {
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final focusedPeerId = vcState.focusedScreenSharePeerId;
    final isLocalFocused = focusedPeerId == localPeerId;
    final isCameraFocused = vcState.focusedSourceType == 'camera';
    final sources = _collectSources(vcState, localPeerId);

    return MouseRegion(
      onHover: (_) => _resetOverlayTimer(),
      onEnter: (_) => _resetOverlayTimer(),
      child: Stack(
        children: [
          // Layer 0: grid of all sources, or the focused source full-bleed.
          Positioned.fill(
            child: vcState.isGridView
                ? Container(
                    color: Colors.black,
                    child:
                        _buildSourceTileGrid(hollow, vcState, localPeerId),
                  )
                : isCameraFocused && focusedPeerId != null
                    ? _buildFocusedCameraContent(
                        hollow, focusedPeerId, localPeerId)
                    : _buildScreenShareContent(
                        hollow, vcState, focusedPeerId, isLocalFocused),
          ),

          // Layer 0.5 (bottom right): own-share feedback PiP while focused on
          // something else (issue #38 — "see my share while watching theirs").
          if (!vcState.isGridView &&
              vcState.isScreenSharing &&
              !(isLocalFocused && !isCameraFocused))
            Positioned(
              right: HollowSpacing.md,
              bottom: 72,
              child: _buildSelfSharePip(hollow),
            ),

          // Layer 1 (top): source switcher tabs (multiple sources)
          if (sources.length > 1 || vcState.isGridView)
            Positioned(
              top: HollowSpacing.md,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                opacity: _overlaysVisible ? 1.0 : 0.0,
                duration: HollowDurations.normal,
                child: IgnorePointer(
                  ignoring: !_overlaysVisible,
                  child: _buildSharerSwitcher(
                      hollow, vcState, localPeerId, sources),
                ),
              ),
            ),

          // Layer 2 (right): chat overlay
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Toggle button
                ChatOverlayToggleButton(
                  overlaysVisible: _overlaysVisible,
                  pinned: _chatOverlayPinned,
                  onTap: () => setState(
                      () => _chatOverlayPinned = !_chatOverlayPinned),
                  onHoverEnter: _pinOverlays,
                  onHoverExit: _resetOverlayTimer,
                ),
                // Chat panel — slides in/out
                _OverlaySlider(
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
                    child: ChannelChatPane(
                      serverId: widget.serverId,
                      channelId: widget.channelId,
                      channelName: widget.channelName,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Layer 3 (bottom center): floating controls pill
          if (!widget.hideControlsPill)
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
                    child: _VoiceControlsPill(
                      serverId: widget.serverId,
                      channelId: widget.channelId,
                      onHoverEnter: _pinOverlays,
                      onHoverExit: _resetOverlayTimer,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildScreenShareContent(
    HollowTheme hollow,
    VoiceChannelState vcState,
    String? focusedPeerId,
    bool isLocalFocused,
  ) {
    if (isLocalFocused && vcState.isScreenSharing) {
      // We are the focused sharer — show self-preview with stop button.
      final localRenderer =
          ref.read(voiceChannelProvider.notifier).localScreenShareRenderer;
      return Stack(
        children: [
          Positioned.fill(
            child: Container(
              color: Colors.black,
              child: localRenderer != null
                  ? RTCVideoView(
                      localRenderer,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                    )
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.monitor,
                              size: 56,
                              color:
                                  hollow.accent.withValues(alpha: 0.5)),
                          const SizedBox(height: HollowSpacing.lg),
                          Text('You are sharing your screen',
                              style: HollowTypography.heading.copyWith(
                                color: hollow.textPrimary,
                                fontWeight: FontWeight.w600,
                                fontSize: 18,
                              )),
                          const SizedBox(height: HollowSpacing.sm),
                          Text('Others can see your screen',
                              style: HollowTypography.body.copyWith(
                                  color: hollow.textSecondary)),
                        ],
                      ),
                    ),
            ),
          ),
          Positioned(
            top: HollowSpacing.md,
            right: HollowSpacing.md,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (vcState.screenShareLabel != null)
                  Container(
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
                      vcState.screenShareLabel!,
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (vcState.screenShareLabel != null)
                  const SizedBox(width: HollowSpacing.sm),
                HollowButton.danger(
                  onPressed: () =>
                      ref.read(voiceChannelProvider.notifier).stopScreenShare(),
                  compact: true,
                  icon: const Icon(LucideIcons.monitorOff, size: 14),
                  child: const Text('Stop sharing'),
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (focusedPeerId == null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.monitor,
                  size: 48,
                  color: hollow.textSecondary.withValues(alpha: 0.3)),
              const SizedBox(height: HollowSpacing.md),
              Text('Waiting for screen share...',
                  style: HollowTypography.caption
                      .copyWith(color: hollow.textSecondary)),
            ],
          ),
        ),
      );
    }

    // Focused on a share we haven't opted into — Watch placeholder, never a
    // dead "Connecting..." (opt-in watching, issue #38).
    if (!vcState.watchingScreenShares.contains(focusedPeerId)) {
      final displayId =
          ref.watch(deviceLinkProvider).identityOf(focusedPeerId);
      final name = displayNameFor(ref.watch(profileProvider), displayId);
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              HollowAvatar(peerId: displayId, size: 64),
              const SizedBox(height: HollowSpacing.md),
              Text('$name is sharing their screen',
                  style: HollowTypography.body
                      .copyWith(color: hollow.textSecondary)),
              const SizedBox(height: HollowSpacing.md),
              HollowButton.filled(
                compact: true,
                icon: const Icon(LucideIcons.eye, size: 14),
                onPressed: () => ref
                    .read(voiceChannelProvider.notifier)
                    .watchScreenShare(focusedPeerId),
                child: const Text('Watch'),
              ),
            ],
          ),
        ),
      );
    }

    // Remote peer is focused — show their screen.
    final renderer = ref
        .read(voiceChannelProvider.notifier)
        .getScreenShareRenderer(focusedPeerId);
    final remoteLabel = vcState.peerScreenShareLabels[focusedPeerId];

    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            color: Colors.black,
            child: renderer != null
                ? RepaintBoundary(
                    child: RTCVideoView(
                      renderer,
                      mirror: false,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                    ),
                  )
                : Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.monitor,
                            size: 48,
                            color: hollow.textSecondary.withValues(alpha: 0.3)),
                        const SizedBox(height: HollowSpacing.md),
                        Text('Connecting to screen share...',
                            style: HollowTypography.caption
                                .copyWith(color: hollow.textSecondary)),
                      ],
                    ),
                  ),
          ),
        ),
        if (remoteLabel != null ||
            vcState.watchingScreenShares.contains(focusedPeerId))
          Positioned(
            top: HollowSpacing.md,
            right: HollowSpacing.md,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (remoteLabel != null || renderer != null) ...[
                  const SizedBox(width: HollowSpacing.xs),
                  // Shows the RECEIVED resolution once frames flow (live —
                  // flips to the source resolution when Source is toggled).
                  ShareQualityChip(
                    renderer: renderer,
                    sourceLabel: remoteLabel,
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  /// Full-bleed camera content (used in mixed mode when camera source is focused).
  Widget _buildFocusedCameraContent(
    HollowTheme hollow,
    String focusedPeerId,
    String localPeerId,
  ) {
    final isLocal = focusedPeerId == localPeerId;
    final renderer = ref.read(voiceChannelProvider.notifier)
        .getCameraRenderer(focusedPeerId);
    // Routable device id → master for the display lookups.
    final displayId = ref.watch(deviceLinkProvider).identityOf(focusedPeerId);
    final focusedProfile =
        ref.watch(profileProvider.select((p) => p[displayId]));
    final name = isLocal
        ? 'You'
        : displayNameForPeer(focusedProfile, displayId);

    return Container(
      color: Colors.black,
      child: renderer != null
          ? RepaintBoundary(
              child: RTCVideoView(
                renderer,
                mirror: isLocal,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              ),
            )
          : Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  HollowAvatar(
                    peerId: displayId,
                    size: 64,
                  ),
                  const SizedBox(height: HollowSpacing.md),
                  Text(
                    'Connecting to $name\'s camera...',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// All video sources in display order: own share, watched remote shares,
  /// unwatched remote shares (placeholder + Watch), then cameras. Feeds both
  /// the switcher pill and the grid view (issue #38).
  List<({String peerId, String type, bool isLocal, bool watched})>
      _collectSources(VoiceChannelState vcState, String localPeerId) {
    return [
      if (vcState.isScreenSharing)
        (peerId: localPeerId, type: 'screen', isLocal: true, watched: true),
      for (final e in vcState.peerScreenSharing.entries)
        if (e.value &&
            e.key != localPeerId &&
            vcState.watchingScreenShares.contains(e.key))
          (peerId: e.key, type: 'screen', isLocal: false, watched: true),
      for (final e in vcState.peerScreenSharing.entries)
        if (e.value &&
            e.key != localPeerId &&
            !vcState.watchingScreenShares.contains(e.key))
          (peerId: e.key, type: 'screen', isLocal: false, watched: false),
      if (vcState.isCameraOn)
        (peerId: localPeerId, type: 'camera', isLocal: true, watched: true),
      for (final e in vcState.peerCameraOn.entries)
        if (e.value && e.key != localPeerId)
          (peerId: e.key, type: 'camera', isLocal: false, watched: true),
    ];
  }

  /// Lay out N tiles: 1-2 side by side, 3-4 two columns, 5+ three columns;
  /// an underfull last row is centered (flex spacers). The ONE grid builder —
  /// used by both the camera grid and the all-sources grid view.
  Widget _buildTileGrid(List<Widget> tiles) {
    final n = tiles.length;
    if (n == 0) return const SizedBox.shrink();
    if (n == 1) return tiles[0];
    final cols = n <= 2 ? n : (n <= 4 ? 2 : 3);
    final rows = <Widget>[];
    for (var i = 0; i < n; i += cols) {
      final end = (i + cols) > n ? n : (i + cols);
      final rowTiles = tiles.sublist(i, end);
      final missing = cols - rowTiles.length;
      rows.add(Expanded(
        child: Row(
          children: [
            if (missing > 0) Spacer(flex: missing),
            for (final t in rowTiles) Expanded(flex: 2, child: t),
            if (missing > 0) Spacer(flex: missing),
          ],
        ),
      ));
    }
    return Column(children: rows);
  }

  /// The all-sources grid (issue #38): every share and camera at once —
  /// own share preview included; unwatched shares as Watch placeholders.
  Widget _buildSourceTileGrid(
    HollowTheme hollow,
    VoiceChannelState vcState,
    String localPeerId,
  ) {
    final sources = _collectSources(vcState, localPeerId);
    return _buildTileGrid([
      for (final src in sources)
        _buildSourceTile(hollow, vcState, src, localPeerId),
    ]);
  }

  /// One grid tile for any source type (issue #38).
  Widget _buildSourceTile(
    HollowTheme hollow,
    VoiceChannelState vcState,
    ({String peerId, String type, bool isLocal, bool watched}) src,
    String localPeerId,
  ) {
    final notifier = ref.read(voiceChannelProvider.notifier);
    void focusThis() {
      notifier.setFocusedSource(src.peerId, src.type);
      notifier.setGridView(false);
    }

    if (src.type == 'camera') {
      return _buildVideoTile(hollow, vcState, src.peerId, localPeerId,
          onTapOverride: focusThis);
    }

    final displayId = ref.watch(deviceLinkProvider).identityOf(src.peerId);
    final profiles = ref.watch(profileProvider);
    final name = src.isLocal ? 'You' : displayNameFor(profiles, displayId);

    // Unwatched share — placeholder tile; only the Watch button acts.
    if (!src.watched) {
      return Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: hollow.elevated,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
        ),
        clipBehavior: Clip.antiAlias,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              HollowAvatar(peerId: displayId, size: 48),
              const SizedBox(height: HollowSpacing.sm),
              Text(
                '$name is sharing their screen',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: HollowSpacing.sm),
              HollowButton.filled(
                compact: true,
                icon: const Icon(LucideIcons.eye, size: 14),
                onPressed: () => notifier.watchScreenShare(src.peerId),
                child: const Text('Watch'),
              ),
            ],
          ),
        ),
      );
    }

    final renderer = src.isLocal
        ? notifier.localScreenShareRenderer
        : notifier.getScreenShareRenderer(src.peerId);
    final quality = src.isLocal
        ? vcState.screenShareLabel
        : vcState.peerScreenShareLabels[src.peerId];

    return GestureDetector(
      onTap: focusThis,
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: hollow.elevated,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (renderer != null)
              RepaintBoundary(
                child: RTCVideoView(
                  renderer,
                  objectFit:
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                ),
              )
            else
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.monitor,
                        size: 32,
                        color: hollow.textSecondary.withValues(alpha: 0.4)),
                    const SizedBox(height: HollowSpacing.xs),
                    Text(
                      'Connecting...',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            // Name + type label (bottom-left).
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(LucideIcons.monitor,
                        size: 10, color: Colors.white70),
                    const SizedBox(width: 4),
                    Text(
                      quality != null ? '$name · $quality' : name,
                      style: HollowTypography.caption.copyWith(
                        color: Colors.white,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Corner action (top-right): stop sharing (own) / stop watching.
            Positioned(
              top: 4,
              right: 4,
              child: HollowTooltip(
                message: src.isLocal ? 'Stop sharing' : 'Stop watching',
                child: HollowPressable(
                  onTap: src.isLocal
                      ? () => notifier.stopScreenShare()
                      : () => notifier.stopWatchingScreenShare(src.peerId),
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(4),
                  semanticLabel: src.isLocal
                      ? 'Stop sharing your screen'
                      : 'Stop watching this share',
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Icon(
                      src.isLocal
                          ? LucideIcons.monitorOff
                          : LucideIcons.eyeOff,
                      size: 13,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Own-share feedback PiP (bottom right of the focus view).
  Widget _buildSelfSharePip(HollowTheme hollow) {
    final renderer =
        ref.read(voiceChannelProvider.notifier).localScreenShareRenderer;
    if (renderer == null) return const SizedBox.shrink();
    return HollowTooltip(
      message: 'Click to focus your share',
      child: GestureDetector(
        onTap: () {
          final localPeerId = ref.read(identityProvider).peerId ?? '';
          ref
              .read(voiceChannelProvider.notifier)
              .setFocusedSource(localPeerId, 'screen');
        },
        child: Container(
          width: 160,
          height: 90,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: hollow.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 8,
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: RTCVideoView(
                  renderer,
                  objectFit:
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
              Positioned(
                left: 4,
                bottom: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Your share',
                    style: HollowTypography.caption.copyWith(
                      color: Colors.white,
                      fontSize: 9,
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

  Widget _buildSharerSwitcher(
    HollowTheme hollow,
    VoiceChannelState vcState,
    String localPeerId,
    List<({String peerId, String type, bool isLocal, bool watched})> sources,
  ) {
    final profiles = ref.watch(profileProvider);
    final notifier = ref.read(voiceChannelProvider.notifier);

    return Center(
      child: MouseRegion(
        onEnter: (_) => _pinOverlays(),
        onExit: (_) => _resetOverlayTimer(),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm,
            vertical: HollowSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: hollow.surface.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(HollowRadius.pill),
            border:
                Border.all(color: hollow.border.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ...sources.map((source) {
                final peerId = source.peerId;
                final sourceType = source.type;
                final isUnwatched =
                    sourceType == 'screen' && !source.watched;
                final isFocused = !vcState.isGridView &&
                    peerId == vcState.focusedScreenSharePeerId &&
                    sourceType == vcState.focusedSourceType;
                // Routable device id → master for the name/avatar lookups;
                // focus tracking stays keyed on the routable id.
                final displayId =
                    ref.watch(deviceLinkProvider).identityOf(peerId);
                final name = displayNameFor(profiles, displayId);

                return Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.xs),
                  child: HollowPressable(
                    onTap: () {
                      // Tapping an unwatched share opts in (issue #38);
                      // watchScreenShare also focuses it.
                      if (isUnwatched) {
                        notifier.watchScreenShare(peerId);
                        notifier.setGridView(false);
                      } else {
                        notifier.setFocusedSource(peerId, sourceType);
                        notifier.setGridView(false);
                      }
                    },
                    semanticLabel: isUnwatched
                        ? 'Watch screen share from $name'
                        : null,
                    borderRadius:
                        BorderRadius.circular(hollow.radiusSm),
                    backgroundColor: isFocused ? hollow.accentMuted : null,
                    padding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.sm,
                      vertical: HollowSpacing.xs,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Source type icon (eye = unwatched share).
                        Icon(
                          isUnwatched
                              ? LucideIcons.eye
                              : sourceType == 'screen'
                                  ? LucideIcons.monitor
                                  : LucideIcons.video,
                          size: 12,
                          color: isFocused
                              ? hollow.accent
                              : hollow.textSecondary,
                        ),
                        const SizedBox(width: HollowSpacing.xs),
                        HollowAvatar(
                          peerId: displayId,
                          size: 18,
                        ),
                        const SizedBox(width: HollowSpacing.xs),
                        Text(
                          peerId == localPeerId ? 'You' : name,
                          style: HollowTypography.caption.copyWith(
                            color: isFocused
                                ? hollow.textPrimary
                                : hollow.textSecondary,
                            fontWeight: isFocused
                                ? FontWeight.w600
                                : FontWeight.w400,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              // Divider + grid toggle (issue #38 — all sources at once).
              Container(
                width: 1,
                height: 18,
                margin: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.xs),
                color: hollow.border.withValues(alpha: 0.6),
              ),
              HollowTooltip(
                message:
                    vcState.isGridView ? 'Exit grid view' : 'Grid view',
                child: HollowPressable(
                  onTap: () => notifier.setGridView(!vcState.isGridView),
                  semanticLabel: vcState.isGridView
                      ? 'Exit grid view'
                      : 'Show all sources in a grid',
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  backgroundColor:
                      vcState.isGridView ? hollow.accentMuted : null,
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Icon(
                    LucideIcons.layoutGrid,
                    size: 14,
                    color: vcState.isGridView
                        ? hollow.accent
                        : hollow.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Floating controls pill (bottom center during screen share)
// ---------------------------------------------------------------------------

class _VoiceControlsPill extends ConsumerStatefulWidget {
  final String serverId;
  final String channelId;
  final VoidCallback onHoverEnter;
  final VoidCallback onHoverExit;

  const _VoiceControlsPill({
    required this.serverId,
    required this.channelId,
    required this.onHoverEnter,
    required this.onHoverExit,
  });

  @override
  ConsumerState<_VoiceControlsPill> createState() =>
      _VoiceControlsPillState();
}

class _VoiceControlsPillState extends ConsumerState<_VoiceControlsPill> {
  Timer? _durationTimer;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final joinedAt = ref.read(voiceChannelProvider).joinedAt;
      if (joinedAt == null) return;
      setState(() => _duration = DateTime.now().difference(joinedAt));
    });
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleScreenShareToggle(VoiceChannelState vcState) async {
    if (vcState.isScreenSharing) {
      ref.read(voiceChannelProvider.notifier).stopScreenShare();
    } else {
      final selection = await showScreenShareDialog(context);
      if (selection != null && mounted) {
        ref.read(voiceChannelProvider.notifier).startScreenShare(
              selection.sourceId,
              selection.width,
              selection.height,
              selection.fps,
              shareAudio: selection.shareAudio,
              pid: selection.pid,
              windowHwnd: selection.windowHwnd,
              profile: selection.profile,
            );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final vcState = ref.watch(voiceChannelProvider);

    return MouseRegion(
      onEnter: (_) => widget.onHoverEnter(),
      onExit: (_) => widget.onHoverExit(),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.lg,
          vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: hollow.surface.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(HollowRadius.pill),
          border: Border.all(color: hollow.border.withValues(alpha: 0.5)),
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
            // Status dot
            StatusDot(color: hollow.success, size: 8, pulse: true),
            const SizedBox(width: HollowSpacing.sm),
            // Duration
            Text(
              _formatDuration(_duration),
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 12,
                fontFeatures: [const FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: HollowSpacing.lg),
            // Mute (PTT-aware: gated mic while idle, accent while held)
            Builder(builder: (context) {
              final mic = micButtonVisual(ref,
                  isMuted: vcState.isMuted,
                  hollow: hollow,
                  idleColor: hollow.textSecondary);
              return HollowTooltip(
                message: mic.tooltip,
                child: HollowPressable(
                  semanticLabel: vcState.isMuted ? 'Unmute' : 'Mute',
                  onTap: () =>
                      ref.read(voiceChannelProvider.notifier).toggleMute(),
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Icon(mic.icon, size: 16, color: mic.color),
                ),
              );
            }),
            const SizedBox(width: HollowSpacing.xs),
            // Deafen
            HollowTooltip(
              message: vcState.isDeafened ? 'Undeafen' : 'Deafen',
              child: HollowPressable(
                semanticLabel: vcState.isDeafened ? 'Undeafen' : 'Deafen',
                onTap: () =>
                    ref.read(voiceChannelProvider.notifier).toggleDeafen(),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(
                  LucideIcons.headphones,
                  size: 16,
                  color: vcState.isDeafened
                      ? hollow.error
                      : hollow.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: HollowSpacing.xs),
            // Camera toggle
            HollowTooltip(
              message: vcState.isCameraOn ? 'Turn off camera' : 'Turn on camera',
              child: HollowPressable(
                semanticLabel: vcState.isCameraOn
                    ? 'Turn off camera'
                    : 'Turn on camera',
                onTap: () =>
                    ref.read(voiceChannelProvider.notifier).toggleCamera(),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(
                  vcState.isCameraOn ? LucideIcons.video : LucideIcons.videoOff,
                  size: 16,
                  color:
                      vcState.isCameraOn ? hollow.accent : hollow.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: HollowSpacing.xs),
            // Screen share (desktop only)
            if (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
              HollowTooltip(
                message: vcState.isScreenSharing
                    ? 'Stop sharing'
                    : 'Share screen',
                child: HollowPressable(
                  semanticLabel: vcState.isScreenSharing
                      ? 'Stop sharing'
                      : 'Share screen',
                  onTap: () => _handleScreenShareToggle(vcState),
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Icon(
                    LucideIcons.monitor,
                    size: 16,
                    color: vcState.isScreenSharing
                        ? hollow.accent
                        : hollow.textSecondary,
                  ),
                ),
              ),
            // Received share audio: volume + duck controls — only when we're
            // actually receiving a share (watch-gated, issue #38).
            if (vcState.isWatchingAnyShare) ...[
              const SizedBox(width: HollowSpacing.xs),
              const ShareVolumeButton(),
            ],
            const SizedBox(width: HollowSpacing.sm),
            // Disconnect
            HollowTooltip(
              message: 'Disconnect',
              child: HollowPressable(
                semanticLabel: 'Disconnect',
                onTap: () =>
                    ref.read(voiceChannelProvider.notifier).leaveChannel(),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(LucideIcons.phoneOff,
                    size: 16, color: hollow.error),
              ),
            ),
          ],
        ),
      ),
    );
  }

}

// ---------------------------------------------------------------------------
// Overlay slider — animated slide-in/out panel for screen share chat overlay.
// ---------------------------------------------------------------------------

/// The screen-share-style right-side chat drawer — chevron toggle + slide-in
/// 360px [ChannelChatPane] — packaged for reuse OUTSIDE VoiceChannelPane. The
/// conference call surface embeds it so meetings get the exact same chat as
/// screen share (same slider, same pane). Pinned state is self-contained and
/// hover pinning is a no-op (static hosts have no auto-hiding overlays).
class VcChatOverlay extends StatefulWidget {
  final String serverId;
  final String channelId;
  final String channelName;
  final bool initiallyOpen;

  const VcChatOverlay({
    super.key,
    required this.serverId,
    required this.channelId,
    required this.channelName,
    this.initiallyOpen = false,
  });

  @override
  State<VcChatOverlay> createState() => _VcChatOverlayState();
}

class _VcChatOverlayState extends State<VcChatOverlay> {
  late bool _pinned = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        GestureDetector(
          onTap: () => setState(() => _pinned = !_pinned),
          child: Semantics(
            label: _pinned ? 'Hide chat' : 'Show chat',
            button: true,
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
                _pinned ? LucideIcons.chevronRight : LucideIcons.chevronLeft,
                size: 14,
                color: hollow.textSecondary,
              ),
            ),
          ),
        ),
        _OverlaySlider(
          visible: _pinned,
          onHoverEnter: () {},
          onHoverExit: () {},
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
            child: ChannelChatPane(
              serverId: widget.serverId,
              channelId: widget.channelId,
              channelName: widget.channelName,
            ),
          ),
        ),
      ],
    );
  }
}

class _OverlaySlider extends StatefulWidget {
  final bool visible;
  final VoidCallback onHoverEnter;
  final VoidCallback onHoverExit;
  final Widget child;

  const _OverlaySlider({
    required this.visible,
    required this.onHoverEnter,
    required this.onHoverExit,
    required this.child,
  });

  @override
  State<_OverlaySlider> createState() => _OverlaySliderState();
}

class _OverlaySliderState extends State<_OverlaySlider>
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
  void didUpdateWidget(covariant _OverlaySlider oldWidget) {
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
// "X is sharing — Watch" banner (opt-in watching, issue #38)
// ---------------------------------------------------------------------------

/// Floating card shown over the channel chat while remote shares exist that
/// we haven't opted into. One row per sharer: avatar + name + Watch + dismiss.
class _UnwatchedShareBanner extends ConsumerWidget {
  final List<String> sharerIds;
  final Map<String, String> labels;
  final void Function(String peerId) onWatch;
  final void Function(String peerId) onDismiss;

  const _UnwatchedShareBanner({
    required this.sharerIds,
    required this.labels,
    required this.onWatch,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);

    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xs,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final peerId in sharerIds)
            Builder(builder: (context) {
              final displayId =
                  ref.watch(deviceLinkProvider).identityOf(peerId);
              final name = displayNameFor(profiles, displayId);
              final quality = labels[peerId];
              return Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.monitor,
                        size: 14, color: hollow.textSecondary),
                    const SizedBox(width: HollowSpacing.xs),
                    HollowAvatar(peerId: displayId, size: 18),
                    const SizedBox(width: HollowSpacing.xs),
                    Flexible(
                      child: Text(
                        '$name is sharing their screen',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textPrimary,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (quality != null) ...[
                      const SizedBox(width: HollowSpacing.xs),
                      Text(
                        quality,
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textTertiary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                    const SizedBox(width: HollowSpacing.sm),
                    HollowButton.filled(
                      compact: true,
                      onPressed: () => onWatch(peerId),
                      child: const Text('Watch'),
                    ),
                    const SizedBox(width: HollowSpacing.xs),
                    HollowTooltip(
                      message: 'Dismiss',
                      child: HollowPressable(
                        onTap: () => onDismiss(peerId),
                        borderRadius: BorderRadius.circular(hollow.radiusSm),
                        padding: const EdgeInsets.all(4),
                        semanticLabel: 'Dismiss share notification',
                        child: Icon(LucideIcons.x,
                            size: 14, color: hollow.textSecondary),
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}
