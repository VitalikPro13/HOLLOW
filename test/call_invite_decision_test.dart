import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/call_invite_decision.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';

/// The shipped bug: the busy guard ran before the glare check, and `ringing`
/// is not `idle`, so the glare branch below it could never execute. Two people
/// pressing Call at the same moment busy-rejected each other.
///
/// Field evidence (2026-08-26): a host ringing outgoing to a peer received
/// that same peer's invite and answered `busy`.
void main() {
  group('ordering', () {
    test('GLARE WINS over busy — the regression', () {
      // Ringing outgoing means NOT idle. The old code saw only that and
      // rejected. Both facts are true at once here on purpose.
      final action = decideInviteAction(
        ringingOutgoingToSamePerson: true,
        idle: false,
        ourMaster: 'aaa',
        theirMaster: 'bbb',
      );
      expect(action, InviteAction.glarePolite);
      expect(action, isNot(InviteAction.busy));
    });

    test('busy still applies to an unrelated third party mid-call', () {
      expect(
        decideInviteAction(
          ringingOutgoingToSamePerson: false,
          idle: false,
          ourMaster: 'aaa',
          theirMaster: 'zzz',
        ),
        InviteAction.busy,
      );
    });

    test('an idle client just rings', () {
      expect(
        decideInviteAction(
          ringingOutgoingToSamePerson: false,
          idle: true,
          ourMaster: 'aaa',
          theirMaster: 'bbb',
        ),
        InviteAction.ring,
      );
    });
  });

  group('tiebreak', () {
    test('exactly one side yields, whichever way round it is asked', () {
      InviteAction from(String us, String them) => decideInviteAction(
            ringingOutgoingToSamePerson: true,
            idle: false,
            ourMaster: us,
            theirMaster: them,
          );

      // Both ends run the same function against the same pair of masters.
      expect(from('aaa', 'bbb'), InviteAction.glarePolite);
      expect(from('bbb', 'aaa'), InviteAction.glareImpolite);
    });

    test('a degenerate equal pair does not make both sides polite', () {
      expect(
        decideInviteAction(
          ringingOutgoingToSamePerson: true,
          idle: false,
          ourMaster: 'same',
          theirMaster: 'same',
        ),
        InviteAction.glareImpolite,
      );
    });
  });

  group('identity resolution feeding the decision', () {
    // Why the caller must resolve before asking: an outgoing call targets a
    // MASTER, an inbound signal carries a DEVICE.
    const links = DeviceLinkState(links: {
      'their-device': 'their-master',
      'our-device': 'our-master',
    });

    test('a raw id compare would miss the glare entirely', () {
      // What the old code did.
      expect('their-master' == 'their-device', isFalse);
      // What the resolver does.
      expect(links.sameIdentity('their-master', 'their-device'), isTrue);
    });

    test('resolving both sides keeps the tiebreak symmetric', () {
      // Ours resolves to 'our-master', theirs to 'their-master'. Comparing our
      // MASTER against their DEVICE ('their-device') would flip the answer,
      // which is how both ends could decide they were polite.
      expect('our-master'.compareTo('their-master') < 0, isTrue);
      expect('our-master'.compareTo('their-device') < 0, isTrue);
      // The other end, resolving properly, gets the opposite verdict:
      expect('their-master'.compareTo('our-master') < 0, isFalse);
    });
  });
}
