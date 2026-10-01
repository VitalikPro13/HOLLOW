import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// What one of our other devices is in: a DM call ([kind] 'call', [peer] the
/// friend's master), a voice channel ('voice', [peer] the server) or a meeting
/// ('meeting', [peer] the conference id).
@immutable
class SiblingCall {
  final String device;
  final String kind;
  final String peer;
  final String channel;

  /// When it connected; null while it still rings or connects.
  final DateTime? startedAt;

  const SiblingCall({
    required this.device,
    required this.kind,
    required this.peer,
    this.channel = '',
    this.startedAt,
  });

  bool get isDmCall => kind == 'call';
}

/// device id -> what that sibling is in. The node reports every change, clears a
/// sibling that goes offline, and on reconnect the device in a call says so again.
class SiblingCallNotifier extends Notifier<Map<String, SiblingCall>> {
  @override
  Map<String, SiblingCall> build() => const {};

  void apply({
    required String device,
    required bool active,
    required String kind,
    required String peer,
    required String channel,
    required int startedMs,
  }) {
    final next = Map.of(state);
    if (active) {
      next[device] = SiblingCall(
        device: device,
        kind: kind,
        peer: peer,
        channel: channel,
        startedAt: startedMs > 0
            ? DateTime.fromMillisecondsSinceEpoch(startedMs)
            : null,
      );
    } else if (next.remove(device) == null) {
      return;
    }
    state = next;
  }

  /// Our relay link dropped: what our siblings were in is unknown until they say.
  void clear() {
    if (state.isNotEmpty) state = const {};
  }
}

final siblingCallProvider =
    NotifierProvider<SiblingCallNotifier, Map<String, SiblingCall>>(
        SiblingCallNotifier.new);

/// The one call our identity is in on another device, if any.
final callElsewhereProvider = Provider<SiblingCall?>(
    (ref) => ref.watch(siblingCallProvider).values.firstOrNull);

/// Why this device cannot start or join a call right now.
String callElsewhereReason(SiblingCall call) => switch (call.kind) {
      'voice' => "You're in a voice channel on another device",
      'meeting' => "You're in a meeting on another device",
      _ => "You're in a call on another device",
    };

/// Tells the node what this device is in, whenever that changes: a DM call from
/// the moment it rings out or is picked up, a voice channel, or a meeting.
/// Kept alive from the event stream's start.
final callPresenceSyncProvider = Provider<void>((ref) {
  ({String kind, String peer, String channel, int startedMs})? current() {
    final call = ref.read(callProvider);
    final ringingIn = call.status == CallStatus.ringing &&
        call.direction == CallDirection.incoming;
    if (call.status != CallStatus.idle && !ringingIn && call.peerId != null) {
      return (
        kind: 'call',
        peer: ref.read(deviceLinkProvider).identityOf(call.peerId!),
        channel: '',
        startedMs: call.startedAt?.millisecondsSinceEpoch ?? 0,
      );
    }
    final vc = ref.read(voiceChannelProvider);
    final server = vc.currentServerId;
    if (vc.isInVoiceChannel && server != null) {
      final meeting = server.startsWith('conf:');
      return (
        kind: meeting ? 'meeting' : 'voice',
        peer: server,
        channel: meeting ? '' : (vc.currentChannelId ?? ''),
        startedMs: vc.joinedAt?.millisecondsSinceEpoch ?? 0,
      );
    }
    return null;
  }

  ({String kind, String peer, String channel, int startedMs})? sent;
  void sync() {
    final now = current();
    if (now == sent) return;
    sent = now;
    network_api
        .setCallPresence(
          kind: now?.kind ?? '',
          with_: now?.peer ?? '',
          channel: now?.channel ?? '',
          startedMs: now?.startedMs ?? 0,
        )
        .catchError((_) {});
  }

  ref.listen(callProvider, (_, _) => sync());
  ref.listen(voiceChannelProvider, (_, _) => sync());
  sync();
});
