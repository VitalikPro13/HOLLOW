// The accent mark on your own messages, and where it is allowed to sit.
//
// It has moved twice, both times because it collided with something:
//
//  1. `Border(right:)` put it 4px from the chat scrollbar's thumb once the
//     rail took the gutter — a teal rule beside a grey rule, reading as one
//     confused double line.
//  2. `Border(left:)` welded it to the divider between the chat and the
//     channel list, so it read as a highlight on the PANEL. A [Border] also
//     INSETS its own Container's child, so it shifted every own-message
//     avatar 2px right of everyone else's and a column of avatars wobbled.
//
// It is a positioned pill now ([OwnMessageMarker]), floating in the chat's
// left margin. What is worth guarding is not its prettiness but the two
// collisions: it must stay OFF the pane edge, and it must cost the row no
// layout at all.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/chat/message_bubble.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';

import '../helpers/test_app.dart';

const _kOther = 'other_peer_bbbbbbbbbbbbbbbb';

class _MockAvatarNotifier extends AvatarNotifier {
  @override
  Map<String, Uint8List> build() => {};

  @override
  Future<void> loadAvatar(String peerId) async {}
}

/// Two grouped-header rows: one of ours, one of theirs.
Future<void> _pumpPair(WidgetTester tester) async {
  tester.view.physicalSize = const Size(700, 400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(
        extra: [avatarProvider.overrideWith(_MockAvatarNotifier.new)],
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MessageBubble(
                message: ChatMessage(text: 'theirs', isMe: false),
                peerId: _kOther,
                showHeader: true,
              ),
              MessageBubble(
                message: ChatMessage(text: 'mine', isMe: true),
                peerId: _kOther,
                showHeader: true,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('only your own messages are marked', (tester) async {
    await _pumpPair(tester);
    expect(find.byType(OwnMessageMarker), findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('mine'),
          matching: find.byType(MessageBubble),
        ),
        matching: find.byType(OwnMessageMarker),
      ),
      findsOneWidget,
      reason: 'and it is the OWN one that carries it',
    );
  });

  testWidgets('the mark floats clear of the pane edge', (tester) async {
    await _pumpPair(tester);
    final row = tester.getRect(find.byType(OwnMessageMarker));
    // `.last`: the row's own DecoratedBoxes (the avatar fallback) come first
    // in the tree, the pill is the Stack's second child.
    final pill = tester.getRect(find.descendant(
      of: find.byType(OwnMessageMarker),
      matching: find.byType(DecoratedBox),
    ).last);

    expect(pill.left - row.left, kOwnMessageBarInset,
        reason: 'flush against the edge it welds itself to the divider with '
            'the channel list and reads as a highlight on the panel rather '
            'than a mark on the message');
    expect(pill.width, kOwnMessageBarWidth);
    expect(pill.height, row.height,
        reason: 'full height: a grouped run of your messages is several rows '
            'whose boxes touch, and any vertical inset breaks the run into a '
            'dashed line');
  });

  testWidgets('the mark costs the row no layout', (tester) async {
    await _pumpPair(tester);

    final avatars = find.byType(HollowAvatar);
    expect(avatars, findsNWidgets(2));

    expect(tester.getTopLeft(avatars.at(1)).dx, tester.getTopLeft(avatars.at(0)).dx,
        reason: 'a Border INSETS its Container\'s child, so the old bar '
            'shifted every own-message avatar 2px right of everyone else\'s '
            'and a column of avatars visibly wobbled. A positioned pill '
            'cannot: it is painted over the row, not inside its box.');
    expect(tester.getTopLeft(find.text('mine')).dx,
        tester.getTopLeft(find.text('theirs')).dx,
        reason: 'the text column lines up for the same reason');
  });
}
