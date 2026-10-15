import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/overlay_mic_provider.dart';
import 'package:hollow/src/core/providers/overlay_runtime_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/services/mic_level_capture.dart';
import 'package:hollow/src/core/services/overlay_mic.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/overlay_mic_indicator.dart';
import 'package:hollow/src/ui/settings/audio_section.dart';

import '../helpers/fake_mic.dart';
import '../helpers/test_app.dart';

/// The user bar's "Mic on for overlay" chip, and the Settings microphone test
/// sharing the one capture path with listening (stream overlay plan 7a).
void main() {
  setUpAll(() => RustLib.initMock(api: _Api()));

  late List<String> events;
  late FakeMic overlayDevice;
  late OverlayMic listen;
  late ProviderContainer container;

  setUp(() {
    events = [];
    overlayDevice = FakeMic(events, closeDelay: Duration.zero);
    listen = overlayMicOn(overlayDevice, resumeDelay: Duration.zero);
    debugOverlayMic = listen;
    overlayMicSupported = () => true;
    // The page lists devices and starts WebRTC as it opens; none of it is
    // under test, so every platform channel it touches answers nothing.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in _quietChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in _quietChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: [
        audioInputDeviceProvider.overrideWith(_NoInput.new),
        callProvider.overrideWith(_IdleCall.new),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return SingleChildScrollView(child: child);
          }),
        ),
      ),
    ));
    await tester.pump();
  }

  Future<void> startListening(WidgetTester tester) async {
    container.read(overlayServerRunningProvider.notifier).state = true;
    await tester.runAsync(
        () => container.read(overlayMicProvider.notifier).turnOn());
    await tester.pump();
  }

  testWidgets('the chip shows only while listening and its tap stops it',
      (tester) async {
    await pump(tester, const OverlayMicIndicator());
    expect(find.text(OverlayMicIndicator.label), findsNothing);

    await startListening(tester);
    expect(find.text(OverlayMicIndicator.label), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text(OverlayMicIndicator.label));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    expect(listen.status.value.on, isFalse);
    expect(overlayDevice.isOpen, isFalse);
    expect(find.text(OverlayMicIndicator.label), findsNothing);
  });

  testWidgets('the microphone test pauses listening and resumes it after',
      (tester) async {
    final testDevice = FakeMic(events, closeDelay: Duration.zero);
    micPcmBackendFactory = () => testDevice;
    addTearDown(() => micPcmBackendFactory = MicPcmBackend.forPlatform);

    await pump(tester, const AudioVideoSettingsView());
    await startListening(tester);
    expect(overlayDevice.isOpen, isTrue);

    await tester.runAsync(() async {
      await tester.tap(find.text('Test microphone'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(overlayDevice.isOpen, isFalse,
        reason: 'the test must not share the mic with listening');
    expect(testDevice.isOpen, isTrue);
    expect(events.indexOf('mic-released'),
        lessThan(events.lastIndexOf('mic-opening')),
        reason: 'the test opened the mic before listening let go');
    expect(listen.status.value.paused, isTrue);

    await tester.runAsync(() async {
      await tester.tap(find.text('Stop and review'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(testDevice.isOpen, isFalse);
    expect(listen.status.value.listening, isTrue);
    expect(overlayDevice.isOpen, isTrue);

    // The fake take is empty, so the page toasts "No audio arrived".
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}

const _quietChannels = [
  'FlutterWebRTC.Method',
  'FlutterWebRTC.Event',
  'win32audio',
];

class _Api implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName.toString().contains('crateApi')
          ? Future<void>.value()
          : super.noSuchMethod(invocation);
}

class _NoInput extends AudioInputDeviceNotifier {
  @override
  Future<String?> build() async => null;
}

class _IdleCall extends CallNotifier {
  @override
  CallState build() => const CallState();
}
