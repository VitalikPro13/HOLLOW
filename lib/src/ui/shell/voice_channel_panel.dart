import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/dm_navigation.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/call/call_stage_sources.dart' show dmCallPeerName;
import 'package:hollow/src/ui/components/connection_visual.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/shell/voice_quick_controls.dart';

/// Classic's "you" block at the foot of the channel sidebar while in a call,
/// a voice room or a DM: where it is, and mute, deafen and Leave as the dock
/// has them. Classic has no dock, so this is how a call is reached from
/// anywhere.
class VoiceChannelPanel extends ConsumerWidget {
  const VoiceChannelPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!watchHasQuickControls(ref)) return const SizedBox.shrink();
    final vcState = ref.watch(voiceChannelProvider);
    final call = ref.watch(callProvider.select((c) => (
          status: c.status,
          peerId: c.peerId,
        )));
    final dmMaster = call.status == CallStatus.idle || call.peerId == null
        ? null
        : ref.watch(deviceLinkProvider).identityOf(call.peerId!);

    final hollow = HollowTheme.of(context);
    final channels = ref.watch(channelListProvider);
    final where = dmMaster != null
        ? dmCallPeerName(ref, dmMaster)
        : channels[vcState.currentChannelId]?.name ??
            vcState.currentChannelName ??
            'Voice';
    final status = dmMaster == null
        ? 'Voice connected'
        : call.status == CallStatus.ringing
            ? 'Calling'
            : 'In a call';

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
                      connected ? status : visual.label,
                      style: HollowTypography.caption.copyWith(
                        color: connected ? hollow.success : visual.color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    HollowPressable(
                      subtle: true,
                      semanticLabel: 'Open $where',
                      onTap: dmMaster != null
                          ? () => openDmConversation(ref, dmMaster)
                          : null,
                      child: Text(
                        where,
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.sm),
          // The same three controls as the dock; camera and share live on the
          // room's own bar.
          const Center(child: VoiceQuickControls()),
        ],
      ),
    );
  }
}
