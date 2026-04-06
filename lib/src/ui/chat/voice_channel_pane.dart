import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/chat/channel_chat_pane.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/dialogs/screen_share_dialog.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Voice channel pane — shows channel text chat with an inline call strip
/// showing connected participants and voice controls. When screen sharing
/// is active, switches to a full-bleed screen share view with a chat overlay.
class VoiceChannelPane extends ConsumerStatefulWidget {
  final String serverId;
  final String channelId;
  final String channelName;

  const VoiceChannelPane({
    super.key,
    required this.serverId,
    required this.channelId,
    required this.channelName,
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

    // Not in this voice channel — show join prompt.
    if (!isInThisChannel) {
      return _buildJoinPrompt(hollow);
    }

    // Screen share active — full-bleed view (mixed mode if cameras too).
    if (vcState.isScreenShareActive) {
      return _buildScreenShareView(hollow, vcState);
    }

    // Camera video active — grid view.
    if (vcState.isCameraActive) {
      return _buildCameraGridView(hollow, vcState);
    }

    // Normal: just channel text chat (voice participants visible in sidebar).
    return ChannelChatPane(
      serverId: widget.serverId,
      channelId: widget.channelId,
      channelName: widget.channelName,
    );
  }

  // ---------------------------------------------------------------------------
  // Join prompt
  // ---------------------------------------------------------------------------

  Widget _buildJoinPrompt(HollowTheme hollow) {
    return Container(
      color: hollow.background,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.volume2,
              size: 56,
              color: hollow.textSecondary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: HollowSpacing.lg),
            Text(
              widget.channelName,
              style: HollowTypography.heading.copyWith(
                color: hollow.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 20,
              ),
            ),
            const SizedBox(height: HollowSpacing.sm),
            Text(
              'Join this voice channel to start talking',
              style: HollowTypography.body.copyWith(
                color: hollow.textSecondary,
              ),
            ),
            const SizedBox(height: HollowSpacing.xl),
            HollowButton.filled(
              onPressed: () => ref.read(voiceChannelProvider.notifier)
                  .joinChannel(widget.serverId, widget.channelId),
              icon: const Icon(LucideIcons.phoneCall, size: 16),
              child: const Text('Join Voice'),
            ),
          ],
        ),
      ),
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
                AnimatedOpacity(
                  opacity: _overlaysVisible ? 1.0 : 0.0,
                  duration: HollowDurations.normal,
                  child: IgnorePointer(
                    ignoring: !_overlaysVisible,
                    child: MouseRegion(
                      onEnter: (_) => _pinOverlays(),
                      onExit: (_) => _resetOverlayTimer(),
                      child: GestureDetector(
                        onTap: () => setState(
                            () => _chatOverlayPinned = !_chatOverlayPinned),
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

  /// Build the N-tile video grid layout.
  Widget _buildVideoGrid(
    HollowTheme hollow,
    VoiceChannelState vcState,
    List<String> cameraPeers,
    String localPeerId,
  ) {
    final n = cameraPeers.length;
    if (n == 0) return const SizedBox.shrink();

    if (n == 1) {
      return _buildVideoTile(
          hollow, vcState, cameraPeers[0], localPeerId, canTap: false);
    }

    if (n == 2) {
      return Row(
        children: [
          Expanded(
              child: _buildVideoTile(
                  hollow, vcState, cameraPeers[0], localPeerId)),
          Expanded(
              child: _buildVideoTile(
                  hollow, vcState, cameraPeers[1], localPeerId)),
        ],
      );
    }

    if (n == 3) {
      return Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(
                    child: _buildVideoTile(
                        hollow, vcState, cameraPeers[0], localPeerId)),
                Expanded(
                    child: _buildVideoTile(
                        hollow, vcState, cameraPeers[1], localPeerId)),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: FractionallySizedBox(
                widthFactor: 0.5,
                child: _buildVideoTile(
                    hollow, vcState, cameraPeers[2], localPeerId),
              ),
            ),
          ),
        ],
      );
    }

    if (n == 4) {
      return Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(
                    child: _buildVideoTile(
                        hollow, vcState, cameraPeers[0], localPeerId)),
                Expanded(
                    child: _buildVideoTile(
                        hollow, vcState, cameraPeers[1], localPeerId)),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(
                    child: _buildVideoTile(
                        hollow, vcState, cameraPeers[2], localPeerId)),
                Expanded(
                    child: _buildVideoTile(
                        hollow, vcState, cameraPeers[3], localPeerId)),
              ],
            ),
          ),
        ],
      );
    }

    // n == 5: top row 3, bottom row 2 centered
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(
                  child: _buildVideoTile(
                      hollow, vcState, cameraPeers[0], localPeerId)),
              Expanded(
                  child: _buildVideoTile(
                      hollow, vcState, cameraPeers[1], localPeerId)),
              Expanded(
                  child: _buildVideoTile(
                      hollow, vcState, cameraPeers[2], localPeerId)),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              const Spacer(),
              Expanded(
                flex: 2,
                child: _buildVideoTile(
                    hollow, vcState, cameraPeers[3], localPeerId),
              ),
              Expanded(
                flex: 2,
                child: _buildVideoTile(
                    hollow, vcState, cameraPeers[4], localPeerId),
              ),
              const Spacer(),
            ],
          ),
        ),
      ],
    );
  }

  /// Single video tile in the grid.
  Widget _buildVideoTile(
    HollowTheme hollow,
    VoiceChannelState vcState,
    String peerId,
    String localPeerId, {
    bool canTap = true,
  }) {
    final isLocal = peerId == localPeerId;
    final renderer = ref.read(voiceChannelProvider.notifier)
        .getCameraRenderer(peerId);
    final profiles = ref.watch(profileProvider);
    final name = isLocal ? 'You' : displayNameFor(profiles, peerId);
    final isSpeaking = vcState.isSpeaking(peerId);

    return GestureDetector(
      onTap: canTap
          ? () => setState(() => _focusedVideoPeerId = peerId)
          : null,
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
                      peerId: peerId,
                      size: 48,
                      imageBytes: profiles[peerId]?.avatarBytes,
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
    final profiles = ref.watch(profileProvider);
    final others = cameraPeers.where((p) => p != focusedPeerId).toList();

    return GestureDetector(
      onTap: () => setState(() => _focusedVideoPeerId = null),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          // Main video (full area)
          Positioned.fill(
            child: renderer != null
                ? RepaintBoundary(
                    child: RTCVideoView(
                      renderer,
                      mirror: isLocal,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
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
                    final profile = profiles[peerId];

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
                                    peerId: peerId,
                                    size: 28,
                                    imageBytes: profile?.avatarBytes,
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

    return MouseRegion(
      onHover: (_) => _resetOverlayTimer(),
      onEnter: (_) => _resetOverlayTimer(),
      child: Stack(
        children: [
          // Layer 0: full-bleed content (screen share or camera)
          Positioned.fill(
            child: isCameraFocused && focusedPeerId != null
                ? _buildFocusedCameraContent(hollow, focusedPeerId, localPeerId)
                : _buildScreenShareContent(
                    hollow, vcState, focusedPeerId, isLocalFocused),
          ),

          // Layer 1 (top): source switcher tabs (multiple sources)
          if (_countActiveSources(vcState) > 1)
            Positioned(
              top: HollowSpacing.md,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                opacity: _overlaysVisible ? 1.0 : 0.0,
                duration: HollowDurations.normal,
                child: IgnorePointer(
                  ignoring: !_overlaysVisible,
                  child: _buildSharerSwitcher(hollow, vcState, localPeerId),
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
                AnimatedOpacity(
                  opacity: _overlaysVisible ? 1.0 : 0.0,
                  duration: HollowDurations.normal,
                  child: IgnorePointer(
                    ignoring: !_overlaysVisible,
                    child: MouseRegion(
                      onEnter: (_) => _pinOverlays(),
                      onExit: (_) => _resetOverlayTimer(),
                      child: GestureDetector(
                        onTap: () => setState(
                            () => _chatOverlayPinned = !_chatOverlayPinned),
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
      // We are the focused sharer — show banner.
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.monitor,
                  size: 56, color: hollow.accent.withValues(alpha: 0.5)),
              const SizedBox(height: HollowSpacing.lg),
              Text('You are sharing your screen',
                  style: HollowTypography.heading.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 18,
                  )),
              const SizedBox(height: HollowSpacing.sm),
              Text('Others can see your screen',
                  style: HollowTypography.body
                      .copyWith(color: hollow.textSecondary)),
              const SizedBox(height: HollowSpacing.lg),
              HollowButton.danger(
                onPressed: () =>
                    ref.read(voiceChannelProvider.notifier).stopScreenShare(),
                child: const Text('Stop Sharing'),
              ),
            ],
          ),
        ),
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

    // Remote peer is focused — show their screen.
    final renderer = ref
        .read(voiceChannelProvider.notifier)
        .getScreenShareRenderer(focusedPeerId);

    return Container(
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
    final profiles = ref.watch(profileProvider);
    final name = isLocal ? 'You' : displayNameFor(profiles, focusedPeerId);

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
                    peerId: focusedPeerId,
                    size: 64,
                    imageBytes: profiles[focusedPeerId]?.avatarBytes,
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

  /// Count all active video sources (screen shares + cameras) for the switcher.
  int _countActiveSources(VoiceChannelState vcState) {
    int count = vcState.isScreenSharing ? 1 : 0;
    count += vcState.peerScreenSharing.values.where((v) => v).length;
    // In mixed mode, also count camera sources.
    if (vcState.isCameraOn) count++;
    count += vcState.peerCameraOn.values.where((v) => v).length;
    return count;
  }

  Widget _buildSharerSwitcher(
    HollowTheme hollow,
    VoiceChannelState vcState,
    String localPeerId,
  ) {
    final profiles = ref.watch(profileProvider);

    // Build list of all sources: (peerId, type) pairs.
    final sources = <(String, String)>[]; // (peerId, 'screen' | 'camera')
    // Screen share sources first.
    if (vcState.isScreenSharing) sources.add((localPeerId, 'screen'));
    for (final entry in vcState.peerScreenSharing.entries) {
      if (entry.value) sources.add((entry.key, 'screen'));
    }
    // Camera sources.
    if (vcState.isCameraOn) sources.add((localPeerId, 'camera'));
    for (final entry in vcState.peerCameraOn.entries) {
      if (entry.value) sources.add((entry.key, 'camera'));
    }

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
            children: sources.map((source) {
              final (peerId, sourceType) = source;
              final isFocused =
                  peerId == vcState.focusedScreenSharePeerId &&
                  sourceType == vcState.focusedSourceType;
              final name = displayNameFor(profiles, peerId);
              final profile = profiles[peerId];

              return Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.xs),
                child: HollowPressable(
                  onTap: () => ref
                      .read(voiceChannelProvider.notifier)
                      .setFocusedSource(peerId, sourceType),
                  borderRadius:
                      BorderRadius.circular(hollow.radiusSm),
                  backgroundColor:
                      isFocused ? hollow.accentMuted : Colors.transparent,
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.sm,
                    vertical: HollowSpacing.xs,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Source type icon.
                      Icon(
                        sourceType == 'screen'
                            ? LucideIcons.monitor
                            : LucideIcons.video,
                        size: 12,
                        color: isFocused
                            ? hollow.accent
                            : hollow.textSecondary,
                      ),
                      const SizedBox(width: HollowSpacing.xs),
                      HollowAvatar(
                        peerId: peerId,
                        size: 18,
                        imageBytes: profile?.avatarBytes,
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
            }).toList(),
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
            // Mute
            HollowTooltip(
              message: vcState.isMuted ? 'Unmute' : 'Mute',
              child: HollowPressable(
                onTap: () =>
                    ref.read(voiceChannelProvider.notifier).toggleMute(),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(
                  vcState.isMuted ? LucideIcons.micOff : LucideIcons.mic,
                  size: 16,
                  color:
                      vcState.isMuted ? hollow.error : hollow.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: HollowSpacing.xs),
            // Deafen
            HollowTooltip(
              message: vcState.isDeafened ? 'Undeafen' : 'Deafen',
              child: HollowPressable(
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
            const SizedBox(width: HollowSpacing.sm),
            // Disconnect
            HollowTooltip(
              message: 'Disconnect',
              child: HollowPressable(
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
