import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/core/message_preview.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/channel_layout.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/hidden_archive_dm_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/pending_join_provider.dart';
import 'package:hollow/src/core/providers/saved_messages_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/time_labels.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/conversation_row.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_count_badge.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/saved_messages_avatar.dart';
import 'package:hollow/src/ui/components/server_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/pending_join_ui.dart';
import 'package:hollow/src/ui/animations/ambient_background.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/dialogs/export_archive_dialog.dart';
import 'package:hollow/src/ui/dialogs/invite_dialog.dart';
import 'package:hollow/src/ui/dialogs/create_channel_dialog.dart';
import 'package:hollow/src/ui/dialogs/new_message_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_channel_actions.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_conferences_route.dart';
import 'package:hollow/src/ui/mobile/mobile_voice_channel_route.dart';
import 'package:hollow/src/ui/mobile/mobile_server_settings_route.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_friends_tab.dart'
    show showMobileAddFriendSheet;
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart'
    show openMobileProfileSettings;
import 'package:hollow/src/ui/shell/home_dashboard.dart';
import 'package:hollow/src/ui/shell/home_inbox.dart';
import 'package:hollow/src/ui/shell/home_rail.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/ui/dialogs/relay_switch_dialog.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';

/// The phone's Home: the desktop inbox (greeting, Needs Attention, the setup
/// checklist, All / Unread / Mentions) plus the server list, which on a phone
/// has no dock to live in.
///
/// Brief (design language 5.1). Job: see what needs me and get back into my
/// conversations and servers. Focal point: the list. Primary action: none on
/// the list itself (a row is the action); New message sits in the title row
/// because the nav bar's centre button already carries the accent.
class MobileChatsTab extends ConsumerStatefulWidget {
  const MobileChatsTab({super.key});

  @override
  ConsumerState<MobileChatsTab> createState() => _MobileChatsTabState();
}

class _MobileHomeActions extends HomeActions {
  const _MobileHomeActions();

  @override
  bool get touch => true;

  /// The App Store and Play update a phone.
  @override
  bool get installsUpdates => false;

  @override
  void openUpdate(BuildContext context) {}

  @override
  void addFriend(BuildContext context) => showMobileAddFriendSheet(context);

  @override
  void addServer(BuildContext context) => showNewConversationDialog(context);

  @override
  void editProfile(BuildContext context) => openMobileProfileSettings(context);
}

const _actions = _MobileHomeActions();

const double _kAvatar = 48;

/// Voice rooms shown before the list; past this they would push it off the
/// first screen.
const int _kRoomCap = 2;

class _MobileChatsTabState extends ConsumerState<MobileChatsTab> {
  final _expandedServers = <String>{};
  HomeFilter _filter = HomeFilter.all;
  String _query = '';

  void _openDmChat(String peerId) {
    ref.read(selectedPeerProvider.notifier).state = peerId;
    ref.read(selectedServerProvider.notifier).state = null;
    Navigator.of(context, rootNavigator: true).push(
      hollowMobileRoute(
        settings: const RouteSettings(name: MobileChatRoute.routeName),
        builder: (_) => MobileChatRoute(peerId: peerId),
      ),
    ).then((_) {
      // Guarded: a notification tap may have replaced this chat already.
      if (mounted && ref.read(selectedPeerProvider) == peerId) {
        ref.read(selectedPeerProvider.notifier).state = null;
      }
    });
  }

  void _showDmSheet(BuildContext context, String peerId, String name) {
    showHollowSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: _DmContextSheet(
          peerId: peerId,
          name: name,
          onDismiss: () => Navigator.pop(context),
        ),
      ),
    );
  }

  void _showServerSheet(BuildContext context, String serverId, String serverName) {
    showHollowSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: _ServerContextSheet(
          serverId: serverId,
          serverName: serverName,
          onNavigateSettings: () {
            Navigator.pop(context);
            Navigator.of(context, rootNavigator: true).push(
              hollowMobileRoute(
                builder: (_) => MobileServerSettingsRoute(serverId: serverId),
              ),
            );
          },
        ),
      ),
    );
  }

  void _openChannelChat(String serverId, String channelId, String channelName) {
    ref.read(selectedServerProvider.notifier).state = serverId;
    ref.read(selectedChannelProvider.notifier).state = channelId;
    Navigator.of(context, rootNavigator: true).push(
      hollowMobileRoute(
        settings: const RouteSettings(name: MobileChatRoute.routeName),
        builder: (_) => MobileChatRoute(
          serverId: serverId,
          channelId: channelId,
          channelName: channelName,
        ),
      ),
    ).then((_) {
      // Guarded: a notification tap may have replaced this chat already.
      if (mounted && ref.read(selectedChannelProvider) == channelId) {
        ref.read(selectedServerProvider.notifier).state = null;
        ref.read(selectedChannelProvider.notifier).state = null;
      }
    });
  }

  Future<void> _openVoiceChannel(String serverId, ChannelInfo channel) async {
    final vcState = ref.read(voiceChannelProvider);
    final callState = ref.read(callProvider);

    if (callState.status != CallStatus.idle) {
      if (mounted) {
        HollowToast.show(context, 'Leave your call first',
            type: HollowToastType.error);
      }
      return;
    }

    // Already in THIS voice channel.
    if (vcState.currentServerId == serverId &&
        vcState.currentChannelId == channel.channelId) {
      if (!mounted) return;
      final nav = Navigator.of(context, rootNavigator: true);
      ref.read(selectedServerProvider.notifier).state = serverId;
      ref.read(selectedChannelProvider.notifier).state = channel.channelId;
      nav.push(
        hollowMobileRoute(
          settings: const RouteSettings(name: MobileChatRoute.routeName),
          builder: (_) => MobileChatRoute(
            serverId: serverId,
            channelId: channel.channelId,
            channelName: channel.name,
          ),
        ),
      ).then((_) {
        // Guarded: a notification tap may have replaced this chat already.
        if (mounted && ref.read(selectedChannelProvider) == channel.channelId) {
          ref.read(selectedServerProvider.notifier).state = null;
          ref.read(selectedChannelProvider.notifier).state = null;
        }
      });
      nav.push(hollowMobileRoute(
        transition: HollowRouteTransition.slideUp,
        builder: (_) => MobileVoiceChannelRoute(
          serverId: serverId,
          channelId: channel.channelId,
          channelName: channel.name,
        ),
      ));
      return;
    }

    // Already in a DIFFERENT voice channel.
    if (vcState.isInVoiceChannel) {
      if (!mounted) return;
      final confirmed = await showHollowConfirm(
        context: context,
        title: 'Switch voice channel?',
        message: 'Leave current voice channel and join #${channel.name}?',
        confirmLabel: 'Switch',
      );
      if (confirmed != true || !mounted) return;
    }

    // Text chat is pushed first, so the back arrow reveals it under the voice
    // route.
    ref.read(voiceChannelProvider.notifier).joinChannel(serverId, channel.channelId);
    if (!mounted) return;
    final nav = Navigator.of(context, rootNavigator: true);
    ref.read(selectedServerProvider.notifier).state = serverId;
    ref.read(selectedChannelProvider.notifier).state = channel.channelId;
    nav.push(
      hollowMobileRoute(
        settings: const RouteSettings(name: MobileChatRoute.routeName),
        builder: (_) => MobileChatRoute(
          serverId: serverId,
          channelId: channel.channelId,
          channelName: channel.name,
        ),
      ),
    ).then((_) {
      // Guarded: a notification tap may have replaced this chat already.
      if (mounted && ref.read(selectedChannelProvider) == channel.channelId) {
        ref.read(selectedServerProvider.notifier).state = null;
        ref.read(selectedChannelProvider.notifier).state = null;
      }
    });
    nav.push(hollowMobileRoute(
      transition: HollowRouteTransition.slideUp,
      builder: (_) => MobileVoiceChannelRoute(
        serverId: serverId,
        channelId: channel.channelId,
        channelName: channel.name,
      ),
    ));
  }

  Future<void> _openVoiceRoom(HomeVoiceRoom room) async {
    final channels =
        await ref.read(serverChannelsProvider(room.serverId).future);
    final channel = channels[room.channelId];
    if (channel == null || !mounted) return;
    await _openVoiceChannel(room.serverId, channel);
  }

  void _newMessage() => showNewMessageDialog(
        context,
        onOpen: (_, peerId) => _openDmChat(peerId),
        onAddFriend: showMobileAddFriendSheet,
      );

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final servers = ref.watch(serverListProvider);
    final hasFriends = ref.watch(sortedFriendsProvider).isNotEmpty;
    final firstRun = homeIsFirstRun(ref);
    final showSetup = homeShowsSetup(ref);
    final unread = ref.watch(unreadProvider);
    final hiddenDms = ref.watch(hiddenArchiveDmsProvider);

    final dms = [
      for (final c in homeDmConversations(ref))
        if (!hiddenDms.contains(c.peerId)) _DmEntry(c),
    ];
    final serverEntries = [
      for (final server in servers.values)
        _ServerEntry(
          serverId: server.serverId,
          name: server.name,
          memberCount: server.memberCount,
          unread: unread.serverUnreadCount(server.serverId),
          mentions: unread.serverMentionCount(server.serverId),
        ),
    ];
    // Servers carry no time, so what is unread leads and the rest keep a
    // stable order under the DMs.
    final ranked = <_Entry>[...dms, ...serverEntries]..sort((a, b) {
        if (a.isUnread != b.isUnread) return a.isUnread ? -1 : 1;
        final at = a.at ?? DateTime(2000);
        final bt = b.at ?? DateTime(2000);
        if (at != bt) return bt.compareTo(at);
        return a.name.compareTo(b.name);
      });
    final mentions = [
      for (final c in homeMentionConversations(ref)..sort(homeNewestFirst))
        _MentionEntry(c),
    ];

    final q = _query.trim().toLowerCase();
    bool matches(_Entry e) => q.isEmpty || e.searchText.contains(q);

    final savedId = ref.watch(savedMessagesPeerIdProvider);
    final pendingJoins = ref.watch(pendingJoinsProvider);
    final List<_Entry> shown = switch (_filter) {
      // Saved messages and parked joins are pinned above the ranking: one is
      // a note to yourself, the other has no name or activity to rank by.
      HomeFilter.all => [
          if (savedId != null && matches(_SavedEntry(savedId))) _SavedEntry(savedId),
          if (q.isEmpty)
            for (final id in pendingJoins.keys) _PendingEntry(id),
          ...ranked.where(matches),
        ],
      HomeFilter.unread => ranked.where((e) => e.isUnread && matches(e)).toList(),
      HomeFilter.mentions => mentions.where(matches).toList(),
    };
    final hasConversations = ranked.isNotEmpty;
    final rooms = homeVoiceRooms(ref);

    return AmbientBackground(
      color1: hollow.accent,
      color2: hollow.accent,
      opacity: 0.12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HollowSpacing.lg,
              HollowSpacing.sm,
              HollowSpacing.xs,
              0,
            ),
            child: Row(
              children: [
                Expanded(child: HomeGreeting(firstRun: firstRun)),
                _HeaderAction(
                  icon: LucideIcons.video,
                  label: 'Conferences',
                  onTap: () {
                    Navigator.of(context, rootNavigator: true).push(
                      hollowMobileRoute(
                        builder: (_) => const MobileConferencesRoute(),
                      ),
                    );
                  },
                ),
                if (hasFriends)
                  _HeaderAction(
                    icon: LucideIcons.squarePen,
                    label: 'New message',
                    onTap: _newMessage,
                  ),
              ],
            ),
          ),
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (firstRun)
                          Text(
                            kHomeFirstRunLine,
                            style: HollowTypography.body
                                .copyWith(color: hollow.textSecondary),
                          ),
                        if (hasConversations) ...[
                          const SizedBox(height: HollowSpacing.sm),
                          HollowTextField(
                            isDense: true,
                            hintText: 'Search conversations',
                            prefixIcon: Icon(LucideIcons.search,
                                size: 16, color: hollow.textTertiary),
                            onChanged: (v) => setState(() => _query = v),
                          ),
                        ],
                        const HomeAttention(actions: _actions),
                        if (showSetup)
                          HomeSetupChecklist(
                            actions: _actions,
                            compact: hasConversations,
                          ),
                        if (rooms.isNotEmpty) ...[
                          const SizedBox(height: HollowSpacing.xl),
                          const HollowSectionHeader('Active Now'),
                          for (final room in rooms.take(_kRoomCap)) ...[
                            HomeVoiceRoomTile(
                              key: ValueKey('${room.serverId}/${room.channelId}'),
                              room: room,
                              touch: true,
                              onOpen: _openVoiceRoom,
                            ),
                            const SizedBox(height: HollowSpacing.xs),
                          ],
                          if (rooms.length > _kRoomCap)
                            Text(
                              rooms.length - _kRoomCap == 1
                                  ? 'and 1 more room'
                                  : 'and ${rooms.length - _kRoomCap} more rooms',
                              style: HollowTypography.bodySmall
                                  .copyWith(color: hollow.textTertiary),
                            ),
                        ],
                        if (hasConversations) ...[
                          const SizedBox(height: HollowSpacing.xl),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: HomeFilters(
                              selected: _filter,
                              unreadCount: ranked.where((e) => e.isUnread).length,
                              mentionCount: mentions.length,
                              onSelect: (f) => setState(() => _filter = f),
                            ),
                          ),
                        ],
                        const SizedBox(height: HollowSpacing.sm),
                      ],
                    ),
                  ),
                ),
                if (shown.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: HollowSpacing.lg,
                        vertical: HollowSpacing.xl,
                      ),
                      child: homeNothingToShow(
                        nothingAtAll: !hasConversations,
                        query: _query,
                        filter: _filter,
                        emptyDescription:
                            'Add a friend or join a server to start chatting.',
                      ),
                    ),
                  )
                else
                  SliverList.builder(
                    itemCount: shown.length,
                    // Keyed by identity: this list mixes DMs and servers and
                    // reorders constantly, and without keys Flutter re-parents
                    // row State across DIFFERENT conversations.
                    findChildIndexCallback: (key) {
                      final i = shown.indexWhere((e) => ValueKey(e.key) == key);
                      return i < 0 ? null : i;
                    },
                    itemBuilder: (context, i) => KeyedSubtree(
                      key: ValueKey(shown[i].key),
                      child: _row(context, shown[i]),
                    ),
                  ),
                const SliverToBoxAdapter(
                    child: SizedBox(height: HollowSpacing.xl)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, _Entry entry) {
    final hollow = HollowTheme.of(context);
    switch (entry) {
      case _SavedEntry(:final peerId):
        final last = ref.watch(lastDmMessageProvider.select((m) => m[peerId]));
        // No context sheet: none of its actions apply to a conversation with
        // yourself, and every message in it is yours, so no "You:" either.
        return ConversationRow(
          touch: true,
          leading: const SavedMessagesAvatar(size: _kAvatar),
          title: 'Saved messages',
          preview: last?.previewText ?? '',
          time: last == null ? null : conversationTimeLabel(last.timestamp),
          onTap: () => _openDmChat(peerId),
        );
      case _PendingEntry(:final serverId):
        // Tap and long press open the same sheet: there is no server to
        // navigate into, and a tap that did nothing would read as broken.
        void openSheet() => showPendingJoinSheet(
              context: context,
              ref: ref,
              serverId: serverId,
            );
        return _PendingJoinRow(
          serverId: serverId,
          onTap: openSheet,
          onLongPress: openSheet,
        );
      case _DmEntry(:final c):
        return ConversationRow(
          touch: true,
          leading: homeConversationLeading(c, size: _kAvatar, ring: hollow.background),
          title: c.title,
          preview: c.preview,
          fromMe: c.fromMe,
          time: _timeFor(c),
          unread: c.unread,
          onTap: () => _openDmChat(c.peerId!),
          onLongPress: () => _showDmSheet(context, c.peerId!, c.title),
        );
      case _MentionEntry(:final c):
        return ConversationRow(
          touch: true,
          leading: homeConversationLeading(c, size: _kAvatar, ring: hollow.background),
          title: c.title,
          detail: c.detail,
          preview: c.preview,
          time: c.at == null ? null : conversationTimeLabel(c.at!),
          unread: c.unread,
          mention: true,
          onTap: () => _openChannelChat(
              c.serverId!, c.channelId!, c.channelName ?? ''),
        );
      case _ServerEntry():
        final id = entry.serverId;
        return _ServerRow(
          serverId: id,
          name: entry.name,
          unreadCount: entry.unread,
          mentionCount: entry.mentions,
          memberCount: entry.memberCount,
          isExpanded: _expandedServers.contains(id),
          onTap: () => setState(() {
            if (!_expandedServers.remove(id)) _expandedServers.add(id);
          }),
          onLongPress: () => _showServerSheet(context, id, entry.name),
          onChannelTap: (channel) {
            if (channel.channelType == ChannelType.voice) {
              _openVoiceChannel(id, channel);
            } else {
              _openChannelChat(id, channel.channelId, channel.name);
            }
          },
        );
    }
  }

  /// A friend with no messages yet has no time to show.
  String? _timeFor(HomeConversation c) {
    final at = c.at;
    if (at == null || at.year <= 2000) return null;
    return conversationTimeLabel(at);
  }
}

/// A plain icon action in the title row, at the 44 px touch target.
class _HeaderAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _HeaderAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      semanticLabel: label,
      onTap: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      padding: const EdgeInsets.all(HollowSpacing.md),
      child: Icon(icon, size: 20, color: hollow.textSecondary),
    );
  }
}

sealed class _Entry {
  const _Entry();
  String get key;
  String get name;
  String get searchText;
  bool get isUnread => false;
  DateTime? get at => null;
}

class _SavedEntry extends _Entry {
  final String peerId;
  const _SavedEntry(this.peerId);
  @override
  String get key => 'saved';
  @override
  String get name => 'Saved messages';
  @override
  String get searchText => 'saved messages';
}

class _PendingEntry extends _Entry {
  final String serverId;
  const _PendingEntry(this.serverId);
  @override
  String get key => 'pending-$serverId';
  @override
  String get name => '';
  @override
  String get searchText => '';
}

class _DmEntry extends _Entry {
  final HomeConversation c;
  const _DmEntry(this.c);
  @override
  String get key => c.key;
  @override
  String get name => c.title;
  @override
  String get searchText => c.searchText;
  @override
  bool get isUnread => c.isUnread;
  @override
  DateTime? get at => c.at;
}

class _MentionEntry extends _Entry {
  final HomeConversation c;
  const _MentionEntry(this.c);
  @override
  String get key => c.key;
  @override
  String get name => c.title;
  @override
  String get searchText => c.searchText;
  @override
  bool get isUnread => true;
  @override
  DateTime? get at => c.at;
}

class _ServerEntry extends _Entry {
  final String serverId;
  @override
  final String name;
  final int memberCount;
  final int unread;
  final int mentions;

  const _ServerEntry({
    required this.serverId,
    required this.name,
    required this.memberCount,
    required this.unread,
    required this.mentions,
  });

  @override
  String get key => 'srv-$serverId';
  @override
  String get searchText => name.toLowerCase();
  @override
  bool get isUnread => unread > 0 || mentions > 0;
}

/// A join we asked for that nobody has answered yet.
///
/// Greyed on purpose: there is nothing to open, and all we know about the
/// server is the id from the invite link. No spinner either, because the wait
/// is for another person to open their app.
class _PendingJoinRow extends ConsumerWidget {
  final String serverId;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _PendingJoinRow({
    required this.serverId,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final info = ref.watch(pendingJoinsProvider)[serverId];
    final rejected = info?.isRejected ?? false;

    return HollowPressable(
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel:
          '${pendingJoinTitle(rejected: rejected)}, show actions',
      subtle: true,
      borderRadius: BorderRadius.zero,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.md,
      ),
      child: Row(
        children: [
          Container(
            width: _kAvatar,
            height: _kAvatar,
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
            ),
            alignment: Alignment.center,
            child: Icon(
              rejected ? LucideIcons.ban : LucideIcons.clock,
              size: 20,
              color: hollow.textTertiary,
            ),
          ),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pendingJoinTitle(rejected: rejected),
                  style: HollowTypography.subheading.copyWith(
                    color: hollow.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  pendingJoinSubtitle(
                    rejected: rejected,
                    reason: info?.reason ?? '',
                  ),
                  style: HollowTypography.body
                      .copyWith(color: hollow.textTertiary),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DmContextSheet extends ConsumerWidget {
  final String peerId;
  final String name;
  final VoidCallback onDismiss;

  const _DmContextSheet({
    required this.peerId,
    required this.name,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final isDmMuted = !ref.watch(
        notificationSettingsProvider.select((s) => s.isDmEnabled(peerId)));
    final isHidden = ref.watch(
        hiddenArchiveDmsProvider.select((s) => s.contains(peerId)));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
          child: Text(name,
              style: HollowTypography.bodySmall
                  .copyWith(color: hollow.textSecondary),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(height: HollowSpacing.sm),
        _SheetAction(
          icon: isDmMuted ? LucideIcons.bell : LucideIcons.bellOff,
          label: isDmMuted ? 'Unmute Notifications' : 'Mute Notifications',
          onTap: () {
            ref.read(notificationSettingsProvider.notifier)
                .setDmEnabled(peerId, isDmMuted);
            onDismiss();
            HollowToast.show(context,
                isDmMuted ? 'Unmuted' : 'Muted',
                type: HollowToastType.success);
          },
        ),
        _SheetAction(
          icon: LucideIcons.fileOutput,
          label: 'Export Archive',
          onTap: () {
            onDismiss();
            showExportArchiveDialog(context,
                isDm: true, peerId: peerId, name: name, messageCount: 0);
          },
        ),
        _SheetAction(
          icon: isHidden ? LucideIcons.eye : LucideIcons.eyeOff,
          label: isHidden ? 'Show in Archive' : 'Hide from Archive',
          onTap: () {
            if (isHidden) {
              ref.read(hiddenArchiveDmsProvider.notifier).unhide(peerId);
            } else {
              ref.read(hiddenArchiveDmsProvider.notifier).hide(peerId);
            }
            onDismiss();
          },
        ),
        _SheetAction(
          icon: LucideIcons.copy,
          label: 'Copy Peer ID',
          onTap: () {
            Clipboard.setData(ClipboardData(text: peerId));
            onDismiss();
            HollowToast.show(context, 'Peer ID copied',
                type: HollowToastType.success);
          },
        ),
        const SizedBox(height: HollowSpacing.md),
      ],
    );
  }
}

class _ServerRow extends ConsumerWidget {
  final String serverId;
  final String name;
  final int unreadCount;
  final int mentionCount;
  final int memberCount;
  final bool isExpanded;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final void Function(ChannelInfo) onChannelTap;

  const _ServerRow({
    required this.serverId,
    required this.name,
    required this.unreadCount,
    required this.mentionCount,
    required this.memberCount,
    required this.isExpanded,
    required this.onTap,
    required this.onLongPress,
    required this.onChannelTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final hot = unreadCount > 0 || mentionCount > 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        HollowPressable(
          onTap: onTap,
          onLongPress: onLongPress,
          subtle: true,
          borderRadius: BorderRadius.zero,
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.lg,
            vertical: HollowSpacing.md,
          ),
          child: Row(
            children: [
              // No hover on touch, so an expanded row counts as watched.
              ServerAvatar(
                serverId: serverId,
                name: name,
                size: _kAvatar,
                animate: isExpanded,
              ),
              const SizedBox(width: HollowSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: HollowTypography.subheading.copyWith(
                        fontWeight: hot ? FontWeight.w600 : FontWeight.w500,
                        color: hollow.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      memberCount == 1 ? '1 member' : '$memberCount members',
                      style: HollowTypography.body.copyWith(
                        color: hollow.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              // Admitted after a parked join, still waiting for a member to
              // finish the MLS setup.
              if (ref.watch(awaitingSetupProvider
                  .select((s) => s.contains(serverId)))) ...[
                const AwaitingSetupBadge(),
                const SizedBox(width: HollowSpacing.sm),
              ],
              if (hot) ...[
                HollowCountBadge(
                  count: mentionCount > 0 ? mentionCount : unreadCount,
                  mention: mentionCount > 0,
                ),
                const SizedBox(width: HollowSpacing.sm),
              ],
              AnimatedRotation(
                turns: isExpanded ? 0.5 : 0.0,
                duration: HollowDurations.fast,
                curve: HollowCurves.enter,
                child: Icon(
                  LucideIcons.chevronDown,
                  size: 20,
                  color: hollow.textSecondary,
                ),
              ),
            ],
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: _ChannelList(
            serverId: serverId,
            onChannelTap: onChannelTap,
          ),
          crossFadeState:
              isExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: HollowDurations.fast,
          sizeCurve: HollowCurves.enter,
        ),
      ],
    );
  }
}

/// Channel rows start under the server name.
const double _kTreeIndent = _kAvatar + HollowSpacing.lg + HollowSpacing.md;

/// The tree line runs down the server avatar's centre.
const double _kTreeLeft = HollowSpacing.lg + _kAvatar / 2;

class _ChannelList extends ConsumerStatefulWidget {
  final String serverId;
  final void Function(ChannelInfo) onChannelTap;

  const _ChannelList({
    required this.serverId,
    required this.onChannelTap,
  });

  @override
  ConsumerState<_ChannelList> createState() => _ChannelListState();
}

class _ChannelListState extends ConsumerState<_ChannelList> {
  List<_DisplayItem> _displayItems = [];
  final _collapsedCategories = <String, bool>{};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadChannels();
  }

  @override
  void didUpdateWidget(covariant _ChannelList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A State reused for a DIFFERENT server still holds the old one's cached
    // display items.
    if (oldWidget.serverId != widget.serverId) {
      setState(() {
        _displayItems = [];
        _collapsedCategories.clear();
        _loading = true;
      });
      _loadChannels();
    }
  }

  Future<void> _loadChannels() async {
    final results = await Future.wait([
      ChannelListNotifier.fetchChannels(widget.serverId),
      ChannelLayoutNotifier.fetchLayout(widget.serverId),
    ]);
    if (!mounted) return;
    final channelMap = results[0] as Map<String, ChannelInfo>;
    final layoutJson = results[1] as String;
    setState(() {
      _displayItems = _buildDisplayItems(channelMap, layoutJson);
      _loading = false;
    });
  }

  List<_DisplayItem> _buildDisplayItems(
    Map<String, ChannelInfo> allChannels,
    String layoutJson,
  ) {
    // `meCanSee` is Rust's full access predicate (tier, label gates, grants);
    // never re-implement the ladder here.
    final channels = <String, ChannelInfo>{
      for (final e in allChannels.entries)
        if (e.value.meCanSee) e.key: e.value,
    };

    final items = <_DisplayItem>[];
    String? currentCategory;

    // Channel LISTS render the normalised layout, never the stored one. The
    // appended channels must come out of this same call: tracked in a separate
    // loop they fall outside the pass that follows the open category, and a
    // channel under a trailing category survives collapsing it.
    final layout = effectiveLayoutFrom(parseLayoutJson(layoutJson), channels);
    for (final entry in layout) {
      switch (entry) {
        case CategoryItem(:final name):
          currentCategory = name;
          items.add(_CategoryDisplayItem(name));
        case SeparatorItem():
          currentCategory = null;
          items.add(_SeparatorDisplayItem());
        case ChannelItem(:final channelId):
          final ch = channels[channelId];
          if (ch == null) break;
          items.add(_ChannelDisplayItem(
            channel: ch,
            category: currentCategory,
          ));
      }
    }

    for (int i = 0; i < items.length; i++) {
      if (items[i] is _ChannelDisplayItem) {
        final next = i + 1 < items.length ? items[i + 1] : null;
        final isLast = next == null ||
            next is _CategoryDisplayItem ||
            next is _SeparatorDisplayItem;
        (items[i] as _ChannelDisplayItem).isLastInGroup = isLast;
      }
    }

    return items;
  }

  void _showChannelActions(BuildContext context, ChannelInfo channel, bool canManage) {
    showMobileChannelActions(
      context: context,
      serverId: widget.serverId,
      channel: channel,
      canManage: canManage,
      onChanged: _loadChannels,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Only THIS server's participant map, so mute, camera and share changes
    // elsewhere do not rebuild the whole channel tree.
    final voiceParticipantsByChannel = ref.watch(
        voiceChannelProvider.select((s) => s.participants[widget.serverId]));
    final unread = ref.watch(unreadProvider);
    final perms = ref.watch(myPermissionsProvider(widget.serverId)).valueOrNull ?? 0;
    final canManage = (perms & Permission.manageChannels) != 0;

    ref.listen(serverListProvider.select((s) => s[widget.serverId]),
        (prev, next) {
      if (prev != next) _loadChannels();
    });
    ref.listen(channelListProvider, (prev, next) {
      if (prev != next) _loadChannels();
    });
    // Visibility, posting and role changes must refresh THIS list even when no
    // server is selected, which is the common Chats-tab case where
    // `channelListProvider` is stale.
    ref.listen(serverChannelsProvider(widget.serverId), (prev, next) {
      _loadChannels();
    });
    ref.listen(myRoleProvider(widget.serverId), (prev, next) {
      if (prev?.valueOrNull != next.valueOrNull) _loadChannels();
    });
    ref.listen(myPermissionsProvider(widget.serverId), (prev, next) {
      if (prev?.valueOrNull != next.valueOrNull) _loadChannels();
    });

    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(
          left: _kTreeIndent,
          bottom: HollowSpacing.sm,
          top: HollowSpacing.xs,
        ),
        child: HollowSpinner(),
      );
    }

    final hasChannels = _displayItems.any((i) => i is _ChannelDisplayItem);
    if (!hasChannels && !canManage) {
      return const Padding(
        padding: EdgeInsets.only(
          left: _kTreeIndent,
          bottom: HollowSpacing.sm,
        ),
        child: HollowEmptyState(dense: true, title: 'No channels'),
      );
    }

    final widgets = <Widget>[];
    for (final item in _displayItems) {
      if (item is _CategoryDisplayItem) {
        final collapsed = _collapsedCategories[item.name] ?? false;
        widgets.add(_CategoryHeaderRow(
          name: item.name,
          isCollapsed: collapsed,
          onToggle: () => setState(() {
            _collapsedCategories[item.name] = !collapsed;
          }),
        ));
      } else if (item is _SeparatorDisplayItem) {
        widgets.add(const _TreeSeparatorRow());
      } else if (item is _ChannelDisplayItem) {
        final collapsed = item.category != null &&
            (_collapsedCategories[item.category] ?? false);
        if (!collapsed) {
          final ch = item.channel;
          widgets.add(_TreeChannelRow(
            channel: ch,
            serverId: widget.serverId,
            unreadCount: unread.channelUnreadCount(widget.serverId, ch.channelId),
            mentionCount:
                unread.channelMentions(widget.serverId, ch.channelId),
            voiceParticipants: ch.channelType == ChannelType.voice
                ? (voiceParticipantsByChannel?[ch.channelId]?.length ?? 0)
                : 0,
            isLast: item.isLastInGroup && !canManage,
            onTap: () => widget.onChannelTap(ch),
            onLongPress: () => _showChannelActions(context, ch, canManage),
          ));
        }
      }
    }

    if (canManage) {
      widgets.add(_CreateChannelRow(
        isLast: true,
        onTap: () => showCreateChannelDialog(
          context, widget.serverId, onCreated: (_) => _loadChannels()),
      ));
    }
    widgets.add(const SizedBox(height: HollowSpacing.xs));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: widgets,
    );
  }
}

sealed class _DisplayItem {}

class _CategoryDisplayItem extends _DisplayItem {
  final String name;
  _CategoryDisplayItem(this.name);
}

class _SeparatorDisplayItem extends _DisplayItem {}

class _ChannelDisplayItem extends _DisplayItem {
  final ChannelInfo channel;
  final String? category;
  bool isLastInGroup = false;
  _ChannelDisplayItem({required this.channel, required this.category});
}

class _TreeSeparatorRow extends StatelessWidget {
  const _TreeSeparatorRow();

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final lineColor = hollow.textSecondary.withValues(alpha: 0.7);
    const double treeLeft = _kTreeLeft;

    return SizedBox(
      height: 12,
      child: Stack(
        children: [
          Positioned(
            left: treeLeft,
            top: 0,
            bottom: 0,
            child: SizedBox(
              width: 1,
              child: ColoredBox(color: lineColor),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryHeaderRow extends StatelessWidget {
  final String name;
  final bool isCollapsed;
  final VoidCallback onToggle;

  const _CategoryHeaderRow({
    required this.name,
    required this.isCollapsed,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: onToggle,
      subtle: true,
      padding: const EdgeInsets.only(
        left: _kTreeIndent,
        right: HollowSpacing.lg,
        top: HollowSpacing.sm,
        bottom: HollowSpacing.xs,
      ),
      child: Row(
        children: [
          AnimatedRotation(
            turns: isCollapsed ? -0.25 : 0,
            duration: HollowDurations.fast,
            curve: HollowCurves.enter,
            child: Icon(LucideIcons.chevronDown, size: 14, color: hollow.textSecondary),
          ),
          const SizedBox(width: HollowSpacing.xs),
          Text(
            name,
            style: HollowTypography.bodySmall.copyWith(
              color: hollow.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _TreeChannelRow extends StatelessWidget {
  final ChannelInfo channel;
  final String serverId;
  final int unreadCount;
  final int mentionCount;
  final int voiceParticipants;
  final bool isLast;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _TreeChannelRow({
    required this.channel,
    required this.serverId,
    required this.unreadCount,
    required this.mentionCount,
    required this.voiceParticipants,
    required this.isLast,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final lineColor = hollow.textSecondary.withValues(alpha: 0.7);
    const double treeLeft = _kTreeLeft;

    return Stack(
      children: [
        Positioned(
          left: treeLeft,
          top: 0,
          bottom: isLast ? null : 0,
          child: SizedBox(
            width: 1,
            height: isLast ? null : double.infinity,
            child: ColoredBox(color: lineColor),
          ),
        ),
        Positioned(
          left: treeLeft,
          top: 18,
          child: SizedBox(
            width: 12,
            height: 1,
            child: ColoredBox(color: lineColor),
          ),
        ),
        if (isLast)
          Positioned(
            left: treeLeft,
            top: 0,
            child: SizedBox(
              width: 1,
              height: 19,
              child: ColoredBox(color: lineColor),
            ),
          ),
        _ChannelRow(
          channel: channel,
          serverId: serverId,
          unreadCount: unreadCount,
          mentionCount: mentionCount,
          voiceParticipants: voiceParticipants,
          onTap: onTap,
          onLongPress: onLongPress,
        ),
      ],
    );
  }
}

class _CreateChannelRow extends StatelessWidget {
  final bool isLast;
  final VoidCallback onTap;

  const _CreateChannelRow({required this.isLast, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final lineColor = hollow.textSecondary.withValues(alpha: 0.7);
    const double treeLeft = _kTreeLeft;

    return Stack(
      children: [
        Positioned(
          left: treeLeft,
          top: 0,
          child: SizedBox(
            width: 1,
            height: 19,
            child: ColoredBox(color: lineColor),
          ),
        ),
        Positioned(
          left: treeLeft,
          top: 18,
          child: SizedBox(
            width: 12,
            height: 1,
            child: ColoredBox(color: lineColor),
          ),
        ),
        HollowPressable(
          onTap: onTap,
          subtle: true,
          padding: const EdgeInsets.only(
            left: _kTreeIndent,
            right: HollowSpacing.lg,
            top: HollowSpacing.sm,
            bottom: HollowSpacing.sm,
          ),
          child: Row(
            children: [
              Icon(LucideIcons.plus, size: 14, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                'New channel',
                style: HollowTypography.body.copyWith(
                  color: hollow.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ChannelRow extends StatelessWidget {
  final ChannelInfo channel;
  final String serverId;
  final int unreadCount;
  final int mentionCount;
  final int voiceParticipants;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ChannelRow({
    required this.channel,
    required this.serverId,
    required this.unreadCount,
    required this.mentionCount,
    required this.voiceParticipants,
    required this.onTap,
    this.onLongPress,
  });

  bool get hasUnread => unreadCount > 0 || mentionCount > 0;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final isVoice = channel.channelType == ChannelType.voice;

    return HollowPressable(
      onTap: onTap,
      onLongPress: onLongPress,
      subtle: true,
      padding: const EdgeInsets.only(
        left: _kTreeIndent,
        right: HollowSpacing.lg,
        top: HollowSpacing.sm,
        bottom: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(
            isVoice ? LucideIcons.volume2 : LucideIcons.hash,
            size: 16,
            color: hasUnread ? hollow.textPrimary : hollow.textSecondary,
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              channel.name,
              style: HollowTypography.body.copyWith(
                fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w400,
                color: hasUnread ? hollow.textPrimary : hollow.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Public indicator (#44).
          if (channel.isPublic) ...[
            const SizedBox(width: HollowSpacing.xs),
            Semantics(
              label: 'Public channel',
              child: Icon(
                LucideIcons.globe,
                size: 14,
                color: hollow.textTertiary,
              ),
            ),
          ],
          if (isVoice && voiceParticipants > 0) ...[
            const SizedBox(width: HollowSpacing.sm),
            HollowBadge(
              '$voiceParticipants',
              kind: HollowBadgeKind.success,
              icon: LucideIcons.users,
            ),
          ],
          if (hasUnread && !isVoice) ...[
            const SizedBox(width: HollowSpacing.sm),
            HollowCountBadge(
              count: mentionCount > 0 ? mentionCount : unreadCount,
              mention: mentionCount > 0,
            ),
          ],
        ],
      ),
    );
  }
}

void showNewConversationDialog(BuildContext context) {
  showHollowDialog(
    context: context,
    builder: (_) => const NewConversationDialog(),
  );
}

class NewConversationDialog extends ConsumerStatefulWidget {
  const NewConversationDialog({super.key});

  @override
  ConsumerState<NewConversationDialog> createState() =>
      _NewConversationDialogState();
}

class _NewConversationDialogState
    extends ConsumerState<NewConversationDialog> {
  final _joinController = TextEditingController();
  final _createController = TextEditingController();

  @override
  void dispose() {
    _joinController.dispose();
    _createController.dispose();
    super.dispose();
  }

  Future<void> _handleJoin() async {
    final input = _joinController.text.trim();
    if (input.isEmpty) return;

    // Accepts a hollow:// link, a web /join#server= link or a raw server id.
    final invite = inviteFromInput(input, HollowLinkType.serverInvite);
    final serverId = invite.id;

    if (!await ensureRelayForInviteId(context, ref,
        type: HollowLinkType.serverInvite,
        id: serverId,
        relay: invite.relay)) {
      return;
    }
    if (!mounted) return;

    Navigator.of(context).pop();
    crdt_api.joinServer(serverId: serverId, nsfwConfirmed: false);
    HollowToast.show(context, 'Joining server...',
        type: HollowToastType.info);
  }

  Future<void> _handleCreate() async {
    final name = _createController.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop();
    await crdt_api.createServer(name: name);
    if (mounted) {
      HollowToast.show(context, 'Server created',
          type: HollowToastType.success);
    }
  }

  @override
  Widget build(BuildContext context) {
    return HollowDialog(
      title: 'New',
      showClose: true,
      maxWidth: 400,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HollowSectionHeader('Join a Server'),
          _InputRow(
            controller: _joinController,
            hint: 'Invite link or server ID',
            mono: true,
            buttonLabel: 'Join',
            onSubmit: _handleJoin,
          ),
          const SizedBox(height: HollowSpacing.xl),
          const HollowSectionHeader('Create a Server'),
          _InputRow(
            controller: _createController,
            hint: 'Server name',
            mono: false,
            buttonLabel: 'Create',
            onSubmit: _handleCreate,
          ),
        ],
      ),
    );
  }
}

class _InputRow extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool mono;
  final String buttonLabel;
  final VoidCallback onSubmit;

  const _InputRow({
    required this.controller,
    required this.hint,
    required this.mono,
    required this.buttonLabel,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final textStyle = mono
        ? HollowTypography.mono.copyWith(color: hollow.textPrimary)
        : HollowTypography.body.copyWith(color: hollow.textPrimary);
    final hintStyle = mono
        ? HollowTypography.mono.copyWith(color: hollow.textSecondary)
        : HollowTypography.body.copyWith(color: hollow.textSecondary);

    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            style: textStyle,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: hintStyle,
              filled: true,
              fillColor: hollow.elevated,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.md,
                vertical: HollowSpacing.md,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                borderSide: BorderSide(color: hollow.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                borderSide: BorderSide(color: hollow.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                borderSide: BorderSide(color: hollow.accent),
              ),
            ),
            onSubmitted: (_) => onSubmit(),
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.filled(
          onPressed: onSubmit,
          compact: true,
          child: Text(buttonLabel),
        ),
      ],
    );
  }
}

class _ServerContextSheet extends ConsumerWidget {
  final String serverId;
  final String serverName;
  final VoidCallback onNavigateSettings;

  const _ServerContextSheet({
    required this.serverId,
    required this.serverName,
    required this.onNavigateSettings,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final role = ref.watch(myRoleProvider(serverId)).valueOrNull ?? 'member';
    final perms = ref.watch(myPermissionsProvider(serverId)).valueOrNull ?? 0;
    final isOwner = role == 'owner';
    final canManageChannels = (perms & Permission.manageChannels) != 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
            child: Text(
              serverName,
              style: HollowTypography.heading.copyWith(color: hollow.textPrimary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: HollowSpacing.lg),
          _SheetAction(
            icon: LucideIcons.settings,
            label: 'Server Settings',
            onTap: onNavigateSettings,
          ),
          if (canManageChannels)
            _SheetAction(
              icon: LucideIcons.plusCircle,
              label: 'Create Channel',
              onTap: () {
                Navigator.pop(context);
                showCreateChannelDialog(context, serverId);
              },
            ),
          _SheetAction(
            icon: LucideIcons.userPlus,
            label: 'Invite',
            onTap: () {
              Navigator.pop(context);
              final link = webServerInviteLink(serverId,
                  relay: ref.read(relayDomainProvider));
              showInviteDialog(context, link, serverId);
            },
          ),
          _SheetAction(
            icon: LucideIcons.copy,
            label: 'Copy Server ID',
            onTap: () {
              Clipboard.setData(ClipboardData(text: serverId));
              Navigator.pop(context);
              HollowToast.show(context, 'Server ID copied',
                  type: HollowToastType.success);
            },
          ),
          const SizedBox(height: HollowSpacing.sm),
          const HollowDivider(indent: HollowSpacing.lg, endIndent: HollowSpacing.lg),
          const SizedBox(height: HollowSpacing.sm),
          _SheetAction(
            icon: isOwner ? LucideIcons.trash2 : LucideIcons.logOut,
            label: isOwner ? 'Delete Server' : 'Leave Server',
            danger: true,
            onTap: () {
              Navigator.pop(context);
              _confirmLeaveOrDelete(context, ref, serverId, serverName, isOwner);
            },
          ),
        ],
      ),
    );
  }

  static Future<void> _confirmLeaveOrDelete(
    BuildContext context,
    WidgetRef ref,
    String serverId,
    String serverName,
    bool isOwner,
  ) async {
    final confirmed = await showHollowConfirm(
      context: context,
      title: isOwner ? 'Delete server' : 'Leave server',
      message: isOwner
          ? 'Are you sure you want to delete "$serverName"? This cannot be undone.'
          : 'Are you sure you want to leave "$serverName"?',
      confirmLabel: isOwner ? 'Delete' : 'Leave',
      destructive: true,
    );
    if (!confirmed) return;
    if (isOwner) {
      await crdt_api.deleteServer(serverId: serverId);
    } else {
      await crdt_api.leaveServer(serverId: serverId);
    }
    ref.read(selectedServerProvider.notifier).state = null;
    ref.read(selectedChannelProvider.notifier).state = null;
    ref.read(channelListProvider.notifier).clear();
    if (context.mounted) {
      HollowToast.show(
        context,
        isOwner ? 'Server deleted' : 'Left server',
        type: HollowToastType.success,
      );
    }
  }
}

class _SheetAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final color = danger ? hollow.error : hollow.textPrimary;
    return HollowPressable(
      onTap: onTap,
      subtle: true,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.md,
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: HollowSpacing.md),
          Text(
            label,
            style: HollowTypography.body.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
