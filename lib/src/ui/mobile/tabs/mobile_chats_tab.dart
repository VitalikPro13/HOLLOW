import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/name_color_provider.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/message_preview.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/hidden_archive_dm_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/saved_messages_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/time_labels.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/conversation_row.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/saved_messages_avatar.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/animations/ambient_background.dart';
import 'package:hollow/src/ui/dialogs/export_archive_dialog.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_servers_tab.dart'
    show showMobileAddServer;
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/ui/dialogs/new_message_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_conferences_route.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_navigation.dart';
import 'package:hollow/src/ui/mobile/mobile_archive_page.dart'
    show openMobileArchive;
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_friends_tab.dart'
    show showMobileAddFriendSheet;
import 'package:hollow/src/core/providers/settings_place_provider.dart'
    show SettingsCategory;
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart'
    show openMobileProfileSettings, openMobileSettingsPage;
import 'package:hollow/src/ui/shell/home_dashboard.dart';
import 'package:hollow/src/ui/shell/home_inbox.dart';
import 'package:hollow/src/ui/shell/home_rail.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';

/// The phone's Home: the desktop inbox (greeting, Needs Attention, the setup
/// checklist, All / Unread / Mentions). Servers have their own tab; channels
/// that mention you stay here, under Mentions.
///
/// Brief (design language 5.1). Job: see what needs me and get back into my
/// conversations. Focal point: the list. Primary action: none on
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
  void addServer(BuildContext context) => showMobileAddServer(context);

  @override
  void editProfile(BuildContext context) => openMobileProfileSettings(context);

  @override
  void openNotificationSettings(BuildContext context) =>
      openMobileSettingsPage(context, SettingsCategory.notifications);

  @override
  void openDevices(BuildContext context) =>
      openMobileSettingsPage(context, SettingsCategory.devices);
}

const _actions = _MobileHomeActions();

const double _kAvatar = 48;

/// Voice rooms shown before the list; past this they would push it off the
/// first screen.
const int _kRoomCap = 2;

class _MobileChatsTabState extends ConsumerState<MobileChatsTab> {
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

  /// One row of a long-press sheet: the sheet closes, then [onTap] runs
  /// against this tab, which outlives it.
  Widget _sheetRow(BuildContext sheetContext, IconData icon, String label,
      VoidCallback onTap) {
    return HollowListRow(
      touch: true,
      title: label,
      leading: Icon(icon,
          size: 20, color: HollowTheme.of(sheetContext).textSecondary),
      onTap: () {
        Navigator.pop(sheetContext);
        onTap();
      },
    );
  }

  /// Runs a sheet action that can fail, toasting [failed] when it does.
  void _report(Future<Object?> action, String failed, {String? done}) {
    action.then((_) {
      if (done != null && mounted) {
        HollowToast.show(context, done, type: HollowToastType.success);
      }
    }, onError: (Object _) {
      if (mounted) {
        HollowToast.show(context, failed, type: HollowToastType.error);
      }
    });
  }

  /// The labels are the desktop person menu's for a DM tile.
  void _showDmSheet(BuildContext context, String peerId, String name) {
    final master = ref.read(deviceLinkProvider).identityOf(peerId);
    final muted =
        !ref.read(notificationSettingsProvider).isDmEnabled(peerId);
    final hidden = ref.read(hiddenArchiveDmsProvider).contains(peerId);
    showHollowSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HollowSheetTitle(name),
            _sheetRow(sheetContext, LucideIcons.checkCheck, 'Mark as read',
                () => _report(
                    ref.read(unreadProvider.notifier).markDmSeenLatest(master),
                    'Could not mark the conversation read')),
            _sheetRow(
                sheetContext,
                muted ? LucideIcons.bell : LucideIcons.bellOff,
                muted ? 'Unmute conversation' : 'Mute conversation',
                () => _report(
                    ref
                        .read(notificationSettingsProvider.notifier)
                        .setDmEnabled(peerId, muted),
                    'Could not change notifications',
                    done: muted
                        ? 'Notifications unmuted'
                        : 'Notifications muted')),
            _sheetRow(sheetContext, LucideIcons.fileOutput,
                'Export conversation',
                () => showExportArchiveDialog(context,
                    isDm: true, peerId: peerId, name: name, messageCount: 0)),
            _sheetRow(
                sheetContext,
                hidden ? LucideIcons.eye : LucideIcons.eyeOff,
                hidden ? 'Show in archive' : 'Hide from archive', () {
              final archive = ref.read(hiddenArchiveDmsProvider.notifier);
              hidden ? archive.unhide(peerId) : archive.hide(peerId);
            }),
            _sheetRow(sheetContext, LucideIcons.copy, 'Copy user ID',
                () => _report(Clipboard.setData(ClipboardData(text: master)),
                    'Could not copy the user ID',
                    done: 'User ID copied')),
            const SizedBox(height: HollowSpacing.sm),
          ],
        ),
      ),
    );
  }

  Future<void> _openVoiceRoom(HomeVoiceRoom room) async {
    final Map<String, ChannelInfo> channels;
    try {
      channels = await ref.read(serverChannelsProvider(room.serverId).future);
    } catch (e) {
      if (mounted) {
        HollowToast.show(
            context, friendlyError(e, fallback: "Couldn't open the room"),
            type: HollowToastType.error);
      }
      return;
    }
    final channel = channels[room.channelId];
    if (channel == null || !mounted) return;
    await openMobileVoiceChannel(context, ref, room.serverId, channel);
  }

  void _newMessage() => showNewMessageDialog(
        context,
        onOpen: (_, peerId) => _openDmChat(peerId),
        onAddFriend: showMobileAddFriendSheet,
      );

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final hasFriends = ref.watch(sortedFriendsProvider).isNotEmpty;
    final firstRun = homeIsFirstRun(ref);
    final showSetup = homeShowsSetup(ref);
    final hiddenDms = ref.watch(hiddenArchiveDmsProvider);

    // Unread first, then newest; servers live on their own tab.
    final dms = [
      for (final c in homeDmConversations(ref))
        if (!hiddenDms.contains(c.peerId)) _DmEntry(c),
    ]..sort((a, b) {
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
    final List<_Entry> shown = switch (_filter) {
      // Saved messages is pinned above the ranking: a note to yourself.
      HomeFilter.all => [
          if (savedId != null && matches(_SavedEntry(savedId))) _SavedEntry(savedId),
          ...dms.where(matches),
        ],
      HomeFilter.unread => dms.where((e) => e.isUnread && matches(e)).toList(),
      HomeFilter.mentions => mentions.where(matches).toList(),
    };
    final hasConversations = dms.isNotEmpty || mentions.isNotEmpty;
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
                Expanded(
                  child: HomeGreeting(firstRun: firstRun, shedName: true),
                ),
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
                // The Archive page, which on a phone has no tab of its own.
                _HeaderAction(
                  icon: LucideIcons.archive,
                  label: 'Archive',
                  onTap: () => openMobileArchive(context, ref),
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
                              unreadCount: dms.where((e) => e.isUnread).length,
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
                if (shown.isEmpty && !hasConversations && !homeListsLoaded(ref))
                  SliverToBoxAdapter(
                    // Still reading friends and servers: nothing, never "none yet".
                    child: homeListsError(ref) == null
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: HollowSpacing.lg,
                              vertical: HollowSpacing.xl,
                            ),
                            child: HollowEmptyState(
                              dense: true,
                              title: "Your conversations didn't load",
                              description: friendlyError(homeListsError(ref)!),
                              action: HollowButton.ghost(
                                touch: true,
                                onPressed: () => homeRetryLists(ref),
                                child: const Text('Try again'),
                              ),
                            ),
                          ),
                  )
                else if (shown.isEmpty)
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
                      ),
                    ),
                  )
                else if (shown.isNotEmpty)
                  SliverList.builder(
                    itemCount: shown.length,
                    // Keyed by identity: this list reorders constantly, and
                    // without keys Flutter re-parents
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
      case _DmEntry(:final c):
        return ConversationRow(
          touch: true,
          leading: homeConversationLeading(c, size: _kAvatar, ring: hollow.opaqueBackground),
          title: c.title,
          titlePaint: ref.chosenNamePaintOf(c.peerId!, hollow),
          preview: c.preview,
          fromMe: c.fromMe,
          time: c.at == null ? null : conversationTimeLabel(c.at!),
          unread: c.unread,
          onTap: () => _openDmChat(c.peerId!),
          onLongPress: () => _showDmSheet(context, c.peerId!, c.title),
        );
      case _MentionEntry(:final c):
        return ConversationRow(
          touch: true,
          leading: homeConversationLeading(c, size: _kAvatar, ring: hollow.opaqueBackground),
          title: c.title,
          detail: c.detail,
          preview: c.preview,
          time: c.at == null ? null : conversationTimeLabel(c.at!),
          unread: c.unread,
          mention: true,
          onTap: () => openMobileChannel(context, ref,
              serverId: c.serverId!,
              channelId: c.channelId!,
              channelName: c.channelName),
        );
    }
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
