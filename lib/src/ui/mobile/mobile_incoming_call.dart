import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/mobile/mobile_call_video_view.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Full-screen incoming call overlay for mobile.
/// Shows avatar, name, call type, accept/decline, 30s countdown ring.
class MobileIncomingCallOverlay extends ConsumerStatefulWidget {
  const MobileIncomingCallOverlay({super.key});

  @override
  ConsumerState<MobileIncomingCallOverlay> createState() =>
      _MobileIncomingCallOverlayState();
}

class _MobileIncomingCallOverlayState
    extends ConsumerState<MobileIncomingCallOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnim;

  bool _wasVisible = false;
  AudioPlayer? _ringtonePlayer;
  Timer? _countdownTimer;
  int _secondsLeft = 30;

  String _cachedPeerId = '';
  String _cachedDisplayName = '';
  bool _cachedIsVideoCall = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _fadeAnim = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
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
    if (ringtonePath == null || ringtonePath.isEmpty) return;
    if (!File(ringtonePath).existsSync()) return;

    final volume = await ref.read(ringtoneVolumeProvider.future);
    final startSec = await ref.read(ringtoneStartProvider.future);
    final endSec = await ref.read(ringtoneEndProvider.future);
    final clipDuration = endSec - startSec;
    if (clipDuration <= 0) return;

    _ringtonePlayer = AudioPlayer();
    await _ringtonePlayer!.setVolume(volume);
    await _ringtonePlayer!.play(DeviceFileSource(ringtonePath));
    await _ringtonePlayer!
        .seek(Duration(milliseconds: (startSec * 1000).round()));

    _ringtonePlayer!.onPositionChanged.listen((pos) {
      final posSeconds = pos.inMilliseconds / 1000.0;
      if (posSeconds >= endSec || posSeconds < startSec - 0.5) {
        _ringtonePlayer
            ?.seek(Duration(milliseconds: (startSec * 1000).round()));
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

    if (isVisible) {
      _cachedPeerId = call.peerId ?? '';
      final callerProfile =
          ref.watch(profileProvider.select((p) => p[_cachedPeerId]));
      _cachedDisplayName =
          displayNameForPeer(callerProfile, _cachedPeerId);
      _cachedIsVideoCall = call.isVideoCall;
    }

    if (isVisible && !_wasVisible) {
      _controller.forward(from: 0);
      _startRingtone();
      _startCountdown();
    } else if (!isVisible && _wasVisible) {
      _controller.reverse();
      _stopRingtone();
      _stopCountdown();
    }
    _wasVisible = isVisible;

    if (!isVisible && !_controller.isAnimating) {
      return const SizedBox.shrink();
    }

    final hollow = HollowTheme.of(context);

    return Positioned.fill(
      child: FadeTransition(
        opacity: _fadeAnim,
        child: Container(
          color: hollow.background.withValues(alpha: 0.95),
          child: SafeArea(
            child: Column(
              children: [
                const Spacer(flex: 2),
                // Avatar
                HollowAvatar(peerId: _cachedPeerId, size: 96),
                const SizedBox(height: HollowSpacing.lg),
                // Name
                Text(
                  _cachedDisplayName,
                  style: HollowTypography.heading.copyWith(
                    color: hollow.textPrimary,
                    fontSize: 22,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: HollowSpacing.sm),
                // Call type
                Text(
                  _cachedIsVideoCall
                      ? 'Incoming video call...'
                      : 'Incoming voice call...',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textSecondary,
                  ),
                ),
                const SizedBox(height: HollowSpacing.lg),
                // Countdown
                SizedBox(
                  width: 52,
                  height: 52,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 52,
                        height: 52,
                        child: CircularProgressIndicator(
                          value: _secondsLeft / 30.0,
                          strokeWidth: 3,
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
                        style: HollowTypography.body.copyWith(
                          color: _secondsLeft <= 5
                              ? hollow.error
                              : hollow.textSecondary,
                          fontWeight: FontWeight.w600,
                          fontFeatures: [const FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(flex: 3),
                // Accept / Decline buttons
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.xl * 2),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Decline
                      _CallActionButton(
                        icon: LucideIcons.phoneOff,
                        color: hollow.error,
                        label: 'Decline',
                        onTap: () =>
                            ref.read(callProvider.notifier).rejectCall(),
                      ),
                      // Accept
                      _CallActionButton(
                        icon: _cachedIsVideoCall
                            ? LucideIcons.video
                            : LucideIcons.phone,
                        color: hollow.success,
                        label: 'Accept',
                        onTap: () {
                          ref.read(callProvider.notifier).acceptCall();
                          final peerId = _cachedPeerId;
                          if (peerId.isNotEmpty) {
                            Navigator.of(context, rootNavigator: true).push(
                              PageRouteBuilder(
                                settings: const RouteSettings(name: 'call-screen'),
                                pageBuilder: (_, __, ___) =>
                                    MobileCallScreen(peerId: peerId),
                                transitionsBuilder: (_, anim, __, child) {
                                  return SlideTransition(
                                    position: Tween<Offset>(
                                      begin: const Offset(0, 1),
                                      end: Offset.zero,
                                    ).animate(CurvedAnimation(
                                      parent: anim,
                                      curve: Curves.easeOut,
                                    )),
                                    child: child,
                                  );
                                },
                              ),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: HollowSpacing.xl * 2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CallActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _CallActionButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.3),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(icon, size: 28, color: Colors.white),
          ),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            label,
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
