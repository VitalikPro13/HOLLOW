import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/network.dart' as network_api;

/// Log to hollow_debug.log (visible in release builds + debug file).
void _fwdLog(String msg) {
  network_api.logFromDart(message: msg);
}

/// The relay's advertised media forwarder (media forwarding step 3).
///
/// `peerId` is static relay config; `online` is the relay's live lookup at
/// request time. Both arrive over the AUTHENTICATED relay WebSocket, re-requested
/// on every reconnect. Staleness of `online` is tolerated by design: the sharer
/// only uses it to decide whether an assignment is worth attempting, and the
/// viewer-side fallback ladder corrects a wrong decision.
class ForwarderInfo {
  final String peerId;
  final bool online;

  const ForwarderInfo({required this.peerId, required this.online});

  /// True when a forwarder is configured and was connected at last report.
  bool get usable => peerId.isNotEmpty && online;
}

/// Cache of the last MediaForwarderInfo event. NOT autoDispose: the cache must
/// survive UI churn, or a rebuild silently degrades every later call.
class ForwarderInfoNotifier extends Notifier<ForwarderInfo> {
  @override
  ForwarderInfo build() => const ForwarderInfo(peerId: '', online: false);

  /// Called by the event dispatcher when the relay reports its forwarder.
  void setInfo({required String peerId, required bool online}) {
    state = ForwarderInfo(peerId: peerId, online: online);
    _fwdLog('[HOLLOW-FWD] Media forwarder advertised: online=$online');
  }
}

final forwarderInfoProvider =
    NotifierProvider<ForwarderInfoNotifier, ForwarderInfo>(
        ForwarderInfoNotifier.new);
