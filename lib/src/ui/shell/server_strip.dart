import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/ui/components/server_folder_popup.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/dialogs/create_server_dialog.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Vertical server icon strip (72px wide) — like Discord's left column.
///
/// Shows the Hollow home icon, server icons from [serverListProvider],
/// and an "add server" button at the bottom.
class ServerStrip extends ConsumerStatefulWidget {
  const ServerStrip({super.key});

  @override
  ConsumerState<ServerStrip> createState() => _ServerStripState();
}

class _ServerStripState extends ConsumerState<ServerStrip> {
  /// Tracks server IDs that existed on first build — these skip the
  /// entrance animation so the strip doesn't bounce on app startup.
  Set<String>? _initialServerIds;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final selectedServerId = ref.watch(selectedServerProvider);

    _initialServerIds ??= ref.read(serverStripLayoutProvider.notifier).allServerIds();

    final stripLayout = ref.watch(serverStripLayoutProvider);

    final unreadState = ref.watch(unreadProvider);

    // Home button — show unread count if any unmuted DM has unreads.
    final notifSettings = ref.watch(notificationSettingsProvider.notifier);
    int dmUnreadTotal = 0;
    for (final entry in unreadState.dmUnreadCounts.entries) {
      if (notifSettings.isDmEnabled(entry.key)) {
        dmUnreadTotal += entry.value;
      }
    }
    Widget homeIcon = _ServerIconWithIndicator(
      isSelected: selectedServerId == null,
      unreadCount: selectedServerId != null ? dmUnreadTotal : 0,
      child: _ServerIcon(
        isSelected: selectedServerId == null,
        backgroundColor: hollow.accent,
        onTap: () {
          ref.read(selectedServerProvider.notifier).state = null;
          ref.read(channelListProvider.notifier).clear();
          ref.read(selectedChannelProvider.notifier).state = null;
          ref.read(serverSettingsOpenProvider.notifier).state = false;
        },
        child: Text(
          'H',
          style: TextStyle(
            color: hollow.textOnAccent,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );

    // Short divider
    Widget divider = Container(
      width: 32,
      height: 2,
      decoration: BoxDecoration(
        color: hollow.border,
        borderRadius: BorderRadius.circular(1),
      ),
    );

    // Add server button
    Widget addButton = Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.md),
      child: _ServerIcon(
        backgroundColor: hollow.elevated,
        tooltip: 'Create a server',
        onTap: () => showCreateServerDialog(context),
        child: Icon(
          LucideIcons.plus,
          color: hollow.accent,
          size: 24,
        ),
      ),
    );

    return Container(
      width: 72,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            hollow.opaqueBackground,
            Color.lerp(hollow.opaqueBackground, hollow.accent, 0.08)!,
          ],
        ),
        border: Border(
          right: BorderSide(color: hollow.border),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: HollowSpacing.md),
          homeIcon,
          const SizedBox(height: HollowSpacing.sm),
          divider,
          const SizedBox(height: HollowSpacing.sm),

          // Server icon list
          Expanded(
            child: ListView.builder(
              // Items interleaved with reorder gaps: gap0, item0, gap1, item1, ..., gapN
              itemCount: stripLayout.length * 2 + 1,
              padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
              itemBuilder: (context, rawIndex) {
                // Even indices = gap, odd indices = item
                if (rawIndex.isEven) {
                  final gapIndex = rawIndex ~/ 2;
                  return _VerticalReorderGap(
                    index: gapIndex,
                    hollow: hollow,
                    onAccept: (data) {
                      ref.read(serverStripLayoutProvider.notifier)
                          .reorder(data.sourceIndex, gapIndex);
                    },
                  );
                }

                final index = rawIndex ~/ 2;
                final item = stripLayout[index];

                Widget icon = switch (item) {
                  ServerStripItem(:final serverId) => _buildServerIcon(
                      index: index,
                      serverId: serverId,
                      selectedServerId: selectedServerId,
                      hollow: hollow,
                    ),
                  FolderStripItem() => _buildFolderIcon(
                      index: index,
                      folder: item,
                      selectedServerId: selectedServerId,
                      hollow: hollow,
                    ),
                };

                // Animate newly created servers
                final isNew = switch (item) {
                  ServerStripItem(:final serverId) =>
                    !_initialServerIds!.contains(serverId),
                  FolderStripItem() => false,
                };
                if (isNew) {
                  icon = _ScaleBounceEntry(
                    key: ValueKey('bounce-${switch (item) {
                      ServerStripItem(:final serverId) => serverId,
                      FolderStripItem(:final id) => id,
                    }}'),
                    child: icon,
                  );
                }

                return Padding(
                  padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
                  child: icon,
                );
              },
            ),
          ),

          addButton,
        ],
      ),
    );
  }

  Widget _buildServerIcon({
    required int index,
    required String serverId,
    required String? selectedServerId,
    required HollowTheme hollow,
  }) {
    final server = ref.watch(serverListProvider)[serverId];
    final isSelected = serverId == selectedServerId;
    final isServerMuted =
        ref.watch(notificationSettingsProvider.notifier).isServerMuted(serverId);
    final serverUnreads = isServerMuted
        ? 0
        : ref.watch(unreadProvider.notifier).serverUnreadCount(serverId);
    final name = server?.name ?? '';

    Widget serverIconChild = Builder(builder: (_) {
      final serverAvatar = ref.watch(serverAvatarProvider)[serverId];
      if (serverAvatar != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(serverAvatar,
              width: 44, height: 44, fit: BoxFit.cover),
        );
      }
      return Text(
        _initialsFromName(name.isNotEmpty ? name : serverId),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      );
    });

    return DragTarget<_StripDragData>(
      onWillAcceptWithDetails: (details) {
        return details.data.serverId != null && details.data.serverId != serverId;
      },
      onAcceptWithDetails: (details) {
        if (details.data.serverId != null) {
          ref.read(serverStripLayoutProvider.notifier)
              .createFolder(details.data.serverId!, serverId);
        }
      },
      builder: (context, candidateData, rejectedData) {
        final isMergeTarget = candidateData.isNotEmpty;
        return LongPressDraggable<_StripDragData>(
          data: _StripDragData(serverId: serverId, sourceIndex: index),
          delay: const Duration(milliseconds: 300),
          feedback: Material(
            color: Colors.transparent,
            child: AnimatedOpacity(
              opacity: 0.8,
              duration: Duration.zero,
              child: _ServerIcon(
                backgroundColor: _colorFromId(serverId),
                child: serverIconChild,
              ),
            ),
          ),
          childWhenDragging: AnimatedOpacity(
            opacity: 0.3,
            duration: const Duration(milliseconds: 150),
            child: _ServerIconWithIndicator(
              isSelected: false,
              child: _ServerIcon(
                backgroundColor: _colorFromId(serverId),
                child: serverIconChild,
              ),
            ),
          ),
          child: AnimatedScale(
            scale: isMergeTarget ? 1.08 : 1.0,
            duration: const Duration(milliseconds: 150),
            child: _ServerIconWithIndicator(
              isSelected: isSelected,
              unreadCount: serverUnreads,
              child: _ServerIcon(
                isSelected: isSelected,
                backgroundColor: _colorFromId(serverId),
                tooltip: name,
                onTap: () => _selectServer(serverId),
                child: serverIconChild,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFolderIcon({
    required int index,
    required FolderStripItem folder,
    required String? selectedServerId,
    required HollowTheme hollow,
  }) {
    final isSelected = folder.serverIds.contains(selectedServerId);
    int folderUnreads = 0;
    final notifS = ref.watch(notificationSettingsProvider.notifier);
    for (final sid in folder.serverIds) {
      if (!notifS.isServerMuted(sid)) {
        folderUnreads +=
            ref.watch(unreadProvider.notifier).serverUnreadCount(sid);
      }
    }

    return DragTarget<_StripDragData>(
      onWillAcceptWithDetails: (details) {
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
          feedback: Material(
            color: Colors.transparent,
            child: AnimatedOpacity(
              opacity: 0.8,
              duration: Duration.zero,
              child: _ServerIcon(
                backgroundColor: hollow.elevated,
                child: ServerFolderIcon(folder: folder, size: 48),
              ),
            ),
          ),
          childWhenDragging: AnimatedOpacity(
            opacity: 0.3,
            duration: const Duration(milliseconds: 150),
            child: _ServerIconWithIndicator(
              isSelected: false,
              child: _ServerIcon(
                backgroundColor: hollow.elevated,
                child: ServerFolderIcon(folder: folder, size: 48),
              ),
            ),
          ),
          child: AnimatedScale(
            scale: isDropTarget ? 1.08 : 1.0,
            duration: const Duration(milliseconds: 150),
            child: _ServerIconWithIndicator(
              isSelected: isSelected,
              unreadCount: isSelected ? 0 : folderUnreads,
              child: GestureDetector(
                onSecondaryTapUp: (_) {
                  showFolderRenameDialog(
                    context: context,
                    ref: ref,
                    folder: folder,
                  );
                },
                child: _ServerIcon(
                  isSelected: isSelected,
                  showBorder: false,
                  backgroundColor: hollow.elevated,
                  tooltip: folder.name,
                  onTap: () {
                    final box = context.findRenderObject() as RenderBox?;
                    if (box == null) return;
                    final pos = box.localToGlobal(Offset.zero);
                    showServerFolderPopup(
                      context: context,
                      ref: ref,
                      folder: folder,
                      anchor: Offset(pos.dx + 72, pos.dy + box.size.height / 2),
                      isDock: false,
                      onServerSelected: (serverId) => _selectServer(serverId),
                      onRenameRequested: () {
                        showFolderRenameDialog(
                          context: context,
                          ref: ref,
                          folder: folder,
                        );
                      },
                    );
                  },
                  child: ServerFolderIcon(folder: folder, size: 48),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _selectServer(String serverId) async {
    ref.read(selectedServerProvider.notifier).state = serverId;
    ref.read(selectedPeerProvider.notifier).state = null;
    ref.read(serverSettingsOpenProvider.notifier).state = false;

    final lastChannels = ref.read(lastChannelPerServerProvider);
    final lastChannel = lastChannels[serverId];

    await ref.read(channelListProvider.notifier).loadForServer(serverId);
    ref.read(channelLayoutProvider.notifier).loadForServer(serverId);

    final channels = ref.read(channelListProvider);
    String? channelToSelect;
    if (lastChannel != null && channels.containsKey(lastChannel)) {
      channelToSelect = lastChannel;
    } else if (channels.isNotEmpty) {
      channelToSelect = channels.keys.first;
    }
    ref.read(selectedChannelProvider.notifier).state = channelToSelect;
    if (channelToSelect != null) {
      final map = Map<String, String>.from(
          ref.read(lastChannelPerServerProvider));
      map[serverId] = channelToSelect;
      ref.read(lastChannelPerServerProvider.notifier).state = map;
    }
  }
}

/// Thin vertical drop zone between items for reordering.
class _VerticalReorderGap extends StatelessWidget {
  final int index;
  final HollowTheme hollow;
  final void Function(_StripDragData data) onAccept;

  const _VerticalReorderGap({
    required this.index,
    required this.hollow,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<_StripDragData>(
      onWillAcceptWithDetails: (details) {
        final src = details.data.sourceIndex;
        return src != index && src != index - 1;
      },
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, candidateData, rejectedData) {
        final isActive = candidateData.isNotEmpty;
        return Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: 36,
            height: isActive ? 4 : HollowSpacing.xs,
            margin: EdgeInsets.symmetric(vertical: isActive ? 2 : 0),
            decoration: BoxDecoration(
              color: isActive ? hollow.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
      },
    );
  }
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

/// Deterministic color from an ID string (same logic as HollowAvatar).
Color _colorFromId(String id) {
  final hash = id.hashCode;
  final hue = (hash % 360).abs().toDouble();
  return HSLColor.fromAHSL(1.0, hue, 0.5, 0.45).toColor();
}

/// Extract 1–2 letter initials from a server name.
String _initialsFromName(String name) {
  final words = name.trim().split(RegExp(r'\s+'));
  if (words.length >= 2) {
    return '${words[0][0]}${words[1][0]}'.toUpperCase();
  }
  return name.substring(0, name.length.clamp(0, 2)).toUpperCase();
}

/// Wraps a server icon with a Discord-style left-edge selection indicator
/// and an optional unread count badge (bottom-right).
class _ServerIconWithIndicator extends StatefulWidget {
  final bool isSelected;
  final int unreadCount;
  final Widget child;

  const _ServerIconWithIndicator({
    required this.isSelected,
    required this.child,
    this.unreadCount = 0,
  });

  @override
  State<_ServerIconWithIndicator> createState() =>
      _ServerIconWithIndicatorState();
}

class _ServerIconWithIndicatorState
    extends State<_ServerIconWithIndicator> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    // Indicator height: selected=36, hovering=20, default=0.
    final indicatorHeight =
        widget.isSelected ? 36.0 : (_hovering ? 20.0 : 0.0);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: SizedBox(
        width: 72,
        height: 48,
        child: Row(
          children: [
            // Left-edge pill indicator
            AnimatedContainer(
              duration: HollowDurations.fast,
              curve: HollowCurves.enter,
              width: 3,
              height: indicatorHeight,
              decoration: BoxDecoration(
                color: hollow.textPrimary,
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
            ),
            const Spacer(),
            // Stack for unread badge overlay.
            Stack(
              clipBehavior: Clip.none,
              children: [
                widget.child,
                if (widget.unreadCount > 0)
                  Positioned(
                    right: -6,
                    bottom: -4,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 16),
                      height: 16,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: hollow.error,
                        borderRadius: BorderRadius.circular(8),
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
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

/// A single icon in the server strip.
/// Rounded square by default, animates to pill shape on hover or when selected.
class _ServerIcon extends StatefulWidget {
  final Widget child;
  final Color backgroundColor;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool isSelected;
  final bool showBorder;

  const _ServerIcon({
    required this.child,
    required this.backgroundColor,
    this.onTap,
    this.tooltip,
    this.isSelected = false,
    this.showBorder = true,
  });

  @override
  State<_ServerIcon> createState() => _ServerIconState();
}

class _ServerIconState extends State<_ServerIcon> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    // Stay pill-shaped when selected or hovering.
    final radius =
        (_hovering || widget.isSelected) ? 16.0 : hollow.radiusLg;

    // Hover brightens the background slightly.
    final effectiveBg = _hovering && !widget.isSelected
        ? Color.lerp(widget.backgroundColor, hollow.accent, 0.15)!
        : widget.backgroundColor;

    Widget icon = MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          width: 48,
          height: 48,
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
      ),
    );

    if (widget.tooltip != null) {
      icon = HollowTooltip(message: widget.tooltip!, child: icon);
    }

    return icon;
  }
}

/// Plays a scale-bounce animation when first built.
/// Used for newly created server icons.
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
