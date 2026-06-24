import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/mobile/mobile_profile_sheet.dart';
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
                child: Padding(
                  padding: const EdgeInsets.only(left: HollowSpacing.sm),
                  child: Icon(BrandIcons.twitch, size: 14, color: const Color(0xFF9146FF)),
                ),
              ),
            if (canManageThis)
              HollowPressable(
                onTap: () => _showActions(context, ref),
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

  Future<void> _changeRole(BuildContext context, WidgetRef ref, String newRole) async {
    Navigator.pop(context);
    try {
      await crdt_api.changeMemberRole(
        serverId: serverId, peerId: member.peerId, newRole: newRole,
      );
      ref.invalidate(serverMembersProvider(serverId));
      if (context.mounted) {
        HollowToast.show(context, 'Role changed to $newRole',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(context, 'Failed to change role',
            type: HollowToastType.error);
      }
    }
  }

  void _confirmKick(BuildContext context, WidgetRef ref) {
    Navigator.pop(context);
    showHollowDialog(
      context: context,
      builder: (_) => HollowDialog(
        title: 'Kick Member',
        content: Text('Are you sure you want to kick ${member.displayName}?',
            style: HollowTypography.body),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          HollowButton.danger(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await crdt_api.kickMember(
                  serverId: serverId, peerId: member.peerId,
                );
                ref.invalidate(serverMembersProvider(serverId));
                if (context.mounted) {
                  HollowToast.show(context, 'Member kicked',
                      type: HollowToastType.success);
                }
              } catch (e) {
                if (context.mounted) {
                  HollowToast.show(context, 'Failed to kick',
                      type: HollowToastType.error);
                }
              }
            },
            child: const Text('Kick'),
          ),
        ],
      ),
    );
  }

  void _confirmBan(BuildContext context, WidgetRef ref) {
    Navigator.pop(context);
    showHollowDialog(
      context: context,
      builder: (_) => HollowDialog(
        title: 'Ban Member',
        content: Text(
          'Are you sure you want to ban ${member.displayName}? They will not be able to rejoin.',
          style: HollowTypography.body,
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          HollowButton.danger(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await crdt_api.banMember(
                  serverId: serverId, peerId: member.peerId,
                );
                ref.invalidate(serverMembersProvider(serverId));
                if (context.mounted) {
                  HollowToast.show(context, 'Member banned',
                      type: HollowToastType.success);
                }
              } catch (e) {
                if (context.mounted) {
                  HollowToast.show(context, 'Failed to ban',
                      type: HollowToastType.error);
                }
              }
            },
            child: const Text('Ban'),
          ),
        ],
      ),
    );
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
