import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/dm_navigation.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/core/providers/window_chrome_provider.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_shadows.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/call/call_stage_sources.dart' show dmCallPeerName;
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The incoming call (5.4): one card under the header, ghost Decline and one
/// filled Accept, the ring's time left as a thin line along its foot. Accept
/// opens the caller's conversation too, so the call lands where it lives.
class IncomingCallOverlay extends ConsumerStatefulWidget {
  const IncomingCallOverlay({super.key});

  @override
  ConsumerState<IncomingCallOverlay> createState() =>
      _IncomingCallOverlayState();
}

class _IncomingCallOverlayState extends ConsumerState<IncomingCallOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnim;

  bool _wasVisible = false;
  AudioPlayer? _ringtonePlayer;
  Timer? _countdownTimer;
  int _secondsLeft = 30;

  // Cached so the card does not go blank during its exit animation.
  String _cachedPeerId = '';
  String _cachedMaster = '';
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
    _fadeAnim = CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.enter,
      reverseCurve: HollowCurves.exit,
    );
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

  void _accept() {
    final calls = ref.read(callProvider.notifier);
    if (!Platform.isAndroid && !Platform.isIOS) {
      openDmConversation(
          ref, ref.read(deviceLinkProvider).identityOf(_cachedPeerId));
    }
    calls.acceptCall().catchError((Object _) {
      if (mounted) {
        HollowToast.show(context, "Couldn't answer the call",
            type: HollowToastType.error);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callProvider);
    final isVisible = call.status == CallStatus.ringing &&
        call.direction == CallDirection.incoming;

    // Cached while visible, so the card survives its exit animation.
    if (isVisible) {
      _cachedPeerId = call.peerId ?? '';
      // The invite carries the caller's DEVICE; names and colours are the
      // person's.
      final master = ref.watch(deviceLinkProvider).identityOf(_cachedPeerId);
      _cachedMaster = master;
      _cachedDisplayName = dmCallPeerName(ref, master);
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
      _controller.reverseDuration = HollowDurations.fast;
      _controller.reverse();
      _stopRingtone();
      _stopCountdown();
    }
    _wasVisible = isVisible;

    if (!isVisible && !_controller.isAnimating) {
      return const SizedBox.shrink();
    }

    final hollow = HollowTheme.of(context);
    final dockHeader = ref.watch(layoutModeProvider) == LayoutMode.dock &&
        !Platform.isAndroid &&
        !Platform.isIOS;
    final top = MediaQuery.of(context).padding.top +
        (dockHeader ? kDockHeaderHeight + 1 : 0) +
        HollowSpacing.md;
    final reduced = ReduceMotionController.instance.isReduced;
    final kind = _cachedIsVideoCall ? 'Video call' : 'Voice call';

    return Positioned(
      top: top,
      left: 0,
      right: 0,
      // Drops a short step from above, not its full height.
      child: AnimatedBuilder(
        animation: _fadeAnim,
        builder: (_, child) => Transform.translate(
          offset: Offset(0, -HollowMotion.rise * (1 - _fadeAnim.value)),
          child: child,
        ),
        child: FadeTransition(
          opacity: _fadeAnim,
          // On the phone this sits above the navigator, outside any Scaffold,
          // so it brings its own text defaults.
          child: Center(
            child: DefaultTextStyle(
            style: HollowTypography.body.copyWith(color: hollow.textPrimary),
            child: Semantics(
              container: true,
              liveRegion: true,
              label: '$kind from $_cachedDisplayName',
              child: Container(
                width: _kCardWidth,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: hollow.overlay,
                  borderRadius: BorderRadius.circular(hollow.radiusLg),
                  border: Border.all(color: hollow.border),
                  boxShadow: HollowShadows.float,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        HollowSpacing.lg,
                        HollowSpacing.lg,
                        HollowSpacing.lg,
                        HollowSpacing.md,
                      ),
                      child: Row(
                        children: [
                          HollowAvatar(peerId: _cachedMaster, size: 44),
                          const SizedBox(width: HollowSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _cachedDisplayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: HollowTypography.subheading.copyWith(
                                    color: nameColorFor(_cachedMaster, hollow),
                                  ),
                                ),
                                Text(
                                  kind,
                                  style: HollowTypography.bodySmall.copyWith(
                                      color: hollow.textSecondary),
                                ),
                                if (_cachedVcChannelName != null)
                                  Text(
                                    'Answering will leave #$_cachedVcChannelName',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: HollowTypography.bodySmall
                                        .copyWith(color: hollow.warning),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        HollowSpacing.lg,
                        0,
                        HollowSpacing.lg,
                        HollowSpacing.lg,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          HollowButton.ghost(
                            onPressed: () => ref
                                .read(callProvider.notifier)
                                .rejectCall()
                                .catchError((Object _) {}),
                            child: const Text('Decline'),
                          ),
                          const SizedBox(width: HollowSpacing.sm),
                          HollowButton.filled(
                            onPressed: _accept,
                            icon: Icon(
                              _cachedIsVideoCall
                                  ? LucideIcons.video
                                  : LucideIcons.phone,
                              size: 14,
                            ),
                            child: const Text('Accept'),
                          ),
                        ],
                      ),
                    ),
                    // The ring's time left, stepped once a second by the
                    // countdown's Timer; nothing ticks per frame.
                    Container(
                      height: HollowSpacing.xxs,
                      color: hollow.border,
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: reduced ? 1 : _secondsLeft / 30,
                        heightFactor: 1,
                        child: ColoredBox(color: hollow.textTertiary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            ),
          ),
        ),
      ),
    );
  }
}

const double _kCardWidth = 340;
