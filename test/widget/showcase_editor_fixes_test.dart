import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  Future<List<showcase_api.ShowcaseAsset>> crateApiShowcaseGetShowcaseAssets({
    required String peerId,
  }) async => const [];

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ShowcaseBlock _text(String title, [String body = 'Some words']) =>
    ShowcaseBlock(
      type: ShowcaseBlockType.text,
      data: {'title': title, 'body': body},
    );

const _art = ShowcaseBlock(
  type: ShowcaseBlockType.artwork,
  data: {'image': 'abc', 'caption': 'Night drive'},
);

const _favourite = ShowcaseBlock(
  type: ShowcaseBlockType.favoriteGame,
  data: {'name': 'Outer Wilds', 'year': 2019, 'blurb': 'Twenty-two minutes'},
);

class _Profiles extends ProfileNotifier {
  _Profiles(this.board);
  final ShowcaseBoard board;
  String? saved;

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

  @override
  Future<void> updateShowcaseBoard(
    String peerId,
    String encoded, {
    List<showcase_api.ShowcaseAsset>? assets,
  }) async {
    saved = encoded;
  }
}

Future<_Profiles> _open(
  WidgetTester tester,
  ShowcaseBoard board, {
  Size size = const Size(1440, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final profiles = _Profiles(board);
  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(
        extra: [profileProvider.overrideWith(() => profiles)],
      ),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              return Center(
                child: TextButton(
                  onPressed: () => showShowcaseEditorDialog(context, ref),
                  child: const Text('open'),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return profiles;
}

void main() {
  setUpAll(() => RustLib.initMock(api: _Api()));

  testWidgets('both boards are open while editing, empty ones say so', (
    tester,
  ) async {
    await _open(tester, const ShowcaseBoard());
    expect(find.text('Left board'), findsOneWidget);
    expect(find.text('Right board'), findsOneWidget);
    expect(find.text('Nothing on this side yet'), findsNWidgets(2));
    expect(find.text('People see your showcase when you save'), findsOneWidget);
  });

  testWidgets('dragging a block down one place moves it one place', (
    tester,
  ) async {
    await _open(
      tester,
      ShowcaseBoard(left: [_text('Alpha'), _text('Bravo'), _text('Charlie')]),
    );
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

    expect(
      y('Bravo'),
      lessThan(y('Alpha')),
      reason: 'one place down lands one place down, not back where it was',
    );
    expect(y('Alpha'), lessThan(y('Charlie')));
  });

  testWidgets('a caption edits in place and Escape keeps the old one', (
    tester,
  ) async {
    await _open(tester, const ShowcaseBoard(left: [_art]));
    await tester.tap(find.bySemanticsLabel('Edit caption'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter saves it, Escape keeps the old caption'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(EditableText), 'Something else');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Night drive'), findsOneWidget);
    expect(
      find.text('Left board'),
      findsOneWidget,
      reason: 'Escape in a field cancels the edit, not the whole editor',
    );
  });

  testWidgets('a favourite game line counts toward 128', (tester) async {
    await _open(tester, const ShowcaseBoard(right: [_favourite]));
    await tester.tap(find.bySemanticsLabel('Edit favourite game'));
    await tester.pumpAndSettle();
    expect(find.text('Why this game?'), findsOneWidget);
    expect(find.text('Optional · 18/128'), findsOneWidget);
  });

  testWidgets('leaving with changes asks first', (tester) async {
    await _open(tester, ShowcaseBoard(left: [_text('Alpha')]));
    await tester.tap(find.bySemanticsLabel('Remove block'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Discard your changes?'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('Left board'), findsNothing);
  });

  testWidgets('a full side says so instead of offering Add block', (
    tester,
  ) async {
    await _open(
      tester,
      ShowcaseBoard(left: [for (var i = 0; i < 4; i++) _text('T$i')]),
    );
    expect(
      find.text('A side holds 4 blocks. Remove one to add another.'),
      findsOneWidget,
    );
    expect(find.text('Add block'), findsOneWidget);
  });

  testWidgets('over the size limit, Save waits and the footer says why', (
    tester,
  ) async {
    // Legacy inline game details are the one way past the cap.
    final heavy = ShowcaseBlock(
      type: ShowcaseBlockType.favoriteGame,
      data: {
        'name': 'Outer Wilds',
        'details': {'summary': 'x' * (ShowcaseBoard.maxEncodedLength + 10)},
      },
    );
    final profiles = await _open(tester, ShowcaseBoard(left: [heavy]));
    expect(
      find.text(
        'Your showcase is over its size limit. Shorten a text block to save.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(profiles.saved, isNull);
  });

  testWidgets('saving ships the edited board and closes', (tester) async {
    final profiles = await _open(tester, ShowcaseBoard(left: [_text('Alpha')]));
    await tester.tap(find.bySemanticsLabel('Remove block'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(profiles.saved, '');
    expect(find.text('Left board'), findsNothing);
    // Lets the success toast time out.
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('a wide artwork sits across both boards with Top and Bottom', (
    tester,
  ) async {
    await _open(
      tester,
      ShowcaseBoard(left: [_text('Alpha')], wide: _art, wideAtTop: false),
    );
    expect(find.text('Top'), findsOneWidget);
    expect(find.text('Bottom'), findsOneWidget);
    final artY = tester.getCenter(find.text('Night drive')).dy;
    expect(artY, greaterThan(tester.getCenter(find.text('Alpha')).dy));
  });

  testWidgets('on a phone the editor is a page with actions behind More', (
    tester,
  ) async {
    await _open(
      tester,
      ShowcaseBoard(left: [_text('Alpha')]),
      size: const Size(390, 844),
    );
    expect(find.text('Edit showcase'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Alpha options'));
    await tester.pumpAndSettle();
    expect(find.text('Move to the right board'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
  });
}
