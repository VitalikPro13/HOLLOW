import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/link_health_provider.dart';
import 'package:hollow/src/core/services/link_resilience.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/call/call_actions.dart';
import 'package:hollow/src/ui/call/call_person_tile.dart';
import 'package:hollow/src/ui/call/call_stage_bar.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/call/call_stage_sources.dart';
import 'package:hollow/src/ui/call/call_theme.dart';
import 'package:hollow/src/ui/components/call_duration_text.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Height of the call row under the DM header.
const double kDmCallRowHeight = 56;

/// A DM voice call starts chat-first (D2): this row under the header carries
/// the call while the conversation stays the page. Ringing out, it is Cancel;
/// in the call, the two of you, the timer, a share offer, and the controls.
/// The stage takes over once a camera or a share needs it.
class DmCallRow extends ConsumerWidget {
  final String peerMaster;

  const DmCallRow({super.key, required this.peerMaster});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callProvider);
    if (!isDmCallWith(ref, call, peerMaster)) return const SizedBox.shrink();
    // An incoming ring belongs to its card, a forced or opened call to the
    // stage.
    if (call.status == CallStatus.ringing &&
        call.direction == CallDirection.incoming) {
      return const SizedBox.shrink();
    }
    if (watchDmStageShown(ref, peerMaster)) return const SizedBox.shrink();

    final hollow = HollowTheme.of(context);
    final content = call.status == CallStatus.ringing
        ? _ringing(context, ref, hollow)
        : _inCall(context, ref, hollow, call);
    return Container(
      height: kDmCallRowHeight,
      padding: const EdgeInsets.only(
        left: HollowSpacing.lg,
        right: HollowSpacing.md,
      ),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Semantics(container: true, label: 'Call', child: content),
    );
  }

  Widget _ringing(BuildContext context, WidgetRef ref, HollowTheme hollow) {
    final name = dmCallPeerName(ref, peerMaster);
    return Row(
      children: [
        HollowAvatar(
            peerId: peerMaster, size: CallMetrics.compactAvatar, frameId: ''),
        const SizedBox(width: HollowSpacing.md),
        Expanded(
          child: _titles(
            Text('Calling $name',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    HollowTypography.label.copyWith(color: hollow.textPrimary)),
            Text('Ringing',
                style: HollowTypography.caption
                    .copyWith(color: hollow.textTertiary)),
          ),
        ),
        HollowButton.ghost(
          compact: true,
          onPressed: () => leaveDmCall(context, ref),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _inCall(
      BuildContext context, WidgetRef ref, HollowTheme hollow, CallState call) {
    final data = DmCallStageSource(peerMaster).watchData(context, ref);
    if (data == null) return const SizedBox.shrink();
    final calls = ref.read(callProvider.notifier);
    final active = call.status == CallStatus.active;
    final link = ref.watch(callLinkHealthProvider);
    final weak = link.health != LinkHealth.healthy;
    final offer = data.shares.where((s) => s.isOffer).firstOrNull;

    return Row(
      children: [
        for (var i = 0; i < data.people.length; i++) ...[
          if (i > 0) const SizedBox(width: HollowSpacing.md),
          CallPersonTile(
            key: ValueKey('row:${data.people[i].id}'),
            person: data.people[i],
            size: CallTileSize.compact,
          ),
        ],
        const SizedBox(width: HollowSpacing.md),
        Expanded(
          child: _titles(
            Text(
              weak ? 'Weak connection' : 'Voice call',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HollowTypography.label.copyWith(
                  color: weak ? hollow.warning : hollow.textPrimary),
            ),
            active && call.startedAt != null
                ? CallDurationText(
                    startedAt: call.startedAt!,
                    style: HollowTypography.monoSmall.copyWith(
                      color: hollow.textTertiary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  )
                : Text('Connecting',
                    style: HollowTypography.caption
                        .copyWith(color: hollow.textTertiary)),
          ),
        ),
        if (offer != null) ...[
          _InlineShareOffer(share: offer, onWatch: () => data.onWatch(offer.owner)),
          const SizedBox(width: HollowSpacing.sm),
        ],
        CallToggleButton(
          icon: call.isVideoEnabled ? LucideIcons.video : LucideIcons.videoOff,
          label: call.isVideoEnabled ? 'Turn off camera' : 'Turn on camera',
          size: 32,
          on: call.isVideoEnabled,
          onPressed: active
              ? () => calls.toggleVideo().catchError((Object _) {})
              : null,
        ),
        if (callCanShareScreen) ...[
          const SizedBox(width: HollowSpacing.xs),
          CallToggleButton(
            icon: LucideIcons.monitorUp,
            label: 'Share your screen',
            size: 32,
            onPressed: active ? () => toggleDmScreenShare(context, ref) : null,
          ),
        ],
        const SizedBox(width: HollowSpacing.xs),
        CallToggleButton(
          icon: LucideIcons.maximize2,
          label: 'Open the call',
          size: 32,
          onPressed: () =>
              ref.read(dmStageOpenedProvider.notifier).state = call.callId,
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
          child: SizedBox(
            height: HollowSpacing.xl,
            child: HollowVerticalDivider(),
          ),
        ),
        CallMuteButton(
          muted: call.isMuted,
          size: 32,
          onPressed: active ? calls.toggleMute : null,
        ),
        const SizedBox(width: HollowSpacing.xs),
        CallToggleButton(
          icon: call.isDeafened
              ? LucideIcons.headphoneOff
              : LucideIcons.headphones,
          label: call.isDeafened ? 'Undeafen' : 'Deafen',
          size: 32,
          alarm: call.isDeafened,
          onPressed: active ? calls.toggleDeafen : null,
        ),
        const SizedBox(width: HollowSpacing.sm),
        CallLeaveButton(
          label: 'Leave the call',
          width: 44,
          height: 36,
          onPressed: () => leaveDmCall(context, ref),
        ),
      ],
    );
  }

  Widget _titles(Widget title, Widget subtitle) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [title, const SizedBox(height: HollowSpacing.xxs), subtitle],
      );
}

/// "Mira is sharing their screen" with Watch, inline in the call row. Nothing
/// streams until Watch (issue #38).
class _InlineShareOffer extends StatelessWidget {
  final CallShare share;
  final VoidCallback onWatch;

  const _InlineShareOffer({required this.share, required this.onWatch});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      padding: const EdgeInsets.only(
        left: HollowSpacing.md,
        right: HollowSpacing.xs,
        top: HollowSpacing.xs,
        bottom: HollowSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.monitor, size: 14, color: hollow.textTertiary),
          const SizedBox(width: HollowSpacing.sm),
          Text.rich(
            TextSpan(children: [
              TextSpan(
                text: share.name,
                style: TextStyle(
                  color: callNameColor(hollow,
                      isSelf: false, master: share.master),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const TextSpan(text: ' is sharing their screen'),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.outline(
            compact: true,
            onPressed: onWatch,
            child: const Text('Watch'),
          ),
        ],
      ),
    );
  }
}
