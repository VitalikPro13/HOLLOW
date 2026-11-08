import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// Servers and meetings (`conf:{id}`) this relay's operator refuses to carry,
/// lowercase. RAM only, like the node's own set: a new launch asks again.
final relayDeniedServersProvider =
    StateProvider<Set<String>>((ref) => const <String>{});

/// Whether this relay refuses [serverId] (a server id or a `conf:` meeting id).
final serverRelayDeniedProvider = Provider.family<bool, String>((ref, serverId) =>
    ref.watch(relayDeniedServersProvider).contains(serverId.toLowerCase()));

/// The relay refuses our login: `account_denied` or `network_denied`, null when
/// it does not (or we do not know yet).
final relayLoginDenialProvider = StateProvider<String?>((ref) => null);

/// What a server blocked on this relay says, Vitalik's copy (11-07).
const String kServerDeniedText =
    "This server is not available on this relay because it broke the relay's Terms of use.";

/// The same for a meeting.
const String kMeetingDeniedText =
    "This meeting is not available on this relay because it broke the relay's Terms of use.";

/// What stays true for the person while a server is blocked.
const String kDeniedKeepsText = 'Your messages and files stay on this device.';

/// A pending join's title while the relay refuses its server.
const String kPendingJoinDeniedTitle = 'Not available on this relay';

/// The refused-login dialog's title; the reason goes in its body.
const String kRelayLoginDeniedTitle = 'Refused by this relay';

/// What stops while the relay refuses our login.
const String kLoginDeniedStopsText =
    'Nothing is sent or received through this relay until it lets you in again.';

/// The connection status while the relay refuses our login.
const String kRelayRefusedStatus = 'Refused by this relay';

/// Above the Terms when a self-hosted relay refused something: the relay's domain
/// comes first, in mono. Draft copy, Vitalik's (11-08).
const String kForeignRelayTermsTail =
    " is not run by Hollow. Its operator sets its own rules, so these Terms cover only Hollow's official relay, and we can't review or reverse what this relay blocks.";

/// The shell's message for a refused login, by the relay's code.
String relayLoginDenialText(String kind) => kind == 'network_denied'
    ? 'This relay does not accept connections from your network.'
    : 'This relay does not accept this account.';

/// Ask the relay again about everything it refused. Never switches relays.
Future<void> retryRelayDenials() =>
    network_api.retryRelayDenials().catchError((_) {});
