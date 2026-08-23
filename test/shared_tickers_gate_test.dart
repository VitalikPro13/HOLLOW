import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/shared_tickers.dart';

void main() {
  group('GatedNotifier', () {
    test('reports the gate opening on the FIRST listener only', () {
      var opens = 0;
      final n = GatedNotifier(() => opens++);
      expect(n.isWatched, isFalse);

      void a() {}
      void b() {}
      n.addListener(a);
      expect(n.isWatched, isTrue);
      expect(opens, 1);

      // A second listener is not a state change — the clock is already running.
      n.addListener(b);
      expect(opens, 1, reason: 'gate was already open');
    });

    test('reports the gate closing only when the LAST listener leaves', () {
      var changes = 0;
      final n = GatedNotifier(() => changes++);
      void a() {}
      void b() {}
      n.addListener(a);
      n.addListener(b);
      expect(changes, 1);

      n.removeListener(a);
      expect(n.isWatched, isTrue);
      expect(changes, 1, reason: 'one listener still watching');

      n.removeListener(b);
      expect(n.isWatched, isFalse);
      expect(changes, 2);
    });

    test('removing a listener that was never added does not close the gate',
        () {
      var changes = 0;
      final n = GatedNotifier(() => changes++);
      void a() {}
      void never() {}
      n.addListener(a);
      expect(changes, 1);

      n.removeListener(never);
      expect(n.isWatched, isTrue);
      expect(changes, 1);
    });

    test('reopens after closing, so a screen can be left and returned to', () {
      final seen = <bool>[];
      late final GatedNotifier n;
      n = GatedNotifier(() => seen.add(n.isWatched));
      void a() {}
      n.addListener(a);
      n.removeListener(a);
      n.addListener(a);
      expect(seen, [true, false, true]);
    });

    test('still behaves as a plain ValueNotifier', () {
      final n = GatedNotifier(() {});
      final got = <double>[];
      n.addListener(() => got.add(n.value));
      n.value = 0.5;
      n.value = 0.5; // same value: ValueNotifier does not re-notify
      n.value = 1.0;
      expect(got, [0.5, 1.0]);
    });
  });
}
