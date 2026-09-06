import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_sensor/proximity_sensor.dart';

import '../../core/providers/audio_route_provider.dart';
import '../../core/providers/call_provider.dart';
import '../../core/providers/voice_channel_provider.dart';
import '../../core/services/audio_route.dart';

/// App-level proximity controller (mobile only), rendering nothing.
///
/// Blanks the screen when the phone is held to the ear while audio is on the
/// earpiece, for ANY active call. It is mounted globally rather than inside the
/// call screens so it follows the call and not the visible screen.
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
      // Android needs an explicit wake-lock-backed screen-off; iOS blanks
      // natively while the events stream is subscribed.
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
    final activeKind = ref.watch(audioRouteProvider).activeKind;

    // The ROUTE decides, never the speaker flag: with headphones in a voice
    // call the flag stays false while audio is nowhere near the ear, and
    // blanking at every passing object is wrong. The flag is only the fallback
    // for a platform that cannot name the route.
    final onEarpiece = activeKind == null
        ? null
        : activeKind == AudioRouteKind.earpiece;

    final callEarpiece = call.status == CallStatus.active &&
        (onEarpiece ?? !call.isSpeakerOn) &&
        !call.isVideoEnabled &&
        !call.remoteVideoEnabled;

    final vcEarpiece = vc.isInVoiceChannel &&
        (onEarpiece ?? !vc.isSpeakerOn) &&
        !_vcHasVideo(vc);

    _setEarpieceMode(callEarpiece || vcEarpiece);

    return const SizedBox.shrink();
  }

  /// Any local or remote camera, or a focused screen share, counts as video and
  /// so rules out earpiece mode.
  bool _vcHasVideo(VoiceChannelState vc) {
    if (vc.focusedScreenSharePeerId != null) return true;
    if (vc.isCameraOn) return true;
    for (final on in vc.peerCameraOn.values) {
      if (on) return true;
    }
    return false;
  }
}
