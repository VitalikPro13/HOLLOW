/// Home's conversation list: Saved messages pinned first, a friend with no
/// messages showing no time (it read "Jan 1, 2000"), and the recovery phrase
/// reminder surviving a hidden checklist.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/home_setup_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/conversation_row.dart';
import 'package:hollow/src/ui/shell/home_inbox.dart';

import '../helpers/test_app.dart';

class _Setup extends HomeSetupNotifier {
  final HomeSetupState seed;
  _Setup(this.seed);
  @override
  HomeSetupState build() => seed;
}

Future<void> _pump(WidgetTester tester, Widget child,
    {HomeSetupState setup = const HomeSetupState(loaded: true)}) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: [
      homeSetupProvider.overrideWith(() => _Setup(setup)),
    ]),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(body: child),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('Saved messages is the first row; empty DMs show no time',
      (tester) async {
    await _pump(
      tester,
      const CustomScrollView(slivers: [HomeConversations(query: '')]),
    );
    final rows = tester
        .widgetList<ConversationRow>(find.byType(ConversationRow))
        .toList();
    expect(rows, isNotEmpty);
    expect(rows.first.title, 'Saved messages');
    for (final row in rows.skip(1)) {
      expect(row.time, isNull,
          reason: '${row.title} has no messages, so no time');
    }
    expect(find.textContaining('2000'), findsNothing);
  });

  testWidgets('the phrase reminder moves to Needs Attention once hidden',
      (tester) async {
    await _pump(
      tester,
      const HomeAttention(),
      setup: const HomeSetupState(loaded: true, hidden: true),
    );
    expect(find.text("Your recovery phrase isn't backed up yet"),
        findsOneWidget);
  });

  testWidgets('a saved phrase needs no reminder', (tester) async {
    await _pump(
      tester,
      const HomeAttention(),
      setup: const HomeSetupState(loaded: true, hidden: true, phraseSaved: true),
    );
    expect(find.text("Your recovery phrase isn't backed up yet"),
        findsNothing);
  });

  testWidgets('while the checklist shows, it carries the phrase step alone',
      (tester) async {
    await _pump(tester, const HomeAttention());
    expect(find.text("Your recovery phrase isn't backed up yet"),
        findsNothing);
  });
}
