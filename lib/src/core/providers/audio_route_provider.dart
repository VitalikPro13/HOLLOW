import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:hollow/src/core/services/audio_route.dart';

/// Live view of the phone's call-audio routing: which routes exist and which
/// one audio is actually on. Mobile only; on desktop it stays empty and every
/// mutator is a no-op (device selection there lives in Settings > Audio).
@immutable
class AudioRouteState {
  final List<AudioRoute> routes;

  /// The route audio is ACTUALLY on, straight from the platform — null until
  /// the first refresh lands or when the platform can't say.
  final AudioRouteKind? activeKind;

  const AudioRouteState({this.routes = const [], this.activeKind});

  /// True once there is a real choice to make (a headset is attached), which
  /// is when the call controls should offer a picker instead of a toggle.
  bool get hasExternalRoute => routes.any((r) => r.kind.isExternal);

  AudioRoute? get activeRoute {
    for (final r in routes) {
      if (r.kind == activeKind) return r;
    }
    return null;
  }

  AudioRouteState copyWith({
    List<AudioRoute>? routes,
    AudioRouteKind? activeKind,
  }) {
    return AudioRouteState(
      routes: routes ?? this.routes,
      activeKind: activeKind ?? this.activeKind,
    );
  }
}

final audioRouteProvider =
    NotifierProvider<AudioRouteNotifier, AudioRouteState>(
        AudioRouteNotifier.new);

class AudioRouteNotifier extends Notifier<AudioRouteState> {
  Function(dynamic)? _previousDeviceChangeHandler;
  bool _listenerAttached = false;
  bool _disposed = false;
  Timer? _settleTimer;
  int _refreshGeneration = 0;

  @override
  AudioRouteState build() {
    _attachDeviceChangeListener();
    ref.onDispose(() {
      _disposed = true;
      _settleTimer?.cancel();
      if (_listenerAttached) {
        webrtc.navigator.mediaDevices.ondevicechange =
            _previousDeviceChangeHandler;
        _listenerAttached = false;
      }
    });
    return const AudioRouteState();
  }

  /// The OS moves the route by itself — a headset plugged in mid-call, a
  /// bluetooth device connecting, audioswitch auto-switching. Both platforms
  /// post `onDeviceChange` for those, so the picker (and the speaker button's
  /// icon) stay truthful without polling.
  void _attachDeviceChangeListener() {
    if (!AudioRoutes.isSupported || _listenerAttached) return;
    final devices = webrtc.navigator.mediaDevices;
    _previousDeviceChangeHandler = devices.ondevicechange;
    devices.ondevicechange = (event) {
      // Don't swallow a handler someone else installed.
      _previousDeviceChangeHandler?.call(event);
      // A route change lands in stages (disconnect, then the new route) —
      // re-read once it settles rather than on the first notification.
      _scheduleRefresh(const Duration(milliseconds: 400));
    };
    _listenerAttached = true;
  }

  void _scheduleRefresh(Duration delay) {
    _settleTimer?.cancel();
    _settleTimer = Timer(delay, () {
      if (!_disposed) unawaited(refresh());
    });
  }

  /// Re-read the available routes and the live one.
  Future<void> refresh() async {
    if (!AudioRoutes.isSupported) return;
    final generation = ++_refreshGeneration;
    final routes = await AudioRoutes.list();
    final active = await AudioRoutes.current();
    // A newer refresh (or a reset) landed — its answer is the fresher one.
    if (_disposed || generation != _refreshGeneration) return;
    state = AudioRouteState(routes: routes, activeKind: active);
  }

  /// Switch the live call to [route]. Optimistically marks it active so the
  /// sheet responds immediately, then re-reads what the OS actually did.
  Future<void> select(AudioRoute route) async {
    if (!AudioRoutes.isSupported || _disposed) return;
    state = state.copyWith(activeKind: route.kind);
    await AudioRoutes.select(route);
    _scheduleRefresh(const Duration(milliseconds: 300));
  }

  /// Clear the cached view when a call ends — the next call re-reads it. The
  /// generation bump also cancels any refresh still in flight.
  void reset() {
    _settleTimer?.cancel();
    _refreshGeneration++;
    if (!_disposed) state = const AudioRouteState();
  }
}
