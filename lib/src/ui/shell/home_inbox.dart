import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/message_preview.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/channel_navigation.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/dm_navigation.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/home_setup_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/mention_preview_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/saved_messages_provider.dart';
import 'package:hollow/src/core/providers/security_alerts_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/core/time_labels.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/call_duration_text.dart';
import 'package:hollow/src/ui/components/conversation_row.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/saved_messages_avatar.dart';
import 'package:hollow/src/ui/components/server_avatar.dart';
import 'package:hollow/src/ui/dialogs/create_server_dialog.dart';
import 'package:hollow/src/ui/dialogs/device_link_dialog.dart';
import 'package:hollow/src/ui/dialogs/mnemonic_dialog.dart';
import 'package:hollow/src/ui/dialogs/verify_contact_dialog.dart';
import 'package:hollow/src/ui/shell/friends_bar.dart';
import 'package:hollow/src/ui/shell/home_dashboard.dart'
    show
        homeListsError,
        homeListsLoaded,
        homeRetryLists,
        homeShowsSetup,
        kHomeRowInset;
import 'package:hollow/src/ui/shell/user_context_menu.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// ---------------------------------------------------------------------------
// What Home's strips do on each platform.
// ---------------------------------------------------------------------------

/// The actions that differ between the desktop shell (dialogs) and the phone
/// (routes and sheets). The strips and the conversation data are shared.
abstract class HomeActions {
  const HomeActions();

  /// Phone layout: larger type, and a row's buttons sit under its text.
  bool get touch;

  /// False where the app store updates Hollow, so no update row is offered.
  bool get installsUpdates;

  void openUpdate(BuildContext context);
  void addFriend(BuildContext context);
  void addServer(BuildContext context);
  void editProfile(BuildContext context);
}

class DesktopHomeActions extends HomeActions {
  const DesktopHomeActions();

  @override
  bool get touch => false;

  @override
  bool get installsUpdates => true;

  @override
  void openUpdate(BuildContext context) => openSettings(
      ProviderScope.containerOf(context, listen: false).read,
      category: SettingsCategory.about);

  @override
  void addFriend(BuildContext context) =>
      showFriendsManager(context, addFriend: true);

  @override
  void addServer(BuildContext context) => showCreateServerDialog(context);

  @override
  void editProfile(BuildContext context) => openSettings(
      ProviderScope.containerOf(context, listen: false).read,
      category: SettingsCategory.profile);
}

// ---------------------------------------------------------------------------
// Needs Attention: things waiting on the person, shown only while they wait.
// ---------------------------------------------------------------------------

class _AttentionItem {
  final String id;
  final Widget leading;
  final String title;
  final String body;
  final String? secondaryLabel;
  final Future<void> Function()? onSecondary;
  final String primaryLabel;
  final Future<void> Function() onPrimary;

  /// Toast text when an action throws.
  final String failure;

  const _AttentionItem({
    required this.id,
    required this.leading,
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.onPrimary,
    required this.failure,
    this.secondaryLabel,
    this.onSecondary,
  });
}

/// Friend requests, a friend's new or changed device, a waiting update. Absent
/// entirely when nothing waits: healthy state is silent (design language 5.3).
class HomeAttention extends ConsumerStatefulWidget {
  final HomeActions actions;
  const HomeAttention({super.key, this.actions = const DesktopHomeActions()});

  @override
  ConsumerState<HomeAttention> createState() => _HomeAttentionState();
}

class _HomeAttentionState extends ConsumerState<HomeAttention> {
  bool _showAll = false;

  /// More than this and the strip starts pushing the conversations away.
  static const _collapsedCount = 3;

  @override
  Widget build(BuildContext context) {
    final items = [
      ..._securityItems(),
      ..._requestItems(),
      ..._phraseItems(),
      ..._updateItems(),
    ];
    if (items.isEmpty) return const SizedBox.shrink();

    final shown =
        _showAll ? items : items.take(_collapsedCount).toList(growable: false);
    return Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowSectionHeader('Needs Attention', count: '${items.length}'),
          for (final item in shown) ...[
            _AttentionRow(
              key: ValueKey(item.id),
              item: item,
              touch: widget.actions.touch,
            ),
            SizedBox(
                height: widget.actions.touch
                    ? HollowSpacing.sm
                    : HollowSpacing.xs),
          ],
          if (items.length > _collapsedCount)
            Align(
              alignment: Alignment.centerLeft,
              child: HollowButton.ghost(
                compact: true,
                onPressed: () => setState(() => _showAll = !_showAll),
                child: Text(_showAll
                    ? 'Show fewer'
                    : 'Show all ${items.length}'),
              ),
            ),
        ],
      ),
    );
  }

  List<_AttentionItem> _securityItems() {
    final alerts = ref.watch(securityAlertsProvider);
    final profiles = ref.watch(profileProvider);
    // displayNameFor reads the nickname cache, so a rename must rebuild.
    ref.watch(localNicknameProvider);
    final byPeer = <String, List<String>>{};
    for (final a in alerts) {
      if (a.acknowledgedAt != null) continue;
      (byPeer[a.peerId] ??= []).add(a.kind);
    }
    return [
      for (final MapEntry(key: peerId, value: kinds) in byPeer.entries)
        () {
          final name = displayNameFor(profiles, peerId);
          final newDevices =
              kinds.where((k) => k == SecurityAlertKind.newDevice).length;
          final (title, body) = kinds.contains(SecurityAlertKind.identityReappeared)
              ? (
                  '$name came back after deleting their identity',
                  'Check the safety number before you trust it.',
                )
              : newDevices > 0
                  ? (
                      newDevices == 1
                          ? '$name added a new device'
                          : '$name added $newDevices new devices',
                      'Verify them before you share anything sensitive.',
                    )
                  : (
                      '$name reinstalled or re-keyed a device',
                      'Their messages are still end-to-end encrypted.',
                    );
          return _AttentionItem(
            id: 'security:$peerId',
            leading: HollowAvatar(peerId: peerId, size: _leadingSize),
            title: title,
            body: body,
            secondaryLabel: 'Dismiss',
            onSecondary: () => ref
                .read(securityAlertsProvider.notifier)
                .acknowledgeForPeer(peerId),
            primaryLabel: 'Verify',
            // Not awaited: the dialog is the action, not a request to wait on.
            onPrimary: () async {
              showVerifyContactDialog(context, peerId: peerId);
            },
            failure: "Couldn't update the warning",
          );
        }(),
    ];
  }

  List<_AttentionItem> _requestItems() {
    final friends = ref.watch(friendsProvider);
    final profiles = ref.watch(profileProvider);
    ref.watch(localNicknameProvider);
    final incoming = friends.values
        .where((f) => f.status == 'pending' && f.direction == 'incoming')
        .toList()
      ..sort((a, b) => b.requestedAt.compareTo(a.requestedAt));
    return [
      for (final f in incoming)
        _AttentionItem(
          id: 'request:${f.peerId}',
          leading: HollowAvatar(peerId: f.peerId, size: _leadingSize),
          title: '${displayNameFor(profiles, f.peerId)} wants to be your friend',
          body: _sentLabel(f.requestedAt),
          secondaryLabel: 'Decline',
          onSecondary: () =>
              ref.read(friendsProvider.notifier).rejectRequest(f.peerId),
          primaryLabel: 'Accept',
          onPrimary: () =>
              ref.read(friendsProvider.notifier).acceptRequest(f.peerId),
          failure: "Couldn't answer the friend request",
        ),
    ];
  }

  /// The checklist carries this step while it shows; once it is hidden or
  /// finished, the reminder has to live here or it vanishes unanswered.
  List<_AttentionItem> _phraseItems() {
    final setup = ref.watch(homeSetupProvider);
    if (!setup.loaded || setup.phraseSaved || homeShowsSetup(ref)) {
      return const [];
    }
    return [
      _AttentionItem(
        id: 'phrase',
        leading: _GlyphTile(LucideIcons.keyRound, size: _leadingSize),
        title: "Your recovery phrase isn't backed up yet",
        body: 'It is the only way back in if this device is lost.',
        primaryLabel: 'Back up now',
        onPrimary: () async => showRecoveryPhrase(context, ref),
        failure: "Couldn't read your recovery phrase",
      ),
    ];
  }

  double get _leadingSize =>
      widget.actions.touch ? _kTouchLeadingSize : _kLeadingSize;

  List<_AttentionItem> _updateItems() {
    if (!widget.actions.installsUpdates) return const [];
    if (!ref.watch(hasUpdateProvider)) return const [];
    final update = ref.watch(updaterProvider);
    final latest = update.manifest?.latest;
    if (latest == null) return const [];
    return [
      _AttentionItem(
        id: 'update:$latest',
        leading: _GlyphTile(LucideIcons.download, size: _leadingSize),
        title: 'Hollow $latest is ready to install',
        body: 'You have ${update.currentVersion}.',
        primaryLabel: 'View update',
        onPrimary: () async => widget.actions.openUpdate(context),
        failure: "Couldn't open the update",
      ),
    ];
  }

  String _sentLabel(int requestedAtMs) {
    if (requestedAtMs <= 0) return 'Friend request';
    final label = conversationTimeLabel(
        DateTime.fromMillisecondsSinceEpoch(requestedAtMs));
    if (label.contains(':')) return 'Sent today at $label';
    if (label == 'Yesterday') return 'Sent yesterday';
    return 'Sent on $label';
  }
}

const double _kLeadingSize = 32;
const double _kTouchLeadingSize = 40;

/// A leading glyph for an item that is not a person, on the row's own surface.
class _GlyphTile extends StatelessWidget {
  final IconData icon;
  final double size;
  const _GlyphTile(this.icon, {required this.size});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: Icon(icon, size: 20, color: hollow.textSecondary),
    );
  }
}

class _AttentionRow extends StatefulWidget {
  final _AttentionItem item;
  final bool touch;
  const _AttentionRow({super.key, required this.item, required this.touch});

  @override
  State<_AttentionRow> createState() => _AttentionRowState();
}

class _AttentionRowState extends State<_AttentionRow> {
  bool _primaryBusy = false;
  bool _secondaryBusy = false;

  Future<void> _run(Future<void> Function() action, bool primary) async {
    setState(() => primary ? _primaryBusy = true : _secondaryBusy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        HollowToast.show(context, widget.item.failure,
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) {
        setState(() => primary ? _primaryBusy = false : _secondaryBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final item = widget.item;
    final touch = widget.touch;
    final busy = _primaryBusy || _secondaryBusy;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: (touch ? HollowTypography.subheading : HollowTypography.body)
              .copyWith(color: hollow.textPrimary, fontWeight: FontWeight.w500),
        ),
        Text(
          item.body,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: (touch ? HollowTypography.body : HollowTypography.bodySmall)
              .copyWith(color: hollow.textSecondary),
        ),
      ],
    );
    // Full size on touch, for the 44 px target.
    final buttons = [
      if (item.onSecondary != null)
        HollowButton.ghost(
          compact: !touch,
          loading: _secondaryBusy,
          onPressed: busy ? null : () => _run(item.onSecondary!, false),
          child: Text(item.secondaryLabel!),
        ),
      HollowButton.outline(
        compact: !touch,
        loading: _primaryBusy,
        onPressed: busy ? null : () => _run(item.onPrimary, true),
        child: Text(item.primaryLabel),
      ),
    ];
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: touch ? HollowSpacing.md : HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius:
            BorderRadius.circular(touch ? hollow.radiusLg : hollow.radiusMd),
      ),
      // A phone is too narrow for the text and two buttons on one line.
      child: touch
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    item.leading,
                    const SizedBox(width: HollowSpacing.md),
                    Expanded(child: text),
                  ],
                ),
                const SizedBox(height: HollowSpacing.sm),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: HollowSpacing.sm,
                  runSpacing: HollowSpacing.sm,
                  children: buttons,
                ),
              ],
            )
          : Row(
              children: [
                item.leading,
                const SizedBox(width: HollowSpacing.md),
                Expanded(child: text),
                for (var i = 0; i < buttons.length; i++) ...[
                  SizedBox(width: i == 0 ? HollowSpacing.md : HollowSpacing.sm),
                  buttons[i],
                ],
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Get Set Up: the first-run checklist, in place of an empty home.
// ---------------------------------------------------------------------------

class _SetupStep {
  final String title;
  final String? body;
  final bool done;
  final String action;
  final VoidCallback onAction;

  const _SetupStep({
    required this.title,
    required this.done,
    required this.action,
    required this.onAction,
    this.body,
  });
}

/// Shown while someone has no friend or no server yet, until they hide it.
class HomeSetupChecklist extends ConsumerStatefulWidget {
  final HomeActions actions;

  /// Only the next step until "Show all": on a phone the full list fills the
  /// first screen and pushes the conversations out of sight.
  final bool compact;

  const HomeSetupChecklist({
    super.key,
    this.actions = const DesktopHomeActions(),
    this.compact = false,
  });

  @override
  ConsumerState<HomeSetupChecklist> createState() => _HomeSetupChecklistState();
}

class _HomeSetupChecklistState extends ConsumerState<HomeSetupChecklist> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final actions = widget.actions;
    final setup = ref.watch(homeSetupProvider);
    final localId = ref.watch(identityProvider).peerId;
    final hasAvatar = localId != null &&
        (ref.watch(avatarProvider.select((c) => c[localId]))?.isNotEmpty ??
            false);

    final steps = [
      _SetupStep(
        title: 'Create your identity',
        done: true,
        action: '',
        onAction: () {},
      ),
      _SetupStep(
        title: 'Back up your recovery phrase',
        body: 'It is the only way back in if this device is lost. Nobody, us '
            'included, can recover it for you.',
        done: setup.phraseSaved,
        action: 'Back up now',
        onAction: () => showRecoveryPhrase(context, ref),
      ),
      _SetupStep(
        title: 'Add a friend',
        body: 'Send a request to someone you know, or accept theirs.',
        done: ref.watch(sortedFriendsProvider).isNotEmpty,
        action: 'Add friend',
        onAction: () => actions.addFriend(context),
      ),
      _SetupStep(
        title: 'Join or create a server',
        body: 'A server is a group space its members host together.',
        done: ref.watch(serverListProvider).isNotEmpty,
        action: 'Add a server',
        onAction: () => actions.addServer(context),
      ),
      _SetupStep(
        title: 'Set a profile picture',
        done: hasAvatar,
        action: 'Choose image',
        onAction: () => actions.editProfile(context),
      ),
      _SetupStep(
        title: 'Link another device',
        body: 'Use Hollow on your phone and computer with one identity.',
        done: ref.watch(myDevicesProvider).length > 1,
        action: 'Link device',
        onAction: () =>
            showDeviceLinkDialog(context, mode: DeviceLinkMode.showCode),
      ),
    ];
    final next = steps.indexWhere((s) => !s.done);
    final doneCount = steps.where((s) => s.done).length;
    final collapsed = widget.compact && !_showAll;

    return Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowSectionHeader(
            'Get Set Up',
            count: '$doneCount / ${steps.length}',
            action: HollowButton.ghost(
              compact: true,
              onPressed: () => ref
                  .read(homeSetupProvider.notifier)
                  .hide()
                  .catchError((_) {}),
              child: const Text('Hide'),
            ),
          ),
          for (var i = 0; i < steps.length; i++)
            if (!collapsed || i == next) ...[
              _SetupRow(step: steps[i], isNext: i == next, touch: actions.touch),
              const SizedBox(height: HollowSpacing.xs),
            ],
          if (widget.compact)
            Align(
              alignment: Alignment.centerLeft,
              child: HollowButton.ghost(
                compact: true,
                onPressed: () => setState(() => _showAll = !_showAll),
                child: Text(_showAll ? 'Show fewer' : 'Show all steps'),
              ),
            ),
        ],
      ),
    );
  }

}

/// Opens the recovery phrase, read from storage when this session has not
/// held it in memory.
Future<void> showRecoveryPhrase(BuildContext context, WidgetRef ref) async {
  var phrase = ref.read(identityProvider).mnemonic;
  if (phrase == null) {
    try {
      phrase = await storage_api.getMnemonic();
    } catch (_) {
      phrase = null;
    }
  }
  if (!context.mounted) return;
  if (phrase == null || phrase.isEmpty) {
    HollowToast.show(context, "Couldn't read your recovery phrase",
        type: HollowToastType.error);
    return;
  }
  showMnemonicDialog(context, phrase);
}

class _SetupRow extends StatelessWidget {
  final _SetupStep step;

  /// The first step not yet done carries the screen's one filled button.
  final bool isNext;
  final bool touch;

  const _SetupRow(
      {required this.step, required this.isNext, required this.touch});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final mark = step.done
        ? Icon(LucideIcons.circleCheck, size: 20, color: hollow.success)
        : Icon(LucideIcons.circle,
            size: 20, color: isNext ? hollow.accentText : hollow.textTertiary);
    final button = step.done
        ? null
        : isNext
            ? HollowButton.filled(
                onPressed: step.onAction,
                child: Text(step.action),
              )
            : HollowButton.outline(
                compact: !touch,
                onPressed: step.onAction,
                child: Text(step.action),
              );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          step.title,
          style: (touch ? HollowTypography.subheading : HollowTypography.body)
              .copyWith(
            color: step.done ? hollow.textTertiary : hollow.textPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (!step.done && step.body != null)
          Text(
            step.body!,
            style: (touch ? HollowTypography.body : HollowTypography.bodySmall)
                .copyWith(color: hollow.textSecondary),
          ),
        // A phone is too narrow for the text and a button on one line.
        if (touch && button != null) ...[
          const SizedBox(height: HollowSpacing.sm),
          button,
        ],
      ],
    );
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: isNext || touch ? HollowSpacing.md : HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: step.done ? null : hollow.elevated,
        borderRadius:
            BorderRadius.circular(touch ? hollow.radiusLg : hollow.radiusMd),
      ),
      child: Row(
        crossAxisAlignment:
            touch ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          Semantics(
            label: step.done ? 'Done' : 'Not done yet',
            child: ExcludeSemantics(child: mark),
          ),
          const SizedBox(width: HollowSpacing.md),
          Expanded(child: text),
          if (!touch && button != null) ...[
            const SizedBox(width: HollowSpacing.md),
            button,
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Conversations: DMs plus the channels that mentioned us.
// ---------------------------------------------------------------------------

/// Which slice of the inbox is showing. Shared by desktop Home and mobile Chats.
enum HomeFilter { all, unread, mentions }

/// One entry of the inbox, before a platform decides how it opens.
class HomeConversation {
  final String key;
  final String title;
  final String? detail;
  final String preview;
  final bool fromMe;
  final DateTime? at;
  final int unread;
  final bool mention;
  final String searchText;

  /// Set for a DM (the friend's MASTER id).
  final String? peerId;
  final bool online;

  /// Set for a channel that mentioned us.
  final String? serverId;
  final String? channelId;
  final String? channelName;
  final String? serverName;

  const HomeConversation({
    required this.key,
    required this.title,
    required this.preview,
    required this.at,
    required this.searchText,
    this.detail,
    this.fromMe = false,
    this.unread = 0,
    this.mention = false,
    this.peerId,
    this.online = false,
    this.serverId,
    this.channelId,
    this.channelName,
    this.serverName,
  });

  bool get isUnread => unread > 0 || mention;
}

/// The avatar a conversation row leads with, at [size], cut from [ring].
Widget homeConversationLeading(
  HomeConversation c, {
  required double size,
  required Color ring,
}) {
  final peerId = c.peerId;
  if (peerId != null) {
    return PresenceAvatar(
        peerId: peerId, size: size, online: c.online, ring: ring);
  }
  return ServerAvatar(
      serverId: c.serverId ?? '', name: c.serverName ?? '', size: size);
}

/// Newest first. A mention with no time (its words did not survive a restart)
/// is still unread, so it leads; a friend with no messages yet sinks.
int homeNewestFirst(HomeConversation a, HomeConversation b) =>
    _sortTime(b).compareTo(_sortTime(a));

DateTime _sortTime(HomeConversation c) =>
    c.at ?? (c.mention ? DateTime(9999) : DateTime(0));

/// One row per friend. A muted DM counts nothing, as its badge elsewhere.
List<HomeConversation> homeDmConversations(WidgetRef ref) {
  final lastMessages = ref.watch(lastDmMessageProvider);
  final online = ref.watch(onlineIdentitiesProvider);
  final dmUnreads = ref.watch(unreadProvider.select((s) => s.dmUnreadCounts));
  final notif = ref.watch(notificationSettingsProvider);
  final profiles = ref.watch(profileProvider);
  ref.watch(localNicknameProvider);
  return [
    for (final friend in ref.watch(sortedFriendsProvider))
      () {
        final id = friend.peerId;
        final last = lastMessages[id];
        final name = displayNameFor(profiles, id);
        return HomeConversation(
          key: 'dm:$id',
          peerId: id,
          online: online.contains(id),
          title: name,
          preview: last?.previewText ?? 'No messages yet',
          fromMe: last?.isMe ?? false,
          at: last?.timestamp,
          unread: notif.isDmEnabled(id) ? dmUnreads[id] ?? 0 : 0,
          searchText: name.toLowerCase(),
        );
      }(),
  ];
}

/// One row per channel with an unanswered mention.
List<HomeConversation> homeMentionConversations(WidgetRef ref) {
  final mentions =
      ref.watch(unreadProvider.select((s) => s.channelMentionCounts));
  final previews = ref.watch(mentionPreviewProvider);
  final servers = ref.watch(serverListProvider);
  final profiles = ref.watch(profileProvider);
  ref.watch(localNicknameProvider);
  final rows = <HomeConversation>[];
  for (final MapEntry(key: key, value: count) in mentions.entries) {
    if (count <= 0) continue;
    final split = key.indexOf(':');
    if (split <= 0) continue;
    final serverId = key.substring(0, split);
    final channelId = key.substring(split + 1);
    final server = servers[serverId];
    if (server == null) continue;
    final channelName = ref
            .watch(serverChannelsProvider(serverId))
            .valueOrNull?[channelId]
            ?.name ??
        '';
    final preview = previews[key];
    rows.add(HomeConversation(
      key: 'mention:$key',
      title: channelName.isEmpty ? 'A channel' : '#$channelName',
      detail: server.name,
      preview: preview == null
          ? (count == 1 ? 'Mentioned you' : 'Mentioned you $count times')
          : '${displayNameFor(profiles, preview.senderId)}: '
              '${messagePreviewText(preview.text)}',
      at: preview?.at,
      unread: count,
      mention: true,
      searchText: '$channelName ${server.name}'.toLowerCase(),
      serverId: serverId,
      channelId: channelId,
      channelName: channelName,
      serverName: server.name,
    ));
  }
  return rows;
}

/// The All / Unread / Mentions chips, each hinting how many it holds.
class HomeFilters extends StatelessWidget {
  final HomeFilter selected;
  final int unreadCount;
  final int mentionCount;
  final ValueChanged<HomeFilter> onSelect;

  const HomeFilters({
    super.key,
    required this.selected,
    required this.unreadCount,
    required this.mentionCount,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    Widget chip(HomeFilter f, String label, int count) => HollowChip(
          label: label,
          hint: count > 0 ? '$count' : null,
          selected: selected == f,
          onTap: () => onSelect(f),
        );
    // Wraps rather than overflowing a phone at large text sizes.
    return Wrap(
      spacing: HollowSpacing.sm,
      runSpacing: HollowSpacing.sm,
      children: [
        chip(HomeFilter.all, 'All', 0),
        chip(HomeFilter.unread, 'Unread', unreadCount),
        chip(HomeFilter.mentions, 'Mentions', mentionCount),
      ],
    );
  }
}

/// What an empty inbox slice says: nothing at all, no search match, or a
/// filter with nothing in it.
Widget homeNothingToShow({
  required bool nothingAtAll,
  required String query,
  required HomeFilter filter,
  String emptyDescription = 'Add a friend and your chats with them land here.',
}) {
  if (nothingAtAll) {
    return HollowEmptyState(
      glyph: LucideIcons.messageCircle,
      title: 'No conversations yet',
      description: emptyDescription,
    );
  }
  final q = query.trim();
  if (q.isNotEmpty) {
    return HollowEmptyState(title: 'No conversation matches "$q"');
  }
  return switch (filter) {
    HomeFilter.mentions => const HollowEmptyState(
        title: 'No mentions',
        description: 'When someone mentions you in a server, it shows up '
            'here.',
      ),
    _ => const HollowEmptyState(
        title: 'Nothing unread',
        description: 'You are caught up on every conversation.',
      ),
  };
}

/// The inbox list as a sliver, so it scrolls with the strips above it.
class HomeConversations extends ConsumerStatefulWidget {
  final String query;
  const HomeConversations({super.key, required this.query});

  @override
  ConsumerState<HomeConversations> createState() => _HomeConversationsState();
}

class _HomeConversationsState extends ConsumerState<HomeConversations> {
  HomeFilter _filter = HomeFilter.all;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final all = [
      ...homeMentionConversations(ref),
      ...homeDmConversations(ref),
    ]..sort(homeNewestFirst);

    final unreadCount = all.where((c) => c.isUnread).length;
    final mentionCount = all.where((c) => c.mention).length;
    final q = widget.query.trim().toLowerCase();
    final shown = all.where((c) {
      if (_filter == HomeFilter.unread && !c.isUnread) return false;
      if (_filter == HomeFilter.mentions && !c.mention) return false;
      return q.isEmpty || c.searchText.contains(q);
    }).toList();
    // Pinned above the ranking and outside the counts, as on the phone: a
    // note to yourself is never unread.
    final savedId = ref.watch(savedMessagesPeerIdProvider);
    final showSaved = savedId != null &&
        _filter == HomeFilter.all &&
        (q.isEmpty || _kSavedTitle.toLowerCase().contains(q));
    final pinned = showSaved ? 1 : 0;
    // The person you are in a call with says so where their preview was.
    final call = ref.watch(callProvider.select((c) => (
          status: c.status,
          peerId: c.peerId,
          startedAt: c.startedAt,
        )));
    final callMaster = call.status == CallStatus.active && call.peerId != null
        ? ref.watch(deviceLinkProvider).identityOf(call.peerId!)
        : null;
    final callStartedAt = call.startedAt;
    final listsLoaded = homeListsLoaded(ref);
    final listsError = homeListsError(ref);

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: kHomeRowInset),
            child: HollowSectionHeader(
              'Conversations',
              action: all.isEmpty
                  ? null
                  : HomeFilters(
                      selected: _filter,
                      unreadCount: unreadCount,
                      mentionCount: mentionCount,
                      onSelect: (f) => setState(() => _filter = f),
                    ),
            ),
          ),
        ),
        if (shown.isEmpty && !showSaved && all.isEmpty && !listsLoaded)
          SliverToBoxAdapter(
            // Still reading friends and servers: nothing, never "none yet".
            child: listsError == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: kHomeRowInset,
                        vertical: HollowSpacing.md),
                    child: HollowEmptyState(
                      dense: true,
                      title: "Your conversations didn't load",
                      description: friendlyError(listsError),
                      action: HollowButton.ghost(
                        compact: true,
                        onPressed: () => homeRetryLists(ref),
                        child: const Text('Try again'),
                      ),
                    ),
                  ),
          )
        else if (shown.isEmpty && !showSaved)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xl),
              child: homeNothingToShow(
                nothingAtAll: all.isEmpty,
                query: widget.query,
                filter: _filter,
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: pinned + shown.length,
            findChildIndexCallback: (key) {
              if (showSaved && key == const ValueKey(_kSavedKey)) return 0;
              final i = shown.indexWhere((c) => ValueKey(c.key) == key);
              return i < 0 ? null : pinned + i;
            },
            itemBuilder: (context, i) {
              if (showSaved && i == 0) {
                return KeyedSubtree(
                  key: const ValueKey(_kSavedKey),
                  child: _SavedMessagesRow(peerId: savedId),
                );
              }
              final c = shown[i - pinned];
              final inCall = c.peerId != null && c.peerId == callMaster;
              final row = ConversationRow(
                leading: homeConversationLeading(c,
                    size: _kRowAvatar, ring: hollow.background),
                title: c.title,
                detail: c.detail,
                preview: c.preview,
                fromMe: c.fromMe,
                time: c.at == null ? null : conversationTimeLabel(c.at!),
                unread: c.unread,
                mention: c.mention,
                onTap: () => _open(context, c),
                live: inCall ? _InCallLine(startedAt: callStartedAt) : null,
                liveLabel: inCall ? 'In a call' : null,
              );
              return KeyedSubtree(
                key: ValueKey(c.key),
                child: c.peerId == null
                    ? row
                    : ContextMenuTarget(
                        semanticLabel: 'Conversation actions',
                        onOpen: (anchor) => showUserContextMenu(
                          context: context,
                          ref: ref,
                          peerId: c.peerId!,
                          surface: UserMenuSurface.dmTile,
                          anchor: anchor,
                        ),
                        child: row,
                      ),
              );
            },
          ),
      ],
    );
  }

  void _open(BuildContext context, HomeConversation c) {
    final peerId = c.peerId;
    if (peerId != null) {
      openDmConversation(ref, peerId);
      return;
    }
    openServerChannel(
      ProviderScope.containerOf(context, listen: false),
      c.serverId!,
      c.channelId!,
    ).catchError((_) {});
  }
}

const double _kRowAvatar = 36;

const _kSavedTitle = 'Saved messages';
const _kSavedKey = 'saved';

/// The self-DM, pinned first. No context menu: none of its actions apply to a
/// conversation with yourself, and every message in it is yours, so no "You:".
/// "In a call · 04:12" in a conversation row, in the success colour.
class _InCallLine extends StatelessWidget {
  final DateTime? startedAt;
  const _InCallLine({required this.startedAt});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final started = startedAt;
    final style = DefaultTextStyle.of(context).style.copyWith(
          color: hollow.success,
          fontFeatures: const [FontFeature.tabularFigures()],
        );
    return Row(
      children: [
        Text(started == null ? 'In a call' : 'In a call · ', style: style),
        if (started != null) CallDurationText(startedAt: started, style: style),
      ],
    );
  }
}

class _SavedMessagesRow extends ConsumerWidget {
  final String peerId;
  const _SavedMessagesRow({required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final last = ref.watch(lastDmMessageProvider.select((m) => m[peerId]));
    return ConversationRow(
      leading: const SavedMessagesAvatar(size: _kRowAvatar),
      title: _kSavedTitle,
      preview: last?.previewText ?? '',
      time: last == null ? null : conversationTimeLabel(last.timestamp),
      onTap: () => openDmConversation(ref, peerId),
    );
  }
}
