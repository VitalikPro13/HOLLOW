import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;

/// The Twitch calls the connection row makes, behind one object.
///
/// A top-level FFI function is not something a test can override, and the
/// connection row's whole job is to show what came back from one.
class TwitchFfi {
  const TwitchFfi();

  Future<bool> isConnected() => twitch_api.twitchIsConnected();

  Future<String?> username() => twitch_api.twitchGetUsername();

  Future<String?> userId() => twitch_api.twitchGetUserId();

  /// Verify the connected account and wear the credential. A refusal from the
  /// shop comes back as an outcome, not a throw.
  Future<twitch_api.TwitchVerifyOutcome> verifyOwner() =>
      twitch_api.twitchVerifyOwner();

  /// Drops the account credential and republishes, then wipes the token.
  Future<void> disconnect() => twitch_api.twitchDisconnect();
}

final twitchFfiProvider = Provider<TwitchFfi>((ref) => const TwitchFfi());
