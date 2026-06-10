import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/ui/mobile/mobile_voice_channel_route.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Floating pill shown when in a voice channel on mobile.
/// Mute, deafen, leave, duration timer. Tap body to return to voice route.
class MobileVoiceChannelPill extends ConsumerStatefulWidget {
  const MobileVoiceChannelPill({super.key});

  @override
  ConsumerState<MobileVoiceChannelPill> createState() =>
      _MobileVoiceChannelPillState();
}

class _MobileVoiceChannelPillState
    extends ConsumerState<MobileVoiceChannelPill> {
  Timer? _durationTimer;
  Duration _duration = Duration.zero;
  Offset _dragOffset = Offset.zero;

  @override
  void dispose() {
    _durationTimer?.cancel();
    super.dispose();
  }

  void _startTimer(DateTime joinedAt) {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _duration = DateTime.now().difference(joinedAt);
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

  void _openVoiceRoute(VoiceChannelState vcState, String channelName) {
    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => MobileVoiceChannelRoute(
          serverId: vcState.currentServerId!,
          channelId: vcState.currentChannelId!,
          channelName: channelName,
        ),
        transitionsBuilder: (_, anim, __, child) => SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vcState = ref.watch(voiceChannelProvider);
    final callState = ref.watch(callProvider);

    // Hide when not in a voice channel or during a DM call.
    final isVisible =
        vcState.isInVoiceChannel && callState.status == CallStatus.idle;

    if (!isVisible) {
      if (_durationTimer != null) _stopTimer();
      return const SizedBox.shrink();
    }

    if (vcState.joinedAt != null && _durationTimer == null) {
      _duration = DateTime.now().difference(vcState.joinedAt!);
      _startTimer(vcState.joinedAt!);
    }

    final hollow = HollowTheme.of(context);
    final channelName = vcState.currentChannelName ?? 'Voice';
    final vcNotifier = ref.read(voiceChannelProvider.notifier);

    return Positioned(
      bottom: 80,
      left: 0,
      right: 0,
      child: Transform.translate(
        offset: _dragOffset,
        child: Center(
          child: GestureDetector(
            onPanUpdate: (details) {
              // Clamp so the pill can't be dragged below its anchor (into
              // the bottom nav) or off-screen.
              final size = MediaQuery.sizeOf(context);
              final topInset = MediaQuery.viewPaddingOf(context).top;
              final next = _dragOffset + details.delta;
              setState(() => _dragOffset = Offset(
                    next.dx.clamp(
                        -(size.width / 2 - 80), size.width / 2 - 80),
                    next.dy.clamp(-(size.height - 80 - 48 - topInset - 8), 0.0),
                  ));
            },
            onTap: () => _openVoiceRoute(vcState, channelName),
            child: Material(
              color: Colors.transparent,
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.md,
                ),
                decoration: BoxDecoration(
                  color: hollow.elevated,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: hollow.success.withValues(alpha: 0.3),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
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
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 100),
                      child: Text(
                        '# $channelName',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
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
                    const SizedBox(width: HollowSpacing.md),
                    // Mute
                    HollowPressable(
                      onTap: () => vcNotifier.toggleMute(),
                      borderRadius: BorderRadius.circular(hollow.radiusSm),
                      padding: const EdgeInsets.all(HollowSpacing.xs),
                      child: Icon(
                        vcState.isMuted
                            ? LucideIcons.micOff
                            : LucideIcons.mic,
                        size: 20,
                        color: vcState.isMuted
                            ? hollow.error
                            : hollow.textSecondary,
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.xs),
                    // Deafen
                    HollowPressable(
                      onTap: () => vcNotifier.toggleDeafen(),
                      borderRadius: BorderRadius.circular(hollow.radiusSm),
                      padding: const EdgeInsets.all(HollowSpacing.xs),
                      child: Icon(
                        LucideIcons.headphones,
                        size: 20,
                        color: vcState.isDeafened
                            ? hollow.error
                            : hollow.textSecondary,
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.xs),
                    // Leave
                    HollowPressable(
                      onTap: () => vcNotifier.leaveChannel(),
                      borderRadius: BorderRadius.circular(hollow.radiusSm),
                      padding: const EdgeInsets.all(HollowSpacing.xs),
                      child: Icon(
                        LucideIcons.phoneOff,
                        size: 20,
                        color: hollow.error,
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
