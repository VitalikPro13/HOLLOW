import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/link_health_provider.dart';
import 'package:hollow/src/core/providers/lost_call_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/status_provider.dart';
import 'package:hollow/src/core/services/link_resilience.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/call/dm_call_row.dart';
import 'package:hollow/src/ui/mobile/mobile_call_video_view.dart';
import 'package:hollow/src/ui/mobile/mobile_minimised_call.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// Renders of the link states and the lost-call linger (#154, Nov 24), for
/// reading by eye. Every test still passes as "builds and settles".
///
/// Output dir: $HOLLOW_SHOT_DIR, falling back to build/ui_screenshots.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${Platform.pathSeparator}build'
          '${Platform.pathSeparator}ui_screenshots';

  setUpAll(() async {
    final lucide = await rootBundle
        .load('packages/lucide_icons_flutter/assets/lucide.ttf');
    await (FontLoader('packages/lucide_icons_flutter/Lucide')
          ..addFont(Future.value(lucide)))
        .load();
    for (final face in Directory('assets/fonts').listSync()) {
      final name = face.uri.pathSegments.last;
      if (!name.endsWith('.ttf') ||
          !(name.startsWith('Onest') || name.startsWith('GeistMono'))) {
        continue;
      }
      final family = name.startsWith('Onest') ? 'Onest' : 'GeistMono';
      final bytes = File(face.path).readAsBytesSync();
      await (FontLoader(family)
            ..addFont(Future.value(ByteData.view(bytes.buffer))))
          .load();
    }
  });

  Future<void> shoot(
    WidgetTester tester,
    String name,
    Widget child, {
    required CallState call,
    LinkHealth? health,
    bool lost = false,
    Size size = const Size(390, 844),
    bool light = false,
    bool phone = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    debugDefaultTargetPlatformOverride =
        phone ? TargetPlatform.android : TargetPlatform.windows;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = ProviderContainer(overrides: [
      ...hollowTestOverrides(extra: [
        callProvider.overrideWith(() => _InCall(call)),
      ]),
      profileProvider.overrideWith(_Profiles.new),
      avatarProvider.overrideWith(_NoAvatars.new),
      statusProvider.overrideWith(_QuietStatus.new),
      ringtonePathProvider.overrideWith(_NoRingtone.new),
    ]);
    addTearDown(container.dispose);
    if (health != null) {
      container
          .read(callLinkHealthProvider.notifier)
          .set(LinkHealthSnapshot(health: health));
    }
    if (lost) {
      container
          .read(lostCallProvider.notifier)
          .show(callId: 'c1', peerMaster: kFriendPeerId1);
    }
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
          home: Scaffold(body: child),
        ),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await tester.runAsync(() async {
      try {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (data == null) return;
        final file = File('$outDir${Platform.pathSeparator}$name.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(data.buffer.asUint8List());
        debugPrint('[screenshot] wrote ${file.path}');
      } catch (e) {
        debugPrint('[screenshot] skipped $name: $e');
      }
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
    debugDefaultTargetPlatformOverride = null;
  }

  final active = CallState(
    status: CallStatus.active,
    peerId: kFriendPeerId1,
    callId: 'c1',
    direction: CallDirection.outgoing,
    startedAt: DateTime.now().subtract(const Duration(minutes: 3)),
  );

  for (final light in [false, true]) {
    final tag = light ? '_light' : '';
    testWidgets('phone call screen, each link state$tag', (tester) async {
      for (final h in [LinkHealth.unstable, LinkHealth.reconnecting]) {
        await shoot(tester, 'link_phone_${h.name}$tag',
            const MobileCallScreen(peerId: kFriendPeerId1),
            call: active, health: h, light: light);
      }
      await shoot(tester, 'link_phone_lost_linger$tag',
          const MobileCallScreen(peerId: kFriendPeerId1),
          call: const CallState(), lost: true, light: light);
      await shoot(tester, 'link_phone_minimised_linger$tag',
          const Align(
              alignment: Alignment.bottomCenter, child: MobileMinimisedCall()),
          call: const CallState(), lost: true, light: light);
      await shoot(tester, 'link_phone_minimised_linger_320$tag',
          const Align(
              alignment: Alignment.bottomCenter, child: MobileMinimisedCall()),
          call: const CallState(),
          lost: true,
          light: light,
          size: const Size(320, 640));
    });

    testWidgets('desktop DM call row, each link state$tag', (tester) async {
      for (final h in [LinkHealth.unstable, LinkHealth.reconnecting]) {
        await shoot(
            tester,
            'link_row_${h.name}$tag',
            const Align(
                alignment: Alignment.topCenter,
                child: DmCallRow(peerMaster: kFriendPeerId1)),
            call: active,
            health: h,
            light: light,
            phone: false,
            size: const Size(800, 120));
      }
      await shoot(
          tester,
          'link_row_lost_linger$tag',
          const Align(
              alignment: Alignment.topCenter,
              child: DmCallRow(peerMaster: kFriendPeerId1)),
          call: const CallState(),
          lost: true,
          light: light,
          phone: false,
          size: const Size(800, 120));
    });
  }
}

class _InCall extends CallNotifier {
  final CallState initial;
  _InCall(this.initial);
  @override
  CallState build() => initial;
}

class _NoAvatars extends AvatarNotifier {
  @override
  Map<String, Uint8List> build() => const {};

  @override
  Future<void> loadAvatar(String peerId) async {}
}

class _Profiles extends ProfileNotifier {
  @override
  Map<String, storage_api.UserProfile> build() => {
        kLocalPeerId: _profile(kLocalPeerId, 'Vitalik'),
        kFriendPeerId1: _profile(kFriendPeerId1, 'Mira'),
      };
}

storage_api.UserProfile _profile(String id, String name) =>
    storage_api.UserProfile(
      peerId: id,
      displayName: name,
      status: '',
      aboutMe: '',
      updatedAt: 0,
      twitchUsername: '',
      showcaseBoard: '',
      avatarFrame: '',
      avatarAnim: '',
      bannerAnim: '',
      supportCreds: '',
      nameColor: '',
    );

class _QuietStatus extends StatusNotifier {
  @override
  StatusState build() => const StatusState();
}

class _NoRingtone extends RingtonePathNotifier {
  @override
  Future<String?> build() async => null;
}
