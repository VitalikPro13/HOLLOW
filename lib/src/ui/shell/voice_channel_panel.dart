import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/dialogs/screen_share_dialog.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Voice channel controls panel.
/// Sits at the bottom of the channel sidebar when the user is in a voice channel.
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
          // Header: connection status + channel name
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Voice Connected',
                      style: HollowTypography.caption.copyWith(
                        color: Colors.green,
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
          // Controls row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Mute toggle
              HollowTooltip(
                message: vcState.isMuted ? 'Unmute' : 'Mute',
                child: HollowPressable(
                  onTap: () =>
                      ref.read(voiceChannelProvider.notifier).toggleMute(),
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.sm),
                  child: Icon(
                    vcState.isMuted ? LucideIcons.micOff : LucideIcons.mic,
                    size: 18,
                    color: vcState.isMuted ? hollow.error : hollow.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              // Deafen toggle
              HollowTooltip(
                message: vcState.isDeafened ? 'Undeafen' : 'Deafen',
                child: HollowPressable(
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
              // Screen share (desktop only)
              if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) ...[
                const SizedBox(width: HollowSpacing.sm),
                HollowTooltip(
                  message: vcState.isScreenSharing
                      ? 'Stop sharing'
                      : 'Share screen',
                  child: HollowPressable(
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
              // Disconnect
              HollowTooltip(
                message: 'Disconnect',
                child: HollowPressable(
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
