import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/call_record.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/link_health_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/speaking_provider.dart';
import 'package:hollow/src/core/providers/status_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/link_resilience.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/chat/message_row.dart';
import 'package:hollow/src/ui/mobile/mobile_call_video_view.dart';
import 'package:hollow/src/ui/mobile/mobile_incoming_call.dart';
import 'package:hollow/src/ui/mobile/mobile_minimised_call.dart';
import 'package:hollow/src/ui/mobile/mobile_voice_channel_route.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// Renders of the phone call surfaces (session 23) and the DM call record
/// line, for reading by eye where no simulator is at hand. Every test still
/// passes as "builds and settles".
///
/// Output dir: $HOLLOW_SHOT_DIR, falling back to build/ui_screenshots.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${Platform.pathSeparator}build'
          '${Platform.pathSeparator}ui_screenshots';

  setUpAll(() async {
    final lucide =
        await rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf');
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

  Future<void> capture(WidgetTester tester, String name) async {
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
  }

  Future<void> shoot(
    WidgetTester tester,
    String name,
    Widget child, {
    List<Override> extra = const [],
    Size size = const Size(390, 844),
    bool light = false,
    bool phone = true,
    bool overlay = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    debugDefaultTargetPlatformOverride =
        phone ? TargetPlatform.android : TargetPlatform.windows;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final theme = light ? HollowThemeData.light() : HollowThemeData.dark();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...hollowTestOverrides(extra: extra),
        profileProvider.overrideWith(_Profiles.new),
        serverListProvider.overrideWith(_Servers.new),
        avatarProvider.overrideWith(_NoAvatars.new),
        statusProvider.overrideWith(_QuietStatus.new),
        ringtonePathProvider.overrideWith(_NoRingtone.new),
      ],
      child: RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          builder: overlay
              ? (context, c) => Stack(children: [c!, child])
              : null,
          home: overlay ? const Scaffold() : child,
        ),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await capture(tester, name);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  }

  final now = DateTime.now();
  CallState dm({
    CallStatus status = CallStatus.active,
    CallDirection direction = CallDirection.outgoing,
    bool offer = false,
  }) =>
      CallState(
        status: status,
        peerId: kFriendPeerId1,
        callId: 'c1',
        direction: direction,
        startedAt: status == CallStatus.active
            ? now.subtract(const Duration(minutes: 4, seconds: 12))
            : null,
        remoteScreenSharing: offer,
        remoteScreenShareLabel: offer ? '1080p60' : null,
      );

  VoiceChannelState room({bool watching = false}) => VoiceChannelState(
        currentServerId: kServerId1,
        currentChannelId: kVoiceChannelId,
        currentChannelName: 'Jam room',
        joinedAt: now.subtract(const Duration(minutes: 42, seconds: 17)),
        participants: {
          kServerId1: {
            kVoiceChannelId: {
              kLocalPeerId,
              kFriendPeerId1,
              kFriendPeerId2,
              kFriendPeerId3,
              'test_friend_peer_777ggg888hhh',
            },
          },
        },
        peerAudioStates: const {
          kFriendPeerId3: PeerAudioState(isMuted: true),
        },
        peerScreenSharing: const {kFriendPeerId2: true},
        peerScreenShareLabels: const {kFriendPeerId2: '1080p60'},
        watchingScreenShares: watching ? const {kFriendPeerId2} : const {},
        focusedScreenSharePeerId: watching ? kFriendPeerId2 : null,
        focusedSourceType: 'screen',
      );

  final speakingMira = callSpeakingProvider.overrideWith(_MiraSpeaks.new);
  final vcSpeaking = vcSpeakingProvider.overrideWith(_JunoSpeaks.new);
  final weakLink = vcLinkHealthProvider.overrideWith(_WeakKes.new);

  testWidgets('dm call, audio with a share offer', (tester) async {
    for (final light in [false, true]) {
      await shoot(
        tester,
        'phone_call_dm_audio${light ? '_light' : ''}',
        const MobileCallScreen(peerId: kFriendPeerId1),
        light: light,
        extra: [
          callProvider.overrideWith(() => _InCall(dm(offer: true))),
          speakingMira,
        ],
      );
    }
  });

  testWidgets('dm call, ringing out', (tester) async {
    await shoot(
      tester,
      'phone_call_dm_ringing',
      const MobileCallScreen(peerId: kFriendPeerId1),
      extra: [
        callProvider
            .overrideWith(() => _InCall(dm(status: CallStatus.ringing))),
      ],
    );
  });

  testWidgets('voice room', (tester) async {
    for (final light in [false, true]) {
      await shoot(
        tester,
        'phone_call_room${light ? '_light' : ''}',
        const MobileVoiceChannelRoute(
          serverId: kServerId1,
          channelId: kVoiceChannelId,
          channelName: 'Jam room',
        ),
        light: light,
        extra: [
          voiceChannelProvider.overrideWith(() => _Room(room())),
          vcSpeaking,
          weakLink,
        ],
      );
    }
  });

  testWidgets('voice room, watching a share', (tester) async {
    await shoot(
      tester,
      'phone_call_room_watching',
      const MobileVoiceChannelRoute(
        serverId: kServerId1,
        channelId: kVoiceChannelId,
        channelName: 'Jam room',
      ),
      extra: [
        voiceChannelProvider.overrideWith(() => _Room(room(watching: true))),
        vcSpeaking,
      ],
    );
  });

  testWidgets('incoming', (tester) async {
    await shoot(
      tester,
      'phone_call_incoming',
      const MobileIncomingCallOverlay(),
      overlay: true,
      extra: [
        callProvider.overrideWith(() => _InCall(dm(
            status: CallStatus.ringing,
            direction: CallDirection.incoming))),
      ],
    );
  });

  testWidgets('minimised call, floating and docked', (tester) async {
    await shoot(
      tester,
      'phone_call_minimised',
      const Scaffold(
        body: Stack(children: [
          Column(children: [
            SizedBox(height: 120),
            MobileMinimisedCall(floating: false),
          ]),
          MobileMinimisedCall(),
        ]),
      ),
      extra: [
        callProvider.overrideWith(() => _InCall(dm())),
        speakingMira,
      ],
    );
  });

  testWidgets('call record lines in a DM', (tester) async {
    final day = DateTime(now.year, now.month, now.day, 14, 2);
    DmCallRecord rec(String id, CallOutcome outcome, DateTime at,
            {bool outgoing = true, Duration talked = Duration.zero}) =>
        DmCallRecord(
          callId: id,
          peer: kFriendPeerId1,
          outgoing: outgoing,
          video: false,
          outcome: outcome,
          startedAt: at,
          connectedAt:
              outcome == CallOutcome.answered ? at.add(const Duration(seconds: 4)) : null,
          endedAt: at.add(talked),
        );
    Widget message(String id, String text, bool me, DateTime at,
            {List<DmCallRecord> before = const [],
            List<DmCallRecord> after = const [],
            DateTime? prev}) =>
        dateSeparatedChatRow(
          rowKey: id,
          timestamp: at,
          prevTimestamp: prev,
          showHeader: true,
          callsBefore: before,
          callsAfter: after,
          child: MessageRow(
            messageId: id,
            senderId: me ? kLocalPeerId : kFriendPeerId1,
            isMe: me,
            text: text,
            timestamp: at,
            editedAt: null,
            replyToMid: null,
            reactions: const {},
            fileAttachment: null,
            linkPreview: null,
            showHeader: true,
          ),
        );
    final m1 = day;
    final m2 = day.add(const Duration(minutes: 40));
    final list = Builder(
      builder: (context) => Scaffold(
        backgroundColor: HollowTheme.of(context).background,
        body: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            message('m1', 'call? easier if I show you', false, m1),
            message('m2', 'that was quick, thanks', true, m2, prev: m1,
                before: [
                  rec('c1', CallOutcome.missed, m1.add(const Duration(minutes: 1)),
                      outgoing: false),
                  rec('c2', CallOutcome.answered,
                      m1.add(const Duration(minutes: 3)),
                      talked: const Duration(minutes: 4, seconds: 20)),
                ],
                after: [
                  rec('c3', CallOutcome.cancelled,
                      m2.add(const Duration(minutes: 2))),
                ]),
          ],
        ),
      ),
    );
    await shoot(tester, 'call_record_lines_desktop', list,
        size: const Size(900, 380), phone: false);
    await shoot(tester, 'call_record_lines_phone', list,
        size: const Size(390, 420));
  });
}

class _Servers extends ServerListNotifier {
  @override
  Map<String, ServerInfo> build() => {
        kServerId1: const ServerInfo(
          serverId: kServerId1,
          name: 'Synth Lab',
          memberCount: 5,
          channelCount: 3,
        ),
      };
}

class _InCall extends CallNotifier {
  final CallState initial;
  _InCall(this.initial);
  @override
  CallState build() => initial;
}

class _Room extends VoiceChannelNotifier {
  final VoiceChannelState initial;
  _Room(this.initial);
  @override
  VoiceChannelState build() => initial;
}

class _MiraSpeaks extends CallSpeakingNotifier {
  @override
  ({bool local, bool remote}) build() => (local: false, remote: true);
}

class _JunoSpeaks extends VcSpeakingNotifier {
  @override
  Set<String> build() => {kFriendPeerId1};
}

class _WeakKes extends VcLinkHealthNotifier {
  @override
  Map<String, LinkHealthSnapshot> build() => {
        'test_friend_peer_777ggg888hhh':
            const LinkHealthSnapshot(health: LinkHealth.unstable),
      };
}

class _QuietStatus extends StatusNotifier {
  @override
  StatusState build() => const StatusState();
}

class _NoRingtone extends RingtonePathNotifier {
  @override
  Future<String?> build() async => null;
}

class _NoAvatars extends AvatarNotifier {
  @override
  Map<String, Uint8List> build() => const {};

  @override
  Future<void> loadAvatar(String peerId) async {}
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
    );

class _Profiles extends ProfileNotifier {
  @override
  Map<String, storage_api.UserProfile> build() => {
        kLocalPeerId: _profile(kLocalPeerId, 'Vitalik'),
        kFriendPeerId1: _profile(kFriendPeerId1, 'Mira'),
        kFriendPeerId2: _profile(kFriendPeerId2, 'Juno'),
        kFriendPeerId3: _profile(kFriendPeerId3, 'Dr Faust'),
        'test_friend_peer_777ggg888hhh':
            _profile('test_friend_peer_777ggg888hhh', 'Kestrel'),
      };
}
