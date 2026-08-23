import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/recording_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/services/macos_version.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/ptt_mic_visual.dart';
import 'package:hollow/src/ui/components/recording_indicator.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
    final rec = ref.watch(recordingProvider);

    // Surface recording lifecycle as toast notifications.
    ref.listen<RecordingState>(recordingProvider, (prev, next) {
      if (next.lastFinished != null &&
          next.lastFinished != prev?.lastFinished) {
        HollowToast.show(
          context,
          'Recording saved to ${next.lastFinished!.filePath}',
          type: HollowToastType.success,
          duration: const Duration(seconds: 15),
        );
        ref.read(recordingProvider.notifier).acknowledgeLastFinished();
      }
      if (next.lastError != null && next.lastError != prev?.lastError) {
        HollowToast.show(
          context,
          'Recording: ${next.lastError}',
          type: HollowToastType.error,
        );
        ref.read(recordingProvider.notifier).acknowledgeLastError();
      }
    });

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
    final displayName = displayNameForPeer(
      ref.watch(profileProvider.select((p) => p[peerId])),
      peerId,
    );

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
                height: 44,
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
                    StatusDot(color: hollow.success, size: 8),
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
                      if (rec.isMyRecording) ...[
                        const SizedBox(width: HollowSpacing.sm),
                        RecordingIndicator(startedAt: rec.myStartedAt),
                      ] else if (rec.remoteRecorders.isNotEmpty) ...[
                        const SizedBox(width: HollowSpacing.sm),
                        const RecordingIndicator(),
                      ],
                    ],
                    const SizedBox(width: HollowSpacing.md),
                    Builder(builder: (context) {
                      // PTT-aware mic (issue #38): gated while idle, live
                      // on hold.
                      final mic = micButtonVisual(ref,
                          isMuted: call.isMuted,
                          hollow: hollow,
                          idleColor: hollow.textSecondary);
                      return HollowTooltip(
                        message: mic.tooltip,
                        child: HollowPressable(
                          semanticLabel: call.isMuted ? 'Unmute' : 'Mute',
                          onTap: () =>
                              ref.read(callProvider.notifier).toggleMute(),
                          borderRadius:
                              BorderRadius.circular(hollow.radiusSm),
                          padding: const EdgeInsets.all(HollowSpacing.xs),
                          child:
                              Icon(mic.icon, size: 18, color: mic.color),
                        ),
                      );
                    }),
                    const SizedBox(width: HollowSpacing.xs),
                    HollowTooltip(
                      message: call.isVideoEnabled
                          ? 'Turn off camera'
                          : 'Turn on camera',
                      child: HollowPressable(
                        semanticLabel: call.isVideoEnabled
                            ? 'Turn off camera'
                            : 'Turn on camera',
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
                          size: 18,
                          color: call.isVideoEnabled
                              ? hollow.accent
                              : hollow.textSecondary,
                        ),
                      ),
                    ),
                    // Screen share indicator (desktop only).
                    if (Platform.isWindows ||
                        Platform.isLinux ||
                        Platform.isMacOS) ...[
                      const SizedBox(width: HollowSpacing.xs),
                      HollowTooltip(
                        message: call.isScreenSharing
                            ? 'Stop sharing'
                            : 'Sharing screen',
                        child: HollowPressable(
                          semanticLabel: call.isScreenSharing
                              ? 'Stop sharing'
                              : 'Sharing screen',
                          onTap: call.isScreenSharing
                              ? () => ref
                                    .read(callProvider.notifier)
                                    .stopScreenShare()
                              : null,
                          borderRadius: BorderRadius.circular(hollow.radiusSm),
                          padding: const EdgeInsets.all(HollowSpacing.xs),
                          child: Icon(
                            call.isScreenSharing
                                ? LucideIcons.monitorOff
                                : LucideIcons.monitor,
                            size: 18,
                            color: call.isScreenSharing
                                ? hollow.accent
                                : hollow.textSecondary.withValues(alpha: 0.4),
                          ),
                        ),
                      ),
                    ],
                    // Record button (Windows + macOS only). Shown; if the
                    // backend isn't available the start call surfaces a clear
                    // error toast instead of silently hiding it. On macOS < 13.0
                    // the native recorder doesn't exist, so the button is
                    // disabled with an explanatory tooltip (mirrors the
                    // audio-share toggle). Hidden on Linux — there's no native
                    // recorder there yet (the libwebrtc-capture + ffmpeg pipe
                    // path was choppy/out-of-sync), so the button is omitted
                    // entirely rather than shipping a broken capture.
                    if (Platform.isWindows || Platform.isMacOS) ...[
                      const SizedBox(width: HollowSpacing.xs),
                      HollowTooltip(
                        message: MacOsScreenAudioSupport.recordBlockedByOldOs
                            ? 'Recording needs macOS 13.0 or later'
                            : (rec.isMyRecording
                                ? 'Stop recording'
                                : 'Record this call'),
                        child: HollowPressable(
                          disabled: MacOsScreenAudioSupport.recordBlockedByOldOs,
                          semanticLabel: rec.isMyRecording
                              ? 'Stop recording'
                              : 'Record this call',
                          onTap: () {
                            final notifier = ref.read(
                              recordingProvider.notifier,
                            );
                            if (rec.isMyRecording) {
                              notifier.stopRecording();
                            } else {
                              notifier.startRecording();
                            }
                          },
                          borderRadius: BorderRadius.circular(hollow.radiusSm),
                          padding: const EdgeInsets.all(HollowSpacing.xs),
                          child: Icon(
                            rec.isMyRecording
                                ? LucideIcons.stopCircle
                                : LucideIcons.circle,
                            size: 18,
                            color: rec.isMyRecording
                                ? const Color(0xFFE53935)
                                : hollow.textSecondary,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: HollowSpacing.xs),
                    HollowTooltip(
                      message: 'End call',
                      child: HollowPressable(
                        semanticLabel: 'End call',
                        onTap: () => ref.read(callProvider.notifier).endCall(),
                        borderRadius: BorderRadius.circular(hollow.radiusSm),
                        padding: const EdgeInsets.all(HollowSpacing.xs),
                        child: Icon(
                          LucideIcons.phoneOff,
                          size: 18,
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
