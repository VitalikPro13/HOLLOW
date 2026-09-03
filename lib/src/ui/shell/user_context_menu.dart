import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/composer_insert_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/dm_navigation.dart';
import 'package:hollow/src/core/providers/favourite_friends_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/verified_peers_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/role_hierarchy.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/profile_card_popup.dart';
import 'package:hollow/src/ui/dialogs/report_user_dialog.dart';
import 'package:hollow/src/ui/dialogs/verify_contact_dialog.dart';
import 'package:hollow/src/ui/settings/manage_member_dialog.dart';
import 'package:hollow/src/ui/settings/moderation_dialogs.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The right-click menu for a person (issue #61, phase 3).
///
/// ONE menu behind every surface that shows a user: the member panel, a sender
/// name or avatar in chat, a voice participant row, and a DM tile in the home
/// sidebar. Mobile already had all of this as bottom sheets; desktop had a
/// profile card and nothing else, so half of these actions were only reachable
/// by opening Server Settings.
///
/// Left click still opens the profile card. The card is an identity surface —
/// banner, showcase, roles — and a list of text rows cannot replace it, so the
/// menu carries "Profile" as its first row rather than trying to be one.
///
/// ## Master vs device
/// Everything about a PERSON is master-keyed: friendship, blocking, verified
/// contacts, roles, nicknames. [peerId] may arrive as either form (voice rows
/// are device-keyed by design), so the first thing this does is collapse it
/// through the resolver. The one thing that stays device-keyed is per-peer
/// call volume, which is a property of an audio stream, not of a person —
/// hence [routablePeerId].

/// Which surface opened the menu. Rows that only make sense in one place hang
/// off this rather than off a pile of booleans.
enum UserMenuSurface {
  /// Member panel, chat sender, anywhere with no extra context.
  generic,

  /// A DM row in the home sidebar: adds the conversation rows (mark read,
  /// mute, favourite) and the friendship one.
  dmTile,

  /// A voice channel participant row: adds the per-peer volume slider that
  /// used to BE the right-click on that row.
  voice,
}

/// Opens the user menu for [peerId] at [anchor] (overlay space).
///
/// [serverId] unlocks the moderation rows; pass it from any server-scoped
/// surface. [routablePeerId] is the device id a voice row is keyed by.
void showUserContextMenu({
  required BuildContext context,
  required WidgetRef ref,
  required String peerId,
  required Offset anchor,
  String? serverId,
  String? nickname,
  String? role,
  List<crdt_api.LabelFfi>? labels,
  UserMenuSurface surface = UserMenuSurface.generic,
  String? routablePeerId,
}) {
  showHollowMenu(
    context: context,
    anchor: anchor,
    // menuRef is deliberately NOT named `ref`: it belongs to the menu route's
    // Consumer and dies with the menu, while actions run AFTER the menu has
    // closed and must use the caller's longer-lived ref. Naming it `ref` here
    // shadows the parameter and makes every row silently do nothing; the
    // build fails on it (test/menu_builder_ref_guard_test.dart).
    builder: (_, menuRef) => userMenuEntries(
      context: context,
      menuRef: menuRef,
      ref: ref,
      peerId: peerId,
      anchor: anchor,
      serverId: serverId,
      nickname: nickname,
      role: role,
      labels: labels,
      surface: surface,
      routablePeerId: routablePeerId,
    ),
  );
}

/// The rows, exposed for tests.
///
/// [menuRef] watches live state for display and dies with the menu; [ref] is
/// the caller's and is what every action uses. [context] is likewise the
/// caller's, so a dialog opened by a row is parented above the menu rather
/// than under the route that is closing.
List<HollowMenuEntry> userMenuEntries({
  required BuildContext context,
  required WidgetRef menuRef,
  required WidgetRef ref,
  required String peerId,
  required Offset anchor,
  String? serverId,
  String? nickname,
  String? role,
  List<crdt_api.LabelFfi>? labels,
  UserMenuSurface surface = UserMenuSurface.generic,
  String? routablePeerId,
}) {
  final master = menuRef.watch(deviceLinkProvider).identityOf(peerId);
  final myMaster = menuRef.watch(identityProvider).peerId;
  final isSelf = master == myMaster;

  final profile = menuRef.watch(profileProvider.select((p) => p[master]));
  final localNick = menuRef.watch(localNicknameProvider)[master];
  final name = serverDisplayNameForPeer(profile, master,
      nickname: nickname ?? '');

  final entries = <HollowMenuEntry>[];

  // The volume slider comes FIRST on a voice row: right-clicking a participant
  // used to open it directly, and a live control belongs above a list of
  // one-shot actions anyway.
  if (surface == UserMenuSurface.voice && !isSelf) {
    entries.add(HollowMenuCustom(
      _PeerVolumeRow(peerId: routablePeerId ?? peerId),
    ));
    entries.add(const HollowMenuDivider());
  }

  entries.add(HollowMenuItem(
    icon: LucideIcons.user,
    label: 'Profile',
    onTap: () => _openProfile(
      context,
      ref,
      peerId: master,
      anchor: anchor,
      nickname: nickname,
      role: role,
      labels: labels,
      serverId: serverId,
    ),
  ));

  if (!isSelf) {
    // Mention drops "@Name " into the composer of the channel currently on
    // screen. No channel open means nothing to type into, so no row.
    final mentionScope = _openChannelScope(menuRef);
    if (mentionScope != null) {
      entries.add(HollowMenuItem(
        icon: LucideIcons.atSign,
        label: 'Mention',
        onTap: () => ref
            .read(composerInsertProvider.notifier)
            .request(mentionScope, '@$name '),
      ));
    }

    entries.add(HollowMenuItem(
      icon: LucideIcons.messageCircle,
      label: 'Message',
      onTap: () => openDmConversation(ref, master),
    ));

    final online = menuRef.watch(onlineIdentitiesProvider).contains(master);
    final inCall =
        menuRef.watch(callProvider.select((c) => c.status)) != CallStatus.idle;
    if (online && !inCall) {
      entries.add(HollowMenuItem(
        icon: LucideIcons.phone,
        label: 'Start a call',
        onTap: () => _report(
          context,
          ref.read(callProvider.notifier).startCall(master),
          'Could not start the call',
        ),
      ));
    }
  }

  // ── Conversation rows (DM tile only) ──
  if (surface == UserMenuSurface.dmTile) {
    final dmMuted = !menuRef
        .watch(notificationSettingsProvider)
        .isDmEnabled(master);
    final isFavourite =
        menuRef.watch(favouriteFriendsProvider).contains(master);
    entries.add(const HollowMenuDivider());
    entries.add(HollowMenuItem(
      icon: LucideIcons.checkCheck,
      label: 'Mark as read',
      onTap: () => _report(
        context,
        ref.read(unreadProvider.notifier).markDmSeenLatest(master),
        'Could not mark the conversation read',
      ),
    ));
    entries.add(HollowMenuItem(
      icon: dmMuted ? LucideIcons.bell : LucideIcons.bellOff,
      label: dmMuted ? 'Unmute conversation' : 'Mute conversation',
      onTap: () => _report(
        context,
        ref
            .read(notificationSettingsProvider.notifier)
            .setDmEnabled(master, dmMuted),
        'Could not change notifications',
      ),
    ));
    if (!isSelf) {
      entries.add(HollowMenuItem(
        icon: isFavourite ? LucideIcons.starOff : LucideIcons.star,
        label: isFavourite ? 'Remove favourite' : 'Add to favourites',
        onTap: () => _report(
          context,
          ref.read(favouriteFriendsProvider.notifier).toggle(master),
          'Could not update favourites',
        ),
      ));
    }
  }

  if (!isSelf) {
    // ── Personal, local-only rows ──
    entries.add(const HollowMenuDivider());
    entries.add(HollowMenuItem(
      icon: localNick != null ? LucideIcons.pencil : LucideIcons.tag,
      label: localNick != null ? 'Edit nickname' : 'Set nickname',
      onTap: () => showLocalNicknameDialog(context, ref, master,
          currentNickname: localNick ?? ''),
    ));
    final isVerified = menuRef.watch(isPeerVerifiedProvider(master));
    entries.add(HollowMenuItem(
      icon: isVerified ? LucideIcons.shieldCheck : LucideIcons.shield,
      label: isVerified ? 'Safety number' : 'Verify contact',
      onTap: () => showVerifyContactDialog(context, peerId: master),
    ));

    // ── Moderation ──
    entries.addAll(_moderationEntries(
      context: context,
      menuRef: menuRef,
      ref: ref,
      serverId: serverId,
      master: master,
      role: role,
      name: name,
    ));

    // ── Safety ──
    entries.add(const HollowMenuDivider());
    final isBlocked = menuRef.watch(blockedUsersProvider).contains(master);
    entries.add(HollowMenuItem(
      icon: LucideIcons.ban,
      label: isBlocked ? 'Unblock' : 'Block',
      isDanger: !isBlocked,
      onTap: () => isBlocked
          ? unblockUser(context, masterId: master)
          : confirmAndBlockUser(context, masterId: master, displayName: name),
    ));
    entries.add(HollowMenuItem(
      icon: LucideIcons.flag,
      label: 'Report',
      isDanger: true,
      onTap: () =>
          showReportUserDialog(context, masterId: master, displayName: name),
    ));

    // Removing a friend belongs where the friendship is visible, and nowhere
    // else: doing it from a chat sender's name would be an easy misclick.
    if (surface == UserMenuSurface.dmTile) {
      entries.add(HollowMenuItem(
        icon: LucideIcons.userMinus,
        label: 'Remove friend',
        isDanger: true,
        onTap: () => _confirmRemoveFriend(context, ref, master, name),
      ));
    }
  }

  entries.add(const HollowMenuDivider());
  entries.add(HollowMenuItem(
    icon: LucideIcons.copy,
    label: 'Copy user ID',
    onTap: () => _copyUserId(context, master),
  ));

  return entries;
}

/// Manage member, mute, kick and ban — the rows that need a server AND a
/// permission. Each is hidden rather than disabled when it is not available:
/// a greyed row still tells you the action exists and taunts you with it.
List<HollowMenuEntry> _moderationEntries({
  required BuildContext context,
  required WidgetRef menuRef,
  required WidgetRef ref,
  required String? serverId,
  required String master,
  required String? role,
  required String name,
}) {
  if (serverId == null) return const [];

  final myRole = menuRef.watch(myRoleProvider(serverId)).valueOrNull ?? 'member';
  final perms = menuRef.watch(myPermissionsProvider(serverId)).valueOrNull ?? 0;
  // The target's role from the member list, falling back to what the calling
  // tile already knew. Reading it live matters: a promotion that lands while
  // the menu is open must close the moderation rows.
  final members = menuRef.watch(serverMembersProvider(serverId)).valueOrNull;
  final targetRole = members
          ?.where((m) => m.peerId == master)
          .map((m) => m.role)
          .firstOrNull ??
      role ??
      'member';
  // Not a member of this server: no moderation rows even for an owner.
  if (members != null && !members.any((m) => m.peerId == master)) {
    return const [];
  }

  final outranks = canManageRole(myRole, targetRole);
  final canModerate = outranks && (perms & Permission.kickMembers) != 0;
  final canManage = (outranks && assignableRoles(myRole).isNotEmpty) ||
      (perms & Permission.manageRoles) != 0 ||
      (perms & Permission.manageChannels) != 0;

  if (!canManage && !canModerate) return const [];

  final entries = <HollowMenuEntry>[const HollowMenuDivider()];
  if (canManage) {
    entries.add(HollowMenuItem(
      icon: LucideIcons.userCog,
      label: 'Manage member',
      onTap: () =>
          showManageMemberDialog(context, serverId: serverId, peerId: master),
    ));
  }
  if (canModerate) {
    entries.add(HollowMenuItem(
      icon: LucideIcons.volumeX,
      label: 'Mute member',
      onTap: () => showMuteMemberDialog(context, ref,
          serverId: serverId, peerId: master, displayName: name),
    ));
    entries.add(HollowMenuItem(
      icon: LucideIcons.userMinus,
      label: 'Kick member',
      isDanger: true,
      onTap: () => showKickMemberDialog(context, ref,
          serverId: serverId, peerId: master, displayName: name),
    ));
    entries.add(HollowMenuItem(
      icon: LucideIcons.ban,
      label: 'Ban member',
      isDanger: true,
      onTap: () => showBanMemberDialog(context, ref,
          serverId: serverId, peerId: master, displayName: name),
    ));
  }
  return entries;
}

/// Runs an un-awaited write and reports a failure instead of letting it reach
/// the zone crash handler.
///
/// A menu row is a VoidCallback, so every provider write from one is a
/// dangling Future. A sync try/catch around it catches NOTHING — the rejection
/// lands later — and a row that silently did nothing is exactly the bug class
/// this menu work keeps producing.
void _report(BuildContext context, Future<void> work, String failure) {
  work.catchError((Object _) {
    if (context.mounted) {
      HollowToast.show(context, failure, type: HollowToastType.error);
    }
  });
}

/// The composer scope of the channel currently on screen, or null when the
/// chat area is showing something else.
String? _openChannelScope(WidgetRef ref) {
  final serverId = ref.watch(selectedServerProvider);
  final channelId = ref.watch(selectedChannelProvider);
  if (serverId == null || channelId == null) return null;
  // A voice channel has no composer to type into.
  final channel = ref.watch(channelListProvider)[channelId];
  if (channel != null && channel.channelType == ChannelType.voice) return null;
  return ComposerInsert.channelScope(serverId, channelId);
}

void _openProfile(
  BuildContext context,
  WidgetRef ref, {
  required String peerId,
  required Offset anchor,
  String? nickname,
  String? role,
  List<crdt_api.LabelFfi>? labels,
  String? serverId,
}) {
  showProfileCardPopup(
    context: context,
    ref: ref,
    peerId: peerId,
    nickname: (nickname != null && nickname.isNotEmpty) ? nickname : null,
    role: role,
    labels: (labels != null && labels.isNotEmpty) ? labels : null,
    serverId: serverId,
    // Nothing to follow: this came from a menu row that is already gone, so
    // the card keeps the point the menu was opened at.
    anchorOf: () => anchor,
  );
}

Future<void> _copyUserId(BuildContext context, String master) async {
  await Clipboard.setData(ClipboardData(text: master));
  if (context.mounted) {
    HollowToast.show(context, 'User ID copied', type: HollowToastType.success);
  }
}

Future<void> _confirmRemoveFriend(
    BuildContext context, WidgetRef ref, String master, String name) async {
  final confirmed = await showHollowDialog<bool>(
    context: context,
    builder: (ctx) => HollowDialog(
      title: 'Remove $name?',
      content: Text(
        'You will both drop off each other\'s friend list. Your conversation '
        'stays on this device.',
        style: HollowTypography.body
            .copyWith(color: HollowTheme.of(ctx).textSecondary),
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        HollowButton.danger(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await ref.read(friendsProvider.notifier).removeFriend(master);
    if (context.mounted) {
      HollowToast.show(context, 'Friend removed',
          type: HollowToastType.success);
    }
  } catch (_) {
    if (context.mounted) {
      HollowToast.show(context, 'Could not remove friend',
          type: HollowToastType.error);
    }
  }
}

/// The per-peer voice volume slider, as a menu row.
///
/// Right-clicking a voice participant opened this and only this before the
/// user menu existed. Folding it in as a custom row keeps the feature and
/// still gives the row every other user action, instead of choosing.
class _PeerVolumeRow extends ConsumerStatefulWidget {
  final String peerId;

  const _PeerVolumeRow({required this.peerId});

  @override
  ConsumerState<_PeerVolumeRow> createState() => _PeerVolumeRowState();
}

class _PeerVolumeRowState extends ConsumerState<_PeerVolumeRow> {
  late double _volume =
      ref.read(voiceChannelProvider).getPeerVolume(widget.peerId);

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Semantics(
      slider: true,
      label: 'Volume',
      value: '${(_volume * 100).round()} percent',
      child: Row(
        children: [
          const SizedBox(width: HollowSpacing.xs),
          Icon(LucideIcons.volume2, size: 14, color: hollow.textSecondary),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                activeTrackColor: hollow.accent,
                inactiveTrackColor: hollow.border,
                thumbColor: hollow.accent,
                overlayColor: hollow.accent.withValues(alpha: 0.08),
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
              ),
              child: Slider(
                value: _volume,
                min: 0.0,
                max: 2.0,
                onChanged: (v) {
                  setState(() => _volume = v);
                  ref
                      .read(voiceChannelProvider.notifier)
                      .setPeerVolume(widget.peerId, v);
                },
              ),
            ),
          ),
          SizedBox(
            width: 34,
            child: Text(
              '${(_volume * 100).round()}%',
              style: HollowTypography.caption
                  .copyWith(color: hollow.textTertiary),
              textAlign: TextAlign.right,
            ),
          ),
          const SizedBox(width: HollowSpacing.xs),
        ],
      ),
    );
  }
}
