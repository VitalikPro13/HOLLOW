import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';

/// Tracks unread message state per channel and per DM.
///
/// "Seen" = the channel/DM was selected while the app was focused.
/// Stored in app_settings as:
/// - `seen:ch:{serverId}:{channelId}` → last seen message ID
/// - `seen:dm:{peerId}` → last seen message ID
///
/// Unread count is computed by comparing the stored last-seen ID
/// against the latest message ID from in-memory state.
class UnreadNotifier extends Notifier<UnreadState> {
  @override
  UnreadState build() => const UnreadState();

  /// Load last-seen state from DB on startup and compute actual unread counts.
  Future<void> loadAll(
      Map<String, List<String>> serverChannels,
      List<String> dmPeerIds) async {
    final channelSeen = <String, String>{};
    final dmSeen = <String, String>{};
    final channelCounts = <String, int>{};
    final dmCounts = <String, int>{};

    for (final entry in serverChannels.entries) {
      for (final cid in entry.value) {
        final stateKey = '${entry.key}:$cid';
        final val = await storage_api.loadSetting(key: 'seen:ch:$stateKey');
        try {
          final int count;
          if (val != null) {
            channelSeen[stateKey] = val;
            count = await storage_api.countUnreadChannel(
              serverId: entry.key,
              channelId: cid,
              lastSeenMessageId: val,
            );
          } else {
            // Never opened — count all messages from others.
            count = await storage_api.countAllUnreadChannel(
              serverId: entry.key,
              channelId: cid,
            );
          }
          if (count > 0) channelCounts[stateKey] = count;
        } catch (_) {}
      }
    }

    for (final peerId in dmPeerIds) {
      final val = await storage_api.loadSetting(key: 'seen:dm:$peerId');
      try {
        final int count;
        if (val != null) {
          dmSeen[peerId] = val;
          count = await storage_api.countUnreadDm(
            peerId: peerId,
            lastSeenMessageId: val,
          );
        } else {
          // Never opened — count all messages from peer.
          count = await storage_api.countAllUnreadDm(peerId: peerId);
        }
        if (count > 0) dmCounts[peerId] = count;
      } catch (_) {}
    }

    state = UnreadState(
      channelLastSeen: channelSeen,
      dmLastSeen: dmSeen,
      channelUnreadCounts: channelCounts,
      dmUnreadCounts: dmCounts,
    );
  }

  /// Recompute unread counts from DB for all channels of a server.
  /// Respects notification settings (All/Mentions/Nothing).
  Future<void> recomputeServerUnread(
      String serverId, List<String> channelIds) async {
    final updatedCounts = Map<String, int>.from(state.channelUnreadCounts);
    final updatedMentions = Map<String, int>.from(state.channelMentionCounts);
    final notifSettings = ref.read(notificationSettingsProvider.notifier);
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final localName = displayNameFor(ref.read(profileProvider), localPeerId);
    final nicknames = ref.read(serverNicknamesProvider(serverId));
    final localNick = nicknames[localPeerId];
    final mentionPatterns = <String>['@everyone', '@$localName'];
    if (localNick != null && localNick.isNotEmpty) {
      mentionPatterns.add('@$localNick');
    }

    for (final cid in channelIds) {
      final key = '$serverId:$cid';
      try {
        final level = notifSettings.effectiveChannelLevel(serverId, cid);
        if (level == NotificationLevel.nothing) {
          updatedCounts.remove(key);
          updatedMentions.remove(key);
          continue;
        }

        final lastSeen = state.channelLastSeen[key];
        final result = await storage_api.countUnreadChannelWithMentions(
          serverId: serverId,
          channelId: cid,
          lastSeenMessageId: lastSeen,
          mentionPatterns: mentionPatterns,
        );

        final unreadCount = level == NotificationLevel.mentions
            ? result.mentions
            : result.total;
        // Keep the higher of DB count vs existing in-memory count.
        // In-memory may include hint-based increments not yet in DB.
        final existingCount = updatedCounts[key] ?? 0;
        final existingMentions = updatedMentions[key] ?? 0;
        final finalUnread = unreadCount > existingCount ? unreadCount : existingCount;
        final finalMentions = result.mentions > existingMentions ? result.mentions : existingMentions;
        debugPrint('[HOLLOW-UNREAD] recompute $key: level=$level total=${result.total} mentions=${result.mentions} existing=$existingCount → final=$finalUnread lastSeen=$lastSeen');
        if (finalUnread > 0) {
          updatedCounts[key] = finalUnread;
        } else {
          updatedCounts.remove(key);
        }
        if (finalMentions > 0) {
          updatedMentions[key] = finalMentions;
        } else {
          updatedMentions.remove(key);
        }
      } catch (e) {
        debugPrint('[HOLLOW-UNREAD] recompute error for $key: $e');
      }
    }
    debugPrint('[HOLLOW-UNREAD] recompute done for $serverId: counts=$updatedCounts');
    state = state.copyWith(
      channelUnreadCounts: updatedCounts,
      channelMentionCounts: updatedMentions,
    );
  }

  /// Recompute unread count for a single DM peer from DB.
  /// Called after DM sync completes.
  Future<void> recomputeDmUnread(String peerId) async {
    final updatedCounts = Map<String, int>.from(state.dmUnreadCounts);
    try {
      final lastSeen = state.dmLastSeen[peerId];
      final int count;
      if (lastSeen != null) {
        count = await storage_api.countUnreadDm(
          peerId: peerId,
          lastSeenMessageId: lastSeen,
        );
      } else {
        count = await storage_api.countAllUnreadDm(peerId: peerId);
      }
      if (count > 0) {
        updatedCounts[peerId] = count;
      } else {
        updatedCounts.remove(peerId);
      }
    } catch (_) {}
    state = state.copyWith(dmUnreadCounts: updatedCounts);
  }

  /// Mark a channel as seen (user is viewing it).
  Future<void> markChannelSeen(
      String serverId, String channelId, String? latestMessageId) async {
    if (latestMessageId == null) return;
    final key = '$serverId:$channelId';

    // Update in-memory.
    final updatedSeen =
        Map<String, String>.from(state.channelLastSeen);
    updatedSeen[key] = latestMessageId;

    // Clear unread + mention counts.
    final updatedCounts =
        Map<String, int>.from(state.channelUnreadCounts);
    updatedCounts.remove(key);
    final updatedMentions =
        Map<String, int>.from(state.channelMentionCounts);
    updatedMentions.remove(key);

    state = state.copyWith(
      channelLastSeen: updatedSeen,
      channelUnreadCounts: updatedCounts,
      channelMentionCounts: updatedMentions,
    );

    // Persist.
    await storage_api.saveSetting(
      key: 'seen:ch:$serverId:$channelId',
      value: latestMessageId,
    );
  }

  /// Mark a DM as seen.
  Future<void> markDmSeen(String peerId, String? latestMessageId) async {
    if (latestMessageId == null) return;

    final updatedSeen = Map<String, String>.from(state.dmLastSeen);
    updatedSeen[peerId] = latestMessageId;

    final updatedCounts = Map<String, int>.from(state.dmUnreadCounts);
    updatedCounts.remove(peerId);

    state = state.copyWith(
      dmLastSeen: updatedSeen,
      dmUnreadCounts: updatedCounts,
    );

    await storage_api.saveSetting(
      key: 'seen:dm:$peerId',
      value: latestMessageId,
    );
  }

  /// Called when a new live channel message arrives.
  /// Increments unread count if the channel is not currently viewed.
  void onChannelMessage(String serverId, String channelId,
      String messageId, bool isCurrentlyViewing,
      {bool isMention = false}) {
    if (isCurrentlyViewing) {
      markChannelSeen(serverId, channelId, messageId);
      return;
    }

    final key = '$serverId:$channelId';
    final updatedCounts =
        Map<String, int>.from(state.channelUnreadCounts);
    updatedCounts[key] = (updatedCounts[key] ?? 0) + 1;

    final updatedLatest =
        Map<String, String>.from(state.channelLatestId);
    updatedLatest[key] = messageId;

    Map<String, int>? updatedMentions;
    if (isMention) {
      updatedMentions = Map<String, int>.from(state.channelMentionCounts);
      updatedMentions[key] = (updatedMentions[key] ?? 0) + 1;
    }

    state = state.copyWith(
      channelUnreadCounts: updatedCounts,
      channelLatestId: updatedLatest,
      channelMentionCounts: updatedMentions,
    );
  }

  /// Called when a new live DM arrives.
  void onDmMessage(
      String peerId, String messageId, bool isCurrentlyViewing) {
    if (isCurrentlyViewing) {
      markDmSeen(peerId, messageId);
      return;
    }

    final updatedCounts = Map<String, int>.from(state.dmUnreadCounts);
    updatedCounts[peerId] = (updatedCounts[peerId] ?? 0) + 1;

    final updatedLatest = Map<String, String>.from(state.dmLatestId);
    updatedLatest[peerId] = messageId;

    state = state.copyWith(
      dmUnreadCounts: updatedCounts,
      dmLatestId: updatedLatest,
    );
  }

  /// Get unread count for a channel.
  int channelUnreadCount(String serverId, String channelId) {
    return state.channelUnreadCounts['$serverId:$channelId'] ?? 0;
  }

  /// Get total unread count for a server (sum of all channels).
  int serverUnreadCount(String serverId) {
    int total = 0;
    for (final entry in state.channelUnreadCounts.entries) {
      if (entry.key.startsWith('$serverId:')) {
        total += entry.value;
      }
    }
    return total;
  }

  /// Whether a channel has unread messages.
  bool isChannelUnread(String serverId, String channelId) {
    return channelUnreadCount(serverId, channelId) > 0;
  }

  /// Whether any channel in a server has unread messages.
  bool isServerUnread(String serverId) {
    return serverUnreadCount(serverId) > 0;
  }

  /// Get unread count for a DM.
  int dmUnreadCount(String peerId) {
    return state.dmUnreadCounts[peerId] ?? 0;
  }

  /// Whether a DM has unread messages.
  bool isDmUnread(String peerId) {
    return dmUnreadCount(peerId) > 0;
  }

  int channelMentionCount(String serverId, String channelId) {
    return state.channelMentionCounts['$serverId:$channelId'] ?? 0;
  }

  int serverMentionCount(String serverId) {
    int total = 0;
    for (final entry in state.channelMentionCounts.entries) {
      if (entry.key.startsWith('$serverId:')) {
        total += entry.value;
      }
    }
    return total;
  }

  bool isChannelMentioned(String serverId, String channelId) {
    return channelMentionCount(serverId, channelId) > 0;
  }

  /// Whether any DM has unread messages.
  bool hasAnyDmUnread() {
    return state.dmUnreadCounts.values.any((c) => c > 0);
  }
}

/// Immutable unread state.
class UnreadState {
  /// Last seen message ID per channel (key: "serverId:channelId").
  final Map<String, String> channelLastSeen;

  /// Last seen message ID per DM (key: peerId).
  final Map<String, String> dmLastSeen;

  /// Current unread counts per channel (key: "serverId:channelId").
  final Map<String, int> channelUnreadCounts;

  /// Current unread counts per DM (key: peerId).
  final Map<String, int> dmUnreadCounts;

  /// Latest message ID per channel (for marking seen).
  final Map<String, String> channelLatestId;

  /// Latest message ID per DM.
  final Map<String, String> dmLatestId;

  /// Mention counts per channel (key: "serverId:channelId").
  final Map<String, int> channelMentionCounts;

  const UnreadState({
    this.channelLastSeen = const {},
    this.dmLastSeen = const {},
    this.channelUnreadCounts = const {},
    this.dmUnreadCounts = const {},
    this.channelLatestId = const {},
    this.dmLatestId = const {},
    this.channelMentionCounts = const {},
  });

  UnreadState copyWith({
    Map<String, String>? channelLastSeen,
    Map<String, String>? dmLastSeen,
    Map<String, int>? channelUnreadCounts,
    Map<String, int>? dmUnreadCounts,
    Map<String, String>? channelLatestId,
    Map<String, String>? dmLatestId,
    Map<String, int>? channelMentionCounts,
  }) {
    return UnreadState(
      channelLastSeen: channelLastSeen ?? this.channelLastSeen,
      dmLastSeen: dmLastSeen ?? this.dmLastSeen,
      channelUnreadCounts: channelUnreadCounts ?? this.channelUnreadCounts,
      dmUnreadCounts: dmUnreadCounts ?? this.dmUnreadCounts,
      channelLatestId: channelLatestId ?? this.channelLatestId,
      dmLatestId: dmLatestId ?? this.dmLatestId,
      channelMentionCounts: channelMentionCounts ?? this.channelMentionCounts,
    );
  }
}

final unreadProvider =
    NotifierProvider<UnreadNotifier, UnreadState>(UnreadNotifier.new);
