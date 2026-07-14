import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/node_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';

/// Fake peer IDs.
const kLocalPeerId = 'test_local_peer_abc123def456';
const kFriendPeerId1 = 'test_friend_peer_111aaa222bbb';
const kFriendPeerId2 = 'test_friend_peer_333ccc444ddd';
const kFriendPeerId3 = 'test_friend_peer_555eee666fff';

/// Fake server/channel IDs.
const kServerId1 = 'test_server_001';
const kServerId2 = 'test_server_002';
const kChannelId1 = 'test_channel_general';
const kChannelId2 = 'test_channel_random';
const kVoiceChannelId = 'test_channel_voice';

/// Pre-loaded identity (skips welcome dialog & mnemonic flow).
const testIdentity = IdentityState(
  peerId: kLocalPeerId,
  isLoaded: true,
);

/// Node connected and ready.
const testNodeConnected = NodeState(status: NodeStatus.connected);

/// Test servers.
final testServers = <String, ServerInfo>{
  kServerId1: const ServerInfo(
    serverId: kServerId1,
    name: 'Test Server',
    memberCount: 5,
    channelCount: 3,
  ),
  kServerId2: const ServerInfo(
    serverId: kServerId2,
    name: 'Dev Hangout',
    memberCount: 12,
    channelCount: 4,
  ),
};

/// Test channels for server 1.
final testChannels = <String, ChannelInfo>{
  kChannelId1: const ChannelInfo(
    channelId: kChannelId1,
    name: 'general',
    channelType: ChannelType.text,
    visibility: 'everyone',
    posting: 'everyone',
  ),
  kChannelId2: const ChannelInfo(
    channelId: kChannelId2,
    name: 'random',
    channelType: ChannelType.text,
    visibility: 'everyone',
    posting: 'everyone',
  ),
  kVoiceChannelId: const ChannelInfo(
    channelId: kVoiceChannelId,
    name: 'Voice',
    channelType: ChannelType.voice,
    visibility: 'everyone',
    posting: 'everyone',
  ),
};

/// Test friends (2 accepted, 1 pending incoming).
final testFriends = <String, FriendInfo>{
  kFriendPeerId1: const FriendInfo(
    peerId: kFriendPeerId1,
    status: 'accepted',
    direction: '',
    requestedAt: 1700000000,
    updatedAt: 1700000100,
  ),
  kFriendPeerId2: const FriendInfo(
    peerId: kFriendPeerId2,
    status: 'accepted',
    direction: '',
    requestedAt: 1700000200,
    updatedAt: 1700000300,
  ),
  kFriendPeerId3: const FriendInfo(
    peerId: kFriendPeerId3,
    status: 'pending',
    direction: 'incoming',
    requestedAt: 1700000400,
    updatedAt: 1700000400,
  ),
};

/// Zero unread state.
const testUnreadEmpty = UnreadState(
  channelLastSeen: {},
  dmLastSeen: {},
  channelUnreadCounts: {},
  dmUnreadCounts: {},
  channelLatestId: {},
  dmLatestId: {},
  channelMentionCounts: {},
);

/// Unread state with some counts (for badge testing).
const testUnreadWithCounts = UnreadState(
  channelLastSeen: {},
  dmLastSeen: {},
  channelUnreadCounts: {'test_server_001:test_channel_general': 3},
  dmUnreadCounts: {'test_friend_peer_111aaa222bbb': 2},
  channelLatestId: {},
  dmLatestId: {},
  channelMentionCounts: {},
);

/// Default notification settings (nothing muted).
const testNotificationSettings = NotificationSettingsState();
