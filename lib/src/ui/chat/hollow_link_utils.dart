/// Base for web-form invite links. The server id rides the FRAGMENT, which
/// never leaves the browser, so the website and any link-preview bot see only
/// `/join` and no log of which servers exist accumulates anywhere.
const String hollowWebJoinBase = 'https://hollow.anonlisten.com/join';

/// Canonical shareable server invite. Hollow renders it as a Join card, a
/// browser bounces it to hollow://, and anyone without Hollow gets a download
/// page.
String webServerInviteLink(String serverId) =>
    '$hollowWebJoinBase#server=$serverId';

/// Canonical shareable conference invite, on the same fragment rule: the conf
/// id never reaches any server log.
String webConferenceInviteLink(String confId) =>
    '$hollowWebJoinBase#conf=$confId';

final _hollowLinkRegex = RegExp(r'hollow://[^\s<>"' "'" r')\]}]+');
final _webJoinRegex =
    RegExp(r'https://hollow\.anonlisten\.com/join[^\s<>"' "'" r')\]}]*');
final _inviteIdRegex = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

/// A Hollow Shop support code. Longer floor than an invite id, because these
/// are typed out of a receipt email and a two-character code is a typo.
final _redeemCodeRegex = RegExp(r'^[A-Za-z0-9_-]{8,128}$');

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

  const HollowLink({
    required this.type,
    required this.fullUrl,
    required this.id,
  });
}

/// Classifies a single URL: the `hollow://` share, join, conference, recovery
/// and redeem forms, plus the web `/join` link. The web form carries its id in
/// the FRAGMENT, with a `?query` tolerated. Null when unrecognised.
HollowLink? classifyHollowLink(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;

  if (uri.scheme == 'hollow') {
    if (uri.host == 'share') {
      final payload = uri.path.length > 1 ? uri.path.substring(1) : '';
      if (payload.isNotEmpty) {
        return HollowLink(
            type: HollowLinkType.share, fullUrl: url, id: payload);
      }
    } else if (uri.host == 'join') {
      final serverId = uri.queryParameters['server'];
      final roomCode = uri.queryParameters['room'];
      if (serverId != null && serverId.isNotEmpty) {
        return HollowLink(
            type: HollowLinkType.serverInvite, fullUrl: url, id: serverId);
      } else if (roomCode != null && roomCode.isNotEmpty) {
        return HollowLink(
            type: HollowLinkType.roomInvite, fullUrl: url, id: roomCode);
      }
    } else if (uri.host == 'conference') {
      final confId = uri.path.length > 1 ? uri.path.substring(1) : '';
      if (confId.isNotEmpty && _inviteIdRegex.hasMatch(confId)) {
        return HollowLink(
            type: HollowLinkType.conference, fullUrl: url, id: confId);
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
      final server = uri.queryParameters['server'];
      final token = uri.queryParameters['token'];
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
    final serverId = params['server'];
    final roomCode = params['room'];
    if (serverId != null && _inviteIdRegex.hasMatch(serverId)) {
      return HollowLink(
        type: HollowLinkType.serverInvite,
        fullUrl: 'hollow://join?server=$serverId',
        id: serverId,
      );
    }
    if (roomCode != null && _inviteIdRegex.hasMatch(roomCode)) {
      return HollowLink(
        type: HollowLinkType.roomInvite,
        fullUrl: 'hollow://join?room=$roomCode',
        id: roomCode,
      );
    }
    final confId = params['conf'];
    if (confId != null && _inviteIdRegex.hasMatch(confId)) {
      return HollowLink(
        type: HollowLinkType.conference,
        fullUrl: 'hollow://conference/$confId',
        id: confId,
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
String inviteIdFromInput(String input, HollowLinkType type) {
  final trimmed = input.trim();
  final link = classifyHollowLink(trimmed);
  if (link != null && link.type == type) return link.id;
  return trimmed;
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
