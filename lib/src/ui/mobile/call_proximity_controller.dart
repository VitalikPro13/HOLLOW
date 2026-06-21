import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_sensor/proximity_sensor.dart';

import '../../core/providers/call_provider.dart';
import '../../core/providers/voice_channel_provider.dart';

/// App-level proximity controller (mobile only).
///
/// Blanks the screen when the phone is held to the ear while audio is on the
/// earpiece — for ANY active call, regardless of which screen is visible.
/// Previously this lived inside the call screens, so it only worked while you
/// were looking at the call sheet; navigate away and it stopped. Mounting it
/// globally (in the app builder's mobile Stack) means it follows the call, not
/// the screen.
///
/// Renders nothing — it's a pure side-effect widget.
class CallProximityController extends ConsumerStatefulWidget {
  const CallProximityController({super.key});

  @override
  ConsumerState<CallProximityController> createState() =>
      _CallProximityControllerState();
}

class _CallProximityControllerState
    extends ConsumerState<CallProximityController> {
  StreamSubscription<int>? _proximitySub;

  static bool get _isMobilePlatform => Platform.isAndroid || Platform.isIOS;

  @override
  void dispose() {
    _disableProximity();
    super.dispose();
  }

  void _setEarpieceMode(bool earpieceMode) {
    if (!_isMobilePlatform) return;
    if (earpieceMode && _proximitySub == null) {
      // Android: explicit wake-lock-backed screen-off. iOS blanks natively
      // while the events stream is subscribed (proximityMonitoringEnabled).
      unawaited(
          ProximitySensor.setProximityScreenOff(true).catchError((_) => false));
      _proximitySub = ProximitySensor.events.listen((_) {}, onError: (_) {});
    } else if (!earpieceMode && _proximitySub != null) {
      _disableProximity();
    }
  }

  void _disableProximity() {
    if (_proximitySub == null) return;
    _proximitySub?.cancel();
    _proximitySub = null;
    unawaited(
        ProximitySensor.setProximityScreenOff(false).catchError((_) => false));
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callProvider);
    final vc = ref.watch(voiceChannelProvider);

    // Earpiece mode = audio actively playing through the earpiece: a live
    // call/VC, speaker off, no video on either side. Proximity should engage
    // if EITHER a DM call or a voice channel is in earpiece mode.
    final callEarpiece = call.status == CallStatus.active &&
        !call.isSpeakerOn &&
        !call.isVideoEnabled &&
        !call.remoteVideoEnabled;

    final vcEarpiece = vc.isInVoiceChannel &&
        !vc.isSpeakerOn &&
        !_vcHasVideo(vc);

    _setEarpieceMode(callEarpiece || vcEarpiece);

    return const SizedBox.shrink();
  }

  /// Mirrors `_hasVideo` in mobile_voice_channel_route.dart: any local/remote
  /// camera or a focused screen share counts as video (→ not earpiece mode).
  bool _vcHasVideo(VoiceChannelState vc) {
    if (vc.focusedScreenSharePeerId != null) return true;
    if (vc.isCameraOn) return true;
    for (final on in vc.peerCameraOn.values) {
      if (on) return true;
    }
    return false;
  }
}
