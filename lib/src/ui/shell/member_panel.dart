import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/core/providers/sync_progress_provider.dart';
import 'package:hollow/src/core/providers/webrtc_provider.dart';
import 'package:hollow/src/core/shared_tickers.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/animations/reveal_widgets.dart';
import 'package:hollow/src/ui/animations/startup_reveal.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/profile_card_popup.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';

/// Right-side member panel (240px) showing online peers or server members.
class MemberPanel extends ConsumerWidget {
  /// Fixed width for desktop/tablet. Pass null on mobile to fill available space.
  final double? width;

  const MemberPanel({super.key, this.width = 240});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final selectedServerId = ref.watch(selectedServerProvider);

    final panelReveal =
        StartupRevealScope.interval(context, 0.45, 0.60);

    Widget panel = Container(
      width: width,
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(
          left: BorderSide(color: hollow.border),
        ),
      ),
      child: AnimatedSwitcher(
        duration: HollowDurations.normal,
        switchInCurve: HollowCurves.enter,
        switchOutCurve: HollowCurves.exit,
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

/// Lightweight data entry for the flat member list. No widget allocation —
/// ListView.builder creates widgets lazily from these entries.
class _MemberListEntry {
  final bool isDivider;
  final bool isOnline;
  // Divider fields
  final String? label;
  final int? count;
  final String? dividerRole;
  // Member fields
  final String? peerId;
  final String? displayName;
  final String? role;
  final String? nickname;
  final String? twitchUsername;
  final List<crdt_api.LabelFfi>? labels;
  final String? serverId;

  const _MemberListEntry._({
    required this.isDivider,
    required this.isOnline,
    this.label,
    this.count,
    this.dividerRole,
    this.peerId,
    this.displayName,
    this.role,
    this.nickname,
    this.twitchUsername,
    this.labels,
    this.serverId,
  });

  factory _MemberListEntry.divider({
    required String label,
    required int count,
    required bool isOnline,
    String? dividerRole,
  }) => _MemberListEntry._(
    isDivider: true, isOnline: isOnline,
    label: label, count: count, dividerRole: dividerRole,
  );

  factory _MemberListEntry.member(dynamic m, {required bool isOnline, String? serverId}) =>
    _MemberListEntry._(
      isDivider: false, isOnline: isOnline,
      peerId: m.peerId, displayName: m.displayName,
      role: m.role, nickname: m.nickname,
      twitchUsername: m.twitchUsername,
      labels: (m.labels as List<dynamic>?)?.cast<crdt_api.LabelFfi>() ?? const [],
      serverId: serverId,
    );
}

/// ASOT-style section divider: "Online ------------ 10"
/// Online variant has a subtle left-to-right glow sweep on the line.
/// Uses [SharedTickers.shimmer] instead of per-instance AnimationController.
/// [glowColor] overrides the default accent color for the glow sweep.
class _SectionDivider extends StatelessWidget {
  final String label;
  final int count;
  final bool isOnline;
  final Color? glowColor;

  const _SectionDivider({
    super.key,
    required this.label,
    required this.count,
    required this.isOnline,
    this.glowColor,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final textStyle = HollowTypography.caption.copyWith(
      color: hollow.textSecondary,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.8,
      fontSize: 11,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm + 2,
        vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          Text(label, style: textStyle),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: isOnline
                ? ValueListenableBuilder<double>(
                    valueListenable: SharedTickers.instance.shimmer,
                    builder: (context, value, _) {
                      // Ping-pong: 0→1→0 with easeInOut curve.
                      final pingPong = value < 0.5
                          ? value * 2.0
                          : 2.0 - value * 2.0;
                      final curved =
                          Curves.easeInOut.transform(pingPong);
                      // Map 0..1 to -0.2..1.2 so the glow fully exits both edges.
                      final t = -0.2 + curved * 1.4;
                      const glowWidth = 0.15;
                      final color = glowColor ?? hollow.accent;
                      return Container(
                        height: 1,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              hollow.border,
                              color.withValues(alpha: 0.5),
                              hollow.border,
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
                    color: hollow.border,
                  ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Text('$count', style: textStyle),
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
      duration: HollowDurations.animationsDisabled
          ? Duration.zero
          : const Duration(milliseconds: 1500),
    );
    if (!HollowDurations.animationsDisabled) _controller.repeat();
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
Color _roleGlowColor(String role, HollowTheme hollow) {
  return switch (role) {
    'owner' => hollow.warning,
    'admin' => const Color(0xFFA78BFA),
    'moderator' =>
      Color.lerp(hollow.warning, hollow.error, 0.5) ?? hollow.warning,
    _ => hollow.accent,
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
Color _roleLabelColor(String role, HollowTheme hollow) {
  return switch (role) {
    'owner' => hollow.warning,
    'admin' => const Color(0xFFA78BFA),
    'moderator' =>
      Color.lerp(hollow.warning, hollow.error, 0.5) ?? hollow.warning,
    _ => hollow.textSecondary,
  };
}

/// Computed member list entries: memoized online/offline split + role grouping.
/// Returns (entries, totalMemberCount, isLoading, errorMessage).
final _serverMemberEntriesProvider = Provider.family
    .autoDispose<(List<_MemberListEntry>, int, bool, String?), String>(
        (ref, serverId) {
  final membersAsync = ref.watch(serverMembersProvider(serverId));
  final peerIds = ref.watch(peersProvider.select((p) => p.keys.toSet()));
  final localPeerId = ref.watch(identityProvider).peerId;
  final invisiblePeers = ref.watch(invisiblePeersProvider);
  final amInvisible = ref.watch(invisibleModeProvider);

  return membersAsync.when(
    data: (members) {
      if (members.isEmpty) return (const <_MemberListEntry>[], 0, false, null);

      final online = members
          .where((m) {
            if (m.peerId == localPeerId) return !amInvisible;
            return peerIds.contains(m.peerId) &&
                !invisiblePeers.contains(m.peerId);
          })
          .toList();
      final offline = members
          .where((m) {
            if (m.peerId == localPeerId) return amInvisible;
            return !peerIds.contains(m.peerId) ||
                invisiblePeers.contains(m.peerId);
          })
          .toList();

      const roleOrder = ['owner', 'admin', 'moderator', 'member'];
      final flatItems = <_MemberListEntry>[];

      if (online.isNotEmpty) {
        final roles = online.map((m) => m.role).toSet();
        if (roles.length == 1 && roles.first == 'member') {
          flatItems.add(_MemberListEntry.divider(
            label: 'Online', count: online.length, isOnline: true,
          ));
          for (final m in online) {
            flatItems.add(
                _MemberListEntry.member(m, isOnline: true, serverId: serverId));
          }
        } else {
          final groups = <String, List<dynamic>>{};
          for (final m in online) {
            (groups[m.role] ??= []).add(m);
          }
          for (final role in roleOrder) {
            final group = groups[role];
            if (group == null || group.isEmpty) continue;
            flatItems.add(_MemberListEntry.divider(
              label: _roleDividerLabel(role),
              count: group.length,
              isOnline: true,
              dividerRole: role,
            ));
            for (final m in group) {
              flatItems.add(_MemberListEntry.member(m,
                  isOnline: true, serverId: serverId));
            }
          }
        }
      }
      if (offline.isNotEmpty) {
        flatItems.add(_MemberListEntry.divider(
          label: 'Offline', count: offline.length, isOnline: false,
        ));
        for (final m in offline) {
          flatItems.add(
              _MemberListEntry.member(m, isOnline: false, serverId: serverId));
        }
      }
      return (flatItems, members.length, false, null);
    },
    loading: () => (const <_MemberListEntry>[], 0, true, null),
    error: (e, _) => (const <_MemberListEntry>[], 0, false, e.toString()),
  );
});

/// Server member list content (header + online/offline member list).
class _ServerMemberContent extends ConsumerWidget {
  final String serverId;

  const _ServerMemberContent({
    super.key,
    required this.serverId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final (entries, totalCount, isLoading, error) =
        ref.watch(_serverMemberEntriesProvider(serverId));

    final captionStyle = HollowTypography.caption.copyWith(
      color: hollow.textSecondary,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.8,
      fontSize: 11,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header — ASOT-style divider matching Online/Offline sections
        Container(
          height: 48,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: hollow.border),
            ),
          ),
          alignment: Alignment.centerLeft,
          child: isLoading
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.sm + 2,
                  ),
                  child: Text('Members ...', style: captionStyle),
                )
              : error != null
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: HollowSpacing.sm + 2,
                      ),
                      child: Text('Members ?', style: captionStyle),
                    )
                  : _SectionDivider(
                      label: 'Members',
                      count: totalCount,
                      isOnline: false,
                    ),
        ),

        // Member list with online/offline sections
        Expanded(
          child: isLoading
              ? const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(HollowSpacing.xl),
                        child: Text(
                          'Failed to load members',
                          style: HollowTypography.bodySmall
                              .copyWith(color: hollow.textSecondary),
                        ),
                      ),
                    )
                  : entries.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(HollowSpacing.xl),
                            child: Text(
                              'No members',
                              style: HollowTypography.bodySmall
                                  .copyWith(color: hollow.textSecondary),
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(
                              vertical: HollowSpacing.sm),
                          itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            if (entry.isDivider) {
                              return _SectionDivider(
                                key: ValueKey('div-${entry.label}'),
                                label: entry.label!,
                                count: entry.count!,
                                isOnline: entry.isOnline,
                                glowColor: entry.dividerRole != null
                                    ? _roleGlowColor(entry.dividerRole!, hollow)
                                    : null,
                              );
                            }
                            return _ServerMemberTile(
                              key: ValueKey('mem-${entry.peerId}'),
                              peerId: entry.peerId!,
                              displayName: entry.displayName!,
                              role: entry.role!,
                              nickname: entry.nickname!,
                              twitchUsername: entry.twitchUsername!,
                              labels: entry.labels!,
                              isOnline: entry.isOnline,
                              serverId: entry.serverId,
                            );
                          },
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
    final hollow = HollowTheme.of(context);
    final allPeers = ref.watch(peersProvider);
    final invisPeers = ref.watch(invisiblePeersProvider);
    final peers = Map.of(allPeers)
      ..removeWhere((id, _) => invisPeers.contains(id));
    final memberListReveal =
        StartupRevealScope.interval(context, 0.60, 0.80);

    return peers.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(HollowSpacing.xl),
              child: Text(
                'No peers online',
                style: HollowTypography.bodySmall.copyWith(
                  color: hollow.textSecondary,
                ),
              ),
            ),
          )
        : ListView.builder(
            itemCount: peers.length + 1, // +1 for ASOT header
            padding: const EdgeInsets.symmetric(
                vertical: HollowSpacing.sm),
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
  final String twitchUsername;
  final bool isOnline;
  final String? serverId;
  final List<crdt_api.LabelFfi> labels;

  const _ServerMemberTile({
    super.key,
    required this.peerId,
    required this.displayName,
    required this.role,
    required this.nickname,
    required this.twitchUsername,
    required this.isOnline,
    this.serverId,
    this.labels = const [],
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final isSyncing = ref.watch(isPeerSyncingProvider(peerId));
    // Resolution: local nickname → server nickname → profile display name → short peer ID.
    final profile = ref.watch(profileProvider.select((p) => p[peerId]));
    ref.watch(localNicknameProvider); // trigger rebuild on local nickname changes
    final resolvedName = profile != null
        ? serverDisplayNameFor({peerId: profile}, peerId, nickname: nickname)
        : serverDisplayNameFor({}, peerId, nickname: nickname);
    final effectiveTwitch = twitchUsername.isNotEmpty
        ? twitchUsername
        : (profile?.twitchUsername ?? '');

    return AnimatedOpacity(
      opacity: isOnline ? 1.0 : 0.5,
      duration: HollowDurations.fast,
      child: HollowPressable(
        subtle: true,
        borderRadius: BorderRadius.circular(hollow.radiusSm),
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
            twitchUsername: effectiveTwitch.isNotEmpty ? effectiveTwitch : null,
            labels: labels.isNotEmpty ? labels : null,
            anchor: Offset(pos.dx - 290, pos.dy - 100),
          );
        },
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm + 2,
          vertical: HollowSpacing.xxs + 1,
        ),
        child: Row(
          children: [
            // Avatar with status overlay
            Stack(
              children: [
                HollowAvatar(peerId: peerId, size: 28),
                Positioned(
                  right: -1,
                  bottom: -1,
                  child: Container(
                    decoration: BoxDecoration(
                      color: hollow.surface,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(1.5),
                    child: isSyncing
                        ? _SpinningRefreshIcon(
                            size: 9, color: hollow.accent)
                        : StatusDot(
                            color: isOnline
                                ? hollow.success
                                : hollow.textSecondary,
                            size: 7,
                            pulse: isOnline,
                          ),
                  ),
                ),
              ],
            ),

            const SizedBox(width: HollowSpacing.sm),

            // Display name + role + pledge info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    resolvedName,
                    style: HollowTypography.bodySmall.copyWith(
                      color: hollow.textPrimary,
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (role != 'member')
                    Text(
                      role[0].toUpperCase() + role.substring(1),
                      style: HollowTypography.caption.copyWith(
                        color: _roleLabelColor(role, hollow),
                        fontSize: 10,
                      ),
                    ),
                  if (effectiveTwitch.isNotEmpty)
                    Row(
                      children: [
                        Icon(SimpleIcons.twitch,
                            size: 10, color: const Color(0xFF9146FF)),
                        const SizedBox(width: 3),
                        Text(
                          effectiveTwitch,
                          style: HollowTypography.caption.copyWith(
                            color: const Color(0xFF9146FF),
                            fontSize: 9,
                          ),
                        ),
                      ],
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
    final hollow = HollowTheme.of(context);
    final profile = ref.watch(profileProvider.select((p) => p[peerId]));
    ref.watch(localNicknameProvider); // trigger rebuild on local nickname changes
    final peerName = profile != null
        ? displayNameFor({peerId: profile}, peerId)
        : displayNameFor({}, peerId);

    return HollowPressable(
      subtle: true,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      onTap: () {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final pos = box.localToGlobal(Offset.zero);
        // Show card to the left of member panel (like Discord)
        showProfileCardPopup(
          context: context,
          ref: ref,
          peerId: peerId,
          anchor: Offset(pos.dx - 290, pos.dy - 100),
        );
      },
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm + 2,
        vertical: HollowSpacing.xxs + 1,
      ),
      child: Row(
        children: [
          // Avatar with online dot
          Stack(
            children: [
              HollowAvatar(peerId: peerId, size: 28),
              Positioned(
                right: -1,
                bottom: -1,
                child: Container(
                  decoration: BoxDecoration(
                    color: hollow.surface,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(1.5),
                  child: StatusDot(
                      color: hollow.success, size: 7, pulse: true),
                ),
              ),
            ],
          ),

          const SizedBox(width: HollowSpacing.sm),

          // Display name
          Expanded(
            child: Text(
              peerName,
              style: HollowTypography.bodySmall.copyWith(
                color: hollow.textSecondary,
                fontSize: 12,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // P2P direct connection indicator
          if (ref.watch(webRtcProvider.select((s) =>
              s.peers[peerId] == WebRtcPeerStatus.connected)))
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(
                LucideIcons.radio,
                size: 11,
                color: hollow.accent,
              ),
            ),

          // Encryption badge or spinning icon
          isEncrypted
              ? Icon(
                  LucideIcons.lock,
                  size: 12,
                  color: hollow.success,
                )
              : _SpinningRefreshIcon(
                  size: 12, color: hollow.textSecondary),
        ],
      ),
    );
  }
}
