// A server whose notification level was never set notifies on mentions only and
// still counts every post unread; an explicit level keeps today's behaviour; a
// message whose hint already counted it is counted and notified once, and a live
// mention keeps its Home preview.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/event_provider.dart';
import 'package:hollow/src/core/providers/mention_preview_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/system_notification_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart';
import 'package:hollow/src/rust/api/network.dart';
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/test_app.dart';

class _Api implements RustLibApi {
  @override
  Future<List<ChannelFfi>> crateApiCrdtGetServerChannels(
          {required String serverId}) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _Notes extends SystemNotificationNotifier {
  final texts = <String>[];

  @override
  Future<void> notifyChannel({
    required String serverId,
    required String channelId,
    required String fromPeerId,
    required String text,
    required bool isMention,
    String? channelName,
    String? messageId,
  }) async =>
      texts.add(text);
}

class _Levels extends NotificationSettingsNotifier {
  _Levels(this.initial);
  final NotificationSettingsState initial;

  @override
  NotificationSettingsState build() => initial;
}

NetworkEvent _post(String server, String mid, String text) =>
    NetworkEvent.channelMessageReceived(
        serverId: server,
        channelId: 'ch',
        fromPeer: 'someone',
        text: text,
        timestamp: 1,
        messageId: mid,
        replyToMid: '',
        replyToOwn: false,
        duplicate: false,
        isOwn: false);

void main() {
  setUpAll(() => RustLib.initMock(api: _Api()));

  late _Notes notes;

  Future<ProviderContainer> pump(WidgetTester tester) async {
    notes = _Notes();
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: [
        systemNotificationProvider.overrideWith(() => notes),
        notificationSettingsProvider.overrideWith(() => _Levels(
              const NotificationSettingsState(serverLevels: {
                'all': NotificationLevel.all,
                'mentions': NotificationLevel.mentions,
              }),
            )),
      ]),
      child: const MaterialApp(home: SizedBox()),
    ));
    return ProviderScope.containerOf(tester.element(find.byType(SizedBox)));
  }

  int unread(ProviderContainer c, String server) =>
      c.read(unreadProvider).channelUnreadCounts['$server:ch'] ?? 0;

  testWidgets('a server never set counts every post but notifies on mentions only',
      (tester) async {
    final c = await pump(tester);
    final events = c.read(eventStreamProvider.notifier);
    events.debugDispatch(_post('unset', 'm1', 'plain post'));
    events.debugDispatch(_post('unset', 'm2', '@everyone look'));
    await tester.pump();
    expect(unread(c, 'unset'), 2, reason: 'badges as before');
    expect(notes.texts, ['@everyone look'], reason: 'no toast for a plain post');
  });

  testWidgets('an explicit "All messages" notifies every post', (tester) async {
    final c = await pump(tester);
    final events = c.read(eventStreamProvider.notifier);
    events.debugDispatch(_post('all', 'a1', 'plain post'));
    await tester.pump();
    expect(unread(c, 'all'), 1);
    expect(notes.texts, ['plain post']);
  });

  testWidgets('an explicit "Mentions only" keeps mentions-only badges',
      (tester) async {
    final c = await pump(tester);
    final events = c.read(eventStreamProvider.notifier);
    events.debugDispatch(_post('mentions', 'n1', 'plain post'));
    events.debugDispatch(_post('mentions', 'n2', '@everyone look'));
    await tester.pump();
    expect(unread(c, 'mentions'), 1);
    expect(notes.texts, ['@everyone look']);
  });

  testWidgets('a mention whose live hint won the race still notifies, counted once',
      (tester) async {
    final c = await pump(tester);
    final events = c.read(eventStreamProvider.notifier);
    events.debugDispatch(const NetworkEvent.channelNotificationHint(
        serverId: 'unset',
        channelId: 'ch',
        fromPeer: 'someone',
        messageId: 'r1',
        hasEveryone: true,
        mentionedNames: [],
        isReplyToOwn: false));
    events.debugDispatch(_post('unset', 'r1', '@everyone look'));
    await tester.pump();
    expect(unread(c, 'unset'), 1, reason: 'the hint counted it already');
    expect(notes.texts, ['@everyone look'],
        reason: 'the hint never notifies, so the live post must');
    expect(c.read(mentionPreviewProvider)['unset:ch']?.text, '@everyone look',
        reason: 'the hint has no text, so the live post records the Home preview');
  });

  testWidgets('a message its hint counted long ago is counted and notified once',
      (tester) async {
    final c = await pump(tester);
    final events = c.read(eventStreamProvider.notifier);
    events.hintLiveWindow = Duration.zero;
    events.debugDispatch(const NetworkEvent.channelNotificationHint(
        serverId: 'all',
        channelId: 'ch',
        fromPeer: 'someone',
        messageId: 'h1',
        hasEveryone: false,
        mentionedNames: [],
        isReplyToOwn: false));
    events.debugDispatch(_post('all', 'h1', 'late body'));
    await tester.pump();
    expect(unread(c, 'all'), 1, reason: 'the hint counted it already');
    expect(notes.texts, isEmpty, reason: 'no second count means no late toast');
  });

  test('a stored level reads back as chosen; absent or "default" is never set', () {
    expect(NotificationSettingsNotifier.parseStoredServerLevel('all'),
        NotificationLevel.all,
        reason: 'an existing explicit "All messages" survives the upgrade');
    expect(NotificationSettingsNotifier.parseStoredServerLevel('mentions'),
        NotificationLevel.mentions);
    expect(NotificationSettingsNotifier.parseStoredServerLevel('nothing'),
        NotificationLevel.nothing);
    expect(NotificationSettingsNotifier.parseStoredServerLevel(null), isNull);
    expect(NotificationSettingsNotifier.parseStoredServerLevel('default'), isNull);
  });
}
