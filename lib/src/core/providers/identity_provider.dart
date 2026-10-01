import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/service_providers.dart';

/// Identity state: peer ID, mnemonic (first run only, until it is confirmed),
/// loaded flag.
class IdentityState {
  final String? peerId;
  final String? mnemonic;
  final bool isLoaded;
  final String? error;

  const IdentityState({
    this.peerId,
    this.mnemonic,
    this.isLoaded = false,
    this.error,
  });

  IdentityState copyWith({
    String? peerId,
    String? mnemonic,
    bool? isLoaded,
    String? error,
  }) {
    return IdentityState(
      peerId: peerId ?? this.peerId,
      mnemonic: mnemonic ?? this.mnemonic,
      isLoaded: isLoaded ?? this.isLoaded,
      error: error,
    );
  }
}

class IdentityNotifier extends Notifier<IdentityState> {
  @override
  IdentityState build() => const IdentityState();

  /// The phrase was written down and checked: nothing keeps it after this
  /// (design ID-1).
  void forgetMnemonic() => state = IdentityState(
        peerId: state.peerId,
        isLoaded: state.isLoaded,
        error: state.error,
      );

  /// Load identity from disk (or create new) and open the message store.
  Future<void> load() async {
    try {
      final identityService = ref.read(identityServiceProvider);
      final storageService = ref.read(storageServiceProvider);

      final info = await identityService.loadOrCreateIdentity();
      await storageService.openMessageStore();

      state = state.copyWith(
        peerId: info.peerId,
        mnemonic: info.mnemonic,
        isLoaded: true,
      );
    } catch (e) {
      debugPrint('[HOLLOW] Identity load error: $e');
      state = state.copyWith(error: e.toString());
    }
  }

  /// Restore identity from a 24-word mnemonic phrase.
  Future<void> restoreFromMnemonic(String phrase) async {
    try {
      final identityService = ref.read(identityServiceProvider);
      final info = await identityService.restoreIdentityFromMnemonic(
        phrase: phrase,
      );
      state = state.copyWith(
        peerId: info.peerId,
        mnemonic: info.mnemonic,
        isLoaded: true,
      );
    } catch (e) {
      debugPrint('[HOLLOW] Restore identity error: $e');
      state = state.copyWith(error: e.toString());
    }
  }
}

final identityProvider =
    NotifierProvider<IdentityNotifier, IdentityState>(IdentityNotifier.new);
