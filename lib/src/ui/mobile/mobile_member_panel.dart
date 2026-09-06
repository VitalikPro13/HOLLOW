import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/sync_progress_provider.dart';
import 'package:hollow/src/core/providers/support_marks_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/mobile/mobile_profile_sheet.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

void showMobileMemberPanel(BuildContext context, String serverId) {
  final hollow = HollowTheme.of(context);
  showModalBottomSheet(
    context: context,
    backgroundColor: hollow.surface,
    isScrollControlled: true,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
    ),
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => _MemberPanelContent(
        serverId: serverId,
        scrollController: scrollController,
      ),
    ),
  );
}

const _roleOrder = ['owner', 'admin', 'moderator', 'member'];

String _roleDividerLabel(String role) {
  switch (role) {
    case 'owner': return 'Owner';
    case 'admin': return 'Admin';
    case 'moderator': return 'Moderator';
    default: return 'Members';
  }
}

Color _roleGlowColor(String role, HollowTheme hollow) {
  switch (role) {
    case 'owner': return hollow.warning;
    case 'admin': return const Color(0xFFA78BFA);
    case 'moderator': return Color.lerp(hollow.warning, hollow.error, 0.5) ?? hollow.warning;
    default: return hollow.accent;
  }
}

class _MemberPanelContent extends ConsumerWidget {
  final String serverId;
  final ScrollController scrollController;

  const _MemberPanelContent({
    required this.serverId,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final membersAsync = ref.watch(serverMembersProvider(serverId));
    final onlineIdentities = ref.watch(onlineIdentitiesProvider);
    final myPeerId = ref.watch(identityProvider).peerId ?? '';

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: HollowSpacing.sm, bottom: HollowSpacing.sm),
          child: Container(
            width: 32, height: 4,
            decoration: BoxDecoration(
              color: hollow.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),

        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm,
          ),
          child: Row(
            children: [
              Icon(LucideIcons.users, size: 18, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              Text('Members', style: HollowTypography.body.copyWith(
                fontWeight: FontWeight.w600,
                color: hollow.textPrimary,
              )),
            ],
          ),
        ),

        Divider(height: 1, color: hollow.border),

        Expanded(
          child: membersAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => Center(
              child: Text('Failed to load members',
                  style: HollowTypography.body.copyWith(color: hollow.textSecondary)),
            ),
            data: (members) {
              final entries = _buildEntries(members, onlineIdentities, myPeerId);
              return ListView.builder(
                controller: scrollController,
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewPadding.bottom + HollowSpacing.xl,
                ),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  if (entry.isDivider) {
                    return _RoleDivider(
                      label: entry.label!,
                      count: entry.count!,
                      isOnline: entry.isOnline,
                      hollow: hollow,
                    );
                  }
                  return _MemberTile(
                    member: entry.member!,
                    isOnline: entry.isOnline,
                    serverId: serverId,
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  List<_MemberEntry> _buildEntries(
    List<crdt_api.MemberFfi> members,
    Set<String> onlineIdentities,
    String myPeerId,
  ) {
    final online = <crdt_api.MemberFfi>[];
    final offline = <crdt_api.MemberFfi>[];

    // A member is online if ANY of their devices is visible.
    for (final m in members) {
      if (onlineIdentities.contains(m.peerId) || m.peerId == myPeerId) {
        online.add(m);
      } else {
        offline.add(m);
      }
    }

    int rolePriority(String role) => _roleOrder.indexOf(role).clamp(0, 3);
    online.sort((a, b) {
      final rp = rolePriority(a.role).compareTo(rolePriority(b.role));
      if (rp != 0) return rp;
      return a.displayName.compareTo(b.displayName);
    });
    offline.sort((a, b) => a.displayName.compareTo(b.displayName));

    final entries = <_MemberEntry>[];

    final allSameRole = online.isNotEmpty &&
        online.every((m) => m.role == online.first.role) &&
        online.first.role == 'member';

    if (allSameRole) {
      entries.add(_MemberEntry.divider('Online', online.length, true));
      for (final m in online) {
        entries.add(_MemberEntry.member(m, true));
      }
    } else {
      String? currentRole;
      for (final m in online) {
        if (m.role != currentRole) {
          currentRole = m.role;
          final count = online.where((x) => x.role == m.role).length;
          entries.add(_MemberEntry.divider(_roleDividerLabel(m.role), count, true));
        }
        entries.add(_MemberEntry.member(m, true));
      }
    }

    if (offline.isNotEmpty) {
      entries.add(_MemberEntry.divider('Offline', offline.length, false));
      for (final m in offline) {
        entries.add(_MemberEntry.member(m, false));
      }
    }

    return entries;
  }
}

class _MemberEntry {
  final bool isDivider;
  final bool isOnline;
  final String? label;
  final int? count;
  final crdt_api.MemberFfi? member;

  _MemberEntry.divider(this.label, this.count, this.isOnline)
      : isDivider = true, member = null;

  _MemberEntry.member(this.member, this.isOnline)
      : isDivider = false, label = null, count = null;
}

class _RoleDivider extends StatelessWidget {
  final String label;
  final int count;
  final bool isOnline;
  final HollowTheme hollow;

  const _RoleDivider({
    required this.label,
    required this.count,
    required this.isOnline,
    required this.hollow,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HollowSpacing.lg, HollowSpacing.lg, HollowSpacing.lg, HollowSpacing.xs,
      ),
      child: Row(
        children: [
          Expanded(child: Divider(color: hollow.border, height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
            child: Text(
              '$label  $count',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0,
              ),
            ),
          ),
          Expanded(child: Divider(color: hollow.border, height: 1)),
        ],
      ),
    );
  }
}

class _MemberTile extends ConsumerWidget {
  final crdt_api.MemberFfi member;
  final bool isOnline;
  final String serverId;

  const _MemberTile({
    required this.member,
    required this.isOnline,
    required this.serverId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final localNicknames = ref.watch(localNicknameProvider);
    final profiles = ref.watch(profileProvider);
    final isSyncing = ref.watch(isPeerSyncingProvider(member.peerId));

    // Local nickname, then server nickname, then profile name, then short id.
    final localNick = localNicknames[member.peerId];
    final serverNick = member.nickname.isNotEmpty ? member.nickname : null;
    final profileName = displayNameFor(profiles, member.peerId);
    final displayName = localNick ?? serverNick ?? profileName;
    // The purple chip draws ONLY from a verified account credential; the
    // member-level handle and the profile field are self-declarations.
    final verifiedTwitch = ref.watch(twitchLoginProvider(member.peerId));

    return AnimatedOpacity(
      opacity: isOnline ? 1.0 : 0.5,
      duration: const Duration(milliseconds: 200),
      child: HollowPressable(
        onTap: () => showMobileProfileSheet(
          context,
          peerId: member.peerId,
          role: member.role,
          labels: member.labels.isNotEmpty ? member.labels : null,
        ),
        subtle: true,
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 36, height: 36,
              child: Stack(
                       clipBehavior: Clip.none,
                children: [
                  HollowAvatar(peerId: member.peerId, size: 36),
                  Positioned(
                    right: 0, bottom: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: hollow.surface, shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(1),
                      child: StatusDot(
                        color: isSyncing
                            ? hollow.warning
                            : isOnline
                                ? hollow.success
                                : hollow.textSecondary,
                        size: 8,
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
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          displayName,
                          style: HollowTypography.body.copyWith(
                            color: hollow.textPrimary,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (member.role != 'member') ...[
                        const SizedBox(width: HollowSpacing.sm),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: _roleGlowColor(member.role, hollow).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            member.role[0].toUpperCase() + member.role.substring(1),
                            style: HollowTypography.caption.copyWith(
                              color: _roleGlowColor(member.role, hollow),
                              fontWeight: FontWeight.w700,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (verifiedTwitch != null)
                    GestureDetector(
                      onTap: () => launchUrl(
                        Uri.parse('https://twitch.tv/$verifiedTwitch'),
                        mode: LaunchMode.externalApplication,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(BrandIcons.twitch, size: 12, color: Color(0xFF9146FF)),
                          const SizedBox(width: HollowSpacing.xs),
                          Text(
                            verifiedTwitch,
                            style: HollowTypography.caption.copyWith(
                              color: const Color(0xFF9146FF),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
