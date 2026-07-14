/// Base for web-form invite links. The server id rides the FRAGMENT
/// (`#server=...`), which never leaves the browser — the website (and any
/// link-preview bot that fetches the URL) sees only `/join`, so no log of
/// which servers exist is ever accumulated anywhere.
const String hollowWebJoinBase = 'https://hollow.anonlisten.com/join';

/// Canonical shareable server invite. Works everywhere: new Hollow clients
/// render it as a Join card, browsers bounce it to hollow:// via the /join
/// redirect page, and people without Hollow land on a download page.
String webServerInviteLink(String serverId) =>
    '$hollowWebJoinBase#server=$serverId';

/// Canonical shareable conference invite. Same fragment rule as server
/// invites: the conf id never reaches any server log.
String webConferenceInviteLink(String confId) =>
    '$hollowWebJoinBase#conf=$confId';

final _hollowLinkRegex = RegExp(r'hollow://[^\s<>"' "'" r')\]}]+');
final _webJoinRegex =
    RegExp(r'https://hollow\.anonlisten\.com/join[^\s<>"' "'" r')\]}]*');
final _inviteIdRegex = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

/// Cheap gate for per-row bubble builds — avoids running the extractor (and
/// its regexes) on the overwhelmingly common no-link message.
bool mightContainHollowLinks(String text) =>
    text.contains('hollow://') || text.contains('hollow.anonlisten.com/join');

enum HollowLinkType { share, serverInvite, roomInvite, recovery, conference }

class HollowLink {
  final HollowLinkType type;

  /// Canonical hollow:// form — web-form https links are normalized to this,
  /// so consumers (room join, share dialog, recovery prefill) can rely on it.
  final String fullUrl;
  final String id;

  const HollowLink({
    required this.type,
    required this.fullUrl,
    required this.id,
  });
}

/// Classify a single URL: hollow://share|join|recovery links, plus the
/// web-form `https://hollow.anonlisten.com/join#server=...` invite (fragment
/// canonical, `?server=` query tolerated). Returns null if unrecognized.
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
    // Query first, then fragment on top — the fragment is canonical and wins.
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

/// Resolve a pasted invite input — canonical `hollow://` link, web-form
/// `https://hollow.anonlisten.com/join` link (`#fragment` canonical, `?query`
/// tolerated), or a raw id — to the id it carries. Only a link of the wanted
/// [type] is unwrapped (a conference link pasted into a server-join field is
/// not silently treated as a server id); anything unrecognized falls back to
/// the trimmed input so plain ids keep working. Every join/browse input bar
/// must go through this instead of hand-parsing `Uri.queryParameters` — the
/// web form carries its id in the FRAGMENT, which query parsing never sees.
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
      // Dedup by canonical form so the same invite in hollow:// and web form
      // renders one card.
      if (!seen.add(link.fullUrl)) continue;
      results.add(link);
    }
  }

  collect(_hollowLinkRegex.allMatches(text));
  collect(_webJoinRegex.allMatches(text));

  return results;
}
