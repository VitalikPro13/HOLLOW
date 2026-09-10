/// Base for web-form invite links. The server id rides the FRAGMENT, which
/// never leaves the browser, so the website and any link-preview bot see only
/// `/join` and no log of which servers exist accumulates anywhere.
const String hollowWebJoinBase = 'https://hollow.anonlisten.com/join';

/// Canonical shareable server invite. Hollow renders it as a Join card, a
/// browser bounces it to hollow://, and anyone without Hollow gets a download
/// page.
String webServerInviteLink(String serverId, {required String relay}) =>
    '$hollowWebJoinBase#server=$serverId${_relayParam(relay, '&')}';

/// Canonical shareable conference invite, on the same fragment rule: the conf
/// id never reaches any server log.
String webConferenceInviteLink(String confId, {required String relay}) =>
    '$hollowWebJoinBase#conf=$confId${_relayParam(relay, '&')}';

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

  const HollowLink({
    required this.type,
    required this.fullUrl,
    required this.id,
    this.relay,
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
        return HollowLink(
          type: HollowLinkType.serverInvite,
          fullUrl: 'hollow://join?server=$serverId${_relayParam(relay, '&')}',
          id: serverId,
          relay: relay,
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
        return HollowLink(
          type: HollowLinkType.conference,
          fullUrl: 'hollow://conference/$confId${_relayParam(relay, '?')}',
          id: confId,
          relay: relay,
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
      return HollowLink(
        type: HollowLinkType.serverInvite,
        fullUrl: 'hollow://join?server=$serverId${_relayParam(relay, '&')}',
        id: serverId,
        relay: relay,
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
      return HollowLink(
        type: HollowLinkType.conference,
        fullUrl: 'hollow://conference/$confId${_relayParam(relay, '?')}',
        id: confId,
        relay: relay,
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

/// [inviteIdFromInput] plus the relay the link named, for the join paths that
/// must offer a relay switch before they can reach the invite at all.
({String id, String? relay}) inviteFromInput(String input, HollowLinkType type) {
  final trimmed = input.trim();
  final link = classifyHollowLink(trimmed);
  if (link != null && link.type == type) {
    return (id: link.id, relay: link.relay);
  }
  return (id: trimmed, relay: null);
}

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
