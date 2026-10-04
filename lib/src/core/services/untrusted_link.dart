import 'package:flutter/foundation.dart';
import 'package:hollow/src/core/services/deep_link_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// Where a link that did not come from Hollow's own code may go.
enum UntrustedLinkRoute { browser, app, refused }

/// The decision for one link: the route, and the parsed target to hand on.
class UntrustedLinkDecision {
  final UntrustedLinkRoute route;
  final Uri? uri;

  const UntrustedLinkDecision._(this.route, this.uri);

  static const refused =
      UntrustedLinkDecision._(UntrustedLinkRoute.refused, null);
}

/// Decides where a URL someone else chose may go: https (and http when
/// [allowHttp]) to the browser, `hollow://` into the app, nothing else.
///
/// Desktop launchers hand any scheme to the OS shell (on Windows ShellExecute:
/// `file:`, UNC paths, every registered protocol handler), so the allowlist is
/// the only thing between a peer's or a feed's string and a local program.
UntrustedLinkDecision classifyUntrustedUrl(String raw,
    {bool allowHttp = false}) {
  final s = raw.trim();
  if (s.isEmpty || s.contains('\\') || s.runes.any(_isSpaceOrControl)) {
    return UntrustedLinkDecision.refused;
  }
  final uri = Uri.tryParse(s);
  if (uri == null) return UntrustedLinkDecision.refused;
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'hollow') {
    return UntrustedLinkDecision._(UntrustedLinkRoute.app, uri);
  }
  final web = scheme == 'https' || (allowHttp && scheme == 'http');
  if (!web || uri.host.isEmpty) return UntrustedLinkDecision.refused;
  return UntrustedLinkDecision._(UntrustedLinkRoute.browser, uri);
}

/// Whether [openUntrustedUrl] would take [raw] anywhere, so a surface can
/// leave out a control that would do nothing.
bool canOpenUntrustedUrl(String raw, {bool allowHttp = false}) =>
    classifyUntrustedUrl(raw, allowHttp: allowHttp).route !=
    UntrustedLinkRoute.refused;

/// THE way to open a URL that did not come from Hollow's own code: chat text,
/// link cards, the news and status feeds, game cards, shop listings.
///
/// A `hollow://` link goes to [DeepLinkService] in process, with the same
/// confirm a pasted link gets, never through the OS. Returns whether the link
/// went anywhere.
Future<bool> openUntrustedUrl(String raw, {bool allowHttp = false}) async {
  final decision = classifyUntrustedUrl(raw, allowHttp: allowHttp);
  switch (decision.route) {
    case UntrustedLinkRoute.app:
      untrustedLinkAppHandler(raw.trim());
      return true;
    case UntrustedLinkRoute.browser:
      try {
        return await untrustedLinkLauncher(decision.uri!);
      } catch (_) {
        return false;
      }
    case UntrustedLinkRoute.refused:
      return false;
  }
}

bool _isSpaceOrControl(int c) => c <= 0x20 || (c >= 0x7F && c <= 0x9F);

/// Hands a browser-bound link to the OS. Tests swap it for a recorder.
@visibleForTesting
Future<bool> Function(Uri uri) untrustedLinkLauncher =
    (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

/// Hands a `hollow://` link to the in-app router. Tests swap it for a recorder.
@visibleForTesting
void Function(String url) untrustedLinkAppHandler =
    DeepLinkService.instance.handleUrl;
