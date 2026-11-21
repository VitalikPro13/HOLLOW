import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/age_gate.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/pending_join_info.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/pending_join_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';

/// A phone with servers in the dock's order: one loose, a folder of two, a
/// muted one, a parked join, and one the age gate hides. The Servers tab and
/// the nav badges read it (#154).
const kSrvBeta = 'srv_beta';
const kSrvAlpha = 'srv_alpha';
const kSrvFolded = 'srv_folded';
const kSrvMuted = 'srv_muted';
const kSrvHidden = 'srv_hidden';
const kSrvPending = 'srv_pending';
const kSrvLoungeId = 'ch_lounge';
const kSrvGeneralId = 'ch_general';

const kFixtureServers = <String, ServerInfo>{
  kSrvAlpha: ServerInfo(serverId: kSrvAlpha, name: 'Synth Lab', memberCount: 12),
  kSrvBeta: ServerInfo(serverId: kSrvBeta, name: 'Pixel Guild', memberCount: 48),
  kSrvFolded:
      ServerInfo(serverId: kSrvFolded, name: 'Book Club', memberCount: 1),
  kSrvMuted: ServerInfo(serverId: kSrvMuted, name: 'Night Owls', memberCount: 7),
  kSrvHidden:
      ServerInfo(serverId: kSrvHidden, name: 'Hidden Place', memberCount: 3),
};

const kFixtureLayout = <StripItem>[
  ServerStripItem(serverId: kSrvBeta),
  FolderStripItem(
      id: 'f_work', name: 'Work stuff', serverIds: [kSrvFolded, kSrvAlpha]),
  ServerStripItem(serverId: kSrvMuted),
  PendingStripItem(serverId: kSrvPending),
  ServerStripItem(serverId: kSrvHidden),
];

/// Pixel Guild: 2 mentions over 6 unread. Synth Lab: 3 unread. Night Owls is
/// muted with 9 unread. A friend DM holds 4 unread.
const kFixtureUnread = UnreadState(
  channelLastSeen: {},
  dmLastSeen: {},
  channelUnreadCounts: {
    '$kSrvBeta:$kSrvGeneralId': 6,
    '$kSrvAlpha:$kSrvGeneralId': 3,
    '$kSrvMuted:$kSrvGeneralId': 9,
    '$kSrvHidden:$kSrvGeneralId': 50,
  },
  dmUnreadCounts: {'test_friend_peer_111aaa222bbb': 4},
  channelLatestId: {},
  dmLatestId: {},
  channelMentionCounts: {'$kSrvBeta:$kSrvGeneralId': 2},
);

class FixtureServers extends ServerListNotifier {
  FixtureServers([this.servers = kFixtureServers]);
  final Map<String, ServerInfo> servers;

  @override
  Map<String, ServerInfo> build() => servers;
}

class FixtureLayout extends ServerStripLayoutNotifier {
  @override
  List<StripItem> build() => kFixtureLayout;
}

class FixturePending extends PendingJoinsNotifier {
  @override
  Map<String, PendingJoinInfo> build() => const {
        kSrvPending: PendingJoinInfo(serverId: kSrvPending, requestedAt: 1),
      };
}

class FixtureUnread extends UnreadNotifier {
  FixtureUnread([this.initial = kFixtureUnread]);
  final UnreadState initial;

  @override
  UnreadState build() => initial;
}

class FixtureNotifications extends NotificationSettingsNotifier {
  @override
  NotificationSettingsState build() => const NotificationSettingsState(
        serverLevels: {kSrvMuted: NotificationLevel.nothing},
      );
}

class FixtureGate extends AgeGateNotifier {
  @override
  AgeGateState build() =>
      const AgeGateState(allowedHere: false, hidden: {kSrvHidden});

  @override
  Future<void> load() async {}
}

/// Three people in Synth Lab's Lounge.
class FixtureVoice extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState(participants: {
        kSrvAlpha: {
          kSrvLoungeId: {'peer_mira', 'peer_juno', 'peer_kai'},
        },
      });
}

const _lounge = ChannelInfo(
  channelId: kSrvLoungeId,
  name: 'Lounge',
  channelType: ChannelType.voice,
  visibility: 'everyone',
  posting: 'everyone',
);

const _general = ChannelInfo(
  channelId: kSrvGeneralId,
  name: 'general',
  channelType: ChannelType.text,
  visibility: 'everyone',
  posting: 'everyone',
);

/// Every override the fixture needs, on top of `hollowTestOverrides`.
List<Override> mobileServersFixture() => [
      serverListProvider.overrideWith(FixtureServers.new),
      serverStripLayoutProvider.overrideWith(FixtureLayout.new),
      pendingJoinsProvider.overrideWith(FixturePending.new),
      unreadProvider.overrideWith(FixtureUnread.new),
      notificationSettingsProvider.overrideWith(FixtureNotifications.new),
      ageGateProvider.overrideWith(FixtureGate.new),
      voiceChannelProvider.overrideWith(FixtureVoice.new),
      for (final id in kFixtureServers.keys)
        serverChannelsProvider(id).overrideWith((ref) async => {
              kSrvGeneralId: _general,
              if (id == kSrvAlpha) kSrvLoungeId: _lounge,
            }),
    ];
