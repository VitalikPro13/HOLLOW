import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/link_health_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/core/services/link_resilience.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/link_health_chip.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Floating pill shown during an active 1:1 call on mobile.
class MobileActiveCallPill extends ConsumerStatefulWidget {
  const MobileActiveCallPill({super.key});

  @override
  ConsumerState<MobileActiveCallPill> createState() =>
      _MobileActiveCallPillState();
}

class _MobileActiveCallPillState extends ConsumerState<MobileActiveCallPill> {
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
    final linkHealth = ref.watch(callLinkHealthProvider);

    final isVisible = call.status == CallStatus.active ||
        call.status == CallStatus.connecting;

    if (!isVisible) {
      if (_durationTimer != null) _stopTimer();
      return const SizedBox.shrink();
    }

    if (call.status == CallStatus.active && call.startedAt != null) {
      if (_durationTimer == null) {
        _duration = DateTime.now().difference(call.startedAt!);
        _startTimer(call.startedAt!);
      }
    }

    final hollow = HollowTheme.of(context);
    final peerId = call.peerId ?? '';
    final displayName = displayNameForPeer(
        ref.watch(profileProvider.select((p) => p[peerId])), peerId);

    return Positioned(
      bottom: 80,
      left: 0,
      right: 0,
      child: Transform.translate(
        offset: _dragOffset,
        child: Center(
          child: GestureDetector(
            onPanUpdate: (details) {
              // Clamped so the pill cannot be dragged into the bottom nav or
              // off-screen.
              final size = MediaQuery.sizeOf(context);
              final topInset = MediaQuery.viewPaddingOf(context).top;
              final next = _dragOffset + details.delta;
              setState(() => _dragOffset = Offset(
                    next.dx.clamp(
                        -(size.width / 2 - 80), size.width / 2 - 80),
                    next.dy.clamp(-(size.height - 80 - 48 - topInset - 8), 0.0),
                  ));
            },
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
                  color: (linkHealth.health == LinkHealth.healthy
                          ? hollow.success
                          : hollow.warning)
                      .withValues(alpha: 0.3),
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
                  StatusDot(
                    color: linkHealth.health == LinkHealth.healthy
                        ? hollow.success
                        : hollow.warning,
                    filled: linkHealth.health == LinkHealth.healthy,
                    size: 8,
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  // Icon only, the pill being tight; the label still reaches
                  // the tooltip and assistive tech.
                  if (linkHealth.hasFlair) ...[
                    LinkHealthChip(snapshot: linkHealth, compact: true),
                    const SizedBox(width: HollowSpacing.sm),
                  ],
                  if (call.status == CallStatus.connecting)
                    Text(
                      'Connecting...',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 12,
                      ),
                    )
                  else ...[
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 100),
                      child: Text(
                        displayName,
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
                  ],
                  const SizedBox(width: HollowSpacing.md),
                  HollowPressable(
                    semanticLabel: call.isMuted ? 'Unmute' : 'Mute',
                    onTap: () =>
                        ref.read(callProvider.notifier).toggleMute(),
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    child: Icon(
                      call.isMuted ? LucideIcons.micOff : LucideIcons.mic,
                      size: 20,
                      color:
                          call.isMuted ? hollow.error : hollow.textSecondary,
                    ),
                  ),
                  const SizedBox(width: HollowSpacing.xs),
                  HollowPressable(
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
                      size: 20,
                      color: call.isVideoEnabled
                          ? hollow.accent
                          : hollow.textSecondary,
                    ),
                  ),
                  const SizedBox(width: HollowSpacing.xs),
                  HollowPressable(
                    semanticLabel: 'End call',
                    onTap: () =>
                        ref.read(callProvider.notifier).endCall(),
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
