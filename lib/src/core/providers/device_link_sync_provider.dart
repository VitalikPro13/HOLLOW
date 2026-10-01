import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'connection_status_provider.dart';

/// Phases of the multi-device device-linking flow (Step 4). Honest about what is
/// actually happening — no fabricated per-category progress.
enum LinkPhase {
  /// Nothing in progress.
  idle,

  /// (Populated device) Showing a link code, waiting for an empty device to
  /// enter it. `code` is set; `countdownSeconds` ticks down from 300.
  showingCode,

  /// (Populated device) An empty sibling requested data; awaiting the user's
  /// Confirm. `peerId` is the requesting device.
  confirmPush,

  /// (Empty device) Entered a code, waiting for the populated device to
  /// answer and start sending.
  waiting,

  /// (Empty device) Receiving the snapshot. `bytesReceived`/`totalBytes` drive
  /// the ONE real progress bar.
  receiving,

  /// (Populated device) Sending the snapshot. The sender pushes fire-and-forget
  /// (no per-byte feedback), so this shows an indeterminate spinner, not a bar.
  sending,

  /// (Empty device) Decrypting + importing the received snapshot.
  importing,

  /// Done. `msgCount`/`friendCount`/`serverCount` are the imported totals.
  done,

  /// (Populated device) The snapshot was fully sent. Sender-only terminal state.
  pushDone,

  /// Something failed. `error` is set.
  failed,
}

class DeviceLinkState {
  final LinkPhase phase;

  // Showing-code side.
  final String? code;
  final int countdownSeconds;

  // Confirm-push side (populated device).
  final String? peerId;
  final int theirMsgCount;
  final int theirFriendCount;
  final bool theirHasProfile;

  /// What the asking device says it is: its name and its platform.
  final String theirLabel;
  final String theirPlatform;

  // Receiving side (empty device).
  final int bytesReceived;
  final int totalBytes;

  // Done summary.
  final int msgCount;
  final int friendCount;
  final int serverCount;

  final String? error;

  const DeviceLinkState({
    this.phase = LinkPhase.idle,
    this.code,
    this.countdownSeconds = 0,
    this.peerId,
    this.theirMsgCount = 0,
    this.theirFriendCount = 0,
    this.theirHasProfile = false,
    this.theirLabel = '',
    this.theirPlatform = '',
    this.bytesReceived = 0,
    this.totalBytes = 0,
    this.msgCount = 0,
    this.friendCount = 0,
    this.serverCount = 0,
    this.error,
  });

  double get progress =>
      totalBytes > 0 ? (bytesReceived / totalBytes).clamp(0.0, 1.0) : 0.0;

  DeviceLinkState copyWith({
    LinkPhase? phase,
    String? code,
    int? countdownSeconds,
    String? peerId,
    int? theirMsgCount,
    int? theirFriendCount,
    bool? theirHasProfile,
    String? theirLabel,
    String? theirPlatform,
    int? bytesReceived,
    int? totalBytes,
    int? msgCount,
    int? friendCount,
    int? serverCount,
    String? error,
  }) =>
      DeviceLinkState(
        phase: phase ?? this.phase,
        code: code ?? this.code,
        countdownSeconds: countdownSeconds ?? this.countdownSeconds,
        peerId: peerId ?? this.peerId,
        theirMsgCount: theirMsgCount ?? this.theirMsgCount,
        theirFriendCount: theirFriendCount ?? this.theirFriendCount,
        theirHasProfile: theirHasProfile ?? this.theirHasProfile,
        theirLabel: theirLabel ?? this.theirLabel,
        theirPlatform: theirPlatform ?? this.theirPlatform,
        bytesReceived: bytesReceived ?? this.bytesReceived,
        totalBytes: totalBytes ?? this.totalBytes,
        msgCount: msgCount ?? this.msgCount,
        friendCount: friendCount ?? this.friendCount,
        serverCount: serverCount ?? this.serverCount,
        error: error ?? this.error,
      );
}

final deviceLinkSyncProvider =
    NotifierProvider<DeviceLinkSyncNotifier, DeviceLinkState>(
  DeviceLinkSyncNotifier.new,
);

/// Code alphabet: unambiguous (no 0/O, 1/I/L) so it's easy to read off a screen
/// and type on another device. Matches Rust's `link_pake::ALPHABET`, and is a
/// subset of the relay's A-Z0-9 check for the part it sees.
const _codeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

/// The part of a link code the relay sees (it brings the two devices together)
/// and the part it never sees (it keys the handshake, HOL-SEC-002).
const kLinkRendezvousLength = 6;
const kLinkSecretLength = 4;
const kLinkCodeLength = kLinkRendezvousLength + kLinkSecretLength;

/// A code as shown and typed: `ABCDEF-GHJK`.
String formatLinkCode(String code) => code.length <= kLinkRendezvousLength
    ? code
    : '${code.substring(0, kLinkRendezvousLength)}-${code.substring(kLinkRendezvousLength)}';

/// What this device calls itself on the other device's confirm prompt: the
/// computer's name on a desktop, nothing on a phone (which reports none worth
/// showing), and the platform.
({String label, String platform}) linkDeviceIdentity() {
  final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  var label = '';
  if (desktop) {
    try {
      label = Platform.localHostname;
    } catch (_) {}
  }
  return (label: label, platform: Platform.operatingSystem);
}

/// The platform a linking device reported, as people name it.
String platformName(String platform) => switch (platform) {
      'windows' => 'Windows',
      'macos' => 'macOS',
      'linux' => 'Linux',
      'android' => 'Android',
      'ios' => 'iOS',
      _ => platform,
    };

/// "A Windows device", "An iOS device": the confirm prompt's name for a device
/// that reported no label of its own.
String aDeviceOn(String platform) {
  final name = platformName(platform);
  if (name.isEmpty) return 'A device';
  final article = RegExp(r'^[AEIOUaeiou]').hasMatch(name) ? 'An' : 'A';
  return '$article $name device';
}

class DeviceLinkSyncNotifier extends Notifier<DeviceLinkState> {
  Timer? _waitingTimer;
  bool _disposed = false;

  @override
  DeviceLinkState build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _waitingTimer?.cancel();
    });
    listenSelf((previous, next) {
      if (next.phase != LinkPhase.waiting) _waitingTimer?.cancel();
    });
    return const DeviceLinkState();
  }

  bool _beginWaiting(DeviceLinkState next) {
    _waitingTimer?.cancel();
    if (!ref.read(overallConnectionProvider).isOnline) {
      state = const DeviceLinkState(phase: LinkPhase.failed,
          error: 'Hollow is not connected to the relay yet. Wait until it is online and try again.');
      return false;
    }
    state = next;
    _waitingTimer = Timer(const Duration(seconds: 60), () {
      if (state.phase != LinkPhase.waiting) return;
      state = state.copyWith(phase: LinkPhase.failed,
          error: 'Your other device did not answer. Check that both devices are online, then try again with a fresh code.');
    });
    return true;
  }

  String _generateCode() {
    final rng = Random.secure();
    return List.generate(kLinkCodeLength, (_) => _codeAlphabet[rng.nextInt(_codeAlphabet.length)]).join();
  }

  /// (Populated device) Generate a link code, claim its rendezvous part and show
  /// it whole. The relay echoes `LinkCodeClaimed`, or `LinkCodeError` on a
  /// collision, and we regenerate.
  Future<void> startShowingCode() async {
    final code = _generateCode();
    state = DeviceLinkState(
      phase: LinkPhase.showingCode,
      code: code,
      countdownSeconds: 300,
    );
    await network_api.claimLinkCode(
      rendezvous: code.substring(0, kLinkRendezvousLength),
      secret: code.substring(kLinkRendezvousLength),
    );
  }

  /// (Populated device) Stop showing / cancel the code.
  Future<void> cancelShowingCode() async {
    state = const DeviceLinkState();
    await network_api.releaseLinkCode();
  }

  /// (Empty device) Link to the device showing [code]. The populated device
  /// decides what the snapshot includes when it confirms.
  Future<void> enterCode(String code) async {
    final typed = code.toUpperCase(); // design-ignore: link code, data
    if (!_beginWaiting(DeviceLinkState(phase: LinkPhase.waiting, code: typed))) return;
    final attempt = state;
    final me = linkDeviceIdentity();
    try {
      await network_api.resolveLinkCode(code: typed, label: me.label, platform: me.platform);
    } catch (_) {
      if (!_disposed && identical(state, attempt)) {
        onLinkFailed('Could not request the link. Check your connection and try again.');
      }
    }
  }

  /// (Populated device) Accept an inbound request and push the snapshot.
  Future<void> acceptPush(String targetPeer, {required bool includeVault, required bool includeFiles}) async {
    state = state.copyWith(phase: LinkPhase.sending, peerId: targetPeer);
    await network_api.acceptLinkPush(
      targetPeer: targetPeer,
      includeVault: includeVault,
      includeFiles: includeFiles,
    );
  }

  /// (Populated device) Decline an inbound request.
  Future<void> declinePush(String targetPeer) async {
    state = const DeviceLinkState();
    await network_api.declineLinkPush(targetPeer: targetPeer);
  }

  void reset() => state = const DeviceLinkState();

  /// The relay echoes only the rendezvous part, so the code on screen stays.
  void onCodeClaimed(String code) {}

  void onCodeError(String error, String code) {
    // A claim collision while showing → regenerate and re-claim.
    if (state.phase == LinkPhase.showingCode && error == 'taken') {
      startShowingCode();
      return;
    }
    // A resolve failure (wrong/expired code) on the empty side.
    if (state.phase == LinkPhase.waiting) {
      state = state.copyWith(phase: LinkPhase.failed, error: _codeErrorMessage(error));
    }
  }

  String _codeErrorMessage(String error) {
    switch (error) {
      case 'not_found':
        return 'Code not found or expired. Check it and try again.';
      case 'invalid':
        return 'Invalid code format.';
      case 'taken':
        return 'Code already in use.';
      case 'too_many_attempts':
        return 'Too many attempts. Wait a minute and try again.';
      default:
        return 'Link error: $error';
    }
  }

  /// (Populated device) A device that typed our code asks for our data: show
  /// Confirm with what it says it is.
  void onSiblingLinkAvailable(
    String peerId,
    int theirMsgCount,
    int theirFriendCount,
    bool theirHasProfile, {
    String label = '',
    String platform = '',
  }) {
    // If WE initiated a pull (empty side) this is our own offer to pull: only
    // surface Confirm when we're showing a code or idle.
    if (state.phase == LinkPhase.waiting || state.phase == LinkPhase.receiving) return;
    state = state.copyWith(
      phase: LinkPhase.confirmPush,
      peerId: peerId,
      theirMsgCount: theirMsgCount,
      theirFriendCount: theirFriendCount,
      theirHasProfile: theirHasProfile,
      theirLabel: label,
      theirPlatform: platform,
    );
  }

  void onLinkProgress(int bytesReceived, int totalBytes) {
    state = state.copyWith(
      phase: LinkPhase.receiving,
      bytesReceived: bytesReceived,
      totalBytes: totalBytes,
    );
  }

  void onLinkComplete(int msgCount, int friendCount, int serverCount) {
    state = state.copyWith(
      phase: LinkPhase.done,
      msgCount: msgCount,
      friendCount: friendCount,
      serverCount: serverCount,
    );
  }

  void onLinkFailed(String error) {
    state = state.copyWith(phase: LinkPhase.failed, error: error);
  }

  /// (Populated device) The snapshot finished sending — show the sender-side done.
  void onPushComplete() {
    if (state.phase == LinkPhase.sending) {
      state = state.copyWith(phase: LinkPhase.pushDone);
    }
  }

  void onDisconnected() {
    if (state.phase == LinkPhase.idle) return;
    // Keep a completed/failed terminal state visible.
    if (state.phase == LinkPhase.done || state.phase == LinkPhase.failed) return;
    // Do NOT tear down an in-flight transfer on a transient relay blip: the link
    // handshake churns the connection, so a brief RelayDisconnected is expected
    // mid-link and the populated device pushes regardless. Only the pre-transfer
    // showingCode/confirmPush states, which depend on a live code claim, reset.
    switch (state.phase) {
      case LinkPhase.waiting:
      case LinkPhase.receiving:
      case LinkPhase.importing:
      case LinkPhase.sending:
        return;
      default:
        state = const DeviceLinkState();
    }
  }
}
