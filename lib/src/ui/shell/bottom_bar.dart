import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/node_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/profile_card_popup.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/dialogs/create_server_dialog.dart';
import 'package:hollow/src/ui/dialogs/mnemonic_dialog.dart';
import 'package:hollow/src/ui/dialogs/user_settings_dialog.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Horizontal bottom bar for the Dock layout.
///
/// Layout: [User Panel] | [Server Strip (center)] | [Utility Buttons]
class BottomBar extends ConsumerStatefulWidget {
  const BottomBar({super.key});

  @override
  ConsumerState<BottomBar> createState() => _BottomBarState();
}

class _BottomBarState extends ConsumerState<BottomBar> {
  /// Tracks initial server IDs to skip entrance animation.
  Set<String>? _initialServerIds;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final identity = ref.watch(identityProvider);
    final nodeState = ref.watch(nodeProvider);
    final profiles = ref.watch(profileProvider);
    final servers = ref.watch(serverListProvider);
    final selectedServerId = ref.watch(selectedServerProvider);
    final unreadState = ref.watch(unreadProvider);
    final notifSettings = ref.watch(notificationSettingsProvider.notifier);

    _initialServerIds ??= servers.keys.toSet();

    final localPeerId = identity.peerId;
    final myDisplayName =
        localPeerId != null ? displayNameFor(profiles, localPeerId) : '---';

    // Node status for user panel dot.
    final statusColor = _statusColor(hollow, nodeState.status);
    final statusPulse = nodeState.status == NodeStatus.connected;

    // DM unread count for Home button.
    int dmUnreadTotal = 0;
    for (final entry in unreadState.dmUnreadCounts.entries) {
      if (notifSettings.isDmEnabled(entry.key)) {
        dmUnreadTotal += entry.value;
      }
    }

    final serverEntries = servers.values.toList();
    final splitState = ref.watch(splitViewProvider);

    return Container(
      height: 58,
      decoration: BoxDecoration(
        color: hollow.background,
        border: Border(
          top: BorderSide(color: hollow.border),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── Left: Compact User Panel ──
          SizedBox(
            width: 140,
            child: HollowPressable(
              onTap: () {
                if (localPeerId != null) {
                  final box = context.findRenderObject() as RenderBox?;
                  final pos =
                      box?.localToGlobal(Offset.zero) ?? Offset.zero;
                  showProfileCardPopup(
                    context: context,
                    ref: ref,
                    peerId: localPeerId,
                    anchor: Offset(pos.dx + 8, pos.dy - 8),
                    anchorBottom: true,
                  );
                }
              },
              borderRadius: BorderRadius.zero,
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.md,
              ),
              child: Row(
                children: [
                  if (localPeerId != null)
                    HollowAvatar(peerId: localPeerId, size: 28)
                  else
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: hollow.elevated,
                        borderRadius:
                            BorderRadius.circular(hollow.radiusMd),
                      ),
                    ),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Row(
                      children: [
                        StatusDot(
                          color: statusColor,
                          size: 7,
                          pulse: statusPulse,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            myDisplayName,
                            style: HollowTypography.caption.copyWith(
                              color: hollow.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          Container(width: 1, height: 28, color: hollow.border),

          // ── Center: Server Strip ──
          // Home pinned left, Add pinned right, server icons centered
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(width: HollowSpacing.sm),

                // Home button (pinned left)
                _BottomServerIcon(
                  isSelected: selectedServerId == null,
                  unreadCount:
                      selectedServerId != null ? dmUnreadTotal : 0,
                  tooltip: 'Home',
                  backgroundColor: hollow.accent,
                  onTap: () => _goHome(ref),
                  child: Text(
                    'H',
                    style: TextStyle(
                      color: hollow.textOnAccent,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),

                Container(
                  width: 2,
                  height: 24,
                  margin: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: hollow.border,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),

                // Server icons (centered in available space)
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (int i = 0;
                              i < serverEntries.length;
                              i++) ...[
                            Builder(builder: (context) {
                              final server = serverEntries[i];
                              final isSelected = server.serverId ==
                                  selectedServerId;
                              final isRightPaneServer =
                                  splitState.isSplit &&
                                      splitState
                                              .rightPane?.serverId ==
                                          server.serverId;
                              final isNew = !_initialServerIds!
                                  .contains(server.serverId);

                              final isServerMuted = notifSettings
                                  .isServerMuted(server.serverId);
                              final serverUnreads = isServerMuted
                                  ? 0
                                  : ref
                                      .watch(
                                          unreadProvider.notifier)
                                      .serverUnreadCount(
                                          server.serverId);

                              Widget icon = _BottomServerIcon(
                                isSelected:
                                    isSelected || isRightPaneServer,
                                unreadCount:
                                    (isSelected || isRightPaneServer)
                                        ? 0
                                        : serverUnreads,
                                tooltip: server.name,
                                backgroundColor:
                                    _colorFromId(server.serverId),
                                onTap: () => _selectServer(
                                    ref, server.serverId),
                                child: Text(
                                  _initialsFromName(server.name),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              );

                              if (isNew) {
                                icon = _ScaleBounceEntry(
                                  key: ValueKey(
                                      'bounce-${server.serverId}'),
                                  child: icon,
                                );
                              }

                              return Padding(
                                padding: EdgeInsets.only(
                                  right: i < serverEntries.length - 1
                                      ? HollowSpacing.xs
                                      : 0,
                                ),
                                child: icon,
                              );
                            }),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),

                Container(
                  width: 2,
                  height: 24,
                  margin: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: hollow.border,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),

                // Add server button (pinned right)
                _BottomServerIcon(
                  tooltip: 'Create a server',
                  backgroundColor: hollow.elevated,
                  onTap: () => showCreateServerDialog(context),
                  child: Icon(
                    LucideIcons.plus,
                    color: hollow.accent,
                    size: 18,
                  ),
                ),

                const SizedBox(width: HollowSpacing.sm),
              ],
            ),
          ),

          Container(width: 1, height: 28, color: hollow.border),

          // ── Right: Utility Buttons (same width as left for symmetry) ──
          SizedBox(
            width: 140,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                HollowTooltip(
                  message: 'Settings',
                  child: HollowPressable(
                    onTap: () => showUserSettingsDialog(context, ref, openSystemTab: true),
                    borderRadius:
                        BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.sm),
                    child: Icon(
                      LucideIcons.settings,
                      size: 18,
                      color: hollow.textSecondary,
                    ),
                  ),
                ),
                if (identity.mnemonic != null)
                  HollowTooltip(
                    message: 'Recovery phrase',
                    child: HollowPressable(
                      onTap: () => showMnemonicDialog(
                          context, identity.mnemonic!),
                      borderRadius:
                          BorderRadius.circular(hollow.radiusSm),
                      padding: const EdgeInsets.all(HollowSpacing.sm),
                      child: Icon(
                        LucideIcons.keyRound,
                        size: 18,
                        color: hollow.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _goHome(WidgetRef ref) {
    // Always close split and go home.
    final split = ref.read(splitViewProvider);
    if (split.isSplit) {
      ref.read(splitViewProvider.notifier).closeSplit();
    }
    ref.read(selectedServerProvider.notifier).state = null;
    ref.read(channelListProvider.notifier).clear();
    ref.read(selectedChannelProvider.notifier).state = null;
    ref.read(selectedPeerProvider.notifier).state = null;
    ref.read(serverSettingsOpenProvider.notifier).state = false;
  }

  Future<void> _selectServer(WidgetRef ref, String serverId) async {
    final split = ref.read(splitViewProvider);
    if (split.isSplit && split.focusedPane == 1) {
      // Navigate right pane to server — load channels directly from FFI
      // to avoid overwriting the global channelListProvider.
      try {
        final channels =
            await crdt_api.getServerChannels(serverId: serverId);
        final lastChannels = ref.read(lastChannelPerServerProvider);
        final lastChannel = lastChannels[serverId];
        String? channelToSelect;
        if (lastChannel != null &&
            channels.any((c) => c.channelId == lastChannel)) {
          channelToSelect = lastChannel;
        } else if (channels.isNotEmpty) {
          channelToSelect = channels.first.channelId;
        }
        ref.read(splitViewProvider.notifier).navigateRightToServer(
              serverId,
              channelId: channelToSelect,
            );
      } catch (_) {
        ref.read(splitViewProvider.notifier).navigateRightToServer(serverId);
      }
      return;
    }

    // Load channels BEFORE setting server — avoids empty sidebar flash.
    ref.read(selectedPeerProvider.notifier).state = null;
    ref.read(serverSettingsOpenProvider.notifier).state = false;

    await ref.read(channelListProvider.notifier).loadForServer(serverId);
    ref.read(channelLayoutProvider.notifier).loadForServer(serverId);

    // Now set the server — sidebar appears with channels already loaded.
    ref.read(selectedServerProvider.notifier).state = serverId;

    final lastChannels = ref.read(lastChannelPerServerProvider);
    final lastChannel = lastChannels[serverId];

    final channels = ref.read(channelListProvider);
    String? channelToSelect;
    if (lastChannel != null && channels.containsKey(lastChannel)) {
      channelToSelect = lastChannel;
    } else if (channels.isNotEmpty) {
      channelToSelect = channels.keys.first;
    }
    ref.read(selectedChannelProvider.notifier).state = channelToSelect;
    if (channelToSelect != null) {
      final map =
          Map<String, String>.from(ref.read(lastChannelPerServerProvider));
      map[serverId] = channelToSelect;
      ref.read(lastChannelPerServerProvider.notifier).state = map;
    }
  }

  Color _statusColor(HollowTheme hollow, NodeStatus status) {
    return switch (status) {
      NodeStatus.connected => hollow.success,
      NodeStatus.starting => hollow.warning,
      NodeStatus.loading => hollow.textSecondary,
      NodeStatus.error => hollow.error,
    };
  }
}

/// Deterministic color from an ID string.
Color _colorFromId(String id) {
  final hash = id.hashCode;
  final hue = (hash % 360).abs().toDouble();
  return HSLColor.fromAHSL(1.0, hue, 0.5, 0.45).toColor();
}

/// Extract 1-2 letter initials from a server name.
String _initialsFromName(String name) {
  final words = name.trim().split(RegExp(r'\s+'));
  if (words.length >= 2) {
    return '${words[0][0]}${words[1][0]}'.toUpperCase();
  }
  return name.substring(0, name.length.clamp(0, 2)).toUpperCase();
}

/// Server icon for the horizontal bottom bar.
/// Rounded square with bottom-edge selection indicator.
class _BottomServerIcon extends StatefulWidget {
  final Widget child;
  final Color backgroundColor;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool isSelected;
  final int unreadCount;

  const _BottomServerIcon({
    required this.child,
    required this.backgroundColor,
    this.onTap,
    this.tooltip,
    this.isSelected = false,
    this.unreadCount = 0,
  });

  @override
  State<_BottomServerIcon> createState() => _BottomServerIconState();
}

class _BottomServerIconState extends State<_BottomServerIcon> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final radius =
        (_hovering || widget.isSelected) ? 12.0 : hollow.radiusLg;
    final effectiveBg = _hovering && !widget.isSelected
        ? Color.lerp(widget.backgroundColor, hollow.accent, 0.15)!
        : widget.backgroundColor;

    // Bottom-edge indicator width.
    final indicatorWidth =
        widget.isSelected ? 28.0 : (_hovering ? 16.0 : 0.0);

    // Stack layout: icon centered, indicator pinned to bottom edge.
    // Indicator uses Positioned so it doesn't affect icon centering.
    Widget icon = MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            // Icon (centered)
            Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOutCubic,
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: effectiveBg,
                    borderRadius: BorderRadius.circular(radius),
                    border: widget.isSelected
                        ? Border.all(
                            color: hollow.accent.withValues(alpha: 0.6),
                            width: 2,
                          )
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: widget.child,
                ),
                // Unread badge
                if (widget.unreadCount > 0)
                  Positioned(
                    right: -5,
                    top: -4,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 14),
                      height: 14,
                      padding:
                          const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: hollow.error,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: hollow.background,
                          width: 2,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        widget.unreadCount > 99
                            ? '99+'
                            : '${widget.unreadCount}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 8,
                          fontWeight: FontWeight.w700,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            // Bottom-edge indicator — pinned to bottom, no layout impact
            Positioned(
              bottom: -8,
              child: AnimatedContainer(
                duration: HollowDurations.fast,
                curve: HollowCurves.enter,
                width: indicatorWidth,
                height: 3,
                decoration: BoxDecoration(
                  color: indicatorWidth > 0
                      ? hollow.textPrimary
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (widget.tooltip != null) {
      icon = HollowTooltip(message: widget.tooltip!, child: icon);
    }

    return icon;
  }
}

/// Scale-bounce entrance animation for new server icons.
class _ScaleBounceEntry extends StatefulWidget {
  final Widget child;

  const _ScaleBounceEntry({super.key, required this.child});

  @override
  State<_ScaleBounceEntry> createState() => _ScaleBounceEntryState();
}

class _ScaleBounceEntryState extends State<_ScaleBounceEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 0.0, end: 1.1), weight: 60),
      TweenSequenceItem(
          tween: Tween(begin: 1.1, end: 0.95), weight: 20),
      TweenSequenceItem(
          tween: Tween(begin: 0.95, end: 1.0), weight: 20),
    ]).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(scale: _scale, child: widget.child);
  }
}
