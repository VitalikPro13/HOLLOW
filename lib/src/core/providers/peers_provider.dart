import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/peer_info.dart';

class PeersNotifier extends Notifier<Map<String, PeerInfo>> {
  @override
  Map<String, PeerInfo> build() => {};

  void addPeer(String peerId, List<String> addresses) {
    final existing = state[peerId];
    final allAddrs = existing != null
        ? {...existing.addresses, ...addresses}.toList()
        : addresses;
    state = {
      ...state,
      peerId: PeerInfo(
        peerId: peerId,
        addresses: allAddrs,
        isEncrypted: existing?.isEncrypted ?? false,
      ),
    };
  }

  void removePeer(String peerId) {
    state = Map.of(state)..remove(peerId);
  }

  void markEncrypted(String peerId) {
    final peer = state[peerId];
    if (peer == null) return;
    state = {...state, peerId: peer.copyWith(isEncrypted: true)};
  }

  void clearAll() {
    state = {};
  }
}

final peersProvider =
    NotifierProvider<PeersNotifier, Map<String, PeerInfo>>(PeersNotifier.new);

class InvisiblePeersNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};

  void setInvisible(String peerId) {
    state = {...state, peerId};
  }

  void setOnline(String peerId) {
    if (state.contains(peerId)) {
      state = Set.of(state)..remove(peerId);
    }
  }

  void removePeer(String peerId) {
    if (state.contains(peerId)) {
      state = Set.of(state)..remove(peerId);
    }
  }
}

final invisiblePeersProvider =
    NotifierProvider<InvisiblePeersNotifier, Set<String>>(
        InvisiblePeersNotifier.new);
