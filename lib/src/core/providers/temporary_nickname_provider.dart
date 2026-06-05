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
  @override
  TemporaryNicknameState build() => const TemporaryNicknameState();

  Future<void> claim(String nickname) async {
    state = TemporaryNicknameState(
      status: NicknameStatus.claiming,
      nickname: nickname,
    );
    await network_api.claimNickname(nickname: nickname);
  }

  Future<void> release() async {
    state = const TemporaryNicknameState(status: NicknameStatus.off);
    await network_api.releaseNickname();
  }

  void onClaimed(String nickname) {
    state = TemporaryNicknameState(
      status: NicknameStatus.claimed,
      nickname: nickname,
    );
  }

  void onReleased() {
    state = const TemporaryNicknameState();
  }

  void onClaimFailed(String error) {
    state = TemporaryNicknameState(
      status: NicknameStatus.failed,
      error: error,
    );
  }

  void onDisconnected() {
    state = const TemporaryNicknameState();
  }
}
