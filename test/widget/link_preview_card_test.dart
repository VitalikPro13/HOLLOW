/// Link previews (issue #45): the two card layouts, and the bookkeeping that
/// rescues a preview whose fetch outlived the send that raced it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/chat/link_preview_card.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// 1x1 transparent PNG. The card only asks the decoder for bytes; it does not
/// care that real thumbnails are WebP.
final String _kTinyPngB64 = base64Encode(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

network_api.LinkPreviewRef _preview({
  String? kind,
  String? author,
  String? videoUrl,
  String title = 'A Page Title',
  String description = 'Some description text',
  bool withThumb = true,
}) {
  return network_api.LinkPreviewRef(
    url: 'https://example.com/thing',
    title: title,
    description: description,
    domain: 'example.com',
    siteName: 'Example',
    thumbWebpB64: withThumb ? _kTinyPngB64 : null,
    thumbW: withThumb ? 800 : null,
    thumbH: withThumb ? 450 : null,
    kind: kind,
    author: author,
    videoUrl: videoUrl,
  );
}

Future<void> _pumpCard(
    WidgetTester tester, network_api.LinkPreviewRef preview) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Center(
            child: LinkPreviewCard(preview: preview, messageId: 'mid-1'),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  // Cards that can play inline wrap themselves in a VisibilityDetector, whose
  // default 500ms debounce would be left pending when the test ends. Zero
  // makes it fire synchronously.
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  group('LinkPreviewCard layout', () {
    testWidgets('compact card clips the description and shows the domain',
        (tester) async {
      await _pumpCard(tester, _preview());

      expect(find.text('A Page Title'), findsOneWidget);
      // Header always states where a tap goes, on both layouts.
      expect(find.text('Example · example.com'), findsOneWidget);

      final desc = tester.widget<Text>(find.text('Some description text'));
      expect(desc.maxLines, 3,
          reason: 'a plain page gets the tight 3-line clip');
    });

    testWidgets('large card gives the body room and leads with the author',
        (tester) async {
      await _pumpCard(
        tester,
        _preview(kind: 'large', author: 'Jane Doe (@jane)'),
      );

      expect(find.text('Jane Doe (@jane)'), findsOneWidget);
      // The author IS the heading on a post card, so the scraped title would
      // just repeat it.
      expect(find.text('A Page Title'), findsNothing);
      expect(find.text('Example · example.com'), findsOneWidget);

      final desc = tester.widget<Text>(find.text('Some description text'));
      expect(desc.maxLines, 6,
          reason: 'a post body is the point of the card, not a teaser');
    });

    testWidgets('large card falls back to the title when there is no author',
        (tester) async {
      await _pumpCard(tester, _preview(kind: 'large'));
      expect(find.text('A Page Title'), findsOneWidget);
    });

    testWidgets('a post with no video has no play affordance', (tester) async {
      await _pumpCard(tester, _preview(kind: 'large', author: '@someone'));
      expect(find.byIcon(LucideIcons.play), findsNothing);
      expect(find.byIcon(LucideIcons.externalLink), findsNothing);
    });

    testWidgets('a direct mp4 offers inline play', (tester) async {
      await _pumpCard(
        tester,
        _preview(
          kind: 'large',
          author: '@someone',
          videoUrl: 'https://video.twimg.com/ext_tw_video/1/vid/720x1280/x.mp4',
        ),
      );
      expect(find.byIcon(LucideIcons.play), findsOneWidget);
      expect(find.byIcon(LucideIcons.externalLink), findsNothing);
    });

    testWidgets('a non-direct video offers open-externally instead',
        (tester) async {
      // A watch page has no file to hand a decoder — the badge must say so
      // by shape, not silently do nothing on tap.
      await _pumpCard(
        tester,
        _preview(
          kind: 'large',
          author: '@someone',
          videoUrl: 'https://www.youtube.com/watch?v=abc123',
        ),
      );
      expect(find.byIcon(LucideIcons.externalLink), findsOneWidget);
      expect(find.byIcon(LucideIcons.play), findsNothing);
    });

    testWidgets('a media page card leads with its title and opens externally',
        (tester) async {
      // The YouTube / Instagram shape: promoted to large off plain OpenGraph,
      // no author line, and video_url is the PAGE (nothing to decode), so the
      // affordance opens the browser.
      await _pumpCard(
        tester,
        _preview(
          kind: 'large',
          title: 'Armin van Buuren - Tell Me Why',
          description: 'Discover the Top 100 releases',
          videoUrl: 'https://www.youtube.com/watch?v=SJdwO5bvhoA',
        ),
      );

      expect(find.text('Armin van Buuren - Tell Me Why'), findsOneWidget);
      final desc =
          tester.widget<Text>(find.text('Discover the Top 100 releases'));
      expect(desc.maxLines, 6);
      expect(find.byIcon(LucideIcons.externalLink), findsOneWidget);
      expect(find.byIcon(LucideIcons.play), findsNothing);
    });

    testWidgets('the whole poster is the play target, not just the glyph',
        (tester) async {
      // Missing a small centred button fell through to the card's own tap and
      // threw the user out to the browser — the worst possible miss for
      // "I wanted to watch this here".
      await _pumpCard(
        tester,
        _preview(
          kind: 'large',
          author: '@someone',
          videoUrl: 'https://video.twimg.com/ext_tw_video/1/vid/720x1280/x.mp4',
        ),
      );

      final poster = find.ancestor(
        of: find.byIcon(LucideIcons.play),
        matching: find.byType(GestureDetector),
      );
      expect(poster, findsWidgets);

      // The tap surface must span the full poster, not the ~42px glyph.
      final glyphSize = tester.getSize(find.byIcon(LucideIcons.play));
      final targetSize = tester.getSize(poster.first);
      expect(targetSize.width, greaterThan(glyphSize.width * 3));
      expect(targetSize.height, greaterThan(glyphSize.height * 3));
    });

    testWidgets('the large image uses the sender-supplied aspect ratio',
        (tester) async {
      await _pumpCard(tester, _preview(kind: 'large', author: '@a'));
      final ratio = tester.widget<AspectRatio>(find.byType(AspectRatio));
      expect(ratio.aspectRatio, closeTo(800 / 450, 0.001));
    });

    testWidgets('a card with no image still renders its text', (tester) async {
      await _pumpCard(
          tester, _preview(kind: 'large', author: '@a', withThumb: false));
      expect(find.text('@a'), findsOneWidget);
      expect(find.byType(AspectRatio), findsNothing);
    });
  });

  group('isDirectPlayableVideo', () {
    test('accepts direct media files over http(s)', () {
      expect(
        isDirectPlayableVideo('https://video.twimg.com/ext/vid/720x1280/a.mp4'),
        isTrue,
      );
      expect(isDirectPlayableVideo('https://cdn.example/clip.webm'), isTrue);
      // Query strings are normal on signed CDN links.
      expect(
        isDirectPlayableVideo('https://cdn.example/clip.mp4?tag=12&sig=abc'),
        isTrue,
      );
      expect(isDirectPlayableVideo('https://cdn.example/CLIP.MP4'), isTrue);
    });

    test('rejects pages that only LOOK like video', () {
      // The YouTube/TikTok case: nothing here is a file a decoder can open,
      // so these must fall through to the browser.
      expect(
        isDirectPlayableVideo('https://www.youtube.com/watch?v=abc123'),
        isFalse,
      );
      expect(isDirectPlayableVideo('https://youtu.be/abc123'), isFalse);
      expect(
        isDirectPlayableVideo('https://www.tiktok.com/@user/video/123'),
        isFalse,
      );
      expect(isDirectPlayableVideo('https://example.com/embed/mp4'), isFalse);
    });

    test('rejects anything that is not http(s), and empties', () {
      expect(isDirectPlayableVideo('file:///etc/passwd.mp4'), isFalse);
      expect(isDirectPlayableVideo('hollow://invite/x.mp4'), isFalse);
      expect(isDirectPlayableVideo(''), isFalse);
      expect(isDirectPlayableVideo(null), isFalse);
    });
  });

  group('LatePreviewAttacher', () {
    test('hands back the message id exactly once for the armed url', () {
      final attacher = LatePreviewAttacher();
      expect(attacher.isArmed, isFalse);

      attacher.arm('https://a.example', 'mid-1');
      expect(attacher.isArmed, isTrue);
      expect(attacher.claim('https://a.example'), 'mid-1');
      // Consumed: a duplicate completion must not attach a second time.
      expect(attacher.claim('https://a.example'), isNull);
      expect(attacher.isArmed, isFalse);
    });

    test('ignores a fetch for a different url', () {
      final attacher = LatePreviewAttacher();
      attacher.arm('https://a.example', 'mid-1');
      // The user retyped; an unrelated fetch must not inherit the pending id.
      expect(attacher.claim('https://b.example'), isNull);
      expect(attacher.claim('https://a.example'), 'mid-1');
    });

    test('a newer send supersedes an older pending one', () {
      final attacher = LatePreviewAttacher();
      attacher.arm('https://a.example', 'mid-1');
      attacher.arm('https://b.example', 'mid-2');
      expect(attacher.claim('https://a.example'), isNull);
      expect(attacher.claim('https://b.example'), 'mid-2');
    });

    test('disarm drops the pending attach', () {
      final attacher = LatePreviewAttacher();
      attacher.arm('https://a.example', 'mid-1');
      attacher.disarm();
      expect(attacher.claim('https://a.example'), isNull);
    });
  });

  group('pendingPreviewUrl', () {
    final urlRegex =
        RegExp(r'(?:https?|hollow)://[^\s<>"' "'" r')\]}]+');

    String? call({
      bool previewsEnabled = true,
      bool alreadyStaged = false,
      bool stagedLoading = false,
      String? stagedUrl,
      String text = '',
    }) =>
        pendingPreviewUrl(
          previewsEnabled: previewsEnabled,
          alreadyStaged: alreadyStaged,
          stagedLoading: stagedLoading,
          stagedUrl: stagedUrl,
          text: text,
          urlRegex: urlRegex,
        );

    test('picks the url out of the text when the debounce never fired', () {
      // THE common case: typed and sent inside the 600ms window, so no fetch
      // was ever started. Handling only the in-flight case would leave this
      // exactly as broken as before the fix.
      expect(
        call(text: 'look at https://example.com/post please'),
        'https://example.com/post',
      );
    });

    test('prefers the staged url while a fetch is in flight', () {
      expect(
        call(
          stagedLoading: true,
          stagedUrl: 'https://staged.example',
          text: 'https://different.example',
        ),
        'https://staged.example',
      );
    });

    test('is null when a card is already staged — it rides the message', () {
      expect(call(alreadyStaged: true, text: 'https://example.com'), isNull);
    });

    test('is null when previews are turned off', () {
      expect(
        call(previewsEnabled: false, text: 'https://example.com'),
        isNull,
      );
    });

    test('is null for text with no link', () {
      expect(call(text: 'no links here at all'), isNull);
    });

    test('never fetches a Hollow deep link', () {
      // Those render from a locally parsed card; a fetch would be pointless
      // and would leak an invite id to a web request.
      expect(call(text: 'join me hollow://invite/abc123'), isNull);
    });
  });
}
