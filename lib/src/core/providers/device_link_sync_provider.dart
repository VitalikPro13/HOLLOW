import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// Phases of the multi-device device-linking flow (Step 4). Honest about what is
/// actually happening — no fabricated per-category progress.
enum LinkPhase {
  /// Nothing in progress.
  idle,

  /// (Populated device) Showing a 6-char code, waiting for an empty device to
  /// enter it. `code` is set; `countdownSeconds` ticks down from 300.
  showingCode,

  /// (Populated device) An empty sibling requested data; awaiting the user's
  /// Confirm. `peerId` is the requesting device.
  confirmPush,

  /// (Empty device) Entered a code / detected a sibling, waiting for the
  /// populated device to come online / start sending.
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

/// 6-char code alphabet: unambiguous (no 0/O, 1/I/L) so it's easy to read off a
/// screen and type on another device. Matches the relay's `is_valid_link_code`
/// (6 chars of A-Z/2-9 is a subset of its A-Z0-9 check).
const _codeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

class DeviceLinkSyncNotifier extends Notifier<DeviceLinkState> {
  @override
  DeviceLinkState build() => const DeviceLinkState();

  String _generateCode() {
    final rng = Random.secure();
    return List.generate(6, (_) => _codeAlphabet[rng.nextInt(_codeAlphabet.length)]).join();
  }

  /// (Populated device) Generate + claim a link code and show it. The relay echoes
  /// `LinkCodeClaimed`, or `LinkCodeError` on collision, and we regenerate.
  Future<void> startShowingCode() async {
    final code = _generateCode();
    state = DeviceLinkState(
      phase: LinkPhase.showingCode,
      code: code,
      countdownSeconds: 300,
    );
    await network_api.claimLinkCode(code: code);
  }

  /// (Populated device) Stop showing / cancel the code.
  Future<void> cancelShowingCode() async {
    state = const DeviceLinkState();
    await network_api.releaseLinkCode();
  }

  /// (Empty device) Resolve a code shown on the populated device and request its
  /// snapshot with the chosen scope.
  Future<void> enterCode(String code, {required bool includeVault, required bool includeFiles}) async {
    state = DeviceLinkState(phase: LinkPhase.waiting, code: code.toUpperCase());
    await network_api.resolveLinkCode(
      code: code.toUpperCase(),
      includeVault: includeVault,
      includeFiles: includeFiles,
    );
  }

  /// (Empty device, mnemonic path) Pull from an already-known online sibling.
  Future<void> pullFromSibling(String peerId, {required bool includeVault, required bool includeFiles}) async {
    state = DeviceLinkState(phase: LinkPhase.waiting, peerId: peerId);
    await network_api.requestLinkSnapshot(
      targetPeer: peerId,
      includeVault: includeVault,
      includeFiles: includeFiles,
    );
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

  void onCodeClaimed(String code) {
    if (state.phase == LinkPhase.showingCode) {
      state = state.copyWith(code: code);
    }
  }

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
      default:
        return 'Link error: $error';
    }
  }

  /// (Populated device) An empty sibling is requesting data → show Confirm.
  void onSiblingLinkAvailable(String peerId, int theirMsgCount, int theirFriendCount, bool theirHasProfile) {
    // If WE initiated a pull (empty side) this is our own offer to pull: only
    // surface Confirm when we're showing a code or idle.
    if (state.phase == LinkPhase.waiting || state.phase == LinkPhase.receiving) return;
    state = state.copyWith(
      phase: LinkPhase.confirmPush,
      peerId: peerId,
      theirMsgCount: theirMsgCount,
      theirFriendCount: theirFriendCount,
      theirHasProfile: theirHasProfile,
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
