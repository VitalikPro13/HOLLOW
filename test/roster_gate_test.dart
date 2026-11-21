import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/core/services/phrase_restore.dart';
import 'package:hollow/src/rust/api/roster.dart' as roster_api;

roster_api.RosterStatus _status({
  bool member = false,
  bool backupWait = true,
  int? joinsAtMs,
  String? removedBy,
  bool hasRoster = true,
  String? tooEarly,
  int? tooEarlyLostSinceMs,
  int? droppedByRecoveryAtMs,
}) =>
    roster_api.RosterStatus(
      member: member,
      protected: true,
      backupWait: backupWait,
      joinsAtMs: joinsAtMs,
      removedBy: removedBy,
      tooEarly: tooEarly,
      tooEarlyLostSinceMs: tooEarlyLostSinceMs,
      droppedByRecoveryAtMs: droppedByRecoveryAtMs,
      devices: hasRoster
          ? [
              const roster_api.RosterDevice(devicePeerId: 'owner', state: 'member', thisDevice: false, added: []),
              roster_api.RosterDevice(
                devicePeerId: 'me',
                state: removedBy != null ? 'removed' : member ? 'member' : 'pending',
                thisDevice: true,
                added: const [],
              ),
            ]
          : const [],
    );

/// What the full-screen lock shows comes from the roster alone: a device the roster
/// does not count never reaches the app, whatever the phrase chose about waiting.
void main() {
  test('a member and an identity with no roster yet are not locked', () {
    expect(RosterGate.fromStatus(_status(member: true)).kind, RosterGateKind.none);
    expect(RosterGate.fromStatus(_status(hasRoster: false)).kind, RosterGateKind.none);
  });

  test('a restored backup waits with a date while the wait is on', () {
    final gate = RosterGate.fromStatus(_status(joinsAtMs: 1800000000000));
    expect(gate.kind, RosterGateKind.pending);
    expect(gate.joinsAt, DateTime.fromMillisecondsSinceEpoch(1800000000000));
  });

  test('a restored backup still waits, with no date, once the phrase turns the wait off', () {
    final gate = RosterGate.fromStatus(_status(backupWait: false));
    expect(gate.kind, RosterGateKind.pending);
    expect(gate.joinsAt, isNull);
  });

  test('a removed device shows the removal', () {
    final gate = RosterGate.fromStatus(_status(removedBy: 'owner'));
    expect(gate.kind, RosterGateKind.removed);
    expect(gate.removedBy, 'owner');
  });

  // HOL-SEC-218: a phrase restore the base outdated types the phrase again,
  // and makes the same statement it made.
  test('an admission that came too early asks for the phrase again', () {
    final gate = RosterGate.fromStatus(_status(tooEarly: 'admit'));
    expect(gate.kind, RosterGateKind.tooEarly);
    expect(gate.tooEarly, PhraseRestoreBranch.admit);
  });

  test('a recovery that came too early keeps the moment it judged from', () {
    final gate = RosterGate.fromStatus(
        _status(tooEarly: 'recover', tooEarlyLostSinceMs: 1700000000000));
    expect(gate.kind, RosterGateKind.tooEarly);
    expect(gate.tooEarly, PhraseRestoreBranch.recover);
    expect(gate.lostSinceMs, 1700000000000);
  });

  test('a removal outranks a too-early restore, and a member is never locked', () {
    expect(RosterGate.fromStatus(_status(removedBy: 'owner', tooEarly: 'admit')).kind,
        RosterGateKind.removed);
    expect(RosterGate.fromStatus(_status(member: true, tooEarly: 'admit')).kind,
        RosterGateKind.none);
  });

  test('an unknown too-early kind waits as before', () {
    expect(RosterGate.fromStatus(_status(tooEarly: 'later')).kind,
        RosterGateKind.pending);
  });

  test('a device a recovery left out waits, and says since when', () {
    final gate = RosterGate.fromStatus(_status(droppedByRecoveryAtMs: 1750000000000));
    expect(gate.kind, RosterGateKind.pending);
    expect(gate.droppedAt, DateTime.fromMillisecondsSinceEpoch(1750000000000));
  });
}
