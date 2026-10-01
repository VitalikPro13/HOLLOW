import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/deleted_messages_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/message_row.dart';

import '../helpers/test_app.dart';

/// Pre-seeded set of deleted ids, so the test needs no store.
class _Deleted extends DeletedMessagesNotifier {
  final Set<String> seed;
  _Deleted(this.seed);
  @override
  Set<String> build() => seed;
}

Widget _row({String? replyToText, VoidCallback? onReplyTap, Set<String> deleted = const {}}) =>
    ProviderScope(
      overrides: hollowTestOverrides(extra: [
        deletedMessagesProvider.overrideWith(() => _Deleted(deleted)),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: MessageRow(
            messageId: 'm2',
            senderId: 'peer-b',
            isMe: false,
            text: 'still here',
            timestamp: DateTime(2026, 10, 1, 12),
            editedAt: null,
            replyToMid: 'm1',
            reactions: const {},
            fileAttachment: null,
            linkPreview: null,
            showHeader: true,
            replyToSenderName: replyToText == null ? null : 'Ada',
            replyToText: replyToText,
            onReplyTap: onReplyTap,
          ),
        ),
      ),
    );

void main() {
  testWidgets('a reply to a deleted original says so, faded, and does nothing on tap',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(_row(onReplyTap: () => taps++, deleted: {'m1'}));
    await tester.pump();

    final quote = find.text('Deleted message');
    expect(quote, findsOneWidget);
    final context = tester.element(quote);
    expect(tester.widget<Text>(quote).style?.color,
        HollowTheme.of(context).textTertiary);

    await tester.tap(quote);
    await tester.pump();
    expect(taps, 0);
  });

  testWidgets('a reply whose original is only out of the loaded page shows no quote',
      (tester) async {
    await tester.pumpWidget(_row());
    await tester.pump();
    expect(find.text('Deleted message'), findsNothing);
  });

  testWidgets('a reply whose original is loaded quotes it and jumps on tap',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
        _row(replyToText: 'the original', onReplyTap: () => taps++, deleted: {'m1'}));
    await tester.pump();
    expect(find.text('Deleted message'), findsNothing);
    await tester.tap(find.text('the original'));
    await tester.pump();
    expect(taps, 1);
  });
}
