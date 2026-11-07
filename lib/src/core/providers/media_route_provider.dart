import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ice_route_probe.dart';

export '../services/ice_route_probe.dart' show MediaRoute;

/// How a watched share reaches us: a forwarder leg is named by who forwards
/// it, a direct leg by its ICE pair. Null when our own app forwards it: the
/// pair is a hop inside this device, and the hop that brings the share in is
/// not one we can read.
MediaRoute? shareRouteOf(
  IceRoute pair, {
  required bool viaForwarder,
  required bool byRelayForwarder,
  required bool byOwnApp,
}) {
  if (!viaForwarder) return pair.mediaRoute;
  if (byOwnApp) return null;
  return byRelayForwarder ? MediaRoute.relayForwarder : MediaRoute.memberForwarder;
}

/// Route of the DM call's media link. Kept off CallState for the reason link
/// health is: a `copyWith` there rebuilds every call surface.
final callMediaRouteProvider =
    NotifierProvider<MediaRouteNotifier, MediaRoute?>(MediaRouteNotifier.new);

/// Route of the DM peer's share we are watching.
final callShareRouteProvider =
    NotifierProvider<MediaRouteNotifier, MediaRoute?>(MediaRouteNotifier.new);

class MediaRouteNotifier extends Notifier<MediaRoute?> {
  @override
  MediaRoute? build() => null;

  void set(MediaRoute? route) {
    if (state != route) state = route;
  }

  void clear() => set(null);
}

/// Route of each voice-room leg, keyed by the DEVICE id the mesh connects to.
final vcMediaRouteProvider =
    NotifierProvider<MediaRouteMapNotifier, Map<String, MediaRoute>>(
        MediaRouteMapNotifier.new);

/// Route of each share we watch in a voice room, keyed by the ORIGINATOR (the
/// key the share's tile and cryptor use), never the deliverer.
final vcShareRouteProvider =
    NotifierProvider<MediaRouteMapNotifier, Map<String, MediaRoute>>(
        MediaRouteMapNotifier.new);

class MediaRouteMapNotifier extends Notifier<Map<String, MediaRoute>> {
  @override
  Map<String, MediaRoute> build() => const {};

  /// Null forgets [key].
  void setFor(String key, MediaRoute? route) {
    if (state[key] == route) return;
    if (route == null) {
      state = {...state}..remove(key);
    } else {
      state = {...state, key: route};
    }
  }

  void clear() {
    if (state.isNotEmpty) state = const {};
  }
}
