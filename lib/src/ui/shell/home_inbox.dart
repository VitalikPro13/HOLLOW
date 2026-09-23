import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/message_preview.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/channel_navigation.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/dm_navigation.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/home_setup_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/mention_preview_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/security_alerts_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/core/time_labels.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/conversation_row.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/server_avatar.dart';
import 'package:hollow/src/ui/dialogs/create_server_dialog.dart';
import 'package:hollow/src/ui/dialogs/device_link_dialog.dart';
import 'package:hollow/src/ui/dialogs/mnemonic_dialog.dart';
import 'package:hollow/src/ui/dialogs/user_settings_dialog.dart';
import 'package:hollow/src/ui/dialogs/verify_contact_dialog.dart';
import 'package:hollow/src/ui/shell/friends_bar.dart';
import 'package:hollow/src/ui/shell/home_dashboard.dart' show kHomeRowInset;
import 'package:hollow/src/ui/shell/user_context_menu.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
  const HomeAttention({super.key});

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
            _AttentionRow(key: ValueKey(item.id), item: item),
            const SizedBox(height: HollowSpacing.xs),
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
            leading: HollowAvatar(peerId: peerId, size: _kLeadingSize),
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
    final incoming = friends.values
        .where((f) => f.status == 'pending' && f.direction == 'incoming')
        .toList()
      ..sort((a, b) => b.requestedAt.compareTo(a.requestedAt));
    return [
      for (final f in incoming)
        _AttentionItem(
          id: 'request:${f.peerId}',
          leading: HollowAvatar(peerId: f.peerId, size: _kLeadingSize),
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

  List<_AttentionItem> _updateItems() {
    if (!ref.watch(hasUpdateProvider)) return const [];
    final update = ref.watch(updaterProvider);
    final latest = update.manifest?.latest;
    if (latest == null) return const [];
    return [
      _AttentionItem(
        id: 'update:$latest',
        leading: const _GlyphTile(LucideIcons.download),
        title: 'Hollow $latest is ready to install',
        body: 'You have ${update.currentVersion}.',
        primaryLabel: 'View update',
        onPrimary: () async =>
            showUserSettingsDialog(context, openUpdatesTab: true),
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

/// A leading glyph for an item that is not a person, on the row's own surface.
class _GlyphTile extends StatelessWidget {
  final IconData icon;
  const _GlyphTile(this.icon);

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return SizedBox(
      width: _kLeadingSize,
      height: _kLeadingSize,
      child: Icon(icon, size: 20, color: hollow.textSecondary),
    );
  }
}

class _AttentionRow extends StatefulWidget {
  final _AttentionItem item;
  const _AttentionRow({super.key, required this.item});

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
    final busy = _primaryBusy || _secondaryBusy;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md, vertical: HollowSpacing.sm),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
      ),
      child: Row(
        children: [
          item.leading,
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary, fontWeight: FontWeight.w500),
                ),
                Text(
                  item.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HollowTypography.bodySmall
                      .copyWith(color: hollow.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.md),
          if (item.onSecondary != null) ...[
            HollowButton.ghost(
              compact: true,
              loading: _secondaryBusy,
              onPressed:
                  busy ? null : () => _run(item.onSecondary!, false),
              child: Text(item.secondaryLabel!),
            ),
            const SizedBox(width: HollowSpacing.sm),
          ],
          HollowButton.outline(
            compact: true,
            loading: _primaryBusy,
            onPressed: busy ? null : () => _run(item.onPrimary, true),
            child: Text(item.primaryLabel),
          ),
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
class HomeSetupChecklist extends ConsumerWidget {
  const HomeSetupChecklist({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        onAction: () => _showPhrase(context, ref),
      ),
      _SetupStep(
        title: 'Add a friend',
        body: 'Send a request to someone you know, or accept theirs.',
        done: ref.watch(sortedFriendsProvider).isNotEmpty,
        action: 'Add friend',
        onAction: () => showFriendsManager(context, addFriend: true),
      ),
      _SetupStep(
        title: 'Join or create a server',
        body: 'A server is a group space its members host together.',
        done: ref.watch(serverListProvider).isNotEmpty,
        action: 'Add a server',
        onAction: () => showCreateServerDialog(context),
      ),
      _SetupStep(
        title: 'Set a profile picture',
        done: hasAvatar,
        action: 'Choose image',
        onAction: () => showUserSettingsDialog(context),
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
          for (var i = 0; i < steps.length; i++) ...[
            _SetupRow(step: steps[i], isNext: i == next),
            const SizedBox(height: HollowSpacing.xs),
          ],
        ],
      ),
    );
  }

  Future<void> _showPhrase(BuildContext context, WidgetRef ref) async {
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
}

class _SetupRow extends StatelessWidget {
  final _SetupStep step;

  /// The first step not yet done carries the screen's one filled button.
  final bool isNext;

  const _SetupRow({required this.step, required this.isNext});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final mark = step.done
        ? Icon(LucideIcons.circleCheck, size: 20, color: hollow.success)
        : Icon(LucideIcons.circle,
            size: 20, color: isNext ? hollow.accentText : hollow.textTertiary);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: isNext ? HollowSpacing.md : HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: step.done ? null : hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
      ),
      child: Row(
        children: [
          Semantics(
            label: step.done ? 'Done' : 'Not done yet',
            child: ExcludeSemantics(child: mark),
          ),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.title,
                  style: HollowTypography.body.copyWith(
                    color: step.done ? hollow.textTertiary : hollow.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (!step.done && step.body != null)
                  Text(
                    step.body!,
                    style: HollowTypography.bodySmall
                        .copyWith(color: hollow.textSecondary),
                  ),
              ],
            ),
          ),
          if (!step.done) ...[
            const SizedBox(width: HollowSpacing.md),
            if (isNext)
              HollowButton.filled(
                onPressed: step.onAction,
                child: Text(step.action),
              )
            else
              HollowButton.outline(
                compact: true,
                onPressed: step.onAction,
                child: Text(step.action),
              ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Conversations: DMs plus the channels that mentioned us.
// ---------------------------------------------------------------------------

enum _Filter { all, unread, mentions }

class _Conversation {
  final String key;
  final Widget leading;
  final String title;
  final String? detail;
  final String preview;
  final bool fromMe;
  final DateTime? at;
  final int unread;
  final bool mention;
  final String searchText;

  /// A DM's peer, for its context menu; null for a channel.
  final String? peerId;
  final void Function(BuildContext context, WidgetRef ref) open;

  const _Conversation({
    required this.key,
    required this.leading,
    required this.title,
    required this.preview,
    required this.at,
    required this.searchText,
    required this.open,
    this.detail,
    this.fromMe = false,
    this.unread = 0,
    this.mention = false,
    this.peerId,
  });

  bool get isUnread => unread > 0 || mention;
}

/// The inbox list as a sliver, so it scrolls with the strips above it.
class HomeConversations extends ConsumerStatefulWidget {
  final String query;
  const HomeConversations({super.key, required this.query});

  @override
  ConsumerState<HomeConversations> createState() => _HomeConversationsState();
}

class _HomeConversationsState extends ConsumerState<HomeConversations> {
  _Filter _filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    final all = [..._mentionRows(), ..._dmRows()]..sort(_newestFirst);

    final unreadCount = all.where((c) => c.isUnread).length;
    final mentionCount = all.where((c) => c.mention).length;
    final q = widget.query.trim().toLowerCase();
    final shown = all.where((c) {
      if (_filter == _Filter.unread && !c.isUnread) return false;
      if (_filter == _Filter.mentions && !c.mention) return false;
      return q.isEmpty || c.searchText.contains(q);
    }).toList();

    Widget chip(_Filter f, String label, int count) => HollowChip(
          label: label,
          hint: count > 0 ? '$count' : null,
          selected: _filter == f,
          onTap: () => setState(() => _filter = f),
        );

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: kHomeRowInset),
            child: HollowSectionHeader(
            'Conversations',
            action: all.isEmpty
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      chip(_Filter.all, 'All', 0),
                      const SizedBox(width: HollowSpacing.sm),
                      chip(_Filter.unread, 'Unread', unreadCount),
                      const SizedBox(width: HollowSpacing.sm),
                      chip(_Filter.mentions, 'Mentions', mentionCount),
                    ],
                  ),
            ),
          ),
        ),
        if (shown.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xl),
              child: _nothingToShow(all.isEmpty, q),
            ),
          )
        else
          SliverList.builder(
            itemCount: shown.length,
            findChildIndexCallback: (key) {
              final i = shown.indexWhere((c) => ValueKey(c.key) == key);
              return i < 0 ? null : i;
            },
            itemBuilder: (context, i) {
              final c = shown[i];
              final row = ConversationRow(
                leading: c.leading,
                title: c.title,
                detail: c.detail,
                preview: c.preview,
                fromMe: c.fromMe,
                time: c.at == null ? null : conversationTimeLabel(c.at!),
                unread: c.unread,
                mention: c.mention,
                onTap: () => c.open(context, ref),
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

  Widget _nothingToShow(bool nothingAtAll, String q) {
    if (nothingAtAll) {
      return const HollowEmptyState(
        glyph: LucideIcons.messageCircle,
        title: 'No conversations yet',
        description: 'Add a friend and your chats with them land here.',
      );
    }
    if (q.isNotEmpty) {
      return HollowEmptyState(
        title: 'No conversation matches "${widget.query.trim()}"',
      );
    }
    return switch (_filter) {
      _Filter.mentions => const HollowEmptyState(
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

  static int _newestFirst(_Conversation a, _Conversation b) {
    // A mention whose words did not survive a restart has no time: it is
    // still unread, so it leads rather than sinking.
    final at = a.at ?? DateTime(9999);
    final bt = b.at ?? DateTime(9999);
    return bt.compareTo(at);
  }

  List<_Conversation> _dmRows() {
    final lastMessages = ref.watch(lastDmMessageProvider);
    final online = ref.watch(onlineIdentitiesProvider);
    final dmUnreads =
        ref.watch(unreadProvider.select((s) => s.dmUnreadCounts));
    final profiles = ref.watch(profileProvider);
    final hollow = HollowTheme.of(context);
    return [
      for (final friend in ref.watch(sortedFriendsProvider))
        () {
          final id = friend.peerId;
          final last = lastMessages[id];
          final name = displayNameFor(profiles, id);
          return _Conversation(
            key: 'dm:$id',
            peerId: id,
            leading: PresenceAvatar(
              peerId: id,
              size: _kRowAvatar,
              online: online.contains(id),
              ring: hollow.background,
            ),
            title: name,
            preview: last?.previewText ?? 'No messages yet',
            fromMe: last?.isMe ?? false,
            at: last?.timestamp ?? DateTime(2000),
            unread: dmUnreads[id] ?? 0,
            searchText: name.toLowerCase(),
            open: (context, ref) => openDmConversation(ref, id),
          );
        }(),
    ];
  }

  List<_Conversation> _mentionRows() {
    final mentions =
        ref.watch(unreadProvider.select((s) => s.channelMentionCounts));
    final previews = ref.watch(mentionPreviewProvider);
    final servers = ref.watch(serverListProvider);
    final profiles = ref.watch(profileProvider);
    final rows = <_Conversation>[];
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
      rows.add(_Conversation(
        key: 'mention:$key',
        leading: ServerAvatar(
            serverId: serverId, name: server.name, size: _kRowAvatar),
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
        open: (context, ref) => openServerChannel(
          ProviderScope.containerOf(context, listen: false),
          serverId,
          channelId,
        ).catchError((_) {}),
      ));
    }
    return rows;
  }
}

const double _kRowAvatar = 36;
