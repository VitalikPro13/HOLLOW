import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/showcase.dart' as showcase_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/dialogs/showcase_editor.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

class _Api implements RustLibApi {
  @override
  Future<List<showcase_api.ShowcaseAsset>> crateApiShowcaseGetShowcaseAssets(
          {required String peerId}) async =>
      const [];

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ShowcaseBlock _text(String title) =>
    ShowcaseBlock(type: ShowcaseBlockType.text, data: {'title': title});

class _Profiles extends ProfileNotifier {
  _Profiles(this.board);
  final ShowcaseBoard board;

  @override
  Map<String, storage_api.UserProfile> build() => {
        kLocalPeerId: storage_api.UserProfile(
          peerId: kLocalPeerId,
          displayName: 'Mira',
          status: '',
          aboutMe: '',
          updatedAt: 0,
          twitchUsername: '',
          showcaseBoard: board.encode(),
          avatarFrame: '',
          avatarAnim: '',
          bannerAnim: '',
          supportCreds: '',
        ),
      };
}

Future<void> _open(WidgetTester tester, ShowcaseBoard board) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(
        extra: [profileProvider.overrideWith(() => _Profiles(board))]),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(body: Consumer(builder: (context, ref, _) {
        return Center(
          child: TextButton(
            onPressed: () => showShowcaseEditorDialog(context, ref),
            child: const Text('open'),
          ),
        );
      })),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RustLib.initMock(api: _Api()));

  testWidgets('dragging a block down one place moves it one place',
      (tester) async {
    await _open(
        tester,
        ShowcaseBoard(left: [_text('Alpha'), _text('Bravo'), _text('Charlie')]));
    double y(String t) => tester.getCenter(find.text(t)).dy;
    final step = y('Bravo') - y('Alpha');

    final grip = find.byType(ReorderableDragStartListener).first;
    final gesture = await tester.startGesture(tester.getCenter(grip));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(Offset(0, step * 1.2 / 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(y('Bravo'), lessThan(y('Alpha')),
        reason: 'one place down lands one place down, not back where it was');
    expect(y('Alpha'), lessThan(y('Charlie')));
  });

  testWidgets('cancelling a caption edit keeps the caption', (tester) async {
    await _open(
      tester,
      const ShowcaseBoard(left: [
        ShowcaseBlock(
          type: ShowcaseBlockType.artwork,
          data: {'image': 'abc', 'caption': 'Night drive'},
        ),
      ]),
    );
    expect(find.textContaining('Night drive'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Edit block'));
    await tester.pumpAndSettle();
    expect(find.text('Skip'), findsNothing,
        reason: 'an edit offers Cancel, never an erasing Skip');
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Night drive'), findsOneWidget);
  });
}
