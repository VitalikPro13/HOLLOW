import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/network.dart' as network_api;
import 'relay_domain_provider.dart';
import 'settings_provider.dart';

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
///
/// This is also the single chokepoint for the "Always relay calls" privacy
/// setting ([alwaysRelayCallsProvider]) — every consumer reads its config from
/// here, so the policy cannot be forgotten at a call site. Hollow Share is
/// deliberately NOT covered: it builds its own map in [shareIceConfigProvider].
class IceConfigNotifier extends Notifier<Map<String, dynamic>> {
  // Latest TURN credentials from the relay, kept so the config can be
  // recomposed when the privacy toggle flips without waiting for the next
  // 50-minute credential refresh.
  String? _turnUsername;
  String? _turnPassword;
  List<String> _turnUris = const [];

  @override
  Map<String, dynamic> build() {
    // ref.listen, NEVER ref.watch: watching re-runs build(), which would reset
    // the cached credentials above and silently drop every later connection to
    // STUN-only until the relay refreshed them.
    ref.listen<bool>(alwaysRelayCallsProvider, (_, next) {
      _iceLog('[HOLLOW-ICE] Always-relay toggled → $next; recomposing config');
      state = _compose();
    });
    return _compose();
  }

  String get _domain => ref.read(relayDomainProvider);

  List<Map<String, dynamic>> _stunServers() => [
        {'urls': 'stun:$_domain:3478'},
        {'urls': 'stun:stun.cloudflare.com:3478'},
        {'urls': 'stun:stun.l.google.com:19302'},
      ];

  /// IMPORTANT: each TURN URI must stay a SEPARATE iceServer entry — the
  /// native layer holds one `uri` per struct.
  List<Map<String, dynamic>> _turnServers() => _turnUris
      .map((uri) => <String, dynamic>{
            'urls': uri,
            'username': _turnUsername,
            'credential': _turnPassword,
          })
      .toList();

  /// Build the config for the current credentials + privacy setting.
  ///
  /// With "Always relay calls" ON we ask for `iceTransportPolicy: 'relay'` and
  /// drop the STUN entries — under that policy no host/server-reflexive
  /// candidate is gathered, so STUN can't contribute anything and only slows
  /// gathering down. The peer therefore only ever sees the TURN server's
  /// address.
  ///
  /// It FAILS CLOSED: if credentials haven't arrived yet the server list is
  /// empty and the connection simply doesn't form — it never quietly falls
  /// back to a direct path that would leak the address. In practice this is
  /// unreachable, because TURN credentials ride the same authenticated relay
  /// WebSocket that carries the signalling needed to place a call at all.
  Map<String, dynamic> _compose() {
    final turnServers = _turnServers();
    if (ref.read(alwaysRelayCallsProvider)) {
      if (turnServers.isEmpty) {
        _iceLog('[HOLLOW-ICE] Always-relay ON but no TURN credentials yet — '
            'connections will not form until they arrive (failing closed)');
      }
      return {
        'iceServers': turnServers,
        'iceTransportPolicy': 'relay',
      };
    }
    return {
      'iceServers': [..._stunServers(), ...turnServers],
    };
  }

  /// Called by the event dispatcher when relay TURN credentials arrive.
  void setTurnCredentials({
    required String username,
    required String password,
    required List<String> uris,
  }) {
    if (uris.isEmpty) return;
    _turnUsername = username;
    _turnPassword = password;
    _turnUris = uris;
    state = _compose();
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
/// with `share:`.
///
/// This provider builds its own server list on purpose: it must stay STUN-only
/// even when "Always relay calls" is ON. NEVER add TURN entries or an
/// `iceTransportPolicy` here — a multi-GB Share riding the relay is exactly
/// what §7A forbids, and the setting's copy discloses the carve-out.
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
