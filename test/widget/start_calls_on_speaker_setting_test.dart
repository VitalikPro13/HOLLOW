import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/age_gate.dart';
import 'package:hollow/src/core/providers/audio_route_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/settings/audio_section.dart';
import 'package:hollow/src/ui/settings/settings_place.dart'
    show settingsSearchHits;

import '../helpers/test_app.dart';

/// #154: "Start calls on the speaker" lives in Settings > Audio and video only
/// where a call can start on an earpiece (a phone; never a desktop or tablet),
/// is on by default, shows the STORED choice after a cold start, and search
/// finds it only where the page shows it.
void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));

  const quiet = ['FlutterWebRTC.Method', 'FlutterWebRTC.Event', 'win32audio'];
  setUp(() {
    api
      ..storeOpen = true
      ..stored = null;
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in quiet) {
      m.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in quiet) {
      m.setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  late ProviderContainer container;
  const title = 'Start calls on the speaker';

  Finder toggle() => find.descendant(
      of: find.ancestor(of: find.text(title), matching: find.byType(Row)).first,
      matching: find.byType(HollowToggle));

  List<Override> overrides({required bool earpiece}) => [
        ...hollowTestOverrides(),
        callProvider.overrideWith(_IdleCall.new),
        hasEarpieceProvider.overrideWith((_) async => earpiece),
      ];

  Future<void> pump(WidgetTester tester,
      {required bool earpiece, ProviderContainer? existing}) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final app = MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return const SingleChildScrollView(
                child: AudioVideoSettingsView());
          }),
        ),
      );
    await tester.pumpWidget(existing != null
        ? UncontrolledProviderScope(container: existing, child: app)
        : ProviderScope(overrides: overrides(earpiece: earpiece), child: app));
    await tester.pump();
    await tester.pump();
  }

  for (final phone in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('a ${phone.name} phone shows the switch, on by default',
        (tester) async {
      debugDefaultTargetPlatformOverride = phone;
      await pump(tester, earpiece: true);
      expect(find.text(title), findsOneWidget);
      expect(tester.widget<HollowToggle>(toggle()).value, isTrue);

      await tester.tap(toggle());
      await tester.pump();
      expect(container.read(startCallsOnSpeakerProvider).valueOrNull, isFalse,
          reason: 'turning it off must save');
      expect(tester.widget<HollowToggle>(toggle()).value, isFalse);
      expect(api.saved['start_calls_on_speaker'], 'false');
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('a tablet has no earpiece, so no switch', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await pump(tester, earpiece: false);
    expect(find.text(title), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('cold start: a read made before the store opened shows the '
      'stored OFF, not the default', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    api
      ..storeOpen = false
      ..stored = 'false';
    // The first frame read the setting while the message store was closed.
    final early = ProviderContainer(overrides: overrides(earpiece: true));
    addTearDown(early.dispose);
    await tester.runAsync(() => early
        .read(startCallsOnSpeakerProvider.future)
        .then<void>((_) {}, onError: (_) {}));
    expect(early.read(startCallsOnSpeakerProvider).hasError, isTrue);
    api.storeOpen = true;

    await pump(tester, earpiece: true, existing: early);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(tester.widget<HollowToggle>(toggle()).value, isFalse,
        reason: 'the row showed the default ON over the stored OFF');
    debugDefaultTargetPlatformOverride = null;
  });

  test('the earpiece query never runs on a desktop', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(await c.read(hasEarpieceProvider.future), isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  test('search finds it only with an earpiece', () {
    bool found(String q, {required bool earpiece}) =>
        settingsSearchHits(q, AgeGateMode.desktop, earpiece: earpiece)
            .any((e) => e.label == title);
    expect(found('speaker', earpiece: true), isTrue);
    expect(found('earpiece', earpiece: true), isTrue);
    expect(found('speaker', earpiece: false), isFalse);
  });
}

class _IdleCall extends CallNotifier {
  @override
  CallState build() => const CallState();
}

class _Api implements RustLibApi {
  bool storeOpen = true;
  String? stored;
  final saved = <String, String>{};

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async {
    if (!storeOpen) throw 'Message store is not open';
    return key == 'start_calls_on_speaker' ? stored : null;
  }

  @override
  Future<void> crateApiStorageSaveSetting(
      {required String key, required String value}) async {
    saved[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName.toString().contains('crateApi')
          ? Future<void>.value()
          : super.noSuchMethod(invocation);
}
