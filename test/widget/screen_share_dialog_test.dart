import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/dialogs/screen_share_dialog.dart';

class _Source extends DesktopCapturerSource {
  _Source(this.id, this.name, this.type);

  @override
  final String id;
  @override
  final String name;
  @override
  final SourceType type;
  @override
  Uint8List? get thumbnail => null;
  @override
  ThumbnailSize get thumbnailSize => ThumbnailSize(320, 180);
}

class _Capturer extends DesktopCapturer {
  _Capturer(this.sources, {this.fail = false});

  final List<DesktopCapturerSource> sources;
  final bool fail;
  final added = StreamController<DesktopCapturerSource>.broadcast();
  final removed = StreamController<DesktopCapturerSource>.broadcast();
  final thumbs = StreamController<DesktopCapturerSource>.broadcast();

  @override
  StreamController<DesktopCapturerSource> get onAdded => added;
  @override
  StreamController<DesktopCapturerSource> get onRemoved => removed;
  @override
  StreamController<DesktopCapturerSource> get onThumbnailChanged => thumbs;

  @override
  Future<List<DesktopCapturerSource>> getSources(
      {required List<SourceType> types, ThumbnailSize? thumbnailSize}) async {
    if (fail) throw Exception('enumeration failed');
    return sources;
  }

  @override
  Future<bool> updateSources({required List<SourceType> types}) async => true;
}

class _Sources extends ScreenShareSources {
  _Sources(this.capturer, {this.permitted = true});

  @override
  final DesktopCapturer capturer;
  final bool permitted;

  @override
  Future<bool> requestPermission() async => permitted;
}

Future<void> _open(WidgetTester tester, ScreenShareSources sources,
    {double textScale = 1}) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late BuildContext host;
  await tester.pumpWidget(MaterialApp(
    theme: HollowThemeData.dark(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(body: Builder(builder: (context) {
      host = context;
      return const SizedBox.expand();
    })),
  ));
  showHollowDialog(
      context: host, builder: (_) => ScreenShareDialog(sources: sources));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _close(WidgetTester tester) async {
  await tester.tap(find.text('Cancel'));
  await tester.pumpAndSettle();
}

HollowButton _share(WidgetTester tester) =>
    tester.widget<HollowButton>(find.widgetWithText(HollowButton, 'Share'));

void main() {
  final screen = _Source('0', 'Screen 1', SourceType.Screen);
  final window = _Source('1234', 'Notes', SourceType.Window);

  testWidgets('a macOS permission denial says how to allow it', (tester) async {
    await _open(tester, _Sources(_Capturer(const []), permitted: false));
    expect(find.text('No screens found'), findsNothing);
    expect(find.text("Hollow isn't allowed to see your screen"), findsOneWidget);
    expect(find.textContaining('Screen Recording'), findsOneWidget);
    expect(find.text('Open System Settings'), findsOneWidget);
    await _close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a failed listing is not "No screens found" and can retry',
      (tester) async {
    await _open(tester, _Sources(_Capturer(const [], fail: true)));
    expect(find.text('No screens found'), findsNothing);
    expect(find.text("Hollow couldn't list your screens and windows"),
        findsOneWidget);
    expect(find.widgetWithText(HollowButton, 'Try again'), findsOneWidget);
    await _close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('the first screen starts picked, so Share works in one click',
      (tester) async {
    await _open(tester, _Sources(_Capturer([screen, window])));
    expect(_share(tester).onPressed, isNotNull);
    expect(find.text('Pick a screen to share.'), findsNothing);
    await _close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Share with nothing picked is disabled and says why',
      (tester) async {
    await _open(tester, _Sources(_Capturer([window])));
    expect(_share(tester).onPressed, isNull);
    expect(find.text('Pick a screen to share.'), findsOneWidget);
    await tester.tap(find.text('Windows'));
    await tester.pump();
    await tester.tap(find.text('Notes'));
    await tester.pump();
    expect(_share(tester).onPressed, isNotNull);
    await _close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a screen picked on Screens does not share from the Windows tab',
      (tester) async {
    await _open(tester, _Sources(_Capturer([screen, window])));
    expect(_share(tester).onPressed, isNotNull);
    await tester.tap(find.text('Windows'));
    await tester.pump();
    expect(_share(tester).onPressed, isNull);
    expect(find.text('Pick a window to share.'), findsOneWidget);
    await tester.tap(find.text('Screens'));
    await tester.pump();
    expect(_share(tester).onPressed, isNotNull);
    await _close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('the tabs are chips and keep their weight when picked',
      (tester) async {
    await _open(tester, _Sources(_Capturer([screen, window])));
    final tab = find.widgetWithText(HollowChip, 'Windows');
    expect(tab, findsOneWidget);
    final before = tester.getSize(tab);
    await tester.tap(tab);
    await tester.pump();
    expect(tester.getSize(tab), before);
    await _close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('option rows wrap at a large text size instead of overflowing',
      (tester) async {
    await _open(tester, _Sources(_Capturer([screen])), textScale: 1.5);
    expect(tester.takeException(), isNull);
    await _close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('closing drops the live source listeners', (tester) async {
    final capturer = _Capturer([screen]);
    await _open(tester, _Sources(capturer));
    expect(capturer.added.hasListener, isTrue);
    await _close(tester);
    expect(capturer.added.hasListener, isFalse);
    expect(capturer.removed.hasListener, isFalse);
    expect(capturer.thumbs.hasListener, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
