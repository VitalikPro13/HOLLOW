/// Links someone else chose (chat text, link cards, the news and status feeds)
/// reach the OS only as https (http where a person posted it), and a hollow://
/// link stays in the app (C-DIST-01). Opening a news post fetches nothing
/// (C-DIST-02).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/news_provider.dart';
import 'package:hollow/src/core/providers/status_provider.dart';
import 'package:hollow/src/core/services/untrusted_link.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/message_text_parser.dart';
import 'package:hollow/src/ui/dialogs/news_post_dialog.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class _FixedStatus extends StatusNotifier {
  _FixedStatus(this.fixed);
  final StatusState fixed;

  @override
  StatusState build() => fixed;
}

const _hostile = [
  'file:///C:/Windows/System32/calc.exe',
  r'\\attacker.example\share\payload.exe',
  '//attacker.example/share',
  'javascript:alert(1)',
  'data:text/html,<script>alert(1)</script>',
  'ms-msdt:/id PCWDiagnostic',
  'search-ms:query=x',
  'ms-settings:privacy',
  'steam://run/1',
  'mailto:a@b.example',
  'https:///nohost',
  'https://evil.example\\@good.example',
  'https://evil.example/a b',
  'https://evil.example/\u0000',
  '',
  '   ',
];

void main() {
  final launched = <String>[];
  final routedInApp = <String>[];
  final osLaunches = <String>[];

  setUp(() {
    launched.clear();
    routedInApp.clear();
    osLaunches.clear();
    untrustedLinkLauncher = (uri) async {
      launched.add(uri.toString());
      return true;
    };
    untrustedLinkAppHandler = routedInApp.add;
    // Anything that slips past the helper to url_launcher lands here.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            (call) async {
      osLaunches.add((call.arguments as Map)['url'] as String);
      return true;
    });
  });

  group('classifyUntrustedUrl', () {
    test('https goes to the browser', () {
      final d = classifyUntrustedUrl('https://example.com/a?b=c#d');
      expect(d.route, UntrustedLinkRoute.browser);
      expect(d.uri!.host, 'example.com');
      expect(classifyUntrustedUrl('  HTTPS://Example.com  ').route,
          UntrustedLinkRoute.browser);
    });

    test('http only where the caller allows it', () {
      expect(classifyUntrustedUrl('http://example.com').route,
          UntrustedLinkRoute.refused);
      expect(classifyUntrustedUrl('http://example.com', allowHttp: true).route,
          UntrustedLinkRoute.browser);
    });

    test('hollow:// stays in the app', () {
      expect(classifyUntrustedUrl('hollow://redeem/ABCD').route,
          UntrustedLinkRoute.app);
      expect(classifyUntrustedUrl('hollow://join?server=x').route,
          UntrustedLinkRoute.app);
    });

    test('every other scheme, UNC path and malformed string is refused', () {
      for (final raw in _hostile) {
        expect(classifyUntrustedUrl(raw, allowHttp: true).route,
            UntrustedLinkRoute.refused,
            reason: raw);
      }
    });
  });

  group('openUntrustedUrl', () {
    test('a web link reaches the launcher, nothing else does', () async {
      expect(await openUntrustedUrl('https://example.com/x'), isTrue);
      for (final raw in _hostile) {
        expect(await openUntrustedUrl(raw, allowHttp: true), isFalse,
            reason: raw);
      }
      expect(launched, ['https://example.com/x']);
      expect(routedInApp, isEmpty);
    });

    test('a hollow:// link is routed in process, never to the OS', () async {
      expect(await openUntrustedUrl(' hollow://redeem/ABCD '), isTrue);
      expect(routedInApp, ['hollow://redeem/ABCD']);
      expect(launched, isEmpty);
    });
  });

  Widget app(Widget child, {List<Override> overrides = const []}) =>
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(body: Center(child: child)),
        ),
      );

  group('chat text', () {
    testWidgets('a hollow:// link opens in the app, not through the OS',
        (tester) async {
      await tester.pumpWidget(app(const MessageText('hollow://redeem/ABCD')));
      await tester.tap(find.text('hollow://redeem/ABCD'));
      await tester.pump();
      expect(routedInApp, ['hollow://redeem/ABCD']);
      expect(launched, isEmpty);
      expect(osLaunches, isEmpty);
    });

    testWidgets('an http link a person posted still opens', (tester) async {
      await tester.pumpWidget(app(const MessageText('http://example.com/x')));
      await tester.tap(find.text('http://example.com/x'));
      await tester.pump();
      expect(launched, ['http://example.com/x']);
    });
  });

  group('status feed', () {
    Future<void> pumpStatus(WidgetTester tester, String link) async {
      final status = SystemStatus(
        id: 'x',
        level: StatusLevel.warning,
        title: 'Relay maintenance',
        message: 'Details inside',
        link: link,
      );
      await tester.pumpWidget(app(const HomeStatusCard(), overrides: [
        statusProvider.overrideWith(() =>
            _FixedStatus(StatusState(status: status, hasFetched: true))),
      ]));
      await tester.tap(find.text('Relay maintenance'));
      await tester.pump();
    }

    testWidgets('a link the helper refuses is not offered', (tester) async {
      await pumpStatus(tester, 'file:///C:/Windows/System32/calc.exe');
      expect(find.text('Details'), findsNothing);
    });

    testWidgets('an https link opens through the helper', (tester) async {
      await pumpStatus(tester, 'https://anonlisten.com/status');
      await tester.tap(find.text('Details'));
      await tester.pump();
      expect(launched, ['https://anonlisten.com/status']);
      expect(osLaunches, isEmpty);
    });

    testWidgets('a hollow:// link goes to the in-app confirm, never the OS',
        (tester) async {
      await pumpStatus(tester, 'hollow://redeem/ABCD');
      await tester.tap(find.text('Details'));
      await tester.pump();
      expect(routedInApp, ['hollow://redeem/ABCD']);
      expect(osLaunches, isEmpty);
    });

    Future<void> pumpBanner(WidgetTester tester, String link) async {
      await tester.pumpWidget(app(const SystemStatusBanner(), overrides: [
        statusProvider.overrideWith(() => _FixedStatus(StatusState(
            status: SystemStatus(
              id: 'x',
              level: StatusLevel.warning,
              title: 'Relay maintenance',
              message: 'Details inside',
              link: link,
            ),
            hasFetched: true))),
      ]));
      await tester.tap(find.byIcon(LucideIcons.chevronDown));
      await tester.pumpAndSettle();
    }

    testWidgets('the shell banner does not offer a UNC link', (tester) async {
      await pumpBanner(tester, r'\\attacker.example\share\x.exe');
      expect(find.text('Details inside'), findsOneWidget);
      expect(find.text('Details'), findsNothing);
    });

    testWidgets('the shell banner opens an https link through the helper',
        (tester) async {
      await pumpBanner(tester, 'https://anonlisten.com/status');
      await tester.tap(find.text('Details'));
      await tester.pump();
      expect(launched, ['https://anonlisten.com/status']);
      expect(osLaunches, isEmpty);
    });
  });

  group('news post', () {
    testWidgets('opening a post fetches no image and shows its alt text',
        (tester) async {
      await tester.pumpWidget(app(Builder(
        builder: (context) => TextButton(
          onPressed: () => showNewsPostDialog(
              context,
              const NewsPost(
                  id: 'n',
                  date: 'today',
                  title: 'News',
                  body: 'Hi ![tracking pixel](https://tracker.example/p.gif) '
                      '[local](file:///C:/x) [site](https://anonlisten.com)')),
          child: const Text('open'),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('tracking pixel'), findsOneWidget);
    });

    testWidgets('a post link opens only through the helper', (tester) async {
      await tester.pumpWidget(app(const NewsPostBody(
          markdown: '[local](file:///C:/x) and [site](https://anonlisten.com)')));
      final body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
      body.onTapLink!('local', 'file:///C:/x', '');
      body.onTapLink!('pool', 'hollow://recovery/abc', '');
      body.onTapLink!('site', 'https://anonlisten.com', '');
      await tester.pump();
      expect(launched, ['https://anonlisten.com']);
      expect(routedInApp, ['hollow://recovery/abc']);
      expect(osLaunches, isEmpty);
    });
  });
}
