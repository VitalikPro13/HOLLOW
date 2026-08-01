import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/settings/category_bulk_access_dialog.dart';

/// Category bulk-access dialog contract: Apply stays disabled until a
/// section is toggled on, tier picks land in the result payload, and the
/// Custom chip routes through the access-label picker.
void main() {
  const serverId = 'srv-1';

  Future<CategoryBulkAccess? Function()> pumpDialog(
      WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    CategoryBulkAccess? result;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverLabelsProvider(serverId).overrideWith((ref) async => const [
                crdt_api.LabelFfi(
                    labelId: 'vip',
                    name: 'VIP',
                    color: '#ff00ff',
                    access: true),
              ]),
        ],
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showCategoryBulkAccessDialog(
                    context,
                    serverId: serverId,
                    categoryName: 'STAFF',
                    channelCount: 3,
                  );
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
    return () => result;
  }

  testWidgets('Apply is disabled until a section is enabled', (tester) async {
    await pumpDialog(tester);
    expect(find.text('Apply to 3'), findsOneWidget);
    // Nothing toggled → tapping Apply does nothing (button disabled).
    await tester.tap(find.text('Apply to 3'));
    await tester.pumpAndSettle();
    expect(find.text('Apply to 3'), findsOneWidget, reason: 'dialog stays open');
  });

  testWidgets('tier pick lands in the result payload', (tester) async {
    final result = await pumpDialog(tester);
    // Enable "Change visibility" via its toggle.
    await tester.tap(find.byType(HollowToggle).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Admin+'));
    await tester.pump();
    await tester.tap(find.text('Apply to 3'));
    await tester.pumpAndSettle();
    final r = result();
    expect(r, isNotNull);
    expect(r!.changeVisibility, isTrue);
    expect(r.visMode, 'admin');
    expect(r.visLabels, isEmpty);
    expect(r.changePosting, isFalse);
  });

  testWidgets('Custom routes through the label picker', (tester) async {
    final result = await pumpDialog(tester);
    await tester.tap(find.byType(HollowToggle).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom…'));
    await tester.pumpAndSettle();
    // The access-label picker opened; select VIP and apply it.
    await tester.tap(find.text('VIP'));
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    // Back in the bulk dialog, the chip now shows the count.
    expect(find.text('1 labels'), findsOneWidget);
    await tester.tap(find.text('Apply to 3'));
    await tester.pumpAndSettle();
    final r = result();
    expect(r, isNotNull);
    expect(r!.visLabels, ['vip']);
  });
}
