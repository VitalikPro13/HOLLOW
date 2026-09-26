import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/profile_identity_column.dart';
import 'package:hollow/src/ui/components/showcase_blocks.dart';
import 'package:hollow/src/ui/dialogs/profile_dialog.dart';

import '../helpers/test_app.dart';

const _peer = 'peer_profile_redesign_0001';

ShowcaseBlock _text(String title) => ShowcaseBlock(
  type: ShowcaseBlockType.text,
  data: {'title': title, 'body': 'x'},
);

ShowcaseBlock _art() =>
    ShowcaseBlock(type: ShowcaseBlockType.artwork, data: {'image': 'a' * 64});

class _Profiles extends ProfileNotifier {
  @override
  Map<String, storage_api.UserProfile> build() => {
    _peer: storage_api.UserProfile(
      peerId: _peer,
      displayName: 'Mira',
      status: 'Painting frames tonight',
      aboutMe: 'Night shifts.',
      updatedAt: 0,
      twitchUsername: '',
      showcaseBoard: '',
      avatarFrame: '',
      avatarAnim: '',
      bannerAnim: '',
      supportCreds: '',
    ),
  };
}

class _Friends extends FriendsNotifier {
  @override
  Map<String, FriendInfo> build() => {
    _peer: FriendInfo(
      peerId: _peer,
      status: 'accepted',
      direction: '',
      requestedAt: 0,
      updatedAt: 0,
    ),
  };
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(
        extra: [
          profileProvider.overrideWith(_Profiles.new),
          friendsProvider.overrideWith(_Friends.new),
        ],
      ),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('the showcase pane', () {
    test(
      'takes two columns only when both sides or a wide artwork fill them',
      () {
        expect(
          ShowcaseBoardView.columnsFor(ShowcaseBoard(left: [_text('a')])),
          1,
        );
        expect(
          ShowcaseBoardView.columnsFor(
            ShowcaseBoard(left: [_text('a')], right: [_text('b')]),
          ),
          2,
        );
        expect(ShowcaseBoardView.columnsFor(ShowcaseBoard(wide: _art())), 2);
      },
    );

    test('a wide artwork is exactly both columns and the gap between', () {
      expect(kShowcaseWideWidth, kShowcaseColumnWidth * 2 + kShowcaseGap);
      expect(
        showcasePaneWidth(2) - showcasePaneWidth(1),
        kShowcaseColumnWidth + kShowcaseGap,
      );
    });
  });

  group('the profile column', () {
    testWidgets('keeps Block and Report behind More, never at rest', (
      tester,
    ) async {
      await _pump(
        tester,
        ProfileIdentityColumn(
          peerId: _peer,
          density: ProfileCardDensity.full,
          width: kProfileColumnWidth,
          dismissHost: () {},
        ),
      );
      expect(find.text('Message'), findsOneWidget);
      expect(find.text('Block'), findsNothing);
      expect(find.text('Report'), findsNothing);

      await tester.tap(find.bySemanticsLabel('More'));
      await tester.pumpAndSettle();
      expect(find.text('Block'), findsOneWidget);
      expect(find.text('Report'), findsOneWidget);
      expect(find.text('Copy user ID'), findsOneWidget);
    });

    testWidgets('shows no raw peer id and says Friend in words', (
      tester,
    ) async {
      await _pump(
        tester,
        ProfileIdentityColumn(
          peerId: _peer,
          density: ProfileCardDensity.full,
          width: kProfileColumnWidth,
          dismissHost: () {},
        ),
      );
      expect(find.textContaining('peer_profile'), findsNothing);
      expect(find.text('Friend'), findsOneWidget);
    });

    testWidgets('the banner is 2.5:1 at every density', (tester) async {
      for (final (density, width) in [
        (ProfileCardDensity.full, kProfileColumnWidth),
        (ProfileCardDensity.compact, kProfileCompactWidth),
      ]) {
        // The host gives the column its width, as the dialog and card do.
        await _pump(
          tester,
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: ProfileIdentityColumn(
                peerId: _peer,
                density: density,
                width: width,
                dismissHost: () {},
                showActions: false,
              ),
            ),
          ),
        );
        final stack = find
            .descendant(
              of: find.byType(ProfileIdentityColumn),
              matching: find.byType(Stack),
            )
            .first;
        expect(tester.getSize(stack), Size(width, width / 2.5));
      }
    });
  });
}
