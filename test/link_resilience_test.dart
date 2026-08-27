import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/services/link_resilience.dart';

/// The bug this file exists for: every media lane treated
/// `RTCPeerConnectionStateDisconnected` as a hangup, and the DM call lane also
/// signalled `end` to the peer, so one side's three-second Wi-Fi stutter hung
/// the call up on BOTH machines. These tests pin the hold-open ladder that
/// replaced it: a lapse is held, escalated to an ICE restart, and only given
/// up on when the whole grace window is gone.

const _connected = RTCPeerConnectionState.RTCPeerConnectionStateConnected;
const _disconnected = RTCPeerConnectionState.RTCPeerConnectionStateDisconnected;
const _failed = RTCPeerConnectionState.RTCPeerConnectionStateFailed;
const _closed = RTCPeerConnectionState.RTCPeerConnectionStateClosed;

final _t0 = DateTime.utc(2026, 1, 1, 12);
DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

/// Tick once a second from [from] to [to], the way the lanes actually drive
/// this, and report the first second at which [want] came back. Jumping the
/// clock instead would let a restart that was due seconds ago fire late and
/// hide the real schedule.
int? _firstSecondWith(LinkResilience link, LinkAction want,
    {int from = 1, required int to, void Function(int second)? each}) {
  for (var s = from; s <= to; s++) {
    each?.call(s);
    if (link.tick(_at(s)) == want) return s;
  }
  return null;
}

LinkResilience _live({bool polite = true, LinkResilienceConfig? config}) {
  final link = LinkResilience(
    isPolite: polite,
    config: config ?? const LinkResilienceConfig(),
  );
  link.onTransportState(_connected, _t0);
  return link;
}

void main() {
  group('a wobble is not a hangup', () {
    test('disconnected does NOT ask the caller to give up', () {
      final link = _live();
      expect(link.onTransportState(_disconnected, _at(1)), LinkAction.none);
      expect(link.health, LinkHealth.reconnecting);
      expect(link.isLapsing, isTrue);
    });

    test('a lapse shorter than restartAfter costs nothing at all', () {
      final link = _live();
      link.onTransportState(_disconnected, _at(1));
      expect(link.tick(_at(2)), LinkAction.none);
      expect(link.tick(_at(3)), LinkAction.none);
      expect(link.restartsSpent, 0);
    });

    test('coming back reports recovered and clears the flair', () {
      final link = _live();
      link.onTransportState(_disconnected, _at(1));
      expect(link.onTransportState(_connected, _at(3)), LinkAction.recovered);
      expect(link.health, LinkHealth.healthy);
      expect(link.isLapsing, isFalse);
    });

    test('a recovered lapse hands its whole restart budget back', () {
      final link = _live();
      link.onTransportState(_failed, _at(0));
      expect(_firstSecondWith(link, LinkAction.restartIce, to: 20), 8);
      expect(link.restartsSpent, 1);
      link.onTransportState(_connected, _at(20));
      expect(link.restartsSpent, 0,
          reason: 'a long call on a flaky line must not run out of restarts '
              'in the morning and be defenceless by the evening');
    });
  });

  group('escalation ladder', () {
    test('a `disconnected` link is NEVER restarted, however long it lasts', () {
      // The reversal, and the field data behind it: across every recorded
      // outage an ICE restart was never the thing that recovered a link.
      // Recovery always coincided with the network returning and libwebrtc
      // restoring consent on the pair it already had. What the restarts DID do
      // was rebuild the transport under SFrame and leave the cryptors wedged in
      // DecryptionFailed. The clean recoveries are exactly the zero-restart
      // ones.
      final link = _live();
      link.onTransportState(_disconnected, _at(0));
      expect(_firstSecondWith(link, LinkAction.restartIce, to: 44), isNull);
      expect(link.restartsSpent, 0);
    });

    test('failed earns one, but not instantly', () {
      final link = _live();
      expect(link.onTransportState(_failed, _at(1)), LinkAction.none,
          reason: 'consent can still come back; waiting has recovered every '
              'outage on record without touching the transport');
      expect(_firstSecondWith(link, LinkAction.restartIce, to: 30), 9,
          reason: '8s after entering failed');
    });

    test('the clock runs from entering failed, not from the lapse', () {
      final link = _live();
      link.onTransportState(_disconnected, _at(0));
      for (var t = 1; t <= 20; t++) {
        link.tick(_at(t));
      }
      link.onTransportState(_failed, _at(20));
      expect(_firstSecondWith(link, LinkAction.restartIce, from: 21, to: 40), 28,
          reason: 'twenty seconds of wobbling earns no head start');
    });

    test('falling back from failed to disconnected keeps it eligible', () {
      // Field-caught 2026-08-27, and it produced a ONE-WAY call. The host went
      // failed, restarted, connected four seconds later. The VM went failed,
      // fell back to disconnected when that restart landed half-way, and an
      // earlier version of this rule then refused to restart it because
      // "disconnected is never restarted". It sat stranded for seventy seconds:
      // audio flowed host to VM and never back, and its flair never cleared.
      //
      // A climb from failed to disconnected is a HALF-recovery, not a cure.
      final link = _live();
      link.onTransportState(_failed, _at(0));
      expect(_firstSecondWith(link, LinkAction.restartIce, to: 20), 8);
      link.onTransportState(_disconnected, _at(10));
      expect(_firstSecondWith(link, LinkAction.restartIce, from: 11, to: 44),
          isNotNull,
          reason: 'a link that has already been down must keep trying');
    });

    test('but a link that only ever wobbled is still left alone', () {
      final link = _live();
      link.onTransportState(_disconnected, _at(0));
      expect(_firstSecondWith(link, LinkAction.restartIce, to: 44), isNull);
    });

    test('a real recovery does clear the escalation', () {
      final link = _live();
      link.onTransportState(_failed, _at(0));
      expect(_firstSecondWith(link, LinkAction.restartIce, to: 20), 8);
      link.onTransportState(_connected, _at(12));
      link.onTransportState(_disconnected, _at(20));
      expect(_firstSecondWith(link, LinkAction.restartIce, from: 21, to: 60),
          isNull,
          reason: 'the NEXT lapse starts fresh: it has not been down yet');
    });

    test('restarts are spaced by the cooldown', () {
      final link = _live();
      link.onTransportState(_failed, _at(0));
      expect(_firstSecondWith(link, LinkAction.restartIce, to: 20), 8);
      expect(link.tick(_at(12)), LinkAction.none);
      expect(link.tick(_at(13)), LinkAction.restartIce);
    });

    test('attempts keep coming for the WHOLE window, they are not rationed',
        () {
      // (A `failed` link. A wobbling one is never restarted at all.)
      // The bug this pins (field-caught 2026-08-27): the ladder allowed three
      // attempts, a VM lost its network card for 25s, and all three fired into
      // a relay that was itself down. By the time signalling came back the
      // budget was gone. Attempts are cheap and make-before-break; the window
      // is the control, not a count.
      final link = _live();
      link.onTransportState(_failed, _at(0));
      var attempts = 0;
      for (var t = 1; t < 45; t++) {
        if (link.tick(_at(t)) == LinkAction.restartIce) attempts++;
      }
      expect(attempts, greaterThan(5),
          reason: 'a 45 second outage should be retried throughout, not three '
              'times in the first twenty seconds and then never again');
      expect(link.health, LinkHealth.reconnecting);
    });
  });

  group('an attempt that cannot be delivered is not spent', () {
    test('no restarts at all while signalling is down', () {
      final link = _live();
      link.setSignalingReady(false);
      link.onTransportState(_failed, _at(0));
      expect(_firstSecondWith(link, LinkAction.restartIce, to: 40), isNull,
          reason: 'restartIce() only arms credentials; the offer that carries '
              'them rides the relay, and with the relay down it is dropped '
              'before it leaves the machine');
      expect(link.restartsSpent, 0);
    });

    test('and one fires immediately when signalling returns', () {
      final link = _live();
      link.setSignalingReady(false);
      link.onTransportState(_failed, _at(0));
      for (var t = 1; t <= 24; t++) {
        link.tick(_at(t));
      }
      link.setSignalingReady(true);
      expect(link.tick(_at(25)), LinkAction.restartIce,
          reason: 'the moment the relay is back the offer can land, and no '
              'cooldown has been earned by attempts that never happened');
    });

    test('the window does NOT run down while we cannot even try', () {
      // Field-caught 2026-08-27. A VM lost its network card, its relay client
      // went into a 30 second reconnect backoff, and the 45 second window
      // expired ELEVEN SECONDS before the relay came back. Zero restarts had
      // been attempted. The call was killed for failing a recovery it was
      // never allowed to start.
      final link = _live();
      link.setSignalingReady(false);
      link.onTransportState(_disconnected, _at(0));
      expect(_firstSecondWith(link, LinkAction.giveUp, to: 60), isNull,
          reason: '"we gave up" has to mean we tried and failed, never that '
              'the clock ran out while we sat unable to speak');
    });

    test('and once signalling returns, the full window is still there', () {
      final link = _live();
      link.setSignalingReady(false);
      link.onTransportState(_failed, _at(0));
      for (var t = 1; t <= 56; t++) {
        link.tick(_at(t));
      }
      link.setSignalingReady(true);
      expect(link.tick(_at(57)), LinkAction.restartIce,
          reason: 'the relay came back at 56s in the field case; the call must '
              'still be alive to use it');
      expect(_firstSecondWith(link, LinkAction.giveUp, from: 58, to: 130),
          isNotNull,
          reason: 'and it must still resolve eventually');
    });

    test('a link that can NEVER signal still resolves, at the ceiling', () {
      final link = _live();
      link.setSignalingReady(false);
      link.onTransportState(_disconnected, _at(0));
      expect(_firstSecondWith(link, LinkAction.giveUp, to: 200), 90,
          reason: 'the extension is generous, not infinite');
    });

    test('a suspended app cannot buy an extension by being asleep', () {
      final link = _live();
      link.setSignalingReady(false);
      link.onTransportState(_disconnected, _at(0));
      link.tick(_at(1));
      // One tick, one hour later: a laptop lid closing, not a network outage
      // we were fighting through.
      link.tick(_at(3601));
      expect(link.tick(_at(3602)), LinkAction.giveUp,
          reason: 'only time we actually spent trying counts');
    });
  });

  group('giving up', () {
    test('only when the whole grace window is gone', () {
      final link = _live();
      link.onTransportState(_disconnected, _at(0));
      expect(_firstSecondWith(link, LinkAction.giveUp, to: 60), 45);
    });

    test('the window runs from the first lapse, not the last restart', () {
      final link = _live();
      link.onTransportState(_failed, _at(0));
      expect(_firstSecondWith(link, LinkAction.giveUp, to: 60), 45,
          reason: 'a flapping link must not extend its own reprieve by '
              'restarting');
      expect(link.restartsSpent, greaterThan(5),
          reason: 'and it tried the whole way down');
    });

    test('a flap that recovers resets the window', () {
      final link = _live();
      link.onTransportState(_disconnected, _at(0));
      final gaveUp = _firstSecondWith(link, LinkAction.giveUp, to: 80,
          each: (s) {
        if (s == 10) link.onTransportState(_connected, _at(10));
        if (s == 20) link.onTransportState(_disconnected, _at(20));
      });
      expect(gaveUp, 65,
          reason: '45s into the SECOND lapse, not 45s after the first');
    });

    test('closed is terminal', () {
      final link = _live();
      expect(link.onTransportState(_closed, _at(1)), LinkAction.giveUp);
      expect(link.health, LinkHealth.lost);
    });
  });

  group('both sides may recover the link', () {
    test('the impolite side waits its offset before initiating', () {
      final polite = _live(polite: true);
      final impolite = _live(polite: false);
      polite.onTransportState(_failed, _at(0));
      impolite.onTransportState(_failed, _at(0));

      expect(polite.tick(_at(8)), LinkAction.restartIce);
      expect(impolite.tick(_at(8)), LinkAction.none);
      expect(impolite.tick(_at(11)), LinkAction.restartIce,
          reason: 'the polite peer may be the machine whose network died, so '
              'the impolite one has to be eligible too');
    });
  });

  group('quality never masks the transport', () {
    test('a degraded sample only moves healthy to unstable', () {
      final link = _live();
      link.setQualityDegraded(true);
      expect(link.health, LinkHealth.unstable);
    });

    test('a lapse outranks a clean quality sample', () {
      final link = _live();
      link.setQualityDegraded(false);
      link.onTransportState(_disconnected, _at(1));
      expect(link.health, LinkHealth.reconnecting);
    });

    test('quality alone never asks anyone to give up', () {
      final link = _live();
      link.setQualityDegraded(true);
      expect(link.tick(_at(120)), LinkAction.none);
    });
  });

  group('share legs run the same ladder on a shorter fuse', () {
    test('20 second window', () {
      final link = LinkResilience(
          isPolite: true, config: LinkResilienceConfig.share);
      link.onTransportState(_connected, _t0);
      link.onTransportState(_disconnected, _at(0));
      expect(_firstSecondWith(link, LinkAction.giveUp, to: 40), 20);
    });
  });

  group('relay presence corroborates, it does not decide', () {
    test('a peer vanishing from the relay does NOT end a healthy call', () {
      final link = _live();
      link.notePeerPresenceLost(_at(1));
      expect(_firstSecondWith(link, LinkAction.giveUp, to: 120), isNull,
          reason: 'relay presence and the media path are different sockets; a '
              'WS reconnect says nothing about a live TURN path');
      expect(link.health, LinkHealth.healthy);
    });

    test('but a peer who is gone from BOTH resolves in seconds', () {
      final link = _live();
      link.onTransportState(_disconnected, _at(0));
      link.notePeerPresenceLost(_at(0));
      expect(_firstSecondWith(link, LinkAction.giveUp, to: 60), 10,
          reason: 'two independent sources agree, so there is nothing left to '
              'out-wait');
    });

    test('corroboration can only ever shorten the wait', () {
      final link = _live();
      link.onTransportState(_disconnected, _at(0));
      link.notePeerPresenceLost(_at(40));
      expect(_firstSecondWith(link, LinkAction.giveUp, to: 90), 45,
          reason: 'never later than the full window');
    });

    test('the peer coming back withdraws it', () {
      final link = _live();
      link.onTransportState(_disconnected, _at(0));
      link.notePeerPresenceLost(_at(0));
      link.notePeerPresenceReturned();
      expect(_firstSecondWith(link, LinkAction.giveUp, to: 60), 45);
    });
  });

  group('a call that never connected fails fast', () {
    test('failed on a link that was never up gives up at once', () {
      final link = LinkResilience(isPolite: true);
      expect(link.onTransportState(_failed, _at(1)), LinkAction.giveUp,
          reason: 'that is a call-establishment failure, not a lapse, and the '
              'lane already has a ring timeout for it');
    });

    test('once it HAS been up, the same state earns the full ladder', () {
      final link = _live();
      expect(link.onTransportState(_failed, _at(0)), LinkAction.none,
          reason: 'held, not abandoned');
      expect(_firstSecondWith(link, LinkAction.restartIce, to: 20), 8,
          reason: 'and it does eventually get its restart');
    });
  });

  group('remainingGrace', () {
    test('is null when healthy and counts down while lapsing', () {
      final link = _live();
      expect(link.remainingGrace(_at(1)), isNull);
      link.onTransportState(_disconnected, _at(10));
      expect(link.remainingGrace(_at(25)), const Duration(seconds: 30));
      expect(link.remainingGrace(_at(100)), Duration.zero);
    });
  });
}
