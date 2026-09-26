import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;

enum NicknameStatus { off, claiming, claimed, failed }

class TemporaryNicknameState {
  final NicknameStatus status;
  final String? nickname;
  final String? error;

  const TemporaryNicknameState({
    this.status = NicknameStatus.off,
    this.nickname,
    this.error,
  });

  TemporaryNicknameState copyWith({
    NicknameStatus? status,
    String? nickname,
    String? error,
  }) =>
      TemporaryNicknameState(
        status: status ?? this.status,
        nickname: nickname ?? this.nickname,
        error: error ?? this.error,
      );
}

final temporaryNicknameProvider =
    NotifierProvider<TemporaryNicknameNotifier, TemporaryNicknameState>(
  TemporaryNicknameNotifier.new,
);

class TemporaryNicknameNotifier extends Notifier<TemporaryNicknameState> {
  /// How long the relay may take to answer a claim.
  static const claimTimeout = Duration(seconds: 10);
  Timer? _claimTimer;

  @override
  TemporaryNicknameState build() {
    ref.onDispose(() => _claimTimer?.cancel());
    return const TemporaryNicknameState();
  }

  /// A relay that never answers must not leave the claim spinning, so the
  /// claim fails with 'timeout' once [claimTimeout] passes unanswered.
  Future<void> claim(String nickname) async {
    state = TemporaryNicknameState(
      status: NicknameStatus.claiming,
      nickname: nickname,
    );
    _claimTimer?.cancel();
    _claimTimer = Timer(claimTimeout, () {
      if (state.status == NicknameStatus.claiming &&
          state.nickname == nickname) {
        onClaimFailed('timeout');
      }
    });
    await network_api.claimNickname(nickname: nickname);
  }

  Future<void> release() async {
    _claimTimer?.cancel();
    state = const TemporaryNicknameState(status: NicknameStatus.off);
    await network_api.releaseNickname();
  }

  void onClaimed(String nickname) {
    _claimTimer?.cancel();
    state = TemporaryNicknameState(
      status: NicknameStatus.claimed,
      nickname: nickname,
    );
  }

  void onReleased() {
    _claimTimer?.cancel();
    state = const TemporaryNicknameState();
  }

  void onClaimFailed(String error) {
    _claimTimer?.cancel();
    state = TemporaryNicknameState(
      status: NicknameStatus.failed,
      error: error,
    );
  }

  void onDisconnected() {
    _claimTimer?.cancel();
    state = const TemporaryNicknameState();
  }
}
