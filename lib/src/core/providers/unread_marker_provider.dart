import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';

/// The read pointer a conversation had when you WALKED INTO it (issue #54).
///
/// The badge pointer in `unreadProvider` cannot answer "where did I leave
/// off?", because opening a conversation is what moves it. So this keeps a
/// second, sticky pointer per conversation and never moves it during a visit.
/// RAM only: coming back tomorrow should not re-draw yesterday's line.
///
/// **The arming rule is what keeps the line honest.** A conversation is armed
/// whenever it is not the one on screen, and the FIRST mark-seen after that
/// records the pointer and disarms it, so no line appears above a reply that
/// lands while you read, or above your own message.
///
/// The disarm is driven off the SELECTION providers rather than pane
/// lifecycles: `markDmSeen` runs from five different places, and a listener
/// that only touches the conversation being LEFT cannot race any of them.
class UnreadMarkerNotifier extends Notifier<Map<String, String>> {
  /// Conversations currently being viewed — their marker is already recorded
  /// and must not move again until they are left.
  final Set<String> _disarmed = <String>{};

  String? _lastChannelKey;
  String? _lastSplitChannelKey;

  @override
  Map<String, String> build() {
    ref.listen<String?>(selectedPeerProvider, (prev, next) {
      if (prev != null && prev != next) _leave(dmMarkerKey(prev));
    });
    ref.listen<String?>(selectedChannelProvider, (_, _) => _syncChannelKey());
    ref.listen<String?>(selectedServerProvider, (_, _) => _syncChannelKey());
    ref.listen<SplitViewState>(splitViewProvider, (prev, next) {
      final prevPeer = prev?.rightPane?.peerId;
      final nextPeer = next.rightPane?.peerId;
      if (prevPeer != null && prevPeer != nextPeer) {
        _leave(dmMarkerKey(prevPeer));
      }
      _syncSplitChannelKey(next);
    });
    return const {};
  }

  /// Recomputes the composite `server:channel` key and releases the previous
  /// one. Either half moving is a different conversation.
  void _syncChannelKey() {
    final server = ref.read(selectedServerProvider);
    final channel = ref.read(selectedChannelProvider);
    final key = (server != null && channel != null)
        ? channelMarkerKey(server, channel)
        : null;
    if (_lastChannelKey != null && _lastChannelKey != key) {
      _leave(_lastChannelKey!);
    }
    _lastChannelKey = key;
  }

  void _syncSplitChannelKey(SplitViewState split) {
    final server = split.rightPane?.serverId;
    final channel = split.rightPane?.channelId;
    final key = (server != null && channel != null)
        ? channelMarkerKey(server, channel)
        : null;
    if (_lastSplitChannelKey != null && _lastSplitChannelKey != key) {
      _leave(_lastSplitChannelKey!);
    }
    _lastSplitChannelKey = key;
  }

  /// Left [key]: arm it again and drop its line, so the next visit computes a
  /// fresh one (and a visit with nothing new draws none at all).
  void _leave(String key) {
    _disarmed.remove(key);
    if (!state.containsKey(key)) return;
    final next = Map<String, String>.from(state)..remove(key);
    state = next;
  }

  /// Called from `unreadProvider` as a conversation's pointer is about to move.
  /// [previousSeenId] is the value being replaced; an empty string means the
  /// conversation was never read, which is a real answer, not "not recorded".
  void noteSeen(String key, String? previousSeenId) {
    // Clearing a badge from OUTSIDE the conversation ("Mark as read", a
    // notification) is the user saying they are done with it, not that they are
    // about to read it, so drop any line and leave it armed for the real visit.
    if (!_isOnScreen(key)) {
      _disarmed.remove(key);
      if (state.containsKey(key)) {
        state = Map<String, String>.from(state)..remove(key);
      }
      return;
    }
    if (_disarmed.contains(key)) return;
    _disarmed.add(key);
    state = {...state, key: previousSeenId ?? ''};
  }

  /// Whether [key] is a conversation currently on screen, in either pane.
  ///
  /// Read live rather than off the cached keys: navigation sets the selection
  /// providers and THEN marks seen, so the listeners have not run yet.
  bool _isOnScreen(String key) {
    final split = ref.read(splitViewProvider).rightPane;
    final peer = ref.read(selectedPeerProvider);
    if (peer != null && dmMarkerKey(peer) == key) return true;
    final rightPeer = split?.peerId;
    if (rightPeer != null && dmMarkerKey(rightPeer) == key) return true;
    final server = ref.read(selectedServerProvider);
    final channel = ref.read(selectedChannelProvider);
    if (server != null &&
        channel != null &&
        channelMarkerKey(server, channel) == key) {
      return true;
    }
    final rs = split?.serverId;
    final rc = split?.channelId;
    return rs != null && rc != null && channelMarkerKey(rs, rc) == key;
  }

  /// The entry pointer for [key], or null when this visit has none.
  String? entrySeenId(String key) => state[key];
}

String dmMarkerKey(String peerId) => 'dm:$peerId';

String channelMarkerKey(String serverId, String channelId) =>
    'ch:$serverId:$channelId';

final unreadMarkerProvider =
    NotifierProvider<UnreadMarkerNotifier, Map<String, String>>(
        UnreadMarkerNotifier.new);
