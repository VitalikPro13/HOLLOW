import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/providers/identity_provider.dart';
import 'package:haven/src/core/providers/peers_provider.dart';
import 'package:haven/src/core/providers/server_provider.dart';
import 'package:haven/src/core/providers/sync_progress_provider.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/animations/haven_curves.dart';
import 'package:haven/src/ui/animations/reveal_widgets.dart';
import 'package:haven/src/ui/animations/startup_reveal.dart';
import 'package:haven/src/ui/components/haven_avatar.dart';
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
class _SectionDivider extends StatelessWidget {
  final String label;
  final int count;
  final bool isOnline;

  const _SectionDivider({
    required this.label,
    required this.count,
    required this.isOnline,
  });

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HavenSpacing.sm + 2,
        vertical: HavenSpacing.sm,
      ),
      child: Row(
        children: [
          Text(
            label,
            style: HavenTypography.caption.copyWith(
              color: haven.textSecondary,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
              fontSize: 11,
            ),
          ),
          const SizedBox(width: HavenSpacing.sm),
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                color: haven.border,
                boxShadow: isOnline
                    ? [
                        BoxShadow(
                          color: haven.accent.withValues(alpha: 0.3),
                          blurRadius: 4,
                        ),
                      ]
                    : null,
              ),
            ),
          ),
          const SizedBox(width: HavenSpacing.sm),
          Text(
            '$count',
            style: HavenTypography.caption.copyWith(
              color: haven.textSecondary,
              fontWeight: FontWeight.w600,
              fontSize: 11,
            ),
          ),
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
        // Header
        Container(
          height: 48,
          padding:
              const EdgeInsets.symmetric(horizontal: HavenSpacing.lg),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: haven.border),
            ),
          ),
          alignment: Alignment.centerLeft,
          child: membersAsync.when(
            data: (members) => Text(
              'Members \u2014 ${members.length}',
              style: HavenTypography.caption.copyWith(
                color: haven.textSecondary,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
              ),
            ),
            loading: () => Text(
              'Members \u2014 ...',
              style: HavenTypography.caption.copyWith(
                color: haven.textSecondary,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
              ),
            ),
            error: (_, _) => Text(
              'Members \u2014 ?',
              style: HavenTypography.caption.copyWith(
                color: haven.textSecondary,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
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

              // Build flat item list
              final items = <Widget>[];
              if (online.isNotEmpty) {
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
                    isOnline: true,
                  ));
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
    final headerReveal =
        StartupRevealScope.interval(context, 0.55, 0.65);
    final memberListReveal =
        StartupRevealScope.interval(context, 0.60, 0.80);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Container(
          height: 48,
          padding:
              const EdgeInsets.symmetric(horizontal: HavenSpacing.lg),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: haven.border),
            ),
          ),
          alignment: Alignment.centerLeft,
          child: TypewriterText(
            text: 'Members \u2014 ${peers.length}',
            animation: headerReveal,
            style: HavenTypography.caption.copyWith(
              color: haven.textSecondary,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
        ),

        // Peer list
        Expanded(
          child: peers.isEmpty
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
                  itemCount: peers.length,
                  padding: const EdgeInsets.symmetric(
                      vertical: HavenSpacing.sm),
                  itemBuilder: (context, index) {
                    final peerId = peers.keys.elementAt(index);
                    final peer = peers[peerId];

                    return StaggeredListItem(
                      parentAnimation: memberListReveal,
                      index: index,
                      totalItems: peers.length,
                      slideFrom: const Offset(0.3, 0),
                      child: _MemberTile(
                        peerId: peerId,
                        isEncrypted: peer?.isEncrypted ?? false,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// A compact member row showing a server member with role badge.
/// Shows online/offline status and per-peer sync icon.
class _ServerMemberTile extends ConsumerWidget {
  final String peerId;
  final String displayName;
  final String role;
  final bool isOnline;

  const _ServerMemberTile({
    required this.peerId,
    required this.displayName,
    required this.role,
    required this.isOnline,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final haven = HavenTheme.of(context);
    final isSyncing = ref.watch(isPeerSyncingProvider(peerId));

    return AnimatedOpacity(
      opacity: isOnline ? 1.0 : 0.5,
      duration: HavenDurations.fast,
      child: Padding(
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
                    displayName.isNotEmpty
                        ? displayName
                        : (peerId.length > 12
                            ? '${peerId.substring(0, 12)}...'
                            : peerId),
                    style: HavenTypography.bodySmall.copyWith(
                      color: haven.textPrimary,
                      fontFamily: 'Consolas',
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (role == 'owner')
                    Text(
                      'Owner',
                      style: HavenTypography.caption.copyWith(
                        color: haven.accent,
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
class _MemberTile extends StatelessWidget {
  final String peerId;
  final bool isEncrypted;

  const _MemberTile({
    required this.peerId,
    required this.isEncrypted,
  });

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);

    return Padding(
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

          // Peer ID
          Expanded(
            child: Text(
              peerId.length > 12
                  ? '${peerId.substring(0, 12)}...'
                  : peerId,
              style: HavenTypography.bodySmall.copyWith(
                color: haven.textSecondary,
                fontFamily: 'Consolas',
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
