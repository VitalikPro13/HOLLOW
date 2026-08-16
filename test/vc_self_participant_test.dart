import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';

/// Voice-channel participant sets are keyed by the ROUTABLE DEVICE id, and a
/// fresh install ALWAYS has device != master (keys.rs mints a distinct device
/// key). Panes that asked "am I in this set?" with the MASTER id therefore got
/// `false` while sitting in the channel, inserted a second self entry on top of
/// the device entry already there, and rendered the local user TWICE — the
/// mobile VC "You x2" report.
///
/// `selfParticipantId` is the one answer to that question, and it hands back
/// the id form THE SET uses, so every downstream compare (isMe, isSelf, muted,
/// speaking, canKick) keys off the same string.
VoiceChannelState _stateWith(Set<String> participants) => VoiceChannelState(
      participants: {
        'srv': {'vc': participants},
      },
    );

void main() {
  const master = 'MASTER_abc';
  const device = 'DEVICE_xyz';

  group('VoiceChannelState.selfParticipantId', () {
    test('finds us by DEVICE id when master and device differ', () {
      final state = _stateWith({device, 'remote_1'});
      expect(
        state.selfParticipantId('srv', 'vc', master: master, device: device),
        device,
        reason: 'a master-only membership test is what listed "You" twice',
      );
    });

    test('finds us by master id (single-device / legacy self entry)', () {
      final state = _stateWith({master, 'remote_1'});
      expect(
        state.selfParticipantId('srv', 'vc', master: master, device: device),
        master,
      );
    });

    test('null when we are genuinely not in the channel', () {
      final state = _stateWith({'remote_1', 'remote_2'});
      expect(
        state.selfParticipantId('srv', 'vc', master: master, device: device),
        isNull,
        reason: 'only then may a pane insert the local user itself',
      );
    });

    test('null for a channel with no participants at all', () {
      final state = _stateWith({});
      expect(
        state.selfParticipantId('srv', 'vc', master: master, device: device),
        isNull,
      );
      expect(
        state.selfParticipantId('other', 'nope', master: master, device: device),
        isNull,
      );
    });

    test('an unresolved device id (null/empty) never matches a remote peer', () {
      final state = _stateWith({device, 'remote_1'});
      expect(
        state.selfParticipantId('srv', 'vc', master: master),
        isNull,
        reason: 'device id not loaded yet — do not guess',
      );
      expect(
        state.selfParticipantId('srv', 'vc', master: master, device: ''),
        isNull,
        reason: 'an empty device id must not match an empty-string entry',
      );
    });

    test('the pane rule: exactly one self row in the rendered list', () {
      final state = _stateWith({device, 'remote_1'});
      final rendered =
          state.getParticipants('srv', 'vc').toList(growable: true);
      final self =
          state.selfParticipantId('srv', 'vc', master: master, device: device);
      if (self == null) rendered.insert(0, master);

      expect(rendered.where((p) => p == self || p == master).length, 1,
          reason: 'one row for us, never two');
      expect(rendered.length, 2);
    });
  });
}
