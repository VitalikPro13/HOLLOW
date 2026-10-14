/// Issue #102: "Show link previews" is a reader-side switch. Off hides the
/// web preview cards in every message row (DM and channel, received and own)
/// while the text, the link and Hollow's own invite cards stay; the stored
/// preview is untouched, so switching it back on shows the cards again.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/providers/link_preview_settings_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/channel_message_bubble.dart';
import 'package:hollow/src/ui/chat/hollow_link_card.dart';
import 'package:hollow/src/ui/chat/link_preview_card.dart';
import 'package:hollow/src/ui/chat/message_bubble.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/settings/network_section.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../helpers/test_app.dart';

class _SettingsApi implements RustLibApi {
  final settings = <String, String>{};

  @override
  Future<void> crateApiStorageSaveSetting(
      {required String key, required String value}) async {
    settings[key] = value;
  }

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async =>
      settings[key];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _kUrl = 'https://example.com/thing';

network_api.LinkPreviewRef _preview() => const network_api.LinkPreviewRef(
      url: _kUrl,
      title: 'A Page Title',
      description: 'Some description text',
      domain: 'example.com',
      siteName: 'Example',
    );

Future<ProviderContainer> _pump(WidgetTester tester, Widget row) async {
  tester.view.physicalSize = const Size(900, 700);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(body: SingleChildScrollView(child: row)),
    ),
  ));
  await tester.pump();
  return ProviderScope.containerOf(tester.element(find.byWidget(row)));
}

Widget _dmRow({required bool isMe, String text = 'look $_kUrl'}) =>
    MessageBubble(
      message: ChatMessage(
        text: text,
        isMe: isMe,
        messageId: 'dm-1',
        timestamp: DateTime(2026, 10, 14, 12),
        linkPreview: _preview(),
      ),
      peerId: 'peer-b',
      showHeader: true,
    );

Widget _channelRow({required bool isMe}) => ChannelMessageBubble(
      message: ChannelChatMessage(
        senderId: 'peer-b',
        text: 'look $_kUrl',
        isMe: isMe,
        messageId: 'ch-1',
        timestamp: DateTime(2026, 10, 14, 12),
        linkPreview: _preview(),
      ),
      serverId: 'server-1',
      showHeader: true,
    );

Future<void> _setShown(ProviderContainer c, WidgetTester tester, bool v) async {
  await c.read(showLinkPreviewsProvider.notifier).setEnabled(v);
  await tester.pump();
}

void main() {
  final api = _SettingsApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api.settings.clear();
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  for (final isMe in [false, true]) {
    final who = isMe ? 'own' : 'received';

    testWidgets('a $who DM card shows when on and hides when off',
        (tester) async {
      final c = await _pump(tester, _dmRow(isMe: isMe));
      expect(find.byType(LinkPreviewCard), findsOneWidget);
      expect(find.text('A Page Title'), findsOneWidget);

      await _setShown(c, tester, false);
      expect(find.byType(LinkPreviewCard), findsNothing);
      expect(find.text('A Page Title'), findsNothing);
      expect(find.textContaining(_kUrl, findRichText: true), findsOneWidget,
          reason: 'the message text and its link stay');

      await _setShown(c, tester, true);
      expect(find.byType(LinkPreviewCard), findsOneWidget,
          reason: 'display only: the stored card comes back');
    });

    testWidgets('a $who channel card shows when on and hides when off',
        (tester) async {
      final c = await _pump(tester, _channelRow(isMe: isMe));
      expect(find.byType(LinkPreviewCard), findsOneWidget);

      await _setShown(c, tester, false);
      expect(find.byType(LinkPreviewCard), findsNothing);
      expect(find.textContaining(_kUrl, findRichText: true), findsOneWidget);

      await _setShown(c, tester, true);
      expect(find.byType(LinkPreviewCard), findsOneWidget);
    });
  }

  testWidgets('a Hollow link card stays when web previews are off',
      (tester) async {
    final c = await _pump(
        tester, _dmRow(isMe: false, text: 'join hollow://redeem/ABCD-EFGH'));
    await _setShown(c, tester, false);
    expect(find.byType(LinkPreviewCard), findsNothing);
    expect(find.byType(HollowLinkCard), findsOneWidget);
  });

  group('the setting', () {
    test('is on for anyone who never chose', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(showLinkPreviewsProvider.notifier).loadCached();
      expect(c.read(showLinkPreviewsProvider), isTrue);
    });

    test('persists off and on across a restart', () async {
      final first = ProviderContainer();
      await first.read(showLinkPreviewsProvider.notifier).setEnabled(false);
      first.dispose();

      final second = ProviderContainer();
      addTearDown(second.dispose);
      await second.read(showLinkPreviewsProvider.notifier).loadCached();
      expect(second.read(showLinkPreviewsProvider), isFalse);

      await second.read(showLinkPreviewsProvider.notifier).setEnabled(true);
      final third = ProviderContainer();
      addTearDown(third.dispose);
      await third.read(showLinkPreviewsProvider.notifier).loadCached();
      expect(third.read(showLinkPreviewsProvider), isTrue);
    });

    test('is its own key, apart from the sender-side switch', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(showLinkPreviewsProvider.notifier).setEnabled(false);
      expect(c.read(linkPreviewsEnabledProvider), isTrue,
          reason: 'hiding cards never stops this device fetching its own');
      expect(api.settings.containsKey('link_previews_enabled'), isFalse);
    });

    testWidgets('the settings row flips and saves it', (tester) async {
      final c = await _pump(tester, const ShowLinkPreviewsRow());
      expect(find.text('Show link previews'), findsOneWidget);
      await c.read(linkPreviewsEnabledProvider.notifier).setEnabled(false);
      await tester.pump();
      expect(tester.widget<HollowToggle>(find.byType(HollowToggle)).value,
          isTrue,
          reason: 'the row shows the reader switch, not the sender one');
      await tester.tap(find.byType(HollowToggle));
      await tester.pump();
      expect(c.read(showLinkPreviewsProvider), isFalse);
      expect(api.settings['link_previews_show'], '0');
    });
  });
}
