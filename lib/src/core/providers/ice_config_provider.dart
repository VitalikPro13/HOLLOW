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
/// TURN credentials arrive over the AUTHENTICATED relay WebSocket, refreshed
/// on every reconnect plus a 50-minute interval. NEVER re-add an HTTP fetch:
/// the old one died permanently on a single non-200 and silently degraded
/// calls to STUN-only until restart. Starts STUN-only until the first set lands.
///
/// Also the single chokepoint for "Always relay calls"
/// ([alwaysRelayCallsProvider]), so the policy cannot be forgotten at a call
/// site. Hollow Share is deliberately NOT covered ([shareIceConfigProvider]).
class IceConfigNotifier extends Notifier<Map<String, dynamic>> {
  // Latest TURN credentials, kept so the config can be recomposed when the
  // privacy toggle flips without waiting for the next 50-minute refresh.
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
  /// drop the STUN entries: under that policy no host or server-reflexive
  /// candidate is gathered, so the peer only ever sees the TURN address.
  ///
  /// It FAILS CLOSED: with no credentials the server list is empty and the
  /// connection simply doesn't form, never a quiet fall back to a direct path.
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

/// STUN-only ICE config used by Hollow Share data channels.
///
/// Per HOLLOW_PLAN.md §7A share traffic must NOT consume relay (TURN)
/// bandwidth; that capacity is reserved for messaging and voice. About 85% of
/// peers connect via STUN.
///
/// Builds its own server list on purpose: it must stay STUN-only even when
/// "Always relay calls" is ON. NEVER add TURN or an `iceTransportPolicy` here.
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
