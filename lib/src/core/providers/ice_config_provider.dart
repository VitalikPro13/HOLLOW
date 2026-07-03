import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/network.dart' as network_api;
import 'relay_domain_provider.dart';

/// Log to hollow_debug.log (visible in release builds + debug file).
void _iceLog(String msg) {
  network_api.logFromDart(message: msg);
}

/// ICE server configuration with STUN and TURN servers.
///
/// TURN credentials arrive over the AUTHENTICATED relay WebSocket
/// (`NetworkEvent.turnCredentials`, routed here by the event dispatcher) —
/// Rust requests a fresh set on every relay (re)connect plus a 50-minute
/// refresh interval. This replaced the old HTTP fetch, whose retry chain
/// died permanently on a single non-200 (e.g. a 503 during a relay
/// restart), silently degrading calls to STUN-only until app restart.
/// Starts STUN-only until the first credential set lands.
class IceConfigNotifier extends Notifier<Map<String, dynamic>> {
  @override
  Map<String, dynamic> build() => _stunOnlyConfig();

  String get _domain => ref.read(relayDomainProvider);

  List<Map<String, dynamic>> _stunServers() => [
        {'urls': 'stun:$_domain:3478'},
        {'urls': 'stun:stun.cloudflare.com:3478'},
        {'urls': 'stun:stun.l.google.com:19302'},
      ];

  Map<String, dynamic> _stunOnlyConfig() => {'iceServers': _stunServers()};

  /// Called by the event dispatcher when relay TURN credentials arrive.
  void setTurnCredentials({
    required String username,
    required String password,
    required List<String> uris,
  }) {
    if (uris.isEmpty) return;
    // IMPORTANT: Each TURN URI must be a SEPARATE iceServer entry.
    final turnServers = uris
        .map((uri) => <String, dynamic>{
              'urls': uri,
              'username': username,
              'credential': password,
            })
        .toList();
    state = {
      'iceServers': [..._stunServers(), ...turnServers],
    };
    _iceLog(
        '[HOLLOW-ICE] TURN credentials OK (WS): ${uris.length} URIs, username=${username.split(':').first}...');
  }
}

final iceConfigProvider =
    NotifierProvider<IceConfigNotifier, Map<String, dynamic>>(
        IceConfigNotifier.new);

/// STUN-only ICE config used by Hollow Share data channels (Phase 7A).
///
/// Per HOLLOW_PLAN.md §7A: share traffic must NOT consume relay (TURN)
/// bandwidth — that capacity is reserved for messaging and voice. About
/// 85% of peers connect via STUN; the rest can't participate in a given
/// share but can still join other shares.
///
/// Pass this map to `RTCPeerConnection` factory calls whose room ID begins
/// with `share:`. Mirrors `IceConfigNotifier._stunOnlyConfig`.
final shareIceConfigProvider = Provider<Map<String, dynamic>>((ref) {
  final domain = ref.watch(relayDomainProvider);
  return {
    'iceServers': [
      {'urls': 'stun:$domain:3478'},
      {'urls': 'stun:stun.cloudflare.com:3478'},
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };
});

/// ICE config for hidden Share connections (video streaming, large files).
/// STUN-only — large file transfers through TURN would saturate relay bandwidth.
final streamIceConfigProvider = Provider<Map<String, dynamic>>((ref) {
  return ref.watch(shareIceConfigProvider);
});
