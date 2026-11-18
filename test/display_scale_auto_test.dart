import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/display_scale_provider.dart';

/// Tablet auto-scale (0.14.1): until the user moves the Interface slider, a
/// tablet's default interface scale follows its screen, so a 13" iPad does not
/// lay out like a giant phone. Any slider choice overrides it.
void main() {
  group('autoUiScaleFor', () {
    test('phones stay at 100%', () {
      // iPhone SE, iPhone 16 Pro Max, a 411 dp Android phone.
      for (final side in [320.0, 375.0, 440.0, 411.0]) {
        expect(autoUiScaleFor(side, mobileForm: true), 1.0, reason: '$side');
      }
    });

    test('tablets follow the shortest side', () {
      // iPad mini (744 pt), 11" iPad (834 pt), 13" iPad (1024 pt).
      expect(autoUiScaleFor(744, mobileForm: true), closeTo(1.08, 0.01));
      expect(autoUiScaleFor(834, mobileForm: true), closeTo(1.21, 0.01));
      expect(autoUiScaleFor(1024, mobileForm: true), closeTo(1.48, 0.01));
    });

    test('clamped to 1.0..1.5', () {
      expect(autoUiScaleFor(2000, mobileForm: true), 1.5);
      expect(autoUiScaleFor(0, mobileForm: true), 1.0);
    });

    test('desktop never auto-scales', () {
      expect(autoUiScaleFor(1440, mobileForm: false), 1.0);
    });
  });

  group('UiScaleNotifier', () {
    late Map<String, String> store;

    ProviderContainer containerFor({required double side}) {
      final c = ProviderContainer(overrides: [
        uiScaleProvider.overrideWith(() => UiScaleNotifier(
              screenShortestSide: () => side,
              mobileForm: true,
              readSetting: (k) async => store[k],
              writeSetting: (k, v) async => store[k] = v,
            )),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    setUp(() => store = {});

    test('never set: the default follows the screen', () async {
      final c = containerFor(side: 1024);
      expect(c.read(uiScaleProvider), closeTo(1.48, 0.01),
          reason: 'the welcome screen, before load, already fits the tablet');
      await c.read(uiScaleProvider.notifier).load();
      expect(c.read(uiScaleProvider), closeTo(1.48, 0.01));
      expect(c.read(uiScaleProvider.notifier).isChosen, isFalse);
    });

    test('a saved choice overrides the screen', () async {
      store['ui_scale'] = '1.00';
      final c = containerFor(side: 1024);
      await c.read(uiScaleProvider.notifier).load();
      expect(c.read(uiScaleProvider), 1.0);
      expect(c.read(uiScaleProvider.notifier).isChosen, isTrue);
    });

    test('moving the slider persists, even onto the screen default', () async {
      final c = containerFor(side: 834);
      final n = c.read(uiScaleProvider.notifier);
      await n.load();
      await n.setScale(n.defaultScale);
      expect(n.isChosen, isTrue);
      expect(store['ui_scale'], isNotEmpty);

      await n.setScale(1.0);
      expect(c.read(uiScaleProvider), 1.0);
      expect(store['ui_scale'], '1.00');
    });

    test('reset returns to following the screen', () async {
      store['ui_scale'] = '1.00';
      final c = containerFor(side: 834);
      final n = c.read(uiScaleProvider.notifier);
      await n.load();
      await n.reset();
      expect(n.isChosen, isFalse);
      expect(c.read(uiScaleProvider), closeTo(1.21, 0.01));
      expect(store['ui_scale'], isEmpty, reason: 'an empty value reads as unset');

      // And a fresh launch keeps following the screen.
      final c2 = containerFor(side: 834);
      await c2.read(uiScaleProvider.notifier).load();
      expect(c2.read(uiScaleProvider.notifier).isChosen, isFalse);
    });
  });
}
