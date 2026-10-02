import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/rust/api/roster.dart' as roster_api;

roster_api.RosterStatus _status({
  bool member = false,
  bool backupWait = true,
  int? joinsAtMs,
  String? removedBy,
  bool hasRoster = true,
}) =>
    roster_api.RosterStatus(
      member: member,
      protected: true,
      backupWait: backupWait,
      joinsAtMs: joinsAtMs,
      removedBy: removedBy,
      devices: hasRoster
          ? [
              const roster_api.RosterDevice(devicePeerId: 'owner', state: 'member', thisDevice: false),
              roster_api.RosterDevice(
                devicePeerId: 'me',
                state: removedBy != null ? 'removed' : member ? 'member' : 'pending',
                thisDevice: true,
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
}
