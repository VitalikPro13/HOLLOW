import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/overlay_look.dart';
import 'package:hollow/src/ui/settings/stream_overlay/overlay_look_draft.dart';

/// Look edits save themselves (#97 polish): a burst is one save, one save runs
/// at a time, an edit made during a save is kept and saved after it, and
/// closing the editor still saves what is pending.
void main() {
  late OverlayLookDraft draft;
  late List<OverlayLook> saved;
  late List<Completer<OverlayLook>> pending;
  late OverlayLookAutosave autosave;

  OverlayLookAutosave make({bool hold = false}) => OverlayLookAutosave(
        draft: draft,
        save: (look) {
          saved.add(look);
          if (!hold) return Future.value(look.copyWith(stamp: look.stamp + 1));
          final c = Completer<OverlayLook>();
          pending.add(c);
          return c.future;
        },
      );

  setUp(() {
    draft = OverlayLookDraft.own(OverlayLook(effects: OverlayEffects.defaults));
    saved = [];
    pending = [];
  });

  void talking(String v) => draft.setEffects((e) => e.copyWith(talking: v));

  testWidgets('a burst of finished edits is one save', (tester) async {
    autosave = make();
    for (final v in ['pop', 'glow', 'shake']) {
      talking(v);
      autosave.commit();
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(saved, isEmpty);
    await tester.pump(const Duration(milliseconds: 300));
    expect(saved.length, 1);
    expect(saved.single.effects.talking, 'shake');
    expect(draft.dirty, isFalse);
  });

  testWidgets('an edit during a save is kept and saved after it',
      (tester) async {
    autosave = make(hold: true);
    talking('pop');
    autosave.commit();
    await tester.pump(const Duration(milliseconds: 300));
    expect(saved.length, 1);

    talking('glow');
    autosave.commit();
    await tester.pump(const Duration(milliseconds: 300));
    expect(saved.length, 1, reason: 'one save at a time');

    pending.first.complete(saved.first);
    await tester.pump();
    expect(draft.draft.effects.talking, 'glow', reason: 'the newer edit stays');
    expect(draft.dirty, isTrue);
    await tester.pump();
    expect(saved.length, 2);
    expect(saved.last.effects.talking, 'glow');
    pending.last.complete(saved.last);
    await tester.pump();
    expect(draft.dirty, isFalse);
  });

  testWidgets('closing saves what is pending and leaves the draft alone',
      (tester) async {
    autosave = make();
    talking('pop');
    autosave.commit();
    autosave.close();
    draft.dispose();
    await tester.pump(const Duration(milliseconds: 400));
    expect(saved.length, 1);
    expect(saved.single.effects.talking, 'pop');
  });

  testWidgets('closing with nothing new saves nothing', (tester) async {
    autosave = make();
    autosave.close();
    await tester.pump(const Duration(milliseconds: 400));
    expect(saved, isEmpty);
  });
}
