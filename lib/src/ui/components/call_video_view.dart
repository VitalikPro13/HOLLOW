import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Floating draggable video panel shown during a call when video is active.
/// Displays remote video (large) and local preview (small PiP corner).
class CallVideoView extends ConsumerStatefulWidget {
  const CallVideoView({super.key});

  @override
  ConsumerState<CallVideoView> createState() => _CallVideoViewState();
}

class _CallVideoViewState extends ConsumerState<CallVideoView> {
  Offset _position = const Offset(20, 80);

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callProvider);
    final hasAnyVideo = call.isVideoEnabled || call.remoteVideoEnabled;

    if (call.status != CallStatus.active || !hasAnyVideo) {
      return const SizedBox.shrink();
    }

    final voiceService = ref.read(callProvider.notifier).voiceService;
    final hollow = HollowTheme.of(context);
    final peerId = call.peerId ?? '';
    final profiles = ref.watch(profileProvider);
    final displayName = displayNameFor(profiles, peerId);
    final avatarBytes = profiles[peerId]?.avatarBytes;

    final remoteRenderer = voiceService?.remoteRenderer;
    final localRenderer = voiceService?.localRenderer;

    return Positioned(
      left: _position.dx,
      top: _position.dy,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            _position += details.delta;
          });
        },
        child: Container(
          width: 320,
          height: 240,
          decoration: BoxDecoration(
            color: hollow.elevated,
            borderRadius: BorderRadius.circular(hollow.radiusLg),
            border: Border.all(color: hollow.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(hollow.radiusLg),
            child: Stack(
              children: [
                if (call.remoteVideoEnabled && remoteRenderer != null)
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: RTCVideoView(
                        remoteRenderer,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      ),
                    ),
                  )
                else
                  Positioned.fill(
                    child: Container(
                      color: hollow.elevated,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            HollowAvatar(
                              peerId: peerId,
                              size: 64,
                              imageBytes: avatarBytes,
                            ),
                            const SizedBox(height: HollowSpacing.sm),
                            Text(
                              displayName,
                              style: HollowTypography.caption.copyWith(
                                color: hollow.textSecondary,
                              ),
                            ),
                            const SizedBox(height: HollowSpacing.xs),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  LucideIcons.videoOff,
                                  size: 12,
                                  color: hollow.textSecondary.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'Camera off',
                                  style: HollowTypography.caption.copyWith(
                                    color: hollow.textSecondary.withValues(
                                      alpha: 0.5,
                                    ),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (call.isVideoEnabled && localRenderer != null)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      width: 96,
                      height: 72,
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
                        child: RepaintBoundary(
                          child: RTCVideoView(
                            localRenderer,
                            mirror: true,
                            objectFit:
                                RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
