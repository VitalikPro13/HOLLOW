import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/server_folder_popup.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Folder popup and rename: the rename is the shared name prompt (Enter
/// renames, "Rename" not "Save"), and taking a server out of the folder is
/// only on hover, never an X resting on every server.
void main() {
  const folder = FolderStripItem(
      id: 'f1', name: 'Games', serverIds: ['s1', 's2']);

  late BuildContext host;
  late WidgetRef hostRef;
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            host = context;
            hostRef = ref;
            container = ProviderScope.containerOf(context, listen: false);
            return const SizedBox.expand();
          }),
        ),
      ),
    ));
    container.read(serverListProvider.notifier).state = {
      's1': const ServerInfo(serverId: 's1', name: 'Alpha'),
      's2': const ServerInfo(serverId: 's2', name: 'Beta'),
    };
    container.read(serverStripLayoutProvider.notifier).state = [folder];
  }

  testWidgets('rename is the shared prompt and Enter renames', (tester) async {
    await pump(tester);
    showFolderRenameDialog(context: host, ref: hostRef, folder: folder);
    await tester.pumpAndSettle();
    expect(find.text('Rename folder'), findsOneWidget);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Save'), findsNothing);
    await tester.enterText(find.byType(TextField), 'Arcade');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Rename folder'), findsNothing);
    final renamed =
        container.read(serverStripLayoutProvider).first as FolderStripItem;
    expect(renamed.name, 'Arcade');
  });

  testWidgets('the take-out X shows only on hover', (tester) async {
    await pump(tester);
    showServerFolderPopup(
      context: host,
      ref: hostRef,
      folder: folder,
      anchor: const Offset(200, 200),
      isDock: false,
      onServerSelected: (_) {},
    );
    await tester.pumpAndSettle();
    final remove = find.bySemanticsLabel('Take Alpha out of the folder');
    final handle = tester.ensureSemantics();
    // The X's own fade: the one wrapping its pressable.
    double xOpacity() => tester
        .widget<AnimatedOpacity>(find
            .ancestor(
                of: find.byIcon(LucideIcons.x),
                matching: find.byWidgetPredicate((w) =>
                    w is AnimatedOpacity && w.child is HollowPressable))
            .first)
        .opacity;
    expect(xOpacity(), 0);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('Alpha')));
    await tester.pumpAndSettle();
    expect(xOpacity(), 1);
    expect(remove, findsOneWidget);
    handle.dispose();
  });
}
