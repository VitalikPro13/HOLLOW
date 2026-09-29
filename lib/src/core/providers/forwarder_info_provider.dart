import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/network.dart' as network_api;
import '../../rust/api/storage.dart' as storage_api;
import 'relay_domain_provider.dart';

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

/// The forwarder a relay first advertised, and when it was last reported online.
class ForwarderPin {
  final String peerId;
  final int lastOnlineMs;

  const ForwarderPin({required this.peerId, required this.lastOnlineMs});

  String encode() => '$peerId|$lastOnlineMs';

  static ForwarderPin? decode(String? raw) {
    if (raw == null) return null;
    final bar = raw.indexOf('|');
    if (bar <= 0) return null;
    final ms = int.tryParse(raw.substring(bar + 1));
    if (ms == null) return null;
    return ForwarderPin(peerId: raw.substring(0, bar), lastOnlineMs: ms);
  }
}

/// How long a pinned forwarder must go unseen before a relay may name another.
/// An operator rotating its forwarder waits this long; a relay turning hostile
/// cannot swap one in while the real one is running.
const kForwarderRepinAfter = Duration(days: 7);

/// Whether the relay's report of [peerId] counts, and the pin to keep after it.
({bool accept, ForwarderPin? pin}) forwarderPinDecision(
  ForwarderPin? pin,
  String peerId,
  bool online,
  int nowMs,
) {
  if (peerId.isEmpty) return (accept: true, pin: pin);
  final fresh =
      ForwarderPin(peerId: peerId, lastOnlineMs: online ? nowMs : pin?.lastOnlineMs ?? 0);
  if (pin == null) return (accept: true, pin: fresh);
  if (pin.peerId == peerId) {
    return (accept: true, pin: online ? fresh : pin);
  }
  final unseen = nowMs - pin.lastOnlineMs;
  if (unseen >= kForwarderRepinAfter.inMilliseconds) {
    return (accept: true, pin: fresh);
  }
  return (accept: false, pin: pin);
}

/// Cache of the last MediaForwarderInfo event. NOT autoDispose: the cache must
/// survive UI churn, or a rebuild silently degrades every later call.
class ForwarderInfoNotifier extends Notifier<ForwarderInfo> {
  @override
  ForwarderInfo build() => const ForwarderInfo(peerId: '', online: false);

  /// Called by the event dispatcher when the relay reports its forwarder. The
  /// first forwarder a relay names is pinned to that relay; a different one is
  /// refused while the pinned one keeps being seen.
  Future<void> setInfo({required String peerId, required bool online}) async {
    final key = 'forwarder_pin:${ref.read(relayDomainProvider).toLowerCase()}';
    final pin = ForwarderPin.decode(await storage_api.loadSetting(key: key));
    final decision = forwarderPinDecision(
        pin, peerId, online, DateTime.now().millisecondsSinceEpoch);
    final kept = decision.pin;
    if (kept != null && kept.encode() != pin?.encode()) {
      await storage_api.saveSetting(key: key, value: kept.encode());
    }
    if (!decision.accept) {
      state = const ForwarderInfo(peerId: '', online: false);
      _fwdLog('[HOLLOW-FWD] Relay named a forwarder other than the pinned one, ignored');
      return;
    }
    state = ForwarderInfo(peerId: peerId, online: online);
    _fwdLog('[HOLLOW-FWD] Media forwarder advertised: online=$online');
  }
}

final forwarderInfoProvider =
    NotifierProvider<ForwarderInfoNotifier, ForwarderInfo>(
        ForwarderInfoNotifier.new);
