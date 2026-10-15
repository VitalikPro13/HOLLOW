import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/overlay_look.dart';
import 'package:hollow/src/core/providers/overlay_settings_provider.dart';
import 'package:hollow/src/core/services/overlay_mic.dart';
import 'package:hollow/src/rust/api/overlay.dart' hide overlayImageBytes;
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/fake_overlay_api.dart';

final _a = 'a' * 64;
final _b = 'b' * 64;

/// The look manifest (plan 16.2) and the layout (16.4) as Dart reads and
/// writes them, and the per-profile settings they persist through.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = FakeOverlayApi();
  setUpAll(() => RustLib.initMock(api: api));

  group('look', () {
    test('a canonical shared look round-trips exactly', () {
      final canonical = '{"v":1,"stamp":1760000000000,"states":{"idle":"$_a",'
          '"talking":"$_b","muted":"","deafened":"","blink":"","loud":""},'
          '"effects":{"talking":"shake","scale_with_voice":false,"idle":"dim",'
          '"transition":"instant","hold_ms":300,"blink_every_s":7,'
          '"loud_threshold":0.8,"mirror":true,"shadow":"outline"}}';
      final look = OverlayLook.fromJson(canonical);
      expect(look.stamp, 1760000000000);
      expect(look.hashOf(OverlayLookState.idle), _a);
      expect(look.hashOf(OverlayLookState.talking), _b);
      expect(look.hashOf(OverlayLookState.loud), '');
      expect(look.effects.talking, 'shake');
      expect(look.effects.scaleWithVoice, false);
      expect(look.effects.blinkEverySec, 7);
      expect(look.effects.loudThreshold, 0.8);
      expect(look.effects.mirror, true);
      expect(look.effects.shadow, 'outline');
      expect(jsonDecode(look.toJson()), jsonDecode(canonical));
      expect(OverlayLook.fromJson(look.toJson()), look);
      expect(look.hashes, [_a, _b]);
    });

    test('unknown enum values take the default; numbers are clamped', () {
      final look = OverlayLook.fromJson(jsonEncode({
        'effects': {
          'talking': 'explode',
          'idle': 'sepia',
          'transition': 'wipe',
          'shadow': 3,
          'mirror': 'yes',
          'hold_ms': 9000,
          'blink_every_s': 1,
          'loud_threshold': 0.2,
        }
      }));
      final e = look.effects;
      expect(e.talking, 'bounce');
      expect(e.idle, 'none');
      expect(e.transition, 'crossfade');
      expect(e.shadow, 'none');
      expect(e.mirror, false);
      expect(e.holdMs, 600);
      expect(e.blinkEverySec, 2);
      expect(e.loudThreshold, 0.5);
      final high = OverlayLook.fromJson(
          '{"effects":{"hold_ms":-5,"blink_every_s":99,"loud_threshold":7}}');
      expect(high.effects.holdMs, 0);
      expect(high.effects.blinkEverySec, 12);
      expect(high.effects.loudThreshold, 0.95);
      final odd = OverlayLook.fromJson('{"effects":{"loud_threshold":0.8333}}');
      expect(odd.effects.loudThreshold, 0.83);
    });

    test('every enum value Rust accepts survives', () {
      for (final v in OverlayEffects.talkingChoices) {
        expect(OverlayEffects.fromMap({'talking': v}).talking, v);
      }
      for (final v in OverlayEffects.idleChoices) {
        expect(OverlayEffects.fromMap({'idle': v}).idle, v);
      }
      for (final v in OverlayEffects.transitionChoices) {
        expect(OverlayEffects.fromMap({'transition': v}).transition, v);
      }
      for (final v in OverlayEffects.shadowChoices) {
        expect(OverlayEffects.fromMap({'shadow': v}).shadow, v);
      }
    });

    test('a state that is not a hash refuses the look', () {
      for (final bad in ['"nothex"', '"${'A' * 64}"', '"${'a' * 63}"', '7']) {
        expect(() => OverlayLook.fromJson('{"states":{"loud":$bad}}'),
            throwsFormatException);
      }
      expect(() => OverlayLook.fromJson('[]'), throwsFormatException);
      expect(() => OverlayLook.fromJson('{"states":[]}'), throwsFormatException);
    });

    test('a LOCAL look keeps absent effect keys absent ("not overridden")', () {
      final local = OverlayLook.fromJson(
          '{"states":{"talking":"$_b"},"effects":{"idle":"dim"}}');
      expect(local.effects.idle, 'dim');
      expect(local.effects.talking, isNull);
      expect(local.effects.holdMs, isNull);
      final out = jsonDecode(local.toJson()) as Map<String, dynamic>;
      expect(out['effects'], {'idle': 'dim'});
      expect(out['states']['idle'], '');
      expect(out['states']['talking'], _b);
      // Clearing an override removes the key, it never writes a default.
      final cleared = local.copyWith(effects: local.effects.without(['idle']));
      expect(jsonDecode(cleared.toJson())['effects'], isEmpty);
      expect(cleared.withState(OverlayLookState.talking, '').isEmpty, isTrue);
      // A set override is written.
      final set = local.copyWith(effects: local.effects.copyWith(holdMs: 400));
      expect(jsonDecode(set.toJson())['effects'], {'idle': 'dim', 'hold_ms': 400});
    });

    test('filled() puts the manifest defaults under what is set', () {
      final e = const OverlayEffects(idle: 'grayscale').filled();
      expect(e.idle, 'grayscale');
      expect(e.talking, 'bounce');
      expect(e.scaleWithVoice, true);
      expect(e.holdMs, 250);
      expect(e.blinkEverySec, 5);
      expect(e.loudThreshold, 0.75);
      expect(OverlayLook.empty().isEmpty, isTrue);
    });

    test('a person reads Rust\'s rows, and the source chip follows them', () {
      final eff = '{"v":1,"stamp":3,"states":{"idle":"$_a"},"effects":{}}';
      final avatar = OverlayPerson.fromFfi(OverlayPersonFfi(
          master: 'm1', slot: 2, field: 'show', effectiveLookJson: eff));
      expect(avatar.slot, 2);
      expect(avatar.source, OverlayLookSource.avatar);
      expect(avatar.effectiveJson, eff);
      final theirs = OverlayPerson.fromFfi(OverlayPersonFfi(
          master: 'm1',
          slot: 2,
          field: 'share',
          theirLookJson: eff,
          localLookJson: '{"states":{},"effects":{}}',
          effectiveLookJson: eff));
      expect(theirs.source, OverlayLookSource.theirs);
      final mine = OverlayPerson.fromFfi(OverlayPersonFfi(
          master: 'm1',
          slot: 2,
          field: 'share',
          theirLookJson: eff,
          localLookJson: '{"effects":{"mirror":true}}',
          effectiveLookJson: eff));
      expect(mine.source, OverlayLookSource.mine);
      final broken = OverlayPerson.fromFfi(const OverlayPersonFfi(
          master: 'm1', slot: 2, field: 'show', effectiveLookJson: 'nope'));
      expect(broken.theirs, isNull);
      expect(broken.effective.effects, OverlayEffects.defaults);
    });
  });

  group('layout', () {
    test('round-trips and clamps like Rust', () {
      final l = OverlayLayout(
          direction: 'grid', size: 200, names: 'plain', onlyTalking: true);
      expect(OverlayLayout.decode(l.encode()), l);
      final bad = OverlayLayout.fromJson({
        'direction': 'spiral',
        'align': 'middle',
        'size': 9000,
        'gap': -3,
        'names': 'huge',
        'self_when_inactive': 'ghost',
        'defaults': {'talking': 'glow'},
      });
      expect(bad.direction, 'row');
      expect(bad.align, 'center');
      expect(bad.size, 512);
      expect(bad.gap, 0);
      expect(bad.names, 'pill');
      expect(bad.selfWhenInactive, 'idle');
      expect(bad.defaults.talking, 'glow');
      expect(bad.defaults.idle, 'dim', reason: 'unset defaults keep ours');
      expect(bad.defaults.holdMs, 250);
      expect(OverlayLayout.decode('not json'), OverlayLayout());
      expect(OverlayLayout.decode(null).size, 160);
    });

    test('the default matches plan 16.4', () {
      final j = OverlayLayout().toJson();
      expect(j['direction'], 'row');
      expect(j['align'], 'center');
      expect(j['size'], 160);
      expect(j['gap'], 12);
      expect(j['names'], 'pill');
      expect(j['only_talking'], false);
      expect(j['only_added'], false);
      expect(j['self_when_inactive'], 'idle');
      expect((j['defaults'] as Map)['talking'], 'bounce');
      expect((j['defaults'] as Map)['idle'], 'dim');
    });
  });

  group('persistence (per-profile app settings)', () {
    test('the layout survives a restart', () async {
      api.settings.clear();
      final c1 = ProviderContainer();
      await c1
          .read(overlayLayoutProvider.notifier)
          .update(OverlayLayout(direction: 'column', gap: 30));
      c1.dispose();
      expect(api.settings['overlay_layout'], isNotNull);

      final c2 = ProviderContainer();
      expect(c2.read(overlayLayoutProvider).direction, 'row',
          reason: 'nothing loads before the bootstrap asks');
      await c2.read(overlayLayoutProvider.notifier).load();
      expect(c2.read(overlayLayoutProvider).direction, 'column');
      expect(c2.read(overlayLayoutProvider).gap, 30);
      c2.dispose();
    });

    test('the listen threshold survives a restart and reaches the mic', () async {
      api.settings.clear();
      final mic = OverlayMic(log: (_) {});
      debugOverlayMic = mic;
      final c1 = ProviderContainer();
      await c1.read(overlayListenSettingsProvider.notifier).setThresholdDb(-52);
      expect(mic.thresholdDb, -52);
      // Clamped to the slider's range.
      await c1.read(overlayListenSettingsProvider.notifier).setThresholdDb(-200);
      expect(c1.read(overlayListenSettingsProvider).thresholdDb,
          kOverlayListenThresholdMinDb);
      await c1.read(overlayListenSettingsProvider.notifier).setThresholdDb(-38);
      c1.dispose();

      final mic2 = OverlayMic(log: (_) {});
      debugOverlayMic = mic2;
      final c2 = ProviderContainer();
      await c2.read(overlayListenSettingsProvider.notifier).load();
      expect(c2.read(overlayListenSettingsProvider).thresholdDb, -38);
      expect(mic2.thresholdDb, -38);
      c2.dispose();
    });

    test('"show my idle look" is the layout\'s self_when_inactive', () async {
      api.settings.clear();
      final c = ProviderContainer();
      expect(c.read(overlayListenSettingsProvider).showIdleWhenInactive, true);
      await c
          .read(overlayListenSettingsProvider.notifier)
          .setShowIdleWhenInactive(false);
      expect(c.read(overlayLayoutProvider).selfWhenInactive, 'hidden');
      expect(c.read(overlayListenSettingsProvider).showIdleWhenInactive, false);
      expect(OverlayLayout.decode(api.settings['overlay_layout'])
          .selfWhenInactive, 'hidden');
      c.dispose();
    });
  });

  group('image bytes', () {
    test('previews read the overlay table, never the emote rail', () async {
      api.calls.clear();
      expect(await overlayImageBytes(_a), isNotNull);
      expect(api.calls, ['overlay_bytes($_a)']);
    });

    test('a hash of the wrong shape asks nothing', () async {
      api.calls.clear();
      expect(await overlayImageBytes('A' * 64), isNull);
      expect(await overlayImageBytes('a' * 63), isNull);
      expect(api.calls, isEmpty);
    });
  });
}
