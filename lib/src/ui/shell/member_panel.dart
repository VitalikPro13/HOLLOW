import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/providers/identity_provider.dart';
import 'package:haven/src/core/providers/peers_provider.dart';
import 'package:haven/src/core/providers/profile_provider.dart';
import 'package:haven/src/core/providers/server_provider.dart';
import 'package:haven/src/core/providers/sync_progress_provider.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/animations/haven_curves.dart';
import 'package:haven/src/ui/animations/reveal_widgets.dart';
import 'package:haven/src/ui/animations/startup_reveal.dart';
import 'package:haven/src/ui/components/haven_avatar.dart';
import 'package:haven/src/ui/components/haven_pressable.dart';
import 'package:haven/src/ui/components/profile_card_popup.dart';
import 'package:haven/src/ui/components/status_dot.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Right-side member panel (240px) showing online peers or server members.
class MemberPanel extends ConsumerWidget {
  /// Fixed width for desktop/tablet. Pass null on mobile to fill available space.
  final double? width;

  const MemberPanel({super.key, this.width = 240});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final haven = HavenTheme.of(context);
    final selectedServerId = ref.watch(selectedServerProvider);

    final panelReveal =
        StartupRevealScope.interval(context, 0.45, 0.60);

    Widget panel = Container(
      width: width,
      decoration: BoxDecoration(
        color: haven.surface,
        border: Border(
          left: BorderSide(color: haven.border),
        ),
      ),
      child: AnimatedSwitcher(
        duration: HavenDurations.normal,
        switchInCurve: HavenCurves.enter,
        switchOutCurve: HavenCurves.exit,
        child: selectedServerId != null
            ? _ServerMemberContent(
                key: ValueKey('server-members-$selectedServerId'),
                serverId: selectedServerId,
              )
            : _PeerMemberContent(
                key: const ValueKey('peer-members'),
              ),
      ),
    );

    return RevealClip(
      animation: panelReveal,
      axis: Axis.horizontal,
      alignment: Alignment.centerRight,
      child: panel,
    );
  }
}

/// ASOT-style section divider: "Online ------------ 10"
/// Online variant has a subtle left-to-right glow sweep on the line.
/// [glowColor] overrides the default accent color for the glow sweep.
class _SectionDivider extends StatefulWidget {
  final String label;
  final int count;
  final bool isOnline;
  final Color? glowColor;

  const _SectionDivider({
    required this.label,
    required this.count,
    required this.isOnline,
    this.glowColor,
  });

  @override
  State<_SectionDivider> createState() => _SectionDividerState();
}

class _SectionDividerState extends State<_SectionDivider>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  late final CurvedAnimation? _curved;

  @override
  void initState() {
    super.initState();
    if (widget.isOnline) {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 4000),
      )..repeat(reverse: true);
      _curved = CurvedAnimation(
        parent: _controller!,
        curve: Curves.easeInOut,
      );
    } else {
      _curved = null;
    }
  }

  @override
  void dispose() {
    _curved?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);

    final textStyle = HavenTypography.caption.copyWith(
      color: haven.textSecondary,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.8,
      fontSize: 11,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HavenSpacing.sm + 2,
        vertical: HavenSpacing.sm,
      ),
      child: Row(
        children: [
          Text(widget.label, style: textStyle),
          const SizedBox(width: HavenSpacing.sm),
          Expanded(
            child: widget.isOnline && _curved != null
                ? AnimatedBuilder(
                    animation: _curved,
                    builder: (context, child) {
                      // Map 0..1 to -0.2..1.2 so the glow fully exits both edges.
                      final t = -0.2 + _curved.value * 1.4;
                      const glowWidth = 0.15;
                      final color = widget.glowColor ?? haven.accent;
                      return Container(
                        height: 1,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              haven.border,
                              color.withValues(alpha: 0.5),
                              haven.border,
                            ],
                            stops: [
                              (t - glowWidth).clamp(0.0, 1.0),
                              t.clamp(0.0, 1.0),
                              (t + glowWidth).clamp(0.0, 1.0),
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: color.withValues(alpha: 0.2),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                      );
                    },
                  )
                : Container(
                    height: 1,
                    color: haven.border,
                  ),
          ),
          const SizedBox(width: HavenSpacing.sm),
          Text('${widget.count}', style: textStyle),
        ],
      ),
    );
  }
}

/// A small continuously spinning refresh icon for sync indication.
class _SpinningRefreshIcon extends StatefulWidget {
  final double size;
  final Color color;

  const _SpinningRefreshIcon({required this.size, required this.color});

  @override
  State<_SpinningRefreshIcon> createState() => _SpinningRefreshIconState();
}

class _SpinningRefreshIconState extends State<_SpinningRefreshIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Icon(LucideIcons.refreshCw, size: widget.size, color: widget.color),
    );
  }
}

/// Glow color for role-grouped ASOT dividers.
/// Gold for owner, purple for admin, orange for moderator, teal for member.
Color _roleGlowColor(String role, HavenTheme haven) {
  return switch (role) {
    'owner' => haven.warning,
    'admin' => const Color(0xFFA78BFA),
    'moderator' =>
      Color.lerp(haven.warning, haven.error, 0.5) ?? haven.warning,
    _ => haven.accent,
  };
}

/// Divider label text for role groups.
String _roleDividerLabel(String role) {
  return switch (role) {
    'owner' => 'Owner',
    'admin' => 'Admin',
    'moderator' => 'Moderator',
    _ => 'Members',
  };
}

/// Color for the role label text in member tiles.
Color _roleLabelColor(String role, HavenTheme haven) {
  return switch (role) {
    'owner' => haven.warning,
    'admin' => const Color(0xFFA78BFA),
    'moderator' =>
      Color.lerp(haven.warning, haven.error, 0.5) ?? haven.warning,
    _ => haven.textSecondary,
  };
}

/// Server member list content (header + online/offline member list).
class _ServerMemberContent extends ConsumerWidget {
  final String serverId;

  const _ServerMemberContent({
    super.key,
    required this.serverId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final haven = HavenTheme.of(context);
    final membersAsync = ref.watch(serverMembersProvider(serverId));
    final connectedPeers = ref.watch(peersProvider);
    final localPeerId = ref.watch(identityProvider).peerId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header — ASOT-style divider matching Online/Offline sections
        Container(
          height: 48,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: haven.border),
            ),
          ),
          alignment: Alignment.centerLeft,
          child: membersAsync.when(
            data: (members) => _SectionDivider(
              label: 'Members',
              count: members.length,
              isOnline: false,
            ),
            loading: () => Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HavenSpacing.sm + 2,
              ),
              child: Text(
                'Members ...',
                style: HavenTypography.caption.copyWith(
                  color: haven.textSecondary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                  fontSize: 11,
                ),
              ),
            ),
            error: (_, _) => Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HavenSpacing.sm + 2,
              ),
              child: Text(
                'Members ?',
                style: HavenTypography.caption.copyWith(
                  color: haven.textSecondary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                  fontSize: 11,
                ),
              ),
            ),
          ),
        ),

        // Member list with online/offline sections
        Expanded(
          child: membersAsync.when(
            data: (members) {
              if (members.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(HavenSpacing.xl),
                    child: Text(
                      'No members',
                      style: HavenTypography.bodySmall
                          .copyWith(color: haven.textSecondary),
                    ),
                  ),
                );
              }

              // Split into online/offline
              final online = members
                  .where((m) =>
                      m.peerId == localPeerId ||
                      connectedPeers.containsKey(m.peerId))
                  .toList();
              final offline = members
                  .where((m) =>
                      m.peerId != localPeerId &&
                      !connectedPeers.containsKey(m.peerId))
                  .toList();

              // Group by role within each section
              final roleOrder = ['owner', 'admin', 'moderator', 'member'];

              Widget buildRoleGrouped(
                List<dynamic> memberList,
                bool isOnline,
              ) {
                final groups = <String, List<dynamic>>{};
                for (final m in memberList) {
                  final role = m.role as String;
                  (groups[role] ??= []).add(m);
                }

                final items = <Widget>[];
                for (final role in roleOrder) {
                  final group = groups[role];
                  if (group == null || group.isEmpty) continue;

                  // Role-colored divider for online groups
                  if (isOnline) {
                    final glowColor = _roleGlowColor(role, haven);
                    final label = _roleDividerLabel(role);
                    items.add(_SectionDivider(
                      label: label,
                      count: group.length,
                      isOnline: true,
                      glowColor: glowColor,
                    ));
                  }

                  for (final m in group) {
                    items.add(_ServerMemberTile(
                      peerId: m.peerId,
                      displayName: m.displayName,
                      role: m.role,
                      nickname: m.nickname,
                      isOnline: isOnline,
                    ));
                  }
                }
                return Column(
                    mainAxisSize: MainAxisSize.min, children: items);
              }

              // Build flat item list
              final items = <Widget>[];
              if (online.isNotEmpty) {
                // If all online members share the same role, show "Online" divider
                final roles = online.map((m) => m.role).toSet();
                if (roles.length == 1 && roles.first == 'member') {
                  // All regular members — use simple "Online" divider
                  items.add(_SectionDivider(
                    label: 'Online',
                    count: online.length,
                    isOnline: true,
                  ));
                  for (final m in online) {
                    items.add(_ServerMemberTile(
                      peerId: m.peerId,
                      displayName: m.displayName,
                      role: m.role,
                      nickname: m.nickname,
                      isOnline: true,
                    ));
                  }
                } else {
                  // Multiple roles — group by role with colored dividers
                  items.add(buildRoleGrouped(online, true));
                }
              }
              if (offline.isNotEmpty) {
                items.add(_SectionDivider(
                  label: 'Offline',
                  count: offline.length,
                  isOnline: false,
                ));
                for (final m in offline) {
                  items.add(_ServerMemberTile(
                    peerId: m.peerId,
                    displayName: m.displayName,
                    role: m.role,
                    nickname: m.nickname,
                    isOnline: false,
                  ));
                }
              }

              return ListView(
                padding: const EdgeInsets.symmetric(
                    vertical: HavenSpacing.sm),
                children: items,
              );
            },
            loading: () => const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(HavenSpacing.xl),
                child: Text(
                  'Failed to load members',
                  style: HavenTypography.bodySmall
                      .copyWith(color: haven.textSecondary),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Peer member list content (header + peer list).
class _PeerMemberContent extends ConsumerWidget {
  const _PeerMemberContent({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final haven = HavenTheme.of(context);
    final peers = ref.watch(peersProvider);
    final memberListReveal =
        StartupRevealScope.interval(context, 0.60, 0.80);

    return peers.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(HavenSpacing.xl),
              child: Text(
                'No peers online',
                style: HavenTypography.bodySmall.copyWith(
                  color: haven.textSecondary,
                ),
              ),
            ),
          )
        : ListView.builder(
            itemCount: peers.length + 1, // +1 for ASOT header
            padding: const EdgeInsets.symmetric(
                vertical: HavenSpacing.sm),
            itemBuilder: (context, index) {
              // First item: ASOT-style divider
              if (index == 0) {
                return _SectionDivider(
                  label: 'Online',
                  count: peers.length,
                  isOnline: true,
                );
              }
              final peerIndex = index - 1;
              final peerId = peers.keys.elementAt(peerIndex);
              final peer = peers[peerId];

              return StaggeredListItem(
                parentAnimation: memberListReveal,
                index: peerIndex,
                totalItems: peers.length,
                slideFrom: const Offset(0.3, 0),
                child: _MemberTile(
                  peerId: peerId,
                  isEncrypted: peer?.isEncrypted ?? false,
                ),
              );
            },
          );
  }
}

/// A compact member row showing a server member with role badge.
/// Shows online/offline status and per-peer sync icon.
class _ServerMemberTile extends ConsumerWidget {
  final String peerId;
  final String displayName;
  final String role;
  final String nickname;
  final bool isOnline;

  const _ServerMemberTile({
    required this.peerId,
    required this.displayName,
    required this.role,
    required this.nickname,
    required this.isOnline,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final haven = HavenTheme.of(context);
    final isSyncing = ref.watch(isPeerSyncingProvider(peerId));
    // Resolution: nickname → profile display name → short peer ID.
    final profiles = ref.watch(profileProvider);
    final resolvedName =
        serverDisplayNameFor(profiles, peerId, nickname: nickname);

    return AnimatedOpacity(
      opacity: isOnline ? 1.0 : 0.5,
      duration: HavenDurations.fast,
      child: HavenPressable(
        subtle: true,
        borderRadius: BorderRadius.circular(haven.radiusSm),
        onTap: () {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null) return;
          final pos = box.localToGlobal(Offset.zero);
          // Show card to the left of member panel (like Discord)
          showProfileCardPopup(
            context: context,
            ref: ref,
            peerId: peerId,
            nickname: nickname.isNotEmpty ? nickname : null,
            role: role,
            anchor: Offset(pos.dx - 270, pos.dy - 100),
          );
        },
        padding: const EdgeInsets.symmetric(
          horizontal: HavenSpacing.sm + 2,
          vertical: HavenSpacing.xxs + 1,
        ),
        child: Row(
          children: [
            // Avatar with status overlay
            Stack(
              children: [
                HavenAvatar(peerId: peerId, size: 28),
                Positioned(
                  right: -1,
                  bottom: -1,
                  child: Container(
                    decoration: BoxDecoration(
                      color: haven.surface,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(1.5),
                    child: isSyncing
                        ? _SpinningRefreshIcon(
                            size: 9, color: haven.accent)
                        : StatusDot(
                            color: isOnline
                                ? haven.success
                                : haven.textSecondary,
                            size: 7,
                            pulse: isOnline,
                          ),
                  ),
                ),
              ],
            ),

            const SizedBox(width: HavenSpacing.sm),

            // Display name + role
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    resolvedName,
                    style: HavenTypography.bodySmall.copyWith(
                      color: haven.textPrimary,
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (role != 'member')
                    Text(
                      role[0].toUpperCase() + role.substring(1),
                      style: HavenTypography.caption.copyWith(
                        color: _roleLabelColor(role, haven),
                        fontSize: 10,
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

/// A compact member row in the member panel (peer/DM mode).
class _MemberTile extends ConsumerWidget {
  final String peerId;
  final bool isEncrypted;

  const _MemberTile({
    required this.peerId,
    required this.isEncrypted,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final haven = HavenTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final peerName = displayNameFor(profiles, peerId);

    return HavenPressable(
      subtle: true,
      borderRadius: BorderRadius.circular(haven.radiusSm),
      onTap: () {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final pos = box.localToGlobal(Offset.zero);
        // Show card to the left of member panel (like Discord)
        showProfileCardPopup(
          context: context,
          ref: ref,
          peerId: peerId,
          anchor: Offset(pos.dx - 270, pos.dy - 100),
        );
      },
      padding: const EdgeInsets.symmetric(
        horizontal: HavenSpacing.sm + 2,
        vertical: HavenSpacing.xxs + 1,
      ),
      child: Row(
        children: [
          // Avatar with online dot
          Stack(
            children: [
              HavenAvatar(peerId: peerId, size: 28),
              Positioned(
                right: -1,
                bottom: -1,
                child: Container(
                  decoration: BoxDecoration(
                    color: haven.surface,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(1.5),
                  child: StatusDot(
                      color: haven.success, size: 7, pulse: true),
                ),
              ),
            ],
          ),

          const SizedBox(width: HavenSpacing.sm),

          // Display name
          Expanded(
            child: Text(
              peerName,
              style: HavenTypography.bodySmall.copyWith(
                color: haven.textSecondary,
                fontSize: 12,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Encryption badge or spinning icon
          isEncrypted
              ? Icon(
                  LucideIcons.lock,
                  size: 12,
                  color: haven.success,
                )
              : _SpinningRefreshIcon(
                  size: 12, color: haven.textSecondary),
        ],
      ),
    );
  }
}
