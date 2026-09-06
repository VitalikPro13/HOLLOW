import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/connection_visual.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/ptt_mic_visual.dart';
import 'package:hollow/src/ui/dialogs/screen_share_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Voice channel controls, at the bottom of the channel sidebar while the user
/// is in a voice channel.
class VoiceChannelPanel extends ConsumerWidget {
  const VoiceChannelPanel({super.key});

  Future<void> _handleScreenShareToggle(
    BuildContext context,
    WidgetRef ref,
    VoiceChannelState vcState,
  ) async {
    if (vcState.isScreenSharing) {
      ref.read(voiceChannelProvider.notifier).stopScreenShare();
    } else {
      final selection = await showScreenShareDialog(context);
      if (selection != null && context.mounted) {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final vcState = ref.watch(voiceChannelProvider);
    if (!vcState.isInVoiceChannel) return const SizedBox.shrink();

    final hollow = HollowTheme.of(context);
    final channels = ref.watch(channelListProvider);
    final channelName =
        channels[vcState.currentChannelId]?.name ?? 'Voice';

    // OUR OWN link, not the mesh's: a per-peer leg in trouble is labelled on
    // that member's row, and this line is the one case affecting everyone. A
    // hardcoded green here contradicts the truth while the relay is down.
    final connection = ref.watch(overallConnectionProvider);
    final visual = connectionVisual(hollow, connection);
    final connected = connection.isOnline;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(
          top: BorderSide(color: hollow.border, width: 1),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Shape carries the state as well as colour: only a settled
              // connection is a filled disc.
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: connected ? visual.color : Colors.transparent,
                  border: connected
                      ? null
                      : Border.all(color: visual.color, width: 1.5),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      connected ? 'Voice connected' : visual.label,
                      style: HollowTypography.caption.copyWith(
                        color: connected ? hollow.success : visual.color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      channelName,
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // PTT-aware: a gated mic while idle, live on hold.
              Builder(builder: (context) {
                final mic = micButtonVisual(ref,
                    isMuted: vcState.isMuted,
                    hollow: hollow,
                    idleColor: hollow.textPrimary);
                return HollowTooltip(
                  message: mic.tooltip,
                  child: HollowPressable(
                    semanticLabel: vcState.isMuted ? 'Unmute' : 'Mute',
                    onTap: () =>
                        ref.read(voiceChannelProvider.notifier).toggleMute(),
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.sm),
                    child: Icon(mic.icon, size: 18, color: mic.color),
                  ),
                );
              }),
              const SizedBox(width: HollowSpacing.sm),
              HollowTooltip(
                message: vcState.isDeafened ? 'Undeafen' : 'Deafen',
                child: HollowPressable(
                  semanticLabel: vcState.isDeafened ? 'Undeafen' : 'Deafen',
                  onTap: () =>
                      ref.read(voiceChannelProvider.notifier).toggleDeafen(),
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.sm),
                  child: Icon(
                    LucideIcons.headphones,
                    size: 18,
                    color: vcState.isDeafened
                        ? hollow.error
                        : hollow.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowTooltip(
                message: vcState.isCameraOn ? 'Turn off camera' : 'Turn on camera',
                child: HollowPressable(
                  semanticLabel: vcState.isCameraOn
                      ? 'Turn off camera'
                      : 'Turn on camera',
                  onTap: () =>
                      ref.read(voiceChannelProvider.notifier).toggleCamera(),
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.sm),
                  child: Icon(
                    vcState.isCameraOn ? LucideIcons.video : LucideIcons.videoOff,
                    size: 18,
                    color: vcState.isCameraOn
                        ? hollow.accent
                        : hollow.textPrimary,
                  ),
                ),
              ),
              if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) ...[
                const SizedBox(width: HollowSpacing.sm),
                HollowTooltip(
                  message: vcState.isScreenSharing
                      ? 'Stop sharing'
                      : 'Share screen',
                  child: HollowPressable(
                    semanticLabel: vcState.isScreenSharing
                        ? 'Stop sharing'
                        : 'Share screen',
                    onTap: () => _handleScreenShareToggle(context, ref, vcState),
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.sm),
                    child: Icon(
                      LucideIcons.monitor,
                      size: 18,
                      color: vcState.isScreenSharing
                          ? hollow.accent
                          : hollow.textPrimary,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: HollowSpacing.sm),
              HollowTooltip(
                message: 'Disconnect',
                child: HollowPressable(
                  semanticLabel: 'Disconnect',
                  onTap: () =>
                      ref.read(voiceChannelProvider.notifier).leaveChannel(),
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.sm),
                  child: Icon(
                    LucideIcons.phoneOff,
                    size: 18,
                    color: hollow.error,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
