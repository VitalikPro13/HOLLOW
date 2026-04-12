import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/node_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
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
import 'package:hollow/src/ui/components/download_icon_button.dart';
import 'package:hollow/src/ui/components/server_folder_popup.dart';
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
  bool _isDragging = false;

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

    _initialServerIds ??= ref.read(serverStripLayoutProvider.notifier).allServerIds();

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

    final stripLayout = ref.watch(serverStripLayoutProvider);
    final splitState = ref.watch(splitViewProvider);

    return Container(
      height: 59,
      decoration: BoxDecoration(
        color: hollow.opaqueBackground,
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
                    HollowAvatar(peerId: localPeerId, size: 28, imageBytes: profiles[localPeerId]?.avatarBytes)
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
                          // Reorder drop zone before first item
                          _ReorderGap(index: 0, hollow: hollow, onAccept: (data) {
                            ref.read(serverStripLayoutProvider.notifier).reorder(data.sourceIndex, 0);
                          }),
                          for (int i = 0;
                              i < stripLayout.length;
                              i++) ...[
                            Builder(builder: (context) {
                              final item = stripLayout[i];

                              return switch (item) {
                                ServerStripItem(:final serverId) =>
                                  _buildServerIcon(
                                    ref: ref,
                                    index: i,
                                    serverId: serverId,
                                    servers: servers,
                                    selectedServerId: selectedServerId,
                                    splitState: splitState,
                                    notifSettings: notifSettings,
                                    hollow: hollow,
                                  ),
                                FolderStripItem() =>
                                  _buildFolderIcon(
                                    ref: ref,
                                    index: i,
                                    folder: item,
                                    servers: servers,
                                    selectedServerId: selectedServerId,
                                    splitState: splitState,
                                    notifSettings: notifSettings,
                                    hollow: hollow,
                                  ),
                              };
                            }),
                            // Reorder drop zone after each item
                            _ReorderGap(index: i + 1, hollow: hollow, onAccept: (data) {
                              ref.read(serverStripLayoutProvider.notifier).reorder(data.sourceIndex, i + 1);
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
                const DownloadIconButton(iconSize: 18),
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
          // Prefer first text channel over voice channels.
          channelToSelect = channels
              .where((c) => c.channelType == 'text')
              .firstOrNull
              ?.channelId ?? channels.first.channelId;
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

    // Fetch data from DB first — no provider writes yet, so no rebuilds.
    final channels = await ChannelListNotifier.fetchChannels(serverId);
    final layout = await ChannelLayoutNotifier.fetchLayout(serverId);

    final lastChannels = ref.read(lastChannelPerServerProvider);
    final lastChannel = lastChannels[serverId];

    String? channelToSelect;
    if (lastChannel != null && channels.containsKey(lastChannel)) {
      channelToSelect = lastChannel;
    } else if (channels.isNotEmpty) {
      channelToSelect = firstTextChannelInLayout(channels, layout)
          ?? channels.keys.first;
    }

    // Batch all provider writes synchronously — single rebuild with
    // consistent server + channels + selectedChannel state.
    ref.read(selectedPeerProvider.notifier).state = null;
    ref.read(serverSettingsOpenProvider.notifier).state = false;
    ref.read(channelListProvider.notifier).setChannels(channels);
    ref.read(channelLayoutProvider.notifier).setLayout(layout);
    ref.read(selectedChannelProvider.notifier).state = channelToSelect;
    ref.read(selectedServerProvider.notifier).state = serverId;
    if (channelToSelect != null) {
      final map =
          Map<String, String>.from(ref.read(lastChannelPerServerProvider));
      map[serverId] = channelToSelect;
      ref.read(lastChannelPerServerProvider.notifier).state = map;
    }
  }

  Widget _buildServerIcon({
    required WidgetRef ref,
    required int index,
    required String serverId,
    required Map<String, dynamic> servers,
    required String? selectedServerId,
    required dynamic splitState,
    required dynamic notifSettings,
    required HollowTheme hollow,
  }) {
    final server = servers[serverId];
    final isSelected = serverId == selectedServerId;
    final isRightPaneServer =
        splitState.isSplit && splitState.rightPane?.serverId == serverId;
    final isNew = !_initialServerIds!.contains(serverId);
    final isServerMuted = notifSettings.isServerMuted(serverId);
    final serverUnreads = isServerMuted
        ? 0
        : ref.watch(unreadProvider.notifier).serverUnreadCount(serverId);
    final serverAvatar = ref.watch(serverAvatarProvider)[serverId];
    final name = server?.name ?? '';

    Widget serverIconChild = serverAvatar != null
        ? ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(serverAvatar,
                width: 38, height: 38, fit: BoxFit.cover),
          )
        : Text(
            _initialsFromName(name.isNotEmpty ? name : serverId),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          );

    Widget icon = DragTarget<_StripDragData>(
      onWillAcceptWithDetails: (details) {
        final data = details.data;
        // Accept server drops (for folder creation) but not self
        return data.serverId != null && data.serverId != serverId;
      },
      onAcceptWithDetails: (details) {
        final data = details.data;
        if (data.serverId != null) {
          ref.read(serverStripLayoutProvider.notifier)
              .createFolder(data.serverId!, serverId);
        }
      },
      builder: (context, candidateData, rejectedData) {
        final isMergeTarget = candidateData.isNotEmpty;
        return LongPressDraggable<_StripDragData>(
            data: _StripDragData(serverId: serverId, sourceIndex: index),
            delay: const Duration(milliseconds: 300),
            onDragStarted: () => setState(() => _isDragging = true),
            onDragEnd: (_) => setState(() => _isDragging = false),
            onDraggableCanceled: (_, __) => setState(() => _isDragging = false),
            feedback: Material(
              color: Colors.transparent,
              child: AnimatedOpacity(
                opacity: 0.8,
                duration: Duration.zero,
                child: _BottomServerIcon(
                  backgroundColor: _colorFromId(serverId),
                  child: serverIconChild,
                ),
              ),
            ),
            childWhenDragging: AnimatedOpacity(
              opacity: 0.3,
              duration: const Duration(milliseconds: 150),
              child: _BottomServerIcon(
                backgroundColor: _colorFromId(serverId),
                child: serverIconChild,
              ),
            ),
            child: AnimatedScale(
              scale: isMergeTarget ? 1.08 : 1.0,
              duration: const Duration(milliseconds: 150),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                decoration: isMergeTarget
                    ? BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: hollow.accent.withValues(alpha: 0.4),
                            blurRadius: 8,
                          ),
                        ],
                      )
                    : null,
                child: _BottomServerIcon(
                  isSelected: isSelected || isRightPaneServer,
                  unreadCount: serverUnreads,
                  tooltip: _isDragging ? null : name,
                  backgroundColor: _colorFromId(serverId),
                  onTap: () => _selectServer(ref, serverId),
                  child: serverIconChild,
                ),
              ),
            ),
          );
      },
    );

    if (isNew) {
      icon = _ScaleBounceEntry(
        key: ValueKey('bounce-$serverId'),
        child: icon,
      );
    }
    return icon;
  }

  Widget _buildFolderIcon({
    required WidgetRef ref,
    required int index,
    required FolderStripItem folder,
    required Map<String, dynamic> servers,
    required String? selectedServerId,
    required dynamic splitState,
    required dynamic notifSettings,
    required HollowTheme hollow,
  }) {
    final isSelected = folder.serverIds.contains(selectedServerId);
    final isRightPaneServer = splitState.isSplit &&
        folder.serverIds.contains(splitState.rightPane?.serverId);

    int folderUnreads = 0;
    for (final sid in folder.serverIds) {
      if (!notifSettings.isServerMuted(sid)) {
        folderUnreads +=
            ref.watch(unreadProvider.notifier).serverUnreadCount(sid);
      }
    }

    return DragTarget<_StripDragData>(
      onWillAcceptWithDetails: (details) {
        // Accept servers being added to this folder
        return details.data.serverId != null &&
            !folder.serverIds.contains(details.data.serverId);
      },
      onAcceptWithDetails: (details) {
        if (details.data.serverId != null) {
          ref.read(serverStripLayoutProvider.notifier)
              .addToFolder(folder.id, details.data.serverId!);
        }
      },
      builder: (context, candidateData, rejectedData) {
        final isDropTarget = candidateData.isNotEmpty;
        return LongPressDraggable<_StripDragData>(
            data: _StripDragData(folderId: folder.id, sourceIndex: index),
            delay: const Duration(milliseconds: 300),
            onDragStarted: () => setState(() => _isDragging = true),
            onDragEnd: (_) => setState(() => _isDragging = false),
            onDraggableCanceled: (_, __) => setState(() => _isDragging = false),
          feedback: Material(
            color: Colors.transparent,
            child: AnimatedOpacity(
              opacity: 0.8,
              duration: Duration.zero,
              child: _BottomServerIcon(
                backgroundColor: hollow.elevated,
                child: ServerFolderIcon(folder: folder, size: 38),
              ),
            ),
          ),
          childWhenDragging: AnimatedOpacity(
            opacity: 0.3,
            duration: const Duration(milliseconds: 150),
            child: _BottomServerIcon(
              backgroundColor: hollow.elevated,
              child: ServerFolderIcon(folder: folder, size: 38),
            ),
          ),
          child: AnimatedScale(
            scale: isDropTarget ? 1.08 : 1.0,
            duration: const Duration(milliseconds: 150),
            child: GestureDetector(
              onSecondaryTapUp: (_) {
                showFolderRenameDialog(
                  context: context,
                  ref: ref,
                  folder: folder,
                );
              },
              child: _BottomServerIcon(
                isSelected: isSelected || isRightPaneServer,
                showBorder: false,
                unreadCount:
                    (isSelected || isRightPaneServer) ? 0 : folderUnreads,
                tooltip: _isDragging ? null : folder.name,
                backgroundColor: hollow.elevated,
                onTap: () {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  final pos = box.localToGlobal(Offset.zero);
                  showServerFolderPopup(
                    context: context,
                    ref: ref,
                    folder: folder,
                    anchor: Offset(pos.dx + box.size.width / 2, pos.dy),
                    isDock: true,
                    onServerSelected: (serverId) =>
                        _selectServer(ref, serverId),
                    onRenameRequested: () {
                      showFolderRenameDialog(
                        context: context,
                        ref: ref,
                        folder: folder,
                      );
                    },
                  );
                },
                child: ServerFolderIcon(folder: folder, size: 38),
              ),
            ),
          ),
        );
      },
    );
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

/// Drag data for server strip items.
class _StripDragData {
  final String? serverId;
  final String? folderId;
  final int sourceIndex;

  const _StripDragData({
    this.serverId,
    this.folderId,
    required this.sourceIndex,
  });
}

/// Server icon for the horizontal bottom bar.
/// Rounded square with bottom-edge selection indicator.
class _BottomServerIcon extends StatefulWidget {
  final Widget child;
  final Color backgroundColor;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool isSelected;
  final bool showBorder;
  final int unreadCount;

  const _BottomServerIcon({
    required this.child,
    required this.backgroundColor,
    this.onTap,
    this.tooltip,
    this.isSelected = false,
    this.showBorder = true,
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
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: effectiveBg,
                    borderRadius: BorderRadius.circular(radius),
                    border: (widget.isSelected && widget.showBorder)
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
/// Thin drop zone between items for reordering. Shows accent line when hovered.
class _ReorderGap extends StatelessWidget {
  final int index;
  final HollowTheme hollow;
  final void Function(_StripDragData data) onAccept;

  const _ReorderGap({
    required this.index,
    required this.hollow,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<_StripDragData>(
      onWillAcceptWithDetails: (details) {
        // Don't accept drop right next to the source (no-op reorder)
        final src = details.data.sourceIndex;
        return src != index && src != index - 1;
      },
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, candidateData, rejectedData) {
        final isActive = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: isActive ? 8 : HollowSpacing.xs,
          height: 38,
          margin: EdgeInsets.symmetric(horizontal: isActive ? 2 : 0),
          decoration: BoxDecoration(
            color: isActive ? hollow.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(2),
          ),
        );
      },
    );
  }
}

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
