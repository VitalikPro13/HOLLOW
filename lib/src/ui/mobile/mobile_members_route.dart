import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/moderation_format.dart';
import 'package:hollow/src/core/providers/channel_provider.dart'
    show mutedMembersProvider;
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/sync_progress_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/mobile/mobile_profile_sheet.dart';
import 'package:hollow/src/ui/settings/moderation_dialogs.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

class MobileMembersRoute extends ConsumerStatefulWidget {
  final String serverId;

  const MobileMembersRoute({super.key, required this.serverId});

  @override
  ConsumerState<MobileMembersRoute> createState() => _MobileMembersRouteState();
}

class _MobileMembersRouteState extends ConsumerState<MobileMembersRoute> {
  List<String> _bannedPeers = [];
  bool _showBanned = false;
  bool _showMuted = false;

  @override
  void initState() {
    super.initState();
    _loadBanned();
  }

  Future<void> _loadBanned() async {
    try {
      final banned = await crdt_api.getBannedMembers(serverId: widget.serverId);
      if (mounted) setState(() => _bannedPeers = banned);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final membersAsync = ref.watch(serverMembersProvider(widget.serverId));
    final myRole = ref.watch(myRoleProvider(widget.serverId)).valueOrNull ?? 'member';
    final perms = ref.watch(myPermissionsProvider(widget.serverId)).valueOrNull ?? 0;
    final canKick = (perms & Permission.kickMembers) != 0;

    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: Column(
          children: [
            _Header(hollow: hollow),
            Expanded(
              child: membersAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, _) => Center(
                  child: Text('Failed to load members',
                      style: HollowTypography.body.copyWith(color: hollow.textSecondary)),
                ),
                data: (members) => _MemberList(
                  members: members,
                  serverId: widget.serverId,
                  myRole: myRole,
                  canKick: canKick,
                  bannedPeers: _bannedPeers,
                  showBanned: _showBanned,
                  onToggleBanned: () => setState(() => _showBanned = !_showBanned),
                  onUnban: _unban,
                  onRefreshBanned: _loadBanned,
                  // Provider-backed so a fresh mute shows without leaving the
                  // route (ServerUpdated invalidates it on the CrdtStore ramp).
                  mutedMembers: ref
                          .watch(mutedMembersProvider(widget.serverId))
                          .valueOrNull ??
                      const [],
                  showMuted: _showMuted,
                  onToggleMuted: () => setState(() => _showMuted = !_showMuted),
                  onUnmute: _unmute,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _unban(String peerId) async {
    try {
      await crdt_api.unbanMember(serverId: widget.serverId, peerId: peerId);
      await _loadBanned();
      ref.invalidate(serverMembersProvider(widget.serverId));
      if (mounted) {
        HollowToast.show(context, 'Member unbanned', type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to unban', type: HollowToastType.error);
      }
    }
  }

  Future<void> _unmute(String peerId) async {
    try {
      await crdt_api.unmuteMember(serverId: widget.serverId, peerId: peerId);
      ref.invalidate(mutedMembersProvider(widget.serverId));
      ref.invalidate(serverMembersProvider(widget.serverId));
      if (mounted) {
        HollowToast.show(context, 'Member unmuted', type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to unmute', type: HollowToastType.error);
      }
    }
  }
}

class _Header extends StatelessWidget {
  final HollowTheme hollow;

  const _Header({required this.hollow});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm, vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          HollowPressable(
            onTap: () => Navigator.pop(context),
            semanticLabel: 'Back',
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            padding: const EdgeInsets.all(HollowSpacing.sm),
            child: Icon(LucideIcons.arrowLeft, size: 22, color: hollow.textPrimary),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Text('Members', style: HollowTypography.heading.copyWith(
            color: hollow.textPrimary,
          )),
        ],
      ),
    );
  }
}

bool _canManageRole(String actorRole, String targetRole) {
  if (actorRole == 'owner') return true;
  if (actorRole == 'admin' && targetRole != 'owner' && targetRole != 'admin') return true;
  return false;
}

List<String> _assignableRoles(String actorRole) {
  if (actorRole == 'owner') return ['admin', 'moderator', 'member'];
  if (actorRole == 'admin') return ['moderator', 'member'];
  return [];
}

class _MemberList extends ConsumerWidget {
  final List<crdt_api.MemberFfi> members;
  final String serverId;
  final String myRole;
  final bool canKick;
  final List<String> bannedPeers;
  final bool showBanned;
  final VoidCallback onToggleBanned;
  final Future<void> Function(String) onUnban;
  final VoidCallback onRefreshBanned;
  final List<crdt_api.MutedMemberFfi> mutedMembers;
  final bool showMuted;
  final VoidCallback onToggleMuted;
  final Future<void> Function(String) onUnmute;

  const _MemberList({
    required this.members,
    required this.serverId,
    required this.myRole,
    required this.canKick,
    required this.bannedPeers,
    required this.showBanned,
    required this.onToggleBanned,
    required this.onUnban,
    required this.onRefreshBanned,
    required this.mutedMembers,
    required this.showMuted,
    required this.onToggleMuted,
    required this.onUnmute,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    // Multi-device: online if any of the member's devices is visible.
    final onlineIdentities = ref.watch(onlineIdentitiesProvider);
    final myPeerId = ref.watch(identityProvider).peerId ?? '';

    return ListView(
      padding: const EdgeInsets.only(bottom: HollowSpacing.xl),
      children: [
        for (final m in members)
          _MemberRow(
            member: m,
            serverId: serverId,
            isOnline: onlineIdentities.contains(m.peerId) || m.peerId == myPeerId,
            isMe: m.peerId == myPeerId,
            myRole: myRole,
            canKick: canKick,
          ),

        // Muted members section
        if (canKick && mutedMembers.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.lg),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
            child: HollowPressable(
              onTap: onToggleMuted,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              padding: const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
              child: Row(
                children: [
                  Icon(
                    showMuted ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                    size: 16, color: hollow.warning,
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  Text('Muted (${mutedMembers.length})',
                      style: HollowTypography.body.copyWith(color: hollow.warning)),
                ],
              ),
            ),
          ),
          if (showMuted)
            for (final muted in mutedMembers)
              _MutedRow(
                muted: muted,
                displayName: members
                    .where((m) => m.peerId == muted.peerId)
                    .map((m) =>
                        m.nickname.isNotEmpty ? m.nickname : m.displayName)
                    .firstOrNull,
                onUnmute: () => onUnmute(muted.peerId),
              ),
        ],

        // Banned members section
        if (canKick && bannedPeers.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.lg),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
            child: HollowPressable(
              onTap: onToggleBanned,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              padding: const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
              child: Row(
                children: [
                  Icon(
                    showBanned ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                    size: 16, color: hollow.error,
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  Text('Banned (${bannedPeers.length})',
                      style: HollowTypography.body.copyWith(color: hollow.error)),
                ],
              ),
            ),
          ),
          if (showBanned)
            for (final bannedId in bannedPeers)
              _BannedRow(
                peerId: bannedId,
                onUnban: () => onUnban(bannedId),
              ),
        ],
      ],
    );
  }
}

class _MemberRow extends ConsumerWidget {
  final crdt_api.MemberFfi member;
  final String serverId;
  final bool isOnline;
  final bool isMe;
  final String myRole;
  final bool canKick;

  const _MemberRow({
    required this.member,
    required this.serverId,
    required this.isOnline,
    required this.isMe,
    required this.myRole,
    required this.canKick,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final localNicknames = ref.watch(localNicknameProvider);
    final profiles = ref.watch(profileProvider);
    final isSyncing = ref.watch(isPeerSyncingProvider(member.peerId));

    final localNick = localNicknames[member.peerId];
    final serverNick = member.nickname.isNotEmpty ? member.nickname : null;
    final profileName = displayNameFor(profiles, member.peerId);
    final displayName = localNick ?? serverNick ?? profileName;

    final canManageThis = !isMe && _canManageRole(myRole, member.role);

    return AnimatedOpacity(
      opacity: isOnline ? 1.0 : 0.5,
      duration: const Duration(milliseconds: 200),
      child: HollowPressable(
        onTap: () => showMobileProfileSheet(
          context,
          peerId: member.peerId,
          role: member.role,
          twitchUsername: member.twitchUsername.isNotEmpty ? member.twitchUsername : null,
          labels: member.labels.isNotEmpty ? member.labels : null,
        ),
        onLongPress: canManageThis ? () => _showActions(context, ref) : null,
        subtle: true,
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.lg, vertical: HollowSpacing.md,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 40, height: 40,
              child: Stack(
                children: [
                  HollowAvatar(peerId: member.peerId, size: 40),
                  Positioned(
                    right: 0, bottom: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: hollow.background, shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(1.5),
                      child: StatusDot(
                        color: isSyncing
                            ? hollow.warning
                            : isOnline ? hollow.success : hollow.textSecondary,
                        size: 10,
                        pulse: isSyncing || isOnline,
                        filled: isSyncing || isOnline,
                        semanticLabel: isSyncing
                            ? 'Syncing'
                            : isOnline ? 'Online' : 'Offline',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(displayName,
                      style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary, fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    member.role[0].toUpperCase() + member.role.substring(1),
                    style: HollowTypography.caption.copyWith(
                      color: _roleColor(member.role, hollow),
                    ),
                  ),
                ],
              ),
            ),
            if (member.twitchUsername.isNotEmpty)
              GestureDetector(
                onTap: () => launchUrl(
                  Uri.parse('https://twitch.tv/${member.twitchUsername}'),
                  mode: LaunchMode.externalApplication,
                ),
                child: const Padding(
                  padding: EdgeInsets.only(left: HollowSpacing.sm),
                  child: Icon(BrandIcons.twitch, size: 14, color: Color(0xFF9146FF)),
                ),
              ),
            if (canManageThis)
              HollowPressable(
                onTap: () => _showActions(context, ref),
                semanticLabel: 'Member options',
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.sm),
                child: Icon(LucideIcons.moreVertical, size: 16, color: hollow.textSecondary),
              ),
          ],
        ),
      ),
    );
  }

  void _showActions(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final assignable = _assignableRoles(myRole).where((r) => r != member.role).toList();

    showModalBottomSheet(
      context: context,
      backgroundColor: hollow.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: HollowSpacing.sm),
              child: Container(width: 32, height: 4,
                decoration: BoxDecoration(color: hollow.border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
            Text(member.displayName,
                style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary, fontWeight: FontWeight.w600,
                )),
            const SizedBox(height: HollowSpacing.md),
            Divider(height: 1, color: hollow.border),

            for (final newRole in assignable)
              HollowPressable(
                onTap: () => _changeRole(context, ref, newRole),
                subtle: true,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg, vertical: HollowSpacing.md,
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.shield, size: 18,
                        color: _roleColor(newRole, hollow)),
                    const SizedBox(width: HollowSpacing.md),
                    Text('Set ${newRole[0].toUpperCase()}${newRole.substring(1)}',
                        style: HollowTypography.body.copyWith(color: hollow.textPrimary)),
                  ],
                ),
              ),

            if (assignable.isNotEmpty) Divider(height: 1, color: hollow.border),

            if (canKick)
              HollowPressable(
                onTap: () => _confirmKick(context, ref),
                subtle: true,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg, vertical: HollowSpacing.md,
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.userMinus, size: 18, color: hollow.error),
                    const SizedBox(width: HollowSpacing.md),
                    Text('Kick', style: HollowTypography.body.copyWith(color: hollow.error)),
                  ],
                ),
              ),

            if (canKick)
              HollowPressable(
                onTap: () => _showMuteSheet(context, ref),
                subtle: true,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg, vertical: HollowSpacing.md,
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.volumeX, size: 18, color: hollow.warning),
                    const SizedBox(width: HollowSpacing.md),
                    Text('Mute', style: HollowTypography.body.copyWith(color: hollow.warning)),
                  ],
                ),
              ),

            if (canKick)
              HollowPressable(
                onTap: () => _confirmBan(context, ref),
                subtle: true,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg, vertical: HollowSpacing.md,
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.ban, size: 18, color: hollow.error),
                    const SizedBox(width: HollowSpacing.md),
                    Text('Ban', style: HollowTypography.body.copyWith(color: hollow.error)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showMuteSheet(BuildContext context, WidgetRef ref) {
    Navigator.pop(context);
    final hollow = HollowTheme.of(context);

    showModalBottomSheet(
      context: context,
      backgroundColor: hollow.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: HollowSpacing.sm),
              child: Container(width: 32, height: 4,
                decoration: BoxDecoration(color: hollow.border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
            Text('Mute ${member.displayName}',
                style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary, fontWeight: FontWeight.w600,
                )),
            const SizedBox(height: HollowSpacing.xs),
            Text('They won\'t be able to send messages in this server',
                style: HollowTypography.caption.copyWith(color: hollow.textSecondary)),
            const SizedBox(height: HollowSpacing.md),
            Divider(height: 1, color: hollow.border),
            for (final (label, secs) in kMuteDurationOptions)
              HollowPressable(
                onTap: () => _mute(context, ref, secs, label),
                subtle: true,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg, vertical: HollowSpacing.md,
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.timer, size: 18,
                        color: secs == 0 ? hollow.error : hollow.textSecondary),
                    const SizedBox(width: HollowSpacing.md),
                    Text(label,
                        style: HollowTypography.body.copyWith(
                          color: secs == 0 ? hollow.error : hollow.textPrimary,
                        )),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _mute(
      BuildContext context, WidgetRef ref, int durationSecs, String label) {
    Navigator.pop(context);
    return muteMemberFor(context, ref,
        serverId: serverId,
        peerId: member.peerId,
        displayName: member.displayName,
        durationSecs: durationSecs,
        label: label);
  }

  // Kick / ban / role changes all run the shared confirms, so this route and
  // the desktop surfaces cannot drift on wording, gating or invalidation.
  Future<void> _changeRole(
      BuildContext context, WidgetRef ref, String newRole) {
    Navigator.pop(context);
    return showChangeRoleDialog(context, ref,
        serverId: serverId,
        peerId: member.peerId,
        displayName: member.displayName,
        newRole: newRole);
  }

  Future<void> _confirmKick(BuildContext context, WidgetRef ref) {
    Navigator.pop(context);
    return showKickMemberDialog(context, ref,
        serverId: serverId,
        peerId: member.peerId,
        displayName: member.displayName);
  }

  Future<void> _confirmBan(BuildContext context, WidgetRef ref) {
    Navigator.pop(context);
    return showBanMemberDialog(context, ref,
        serverId: serverId,
        peerId: member.peerId,
        displayName: member.displayName);
  }
}

Color _roleColor(String role, HollowTheme hollow) {
  switch (role) {
    case 'owner': return hollow.warning;
    case 'admin': return const Color(0xFFA78BFA);
    case 'moderator': return Color.lerp(hollow.warning, hollow.error, 0.5) ?? hollow.warning;
    default: return hollow.textSecondary;
  }
}

class _MutedRow extends StatelessWidget {
  final crdt_api.MutedMemberFfi muted;
  final String? displayName;
  final VoidCallback onUnmute;

  const _MutedRow(
      {required this.muted, required this.displayName, required this.onUnmute});

  String get _label {
    if (muted.permanent) return 'Permanent';
    final remaining = DateTime.fromMillisecondsSinceEpoch(muted.expiresAtMs)
        .difference(DateTime.now());
    if (remaining.isNegative) return 'Expired';
    return '${formatMuteRemaining(remaining)} left';
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          HollowAvatar(peerId: muted.peerId, size: 36),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName ?? '${muted.peerId.substring(0, 8)}...',
                  style: HollowTypography.bodySmall.copyWith(
                    color: hollow.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _label,
                  style: HollowTypography.caption.copyWith(color: hollow.warning),
                ),
              ],
            ),
          ),
          HollowButton.ghost(
            onPressed: onUnmute,
            compact: true,
            child: Text('Unmute', style: TextStyle(color: hollow.success)),
          ),
        ],
      ),
    );
  }
}

class _BannedRow extends StatelessWidget {
  final String peerId;
  final VoidCallback onUnban;

  const _BannedRow({required this.peerId, required this.onUnban});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          HollowAvatar(peerId: peerId, size: 36),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Text(
              '${peerId.substring(0, 8)}...',
              style: HollowTypography.mono.copyWith(
                color: hollow.textSecondary, fontSize: 12,
              ),
            ),
          ),
          HollowButton.ghost(
            onPressed: onUnban,
            compact: true,
            child: Text('Unban', style: TextStyle(color: hollow.success)),
          ),
        ],
      ),
    );
  }
}
