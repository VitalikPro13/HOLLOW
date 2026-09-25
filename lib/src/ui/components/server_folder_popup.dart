import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/name_initials.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/theme/hollow_shadows.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_count_badge.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/server_avatar.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:hollow/src/ui/components/overlay_hosts.dart';

/// 2x2 mini-grid preview of the first 4 servers in a folder.
class ServerFolderIcon extends ConsumerWidget {
  final FolderStripItem folder;
  final double size;

  /// Paints its own `elevated` square; false when the host tile owns the fill
  /// and its hover step.
  final bool filled;

  const ServerFolderIcon({
    super.key,
    required this.folder,
    required this.size,
    this.filled = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final servers = ref.watch(serverListProvider);
    final avatars = ref.watch(serverAvatarProvider);
    final previews = folder.serverIds.take(4).toList();

    // The grid adapts to the space actually available, which a parent border
    // eats into.
    return LayoutBuilder(builder: (context, constraints) {
      final actualSize = constraints.biggest.shortestSide > 0
          ? constraints.biggest.shortestSide
          : size;
      const gap = HollowSpacing.xxs;
      final cellSize = (actualSize - gap * 4) / 2;

      Widget cell(int i) {
        if (i >= previews.length) return SizedBox.square(dimension: cellSize);
        final sid = previews[i];
        final avatar = avatars[sid];
        final name = servers[sid]?.name ?? '';
        return ClipRRect(
          borderRadius: BorderRadius.circular(hollow.radiusXs),
          child: SizedBox.square(
            dimension: cellSize,
            child: avatar != null
                ? Image.memory(avatar, fit: BoxFit.cover)
                : Container(
                    color: colorFromId(sid),
                    alignment: Alignment.center,
                    child: Text(
                      initialsFromName(name.isNotEmpty ? name : sid),
                      style: HollowTypography.micro.copyWith(
                        color: Colors.white, // design-ignore: initials on an identity colour, as ServerAvatar
                        fontWeight: FontWeight.w600,
                        height: 1,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                    ),
                  ),
          ),
        );
      }

      return Container(
        width: actualSize,
        height: actualSize,
        color: filled ? hollow.elevated : null,
        padding: const EdgeInsets.all(gap),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [cell(0), const SizedBox(width: gap), cell(1)],
            ),
            const SizedBox(height: gap),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [cell(2), const SizedBox(width: gap), cell(3)],
            ),
          ],
        ),
      );
    });
  }
}

/// Show a folder popup overlay near the anchor.
void showServerFolderPopup({
  required BuildContext context,
  required WidgetRef ref,
  required FolderStripItem folder,
  required Offset anchor,
  required bool isDock,
  required void Function(String serverId) onServerSelected,
  VoidCallback? onRenameRequested,
}) {
  final overlay = Overlay.of(context);
  late final OverlayEntry entry;
  var removed = false;
  void close() {
    if (removed) return;
    removed = true;
    OverlayHosts.unregister(entry);
    entry.remove();
    entry.dispose();
  }

  entry = OverlayEntry(
    builder: (context) => _FolderPopupOverlay(
      folder: folder,
      anchor: anchor,
      isDock: isDock,
      onServerSelected: (serverId) {
        close();
        onServerSelected(serverId);
      },
      onDismiss: close,
      onRenameRequested: () {
        close();
        onRenameRequested?.call();
      },
    ),
  );
  overlay.insert(entry);
  OverlayHosts.register(entry, close);
}

class _FolderPopupOverlay extends ConsumerStatefulWidget {
  final FolderStripItem folder;
  final Offset anchor;
  final bool isDock;
  final void Function(String serverId) onServerSelected;
  final VoidCallback onDismiss;
  final VoidCallback onRenameRequested;

  const _FolderPopupOverlay({
    required this.folder,
    required this.anchor,
    required this.isDock,
    required this.onServerSelected,
    required this.onDismiss,
    required this.onRenameRequested,
  });

  @override
  ConsumerState<_FolderPopupOverlay> createState() =>
      _FolderPopupOverlayState();
}

class _FolderPopupOverlayState extends ConsumerState<_FolderPopupOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnim;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.fast,
    );
    final curve = CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.enter,
      reverseCurve: HollowCurves.exit,
    );
    _scaleAnim = Tween<double>(begin: HollowMotion.popoverScale, end: 1.0)
        .animate(curve);
    _fadeAnim = curve;
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    if (_controller.status == AnimationStatus.reverse) return;
    _controller.reverseDuration = HollowDurations.exit;
    _controller.reverse().then((_) => widget.onDismiss());
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final layout = ref.watch(serverStripLayoutProvider);
    final servers = ref.watch(serverListProvider);
    final notifSettings = ref.watch(notificationSettingsProvider);

    final currentFolder = layout
        .whereType<FolderStripItem>()
        .where((f) => f.id == widget.folder.id)
        .firstOrNull;

    if (currentFolder == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onDismiss());
      return const SizedBox.shrink();
    }

    const iconSize = 38.0;
    const columns = 5;
    const iconSpacing = 6.0;
    const itemWidth = iconSize + 8; // icon + horizontal padding
    const cardPadding = HollowSpacing.md;
    final cardWidth =
        (itemWidth * columns) + (iconSpacing * (columns - 1)) + cardPadding * 2;

    final screenSize = MediaQuery.of(context).size;

    double left = widget.anchor.dx - cardWidth / 2;
    if (left < 8) left = 8;
    if (left + cardWidth > screenSize.width - 8) {
      left = screenSize.width - cardWidth - 8;
    }

    double? top;
    double? bottom;
    if (widget.isDock) {
      bottom = screenSize.height - widget.anchor.dy + 8;
      if (bottom < 8) bottom = 8;
    } else {
      top = widget.anchor.dy;
      if (top + 200 > screenSize.height - 8) {
        top = screenSize.height - 208;
      }
      if (top < 8) top = 8;
    }

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: _dismiss,
            behavior: HitTestBehavior.opaque,
            child: const ColoredBox(color: Colors.transparent),
          ),
        ),

        Positioned(
          left: left,
          top: top,
          bottom: bottom,
          child: Focus(
            autofocus: true,
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                _dismiss();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: ScaleTransition(
              scale: _scaleAnim,
              alignment: widget.isDock
                  ? Alignment.bottomCenter
                  : Alignment.centerLeft,
              child: FadeTransition(
                opacity: _fadeAnim,
                child: Material(
                  type: MaterialType.transparency,
                  child: Container(
                    width: cardWidth,
                    decoration: BoxDecoration(
                      color: hollow.overlay,
                      borderRadius:
                          BorderRadius.circular(hollow.radiusLg),
                      border: Border.all(color: hollow.border),
                      boxShadow: HollowShadows.float,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            cardPadding,
                            HollowSpacing.xs,
                            HollowSpacing.xs,
                            HollowSpacing.xs,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  currentFolder.name,
                                  style: HollowTypography.label.copyWith(
                                    color: hollow.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              HollowIconButton(
                                icon: LucideIcons.pencil,
                                label: 'Rename folder',
                                onPressed: widget.onRenameRequested,
                              ),
                            ],
                          ),
                        ),
                        const HollowDivider(),

                        Padding(
                          padding: const EdgeInsets.all(cardPadding),
                          child: Wrap(
                            spacing: iconSpacing,
                            runSpacing: iconSpacing + 4,
                            children: [
                              for (final sid
                                  in currentFolder.serverIds) ...[
                                _FolderServerItem(
                                  serverId: sid,
                                  name: servers[sid]?.name ?? '',
                                  iconSize: iconSize,
                                  unreadCount:
                                      notifSettings.isServerMuted(sid)
                                          ? 0
                                          : ref
                                              .watch(unreadProvider
                                                  .notifier)
                                              .serverUnreadCount(sid),
                                  onTap: () =>
                                      widget.onServerSelected(sid),
                                  onRemove: currentFolder.serverIds.length > 1
                                      ? () {
                                          final layoutItems = ref.read(serverStripLayoutProvider);
                                          final folderIdx = layoutItems.indexWhere(
                                              (e) => e is FolderStripItem && e.id == currentFolder.id);
                                          ref.read(serverStripLayoutProvider.notifier)
                                              .removeFromFolder(currentFolder.id, sid, folderIdx + 1);
                                        }
                                      : null,
                                  hollow: hollow,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One server in the folder: its icon, name and unread count. Taking it out
/// of the folder is on hover only, so no X rests on every server.
class _FolderServerItem extends StatefulWidget {
  final String serverId;
  final String name;
  final double iconSize;
  final int unreadCount;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final HollowTheme hollow;

  const _FolderServerItem({
    required this.serverId,
    required this.name,
    required this.iconSize,
    required this.unreadCount,
    required this.onTap,
    this.onRemove,
    required this.hollow,
  });

  @override
  State<_FolderServerItem> createState() => _FolderServerItemState();
}

class _FolderServerItemState extends State<_FolderServerItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final hollow = widget.hollow;
    final name = widget.name;
    final iconSize = widget.iconSize;
    final showRemove = widget.onRemove != null && _hovered;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: HollowPressable(
        onTap: widget.onTap,
        subtle: true,
        semanticLabel: name.isNotEmpty ? name : 'Server',
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        padding: const EdgeInsets.all(HollowSpacing.xs),
        child: SizedBox(
          width: iconSize + HollowSpacing.sm,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  ServerAvatar(
                    serverId: widget.serverId,
                    name: name.isNotEmpty ? name : widget.serverId,
                    size: iconSize,
                  ),
                  if (widget.unreadCount > 0)
                    Positioned(
                      top: -HollowSpacing.xs,
                      right: -HollowSpacing.xs,
                      child: HollowCountBadge(
                        count: widget.unreadCount,
                        ring: hollow.overlay,
                      ),
                    ),
                  if (widget.onRemove != null)
                    Positioned(
                      top: -HollowSpacing.sm,
                      left: -HollowSpacing.sm,
                      child: IgnorePointer(
                        ignoring: !showRemove,
                        child: AnimatedOpacity(
                          opacity: showRemove ? 1 : 0,
                          duration: HollowDurations.fast,
                          child: HollowPressable(
                            onTap: widget.onRemove,
                            subtle: true,
                            padding: EdgeInsets.zero,
                            semanticLabel: 'Take ${name.isNotEmpty ? name : 'this server'} out of the folder',
                            child: Container(
                              width: HollowSpacing.lg + HollowSpacing.xs,
                              height: HollowSpacing.lg + HollowSpacing.xs,
                              decoration: BoxDecoration(
                                color: hollow.overlay,
                                shape: BoxShape.circle,
                                border: Border.all(color: hollow.border),
                              ),
                              child: Icon(
                                LucideIcons.x,
                                size: 14,
                                color: hollow.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: HollowSpacing.xxs),
              Text(
                name.isNotEmpty ? name : 'Server',
                style: HollowTypography.micro.copyWith(
                  color: hollow.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Renames [folder]: the shared name prompt, 32 characters at most.
void showFolderRenameDialog({
  required BuildContext context,
  required WidgetRef ref,
  required FolderStripItem folder,
}) {
  // The container, not [ref]: a menu's ref dies with the menu.
  final layout = ProviderScope.containerOf(context, listen: false)
      .read(serverStripLayoutProvider.notifier);
  promptForName(
    context: context,
    title: 'Rename folder',
    hintText: 'Folder name',
    initial: folder.name,
    maxLength: 32,
    confirmLabel: 'Rename',
    onSubmit: (name) => layout.renameFolder(folder.id, name),
  );
}
