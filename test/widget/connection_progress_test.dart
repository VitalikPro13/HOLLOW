import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/connection_progress.dart';

/// Issue #23: the channel header said "Offline" whenever no other member was
/// online — while the user was connected, synced, and sitting in a voice
/// channel. "Offline" now means OUR link is down and nothing else; an empty
/// room has its own wording.
Future<void> _pumpStage(WidgetTester tester, ConnectionStage stage) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: Center(child: ConnectionProgress(stage: stage)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('alone reads as "Only you", never "Offline"', (tester) async {
    await _pumpStage(tester, ConnectionStage.alone);
    expect(find.text('Only you'), findsOneWidget);
    expect(find.text('Offline'), findsNothing);
  });

  testWidgets('offline still says "Offline"', (tester) async {
    await _pumpStage(tester, ConnectionStage.offline);
    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets('encrypted says "Encrypted"', (tester) async {
    await _pumpStage(tester, ConnectionStage.encrypted);
    expect(find.text('Encrypted'), findsOneWidget);
  });

  testWidgets('custom relay says "Custom Network"', (tester) async {
    await _pumpStage(tester, ConnectionStage.customNetwork);
    expect(find.text('Custom Network'), findsOneWidget);
  });

  testWidgets('every stage renders exactly one label + icon', (tester) async {
    for (final stage in ConnectionStage.values) {
      await _pumpStage(tester, stage);
      expect(find.byType(Icon), findsOneWidget, reason: '$stage');
      expect(find.byType(Text), findsOneWidget, reason: '$stage');
    }
  });
}
