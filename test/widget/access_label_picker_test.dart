import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/settings/access_label_picker.dart';

/// Access-label picker contract:
///  - only ACCESS labels are offered (cosmetic tags can't gate a channel),
///  - toggling chips and pressing Apply returns the selected id set,
///  - clearing every chip returns an EMPTY set (= back to tier mode), and
///  - with no access labels at all the empty state points at the Labels tab.
void main() {
  const serverId = 'srv-1';
  const labels = [
    crdt_api.LabelFfi(
        labelId: 'vip', name: 'VIP', color: '#ff00ff', access: true),
    crdt_api.LabelFfi(
        labelId: 'staff', name: 'Staff', color: '#00ff00', access: true),
    crdt_api.LabelFfi(
        labelId: 'fun', name: 'Fun', color: '#0000ff', access: false),
  ];

  Future<Set<String>?Function()> pumpPicker(
    WidgetTester tester, {
    List<crdt_api.LabelFfi> serverLabels = labels,
    Set<String> initial = const {},
  }) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    Set<String>? result;
    var completed = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverLabelsProvider(serverId)
              .overrideWith((ref) async => serverLabels),
        ],
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showAccessLabelPicker(
                    context: context,
                    serverId: serverId,
                    title: 'Custom visibility',
                    initial: initial,
                  );
                  completed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => completed ? result : throw StateError('dialog still open');
  }

  testWidgets('offers only access labels', (tester) async {
    await pumpPicker(tester);
    expect(find.text('VIP'), findsOneWidget);
    expect(find.text('Staff'), findsOneWidget);
    expect(find.text('Fun'), findsNothing);
  });

  testWidgets('apply returns the toggled selection', (tester) async {
    final result = await pumpPicker(tester);
    await tester.tap(find.text('VIP'));
    await tester.pump();
    await tester.tap(find.text('Staff'));
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(result(), {'vip', 'staff'});
  });

  testWidgets('clearing every chip returns an empty set (tier mode)',
      (tester) async {
    final result = await pumpPicker(tester, initial: {'vip'});
    await tester.tap(find.text('VIP'));
    await tester.pump();
    // The picker warns that the channel falls back to tier access.
    expect(find.textContaining('tier-based access'), findsOneWidget);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(result(), isEmpty);
  });

  testWidgets('cancel returns null', (tester) async {
    final result = await pumpPicker(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result(), isNull);
  });

  testWidgets('empty state points to the Labels tab', (tester) async {
    await pumpPicker(tester, serverLabels: const [
      crdt_api.LabelFfi(
          labelId: 'fun', name: 'Fun', color: '#0000ff', access: false),
    ]);
    expect(find.textContaining('No access labels yet'), findsOneWidget);
  });
}
