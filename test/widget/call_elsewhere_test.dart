/// One call at a time per identity: while another of our devices is in a call,
/// this one shows the DM's call row locked, says why it cannot start one, and
/// forgets what its siblings were in when its own link drops.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/sibling_call_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/call/dm_call_row.dart';
import 'package:hollow/src/ui/components/call_duration_text.dart';
import 'package:hollow/src/ui/mobile/mobile_minimised_call.dart';

import '../helpers/test_app.dart';

const _friend = 'friend_master';

Future<ProviderContainer> _pump(WidgetTester tester, Widget child) async {
  final container = ProviderContainer(overrides: hollowTestOverrides());
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(body: Column(children: [child])),
    ),
  ));
  return container;
}

void _sibling(ProviderContainer c,
    {String kind = 'call', String peer = _friend, int startedMs = 0, bool active = true}) {
  c.read(siblingCallProvider.notifier).apply(
        device: 'sibling_device',
        active: active,
        kind: kind,
        peer: peer,
        channel: '',
        startedMs: startedMs,
      );
}

void main() {
  for (final (name, widget) in [
    ('desktop', const DmCallRow(peerMaster: _friend) as Widget),
    ('phone', const MobileCallElsewhereBar(peerMaster: _friend)),
  ]) {
    testWidgets('$name: the DM shows the call on another device, locked', (tester) async {
      final c = await _pump(tester, widget);
      expect(find.text('In a call on another device'), findsNothing);

      _sibling(c, startedMs: DateTime.now().millisecondsSinceEpoch - 65000);
      await tester.pump();
      expect(find.text('In a call on another device'), findsOneWidget);
      expect(find.byType(CallDurationText), findsOneWidget, reason: 'the timer runs');
      expect(find.byType(GestureDetector), findsNothing, reason: 'nothing to press');

      _sibling(c, active: false);
      await tester.pump();
      expect(find.text('In a call on another device'), findsNothing);
    });

    testWidgets('$name: a call with someone else or a voice channel leaves this DM alone',
        (tester) async {
      final c = await _pump(tester, widget);
      _sibling(c, peer: 'someone_else');
      await tester.pump();
      expect(find.text('In a call on another device'), findsNothing);
      _sibling(c, kind: 'voice', peer: 'a_server');
      await tester.pump();
      expect(find.text('In a call on another device'), findsNothing);
    });
  }

  test('the reason names what the other device is in', () {
    SiblingCall of(String kind) => SiblingCall(device: 'd', kind: kind, peer: 'p');
    expect(callElsewhereReason(of('call')), "You're in a call on another device");
    expect(callElsewhereReason(of('voice')), "You're in a voice channel on another device");
    expect(callElsewhereReason(of('meeting')), "You're in a meeting on another device");
  });

  test('a dropped relay link forgets what the siblings were in', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    _sibling(c);
    expect(c.read(callElsewhereProvider)?.peer, _friend);
    c.read(siblingCallProvider.notifier).clear();
    expect(c.read(callElsewhereProvider), isNull);
  });
}
