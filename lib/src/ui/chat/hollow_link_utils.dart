import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;

/// Base for web-form invite links. The server id rides the FRAGMENT, which
/// never leaves the browser, so the website and any link-preview bot see only
/// `/join` and no log of which servers exist accumulates anywhere.
const String hollowWebJoinBase = 'https://hollow.anonlisten.com/join';

/// Canonical shareable server invite. Hollow renders it as a Join card, a
/// browser bounces it to hollow://, and anyone without Hollow gets a download
/// page. [key] is the server's join key (`serverInviteKey(serverId:)`): a
/// request to join is sealed to it, so a link without one cannot join. [owner]
/// pins the owner of a server founded before 0.12 (a newer id proves its owner
/// by itself); pass `serverInviteOwner(serverId:)`.
String webServerInviteLink(String serverId,
        {required String relay, String? owner, String? key}) =>
    '$hollowWebJoinBase#server=$serverId${_keyParam(key)}${_ownerParam(owner)}${_relayParam(relay, '&')}';

/// The invite link to a server we hold, with its join key, pinning its owner
/// when its id cannot.
String serverInviteLinkFor(String serverId, {required String relay}) {
  String? owner;
  String? key;
  try {
    owner = crdt_api.serverInviteOwner(serverId: serverId);
    key = crdt_api.serverInviteKey(serverId: serverId);
  } catch (_) {
    // No Rust library (a widget test): the link goes out without them.
  }
  return webServerInviteLink(serverId, relay: relay, owner: owner, key: key);
}

String _ownerParam(String? owner) =>
    owner != null && _peerIdRegex.hasMatch(owner) ? '&owner=$owner' : '';

String _keyParam(String? key) =>
    key != null && _joinKeyRegex.hasMatch(key) ? '&key=$key' : '';

/// Canonical shareable conference invite, on the same fragment rule: the conf
/// id never reaches any server log. [key] is the room's link key: a knock is
/// sealed under it, so a link without one cannot join.
String webConferenceInviteLink(String confId,
        {required String relay, String? key}) =>
    '$hollowWebJoinBase#conf=$confId${_keyParam(key)}${_relayParam(relay, '&')}';

/// The query of a `hollow://conference/<id>` link: its key, then its relay.
String _conferenceQuery(String? key, String? relay) {
  final params = '${_keyParam(key)}${_relayParam(relay, '&')}';
  return params.isEmpty ? '' : '?${params.substring(1)}';
}

/// Rooms are ephemeral, so their invite skips the website bounce.
String roomInviteLink(String roomCode, {required String relay}) =>
    'hollow://join?room=$roomCode${_relayParam(relay, '&')}';

String _relayParam(String? relay, String sep) {
  final host = relay == null ? null : normalizeRelayHost(relay);
  if (host == null) return '';
  return '${sep}relay=${Uri.encodeQueryComponent(host)}';
}

final _hollowLinkRegex = RegExp(r'hollow://[^\s<>"' "'" r')\]}]+');
final _webJoinRegex =
    RegExp(r'https://hollow\.anonlisten\.com/join[^\s<>"' "'" r')\]}]*');
final _inviteIdRegex = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

/// A master peer id: base58, so no 0, O, I or l.
final _peerIdRegex = RegExp(r'^[1-9A-HJ-NP-Za-km-z]{20,128}$');

/// A server's join key or a meeting's link key: 32 bytes as unpadded URL-safe
/// base64.
final _joinKeyRegex = RegExp(r'^[A-Za-z0-9_-]{43}$');

/// A Hollow Shop support code. Longer floor than an invite id, because these
/// are typed out of a receipt email and a two-character code is a typo.
final _redeemCodeRegex = RegExp(r'^[A-Za-z0-9_-]{8,128}$');

final _hostLabelRegex = RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$');
final _ipv6InnerRegex = RegExp(r'^[0-9a-f:.]+$');

/// Reduces anything a self-hoster might paste or stamp into an invite to the
/// bare `host` or `host:port` the relay URLs are built from, or null when it is
/// not a host at all.
///
/// Everything downstream (the setting, the link param, the dialog text) holds
/// this one shape, so a link and a setting typed differently still compare
/// equal.
String? normalizeRelayHost(String input) {
  var s = input.trim().toLowerCase();
  for (final scheme in const ['wss://', 'ws://', 'https://', 'http://']) {
    if (s.startsWith(scheme)) {
      s = s.substring(scheme.length);
      break;
    }
  }
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.endsWith('/ws')) s = s.substring(0, s.length - 3);
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.isEmpty) return null;

  String host;
  String port = '';
  if (s.startsWith('[')) {
    final close = s.indexOf(']');
    if (close < 0) return null;
    final inner = s.substring(1, close);
    if (!inner.contains(':') || !_ipv6InnerRegex.hasMatch(inner)) return null;
    host = s.substring(0, close + 1);
    port = s.substring(close + 1);
  } else {
    final colon = s.indexOf(':');
    if (colon >= 0) {
      // A second colon means a bare IPv6, which must be bracketed to be
      // distinguishable from a port.
      if (s.indexOf(':', colon + 1) >= 0) return null;
      host = s.substring(0, colon);
      port = s.substring(colon);
    } else {
      host = s;
    }
    if (host.length > 253) return null;
    for (final label in host.split('.')) {
      if (label.isEmpty ||
          label.length > 63 ||
          !_hostLabelRegex.hasMatch(label)) {
        return null;
      }
    }
  }

  if (port.isNotEmpty) {
    if (!port.startsWith(':')) return null;
    final digits = port.substring(1);
    if (digits.isEmpty || digits.length > 5) return null;
    final value = int.tryParse(digits);
    if (value == null || value < 1 || value > 65535) return null;
  }
  return '$host$port';
}

/// Cheap gate for per-row bubble builds, so the extractor's regexes never run
/// on the overwhelmingly common no-link message.
bool mightContainHollowLinks(String text) =>
    text.contains('hollow://') || text.contains('hollow.anonlisten.com/join');

enum HollowLinkType {
  share,
  serverInvite,
  roomInvite,
  recovery,
  conference,
  redeem,
}

class HollowLink {
  final HollowLinkType type;

  /// Canonical hollow:// form; web-form https links normalise to it, so every
  /// consumer can rely on the one shape.
  final String fullUrl;
  final String id;

  /// Relay the inviter was on. Null means an old link, never "the official
  /// relay": every invite Hollow builds stamps its sender's current relay.
  final String? relay;

  /// The owner a server invite pins, for a server founded before 0.12.
  final String? owner;

  /// The join key a server invite carries, or the key a meeting link does; null
  /// on a link made before 0.12, which cannot join.
  final String? key;

  const HollowLink({
    required this.type,
    required this.fullUrl,
    required this.id,
    this.relay,
    this.owner,
    this.key,
  });
}

/// Classifies a single URL: the `hollow://` share, join, conference, recovery
/// and redeem forms, plus the web `/join` link. The web form carries its id in
/// the FRAGMENT, with a `?query` tolerated. Null when unrecognised.
HollowLink? classifyHollowLink(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;

  String? relayOf(Map<String, String> params) {
    final raw = params['relay'];
    if (raw == null || raw.isEmpty) return null;
    return normalizeRelayHost(raw);
  }

  String? ownerOf(Map<String, String> params) {
    final raw = params['owner'];
    return raw != null && _peerIdRegex.hasMatch(raw) ? raw : null;
  }

  String? keyOf(Map<String, String> params) {
    final raw = params['key'];
    return raw != null && _joinKeyRegex.hasMatch(raw) ? raw : null;
  }

  if (uri.scheme == 'hollow') {
    final params = uri.queryParameters;
    final relay = relayOf(params);
    if (uri.host == 'share') {
      final payload = uri.path.length > 1 ? uri.path.substring(1) : '';
      if (payload.isNotEmpty) {
        return HollowLink(
            type: HollowLinkType.share, fullUrl: url, id: payload);
      }
    } else if (uri.host == 'join') {
      final serverId = params['server'];
      final roomCode = params['room'];
      if (serverId != null && serverId.isNotEmpty) {
        final owner = ownerOf(params);
        final key = keyOf(params);
        return HollowLink(
          type: HollowLinkType.serverInvite,
          fullUrl:
              'hollow://join?server=$serverId${_keyParam(key)}${_ownerParam(owner)}${_relayParam(relay, '&')}',
          id: serverId,
          relay: relay,
          owner: owner,
          key: key,
        );
      } else if (roomCode != null && roomCode.isNotEmpty) {
        return HollowLink(
          type: HollowLinkType.roomInvite,
          fullUrl: 'hollow://join?room=$roomCode${_relayParam(relay, '&')}',
          id: roomCode,
          relay: relay,
        );
      }
    } else if (uri.host == 'conference') {
      final confId = uri.path.length > 1 ? uri.path.substring(1) : '';
      if (confId.isNotEmpty && _inviteIdRegex.hasMatch(confId)) {
        final key = keyOf(params);
        return HollowLink(
          type: HollowLinkType.conference,
          fullUrl: 'hollow://conference/$confId${_conferenceQuery(key, relay)}',
          id: confId,
          relay: relay,
          key: key,
        );
      }
    } else if (uri.host == 'redeem') {
      // The shop builds these with encodeURIComponent, so the code arrives
      // percent-encoded and `pathSegments` decodes it.
      final segments = uri.pathSegments;
      final code = segments.isEmpty ? '' : segments.first;
      if (_redeemCodeRegex.hasMatch(code)) {
        return HollowLink(
          type: HollowLinkType.redeem,
          fullUrl: 'hollow://redeem/$code',
          id: code,
        );
      }
    } else if (uri.host == 'recovery') {
      final server = params['server'];
      final token = params['token'];
      if (server != null &&
          server.isNotEmpty &&
          token != null &&
          token.isNotEmpty) {
        return HollowLink(
            type: HollowLinkType.recovery, fullUrl: url, id: server);
      }
    }
    return null;
  }

  if (uri.scheme == 'https' &&
      uri.host == 'hollow.anonlisten.com' &&
      uri.path == '/join') {
    // The fragment is canonical, so it goes on top of the query.
    final params = <String, String>{...uri.queryParameters};
    if (uri.fragment.isNotEmpty) {
      try {
        params.addAll(Uri.splitQueryString(uri.fragment));
      } catch (_) {}
    }
    final relay = relayOf(params);
    final serverId = params['server'];
    final roomCode = params['room'];
    if (serverId != null && _inviteIdRegex.hasMatch(serverId)) {
      final owner = ownerOf(params);
      final key = keyOf(params);
      return HollowLink(
        type: HollowLinkType.serverInvite,
        fullUrl:
            'hollow://join?server=$serverId${_keyParam(key)}${_ownerParam(owner)}${_relayParam(relay, '&')}',
        id: serverId,
        relay: relay,
        owner: owner,
        key: key,
      );
    }
    if (roomCode != null && _inviteIdRegex.hasMatch(roomCode)) {
      return HollowLink(
        type: HollowLinkType.roomInvite,
        fullUrl: 'hollow://join?room=$roomCode${_relayParam(relay, '&')}',
        id: roomCode,
        relay: relay,
      );
    }
    final confId = params['conf'];
    if (confId != null && _inviteIdRegex.hasMatch(confId)) {
      final key = keyOf(params);
      return HollowLink(
        type: HollowLinkType.conference,
        fullUrl: 'hollow://conference/$confId${_conferenceQuery(key, relay)}',
        id: confId,
        relay: relay,
        key: key,
      );
    }
  }
  return null;
}

/// Resolves a pasted invite input, in any of its link forms or as a raw id, to
/// the id it carries.
///
/// Only a link of the wanted [type] is unwrapped, so a conference link pasted
/// into a server-join field is not silently read as a server id; anything else
/// falls back to the trimmed input. EVERY join or browse input bar goes through
/// this rather than hand-parsing `Uri.queryParameters`, which never sees the
/// FRAGMENT the web form carries its id in.
String inviteIdFromInput(String input, HollowLinkType type) =>
    inviteFromInput(input, type).id;

/// [inviteIdFromInput] plus the relay, owner pin and join key the link named, for
/// the join paths that must offer a relay switch before they can reach the invite.
({String id, String? relay, String? owner, String? key}) inviteFromInput(
    String input, HollowLinkType type) {
  final trimmed = input.trim();
  final link = classifyHollowLink(trimmed);
  if (link != null && link.type == type) {
    return (id: link.id, relay: link.relay, owner: link.owner, key: link.key);
  }
  return (id: trimmed, relay: null, owner: null, key: null);
}

/// Whether [id] has the shape of a server id: 40 hex characters for a server
/// founded on 0.12 or later (derived from its owner), 32 for an older one. A
/// pasted typo fails here instead of parking a join no member can ever answer.
bool isServerIdShape(String id) => _serverIdShape.hasMatch(id);

final _serverIdShape = RegExp(r'^([0-9a-fA-F]{32}|[0-9a-fA-F]{40})$');

List<HollowLink> extractHollowLinks(String text) {
  final results = <HollowLink>[];
  final seen = <String>{};

  void collect(Iterable<RegExpMatch> matches) {
    for (final match in matches) {
      final url = match.group(0)!;
      final link = classifyHollowLink(url);
      if (link == null) continue;
      // Dedup by canonical form, so one invite in two link forms is one card.
      if (!seen.add(link.fullUrl)) continue;
      results.add(link);
    }
  }

  collect(_hollowLinkRegex.allMatches(text));
  collect(_webJoinRegex.allMatches(text));

  return results;
}
