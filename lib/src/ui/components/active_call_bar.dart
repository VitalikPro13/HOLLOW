import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Thin bar shown at the top of the screen during an active voice call.
/// Displays call duration, mute toggle, and end call button.
class ActiveCallBar extends ConsumerStatefulWidget {
  const ActiveCallBar({super.key});

  @override
  ConsumerState<ActiveCallBar> createState() => _ActiveCallBarState();
}

class _ActiveCallBarState extends ConsumerState<ActiveCallBar> {
  Timer? _durationTimer;
  Duration _duration = Duration.zero;
  Offset _dragOffset = Offset.zero;

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

  void _stopTimer() {
    _durationTimer?.cancel();
    _durationTimer = null;
    _duration = Duration.zero;
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callProvider);

    // Only show during active or connecting states.
    final isVisible =
        call.status == CallStatus.active ||
        call.status == CallStatus.connecting;

    // Hide the floating pill when the user is viewing the call peer's DM
    // (the inline call panel handles it there).
    final selectedPeer = ref.watch(selectedPeerProvider);
    final isViewingCallDm = selectedPeer == call.peerId;

    if (!isVisible || isViewingCallDm) {
      if (_durationTimer != null) _stopTimer();
      return const SizedBox.shrink();
    }

    // Start duration timer when call becomes active.
    if (call.status == CallStatus.active && call.startedAt != null) {
      if (_durationTimer == null) {
        _duration = DateTime.now().difference(call.startedAt!);
        _startTimer(call.startedAt!);
      }
    }

    final hollow = HollowTheme.of(context);
    final peerId = call.peerId ?? '';
    final displayName = displayNameFor(ref.watch(profileProvider), peerId);

    return Positioned(
      top: 80, // below title bar + friends bar
      left: 0,
      right: 0,
      child: Transform.translate(
        offset: _dragOffset,
        child: Center(
          child: GestureDetector(
            onPanUpdate: (details) {
              setState(() {
                _dragOffset += details.delta;
              });
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.move,
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.md,
                ),
                decoration: BoxDecoration(
                  color: hollow.elevated,
                  borderRadius: BorderRadius.circular(hollow.radiusLg),
                  border: Border.all(
                    color: hollow.success.withValues(alpha: 0.3),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 12,
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
                    const SizedBox(width: HollowSpacing.md),
                    HollowTooltip(
                      message: call.isMuted ? 'Unmute' : 'Mute',
                      child: HollowPressable(
                        onTap: () =>
                            ref.read(callProvider.notifier).toggleMute(),
                        borderRadius: BorderRadius.circular(hollow.radiusSm),
                        padding: const EdgeInsets.all(HollowSpacing.xs),
                        child: Icon(
                          call.isMuted ? LucideIcons.micOff : LucideIcons.mic,
                          size: 14,
                          color: call.isMuted
                              ? hollow.error
                              : hollow.textSecondary,
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
                            ? () =>
                                  ref.read(callProvider.notifier).toggleVideo()
                            : null,
                        borderRadius: BorderRadius.circular(hollow.radiusSm),
                        padding: const EdgeInsets.all(HollowSpacing.xs),
                        child: Icon(
                          call.isVideoEnabled
                              ? LucideIcons.video
                              : LucideIcons.videoOff,
                          size: 14,
                          color: call.isVideoEnabled
                              ? hollow.accent
                              : hollow.textSecondary,
                        ),
                      ),
                    ),
                    // Switch camera — mobile only (desktop has one camera).
                    if (call.isVideoEnabled &&
                        !Platform.isWindows &&
                        !Platform.isLinux &&
                        !Platform.isMacOS) ...[
                      const SizedBox(width: HollowSpacing.xs),
                      HollowTooltip(
                        message: 'Switch camera',
                        child: HollowPressable(
                          onTap: () =>
                              ref.read(callProvider.notifier).switchCamera(),
                          borderRadius: BorderRadius.circular(hollow.radiusSm),
                          padding: const EdgeInsets.all(HollowSpacing.xs),
                          child: Icon(
                            LucideIcons.switchCamera,
                            size: 14,
                            color: hollow.textSecondary,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: HollowSpacing.xs),
                    HollowTooltip(
                      message: 'End call',
                      child: HollowPressable(
                        onTap: () => ref.read(callProvider.notifier).endCall(),
                        borderRadius: BorderRadius.circular(hollow.radiusSm),
                        padding: const EdgeInsets.all(HollowSpacing.xs),
                        child: Icon(
                          LucideIcons.phoneOff,
                          size: 14,
                          color: hollow.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
