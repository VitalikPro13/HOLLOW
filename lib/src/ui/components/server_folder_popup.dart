import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:lucide_icons/lucide_icons.dart';

// ── Folder Icon (2x2 mini-grid) ─────────────────────────────────

/// 2x2 mini-grid preview of the first 4 servers in a folder.
class ServerFolderIcon extends ConsumerWidget {
  final FolderStripItem folder;
  final double size;

  const ServerFolderIcon({
    super.key,
    required this.folder,
    required this.size,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final servers = ref.watch(serverListProvider);
    final avatars = ref.watch(serverAvatarProvider);

    final cellSize = (size - 6) / 2; // 2 cells + 2px gap each side
    final previews = folder.serverIds.take(4).toList();

    Widget cell(int i) {
      if (i < previews.length) {
        final sid = previews[i];
        final avatar = avatars[sid];
        final server = servers[sid];
        final name = server?.name ?? '';

        return ClipRRect(
          borderRadius: BorderRadius.circular(cellSize * 0.2),
          child: SizedBox(
            width: cellSize,
            height: cellSize,
            child: avatar != null
                ? Image.memory(avatar,
                    width: cellSize,
                    height: cellSize,
                    fit: BoxFit.cover)
                : Container(
                    color: colorFromId(sid),
                    alignment: Alignment.center,
                    child: Text(
                      _initialsFromName(name.isNotEmpty ? name : sid),
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: cellSize * 0.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
          ),
        );
      }
      return Container(
        width: cellSize,
        height: cellSize,
        decoration: BoxDecoration(
          color: hollow.border.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(cellSize * 0.2),
        ),
      );
    }

    // Use LayoutBuilder so the grid adapts to the actual available space
    // (important when parent has a border that eats into the size)
    return LayoutBuilder(builder: (context, constraints) {
      final actualSize = constraints.biggest.shortestSide > 0
          ? constraints.biggest.shortestSide
          : size;
      final actualCellSize = (actualSize - 8) / 2;

      Widget adaptiveCell(int i) {
        if (i < previews.length) {
          final sid = previews[i];
          final avatar = avatars[sid];
          final server = servers[sid];
          final cName = server?.name ?? '';
          return ClipRRect(
            borderRadius: BorderRadius.circular(actualCellSize * 0.2),
            child: SizedBox(
              width: actualCellSize,
              height: actualCellSize,
              child: avatar != null
                  ? Image.memory(avatar, fit: BoxFit.cover)
                  : Container(
                      color: colorFromId(sid),
                      alignment: Alignment.center,
                      child: Text(
                        _initialsFromName(cName.isNotEmpty ? cName : sid),
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: actualCellSize * 0.38,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
            ),
          );
        }
        return Container(
          width: actualCellSize,
          height: actualCellSize,
          decoration: BoxDecoration(
            color: hollow.border.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(actualCellSize * 0.2),
          ),
        );
      }

      return Container(
        width: actualSize,
        height: actualSize,
        color: hollow.elevated,
        padding: const EdgeInsets.all(2),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                adaptiveCell(0),
                const SizedBox(width: 2),
                adaptiveCell(1),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                adaptiveCell(2),
                const SizedBox(width: 2),
                adaptiveCell(3),
              ],
            ),
          ],
        ),
      );
    });
  }
}

// ── Folder Popup ────────────────────────────────────────────────

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

  entry = OverlayEntry(
    builder: (context) => _FolderPopupOverlay(
      folder: folder,
      anchor: anchor,
      isDock: isDock,
      onServerSelected: (serverId) {
        entry.remove();
        entry.dispose();
        onServerSelected(serverId);
      },
      onDismiss: () {
        entry.remove();
        entry.dispose();
      },
      onRenameRequested: () {
        entry.remove();
        entry.dispose();
        onRenameRequested?.call();
      },
    ),
  );
  overlay.insert(entry);
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
      duration: HollowDurations.animationsDisabled ? Duration.zero : const Duration(milliseconds: 180),
    );
    _scaleAnim = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    _controller.reverse().then((_) => widget.onDismiss());
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final layout = ref.watch(serverStripLayoutProvider);
    final servers = ref.watch(serverListProvider);
    final avatars = ref.watch(serverAvatarProvider);
    final notifSettings = ref.watch(notificationSettingsProvider);

    // Find the current folder state (may have changed)
    final currentFolder = layout
        .whereType<FolderStripItem>()
        .where((f) => f.id == widget.folder.id)
        .firstOrNull;

    // Auto-dismiss if folder was dissolved
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

    // Position
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
        // Dismiss barrier
        Positioned.fill(
          child: GestureDetector(
            onTap: _dismiss,
            behavior: HitTestBehavior.opaque,
            child: const ColoredBox(color: Colors.transparent),
          ),
        ),

        // Popup card
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
                  color: Colors.transparent,
                  child: Container(
                    width: cardWidth,
                    decoration: BoxDecoration(
                      color: hollow.surface,
                      borderRadius:
                          BorderRadius.circular(hollow.radiusLg),
                      border: Border.all(color: hollow.border),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Header
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            cardPadding,
                            HollowSpacing.sm + 2,
                            HollowSpacing.sm,
                            HollowSpacing.xs,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  currentFolder.name,
                                  style: HollowTypography.body.copyWith(
                                    color: hollow.textPrimary,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              HollowPressable(
                                onTap: () {
                                  widget.onRenameRequested();
                                },
                                subtle: true,
                                hoverColor: hollow.border.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                                padding: const EdgeInsets.all(6),
                                child: Icon(
                                  LucideIcons.pencil,
                                  size: 12,
                                  color: hollow.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(height: 1, color: hollow.border),

                        // Server grid
                        Padding(
                          padding: EdgeInsets.all(cardPadding),
                          child: Wrap(
                            spacing: iconSpacing,
                            runSpacing: iconSpacing + 4,
                            children: [
                              for (final sid
                                  in currentFolder.serverIds) ...[
                                _FolderServerItem(
                                  serverId: sid,
                                  server: servers[sid],
                                  avatar: avatars[sid],
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
                                          // Find the folder's index in the layout to insert after it
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

// ── Server item inside folder popup ─────────────────────────────

class _FolderServerItem extends StatelessWidget {
  final String serverId;
  final dynamic server;
  final Uint8List? avatar;
  final double iconSize;
  final int unreadCount;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final HollowTheme hollow;

  const _FolderServerItem({
    required this.serverId,
    required this.server,
    this.avatar,
    required this.iconSize,
    required this.unreadCount,
    required this.onTap,
    this.onRemove,
    required this.hollow,
  });

  @override
  Widget build(BuildContext context) {
    final name = server?.name ?? '';
    final bgColor = colorFromId(serverId);

    return HollowPressable(
      onTap: onTap,
      subtle: true,
      hoverColor: hollow.border.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: SizedBox(
        width: iconSize + 8,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icon with unread badge + remove button
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: iconSize,
                  height: iconSize,
                  decoration: BoxDecoration(
                    color: bgColor,
                    borderRadius:
                        BorderRadius.circular(hollow.radiusMd),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: avatar != null
                      ? Image.memory(avatar!,
                          width: iconSize,
                          height: iconSize,
                          fit: BoxFit.cover)
                      : Center(
                          child: Text(
                            _initialsFromName(
                                name.isNotEmpty ? name : serverId),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                ),
                if (unreadCount > 0)
                  Positioned(
                    top: -4,
                    right: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: hollow.error,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        unreadCount > 99 ? '99+' : '$unreadCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                // Remove from folder button
                if (onRemove != null)
                  Positioned(
                    top: -5,
                    left: -5,
                    child: HollowPressable(
                      onTap: onRemove,
                      subtle: true,
                      padding: EdgeInsets.zero,
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: hollow.surface,
                          shape: BoxShape.circle,
                          border: Border.all(color: hollow.border, width: 1),
                        ),
                        child: Icon(
                          LucideIcons.x,
                          size: 9,
                          color: hollow.textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 3),
            // Name
            Text(
              name.isNotEmpty ? name : 'Server',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 9,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Rename Dialog ───────────────────────────────────────────────

/// Show a dialog to rename a folder.
void showFolderRenameDialog({
  required BuildContext context,
  required WidgetRef ref,
  required FolderStripItem folder,
}) {
  showHollowDialog(
    context: context,
    builder: (ctx) => _FolderRenameDialog(folder: folder),
  );
}

class _FolderRenameDialog extends ConsumerStatefulWidget {
  final FolderStripItem folder;
  const _FolderRenameDialog({required this.folder});

  @override
  ConsumerState<_FolderRenameDialog> createState() =>
      _FolderRenameDialogState();
}

class _FolderRenameDialogState extends ConsumerState<_FolderRenameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.folder.name);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final name = _controller.text.trim();
    if (name.isNotEmpty) {
      ref
          .read(serverStripLayoutProvider.notifier)
          .renameFolder(widget.folder.id, name);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 280,
          padding: const EdgeInsets.all(HollowSpacing.xl),
          decoration: BoxDecoration(
            color: hollow.surface,
            borderRadius: BorderRadius.circular(hollow.radiusLg),
            border: Border.all(color: hollow.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Rename Folder',
                style: HollowTypography.subheading.copyWith(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: HollowSpacing.md),
              HollowTextField(
                controller: _controller,
                hintText: 'Folder name',
                maxLength: 32,
                autofocus: true,
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: HollowSpacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  HollowButton.ghost(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  HollowButton.filled(
                    onPressed: _save,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Shared Helpers ──────────────────────────────────────────────

String _initialsFromName(String name) {
  final words = name.trim().split(RegExp(r'\s+'));
  if (words.length >= 2) {
    return '${words[0][0]}${words[1][0]}'.toUpperCase();
  }
  return name.substring(0, name.length.clamp(0, 2)).toUpperCase();
}
