import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Incoming call card, rendered only while a call is ringing inbound.
class IncomingCallOverlay extends ConsumerStatefulWidget {
  const IncomingCallOverlay({super.key});

  @override
  ConsumerState<IncomingCallOverlay> createState() =>
      _IncomingCallOverlayState();
}

class _IncomingCallOverlayState extends ConsumerState<IncomingCallOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnim;
  late Animation<double> _fadeAnim;

  bool _wasVisible = false;
  AudioPlayer? _ringtonePlayer;
  Timer? _countdownTimer;
  int _secondsLeft = 30;

  // Cached so the card does not go blank during its exit animation.
  String _cachedPeerId = '';
  String _cachedDisplayName = '';
  bool _cachedIsVideoCall = false;
  String? _cachedVcChannelName;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.normal,
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.enter,
    ));
    _fadeAnim = Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.enter,
    ));
  }

  @override
  void dispose() {
    _stopRingtone();
    _stopCountdown();
    _controller.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _secondsLeft = 30;
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _secondsLeft = (_secondsLeft - 1).clamp(0, 30);
      });
    });
  }

  void _stopCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  Future<void> _startRingtone() async {
    final ringtonePath = await ref.read(ringtonePathProvider.future);
    final volume = await ref.read(ringtoneVolumeProvider.future);
    final startSec = await ref.read(ringtoneStartProvider.future);
    final endSec = await ref.read(ringtoneEndProvider.future);
    // The call may have been answered or declined while the providers loaded.
    if (!mounted || !_wasVisible) return;

    final hasCustom = ringtonePath != null &&
        ringtonePath.isNotEmpty &&
        File(ringtonePath).existsSync();
    final clipDuration = endSec - startSec;

    if (!hasCustom || clipDuration <= 0) {
      // The bundled default loops the whole file: no trim range applies.
      _ringtonePlayer = AudioPlayer();
      await _ringtonePlayer!.setVolume(volume);
      await _ringtonePlayer!.setReleaseMode(ReleaseMode.loop);
      await _ringtonePlayer!.play(AssetSource('sounds/default_ringtone.wav'));
      return;
    }

    _ringtonePlayer = AudioPlayer();
    await _ringtonePlayer!.setVolume(volume);
    // Looping is manual, within the clip range.
    await _ringtonePlayer!.play(DeviceFileSource(ringtonePath));
    await _ringtonePlayer!.seek(Duration(milliseconds: (startSec * 1000).round()));

    _ringtonePlayer!.onPositionChanged.listen((pos) {
      final posSeconds = pos.inMilliseconds / 1000.0;
      if (posSeconds >= endSec || posSeconds < startSec - 0.5) {
        _ringtonePlayer?.seek(
            Duration(milliseconds: (startSec * 1000).round()));
      }
    });
  }

  Future<void> _stopRingtone() async {
    await _ringtonePlayer?.stop();
    await _ringtonePlayer?.dispose();
    _ringtonePlayer = null;
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callProvider);
    final isVisible = call.status == CallStatus.ringing &&
        call.direction == CallDirection.incoming;

    // Cached while visible, so the card survives its exit animation.
    if (isVisible) {
      _cachedPeerId = call.peerId ?? '';
      final callerProfile = ref.watch(profileProvider.select((p) => p[_cachedPeerId]));
      _cachedDisplayName = displayNameForPeer(callerProfile, _cachedPeerId);
      _cachedIsVideoCall = call.isVideoCall;
      // Answering auto-leaves a voice channel, so it is worth a warning
      // (issue #49).
      final vc = ref.watch(voiceChannelProvider);
      _cachedVcChannelName =
          vc.isInVoiceChannel ? (vc.currentChannelName ?? 'voice') : null;
    }

    if (isVisible && !_wasVisible) {
      _controller.duration = HollowDurations.normal;
      _controller.forward(from: 0);
      _startRingtone();
      _startCountdown();
    } else if (!isVisible && _wasVisible) {
      _controller.duration = HollowDurations.normal;
      _controller.reverse();
      _stopRingtone();
      _stopCountdown();
    }
    _wasVisible = isVisible;

    if (!isVisible && !_controller.isAnimating) {
      return const SizedBox.shrink();
    }

    final hollow = HollowTheme.of(context);

    final safePadding = MediaQuery.of(context).padding.top;
    return Positioned(
      top: safePadding + HollowSpacing.xl,
      left: 0,
      right: 0,
      child: SlideTransition(
        position: _slideAnim,
        child: FadeTransition(
          opacity: _fadeAnim,
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
              width: 320,
              padding: const EdgeInsets.all(HollowSpacing.lg),
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  HollowAvatar(
                    peerId: _cachedPeerId,
                    size: 56,
                  ),
                  const SizedBox(height: HollowSpacing.sm),
                  Text(
                    _cachedDisplayName,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: HollowSpacing.xs),
                  Text(
                    _cachedIsVideoCall
                        ? 'Incoming video call...'
                        : 'Incoming voice call...',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                    ),
                  ),
                  if (_cachedVcChannelName != null) ...[
                    const SizedBox(height: HollowSpacing.xs),
                    Text(
                      'Answering will leave #$_cachedVcChannelName',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.warning,
                      ),
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: HollowSpacing.lg),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      HollowButton.danger(
                        onPressed: () {
                          ref.read(callProvider.notifier).rejectCall();
                        },
                        icon: const Icon(LucideIcons.phoneOff, size: 16),
                        child: const Text('Decline'),
                      ),
                      const SizedBox(width: HollowSpacing.md),
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: 36,
                              height: 36,
                              child: CircularProgressIndicator(
                                value: _secondsLeft / 30.0,
                                strokeWidth: 2.5,
                                backgroundColor:
                                    hollow.border.withValues(alpha: 0.3),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  _secondsLeft <= 5
                                      ? hollow.error
                                      : hollow.textSecondary,
                                ),
                              ),
                            ),
                            Text(
                              '$_secondsLeft',
                              style: HollowTypography.caption.copyWith(
                                color: _secondsLeft <= 5
                                    ? hollow.error
                                    : hollow.textSecondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                fontFeatures: [
                                  const FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.md),
                      HollowButton.filled(
                        onPressed: () {
                          ref.read(callProvider.notifier).acceptCall();
                        },
                        icon: Icon(
                          _cachedIsVideoCall ? LucideIcons.video : LucideIcons.phone,
                          size: 16,
                        ),
                        child: const Text('Accept'),
                      ),
                    ],
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
