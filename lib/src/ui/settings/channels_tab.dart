import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:lucide_icons/lucide_icons.dart';

/// A layout item — either a category header or a channel.
sealed class LayoutItem {
  const LayoutItem();
}

class CategoryItem extends LayoutItem {
  final String name;
  const CategoryItem(this.name);
}

class ChannelItem extends LayoutItem {
  final String channelId;
  const ChannelItem(this.channelId);
}

class SeparatorItem extends LayoutItem {
  const SeparatorItem();
}

/// Channels tab — drag-and-drop layout editor with categories.
class ChannelsTab extends ConsumerStatefulWidget {
  final String serverId;

  const ChannelsTab({super.key, required this.serverId});

  @override
  ConsumerState<ChannelsTab> createState() => _ChannelsTabState();
}

class _ChannelsTabState extends ConsumerState<ChannelsTab> {
  List<LayoutItem> _layout = [];
  List<LayoutItem> _savedLayout = []; // What's in DB — for discard comparison.
  bool _loaded = false;

  /// Compare current layout against saved to determine if changes exist.
  bool get _dirty {
    if (_layout.length != _savedLayout.length) return true;
    for (int i = 0; i < _layout.length; i++) {
      final a = _layout[i];
      final b = _savedLayout[i];
      if (a.runtimeType != b.runtimeType) return true;
      if (a is CategoryItem && b is CategoryItem && a.name != b.name) return true;
      if (a is ChannelItem && b is ChannelItem && a.channelId != b.channelId) return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _loadLayout();
  }

  Future<void> _loadLayout() async {
    try {
      final json = await crdt_api.getChannelLayout(serverId: widget.serverId);
      final List<dynamic> items = jsonDecode(json);
      final layout = <LayoutItem>[];
      for (final item in items) {
        if (item['type'] == 'category') {
          layout.add(CategoryItem(item['name'] as String));
        } else if (item['type'] == 'channel') {
          layout.add(ChannelItem(item['channel_id'] as String));
        } else if (item['type'] == 'separator') {
          layout.add(const SeparatorItem());
        }
      }
      if (mounted) {
        // Compute effective layout (includes newly created channels)
        // and use it as both current and saved baseline.
        final channels = ref.read(channelListProvider);
        final effective = _effectiveLayoutFrom(layout, channels);
        setState(() { _layout = effective; _savedLayout = List.from(effective); _loaded = true; });
      }
    } catch (_) {
      if (mounted) {
        final channels = ref.read(channelListProvider);
        final effective = _effectiveLayoutFrom([], channels);
        setState(() { _layout = effective; _savedLayout = List.from(effective); _loaded = true; });
      }
    }
  }

  /// Like _effectiveLayout but takes an explicit base layout.
  List<LayoutItem> _effectiveLayoutFrom(List<LayoutItem> base, Map<String, ChannelInfo> channels) {
    final layout = List<LayoutItem>.from(base);
    final layoutChannelIds = layout
        .whereType<ChannelItem>()
        .map((c) => c.channelId)
        .toSet();
    final missing = channels.keys
        .where((id) => !layoutChannelIds.contains(id))
        .toList()
      ..sort((a, b) =>
          (channels[a]?.name ?? '').compareTo(channels[b]?.name ?? ''));
    for (final id in missing) {
      layout.add(ChannelItem(id));
    }
    layout.removeWhere((item) =>
        item is ChannelItem && !channels.containsKey(item.channelId));
    return layout;
  }

  /// Build the effective layout: current layout + any channels not yet in it.
  List<LayoutItem> _effectiveLayout(Map<String, ChannelInfo> channels) {
    return _effectiveLayoutFrom(_layout, channels);
  }

  void _save() {
    final jsonList = _layout.map((item) {
      if (item is CategoryItem) {
        return {'type': 'category', 'name': item.name};
      } else if (item is ChannelItem) {
        return {'type': 'channel', 'channel_id': item.channelId};
      } else if (item is SeparatorItem) {
        return {'type': 'separator'};
      }
    }).toList();

    crdt_api.updateChannelLayout(
      serverId: widget.serverId,
      layoutJson: jsonEncode(jsonList),
    );

    setState(() {
           _savedLayout = List.from(_layout);
    });
    HollowToast.show(
      context,
      'Channel layout saved',
      type: HollowToastType.success,
    );
  }

  void _addChannel() {
    final controller = TextEditingController();
    var isVoice = false;
    showHollowDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          void submit() {
            final name = controller.text.trim();
            if (name.isNotEmpty) {
              crdt_api.createChannel(
                serverId: widget.serverId,
                name: name,
                category: null,
                channelType: isVoice ? 'voice' : 'text',
              );
              setState(() {});
            }
            Navigator.pop(ctx);
          }

          return HollowDialog(
            title: 'New Channel',
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Channel type toggle
                Row(
                  children: [
                    _ChannelTypeChip(
                      icon: LucideIcons.hash,
                      label: 'Text',
                      isSelected: !isVoice,
                      onTap: () => setDialogState(() => isVoice = false),
                    ),
                    const SizedBox(width: HollowSpacing.sm),
                    _ChannelTypeChip(
                      icon: LucideIcons.volume2,
                      label: 'Voice',
                      isSelected: isVoice,
                      onTap: () => setDialogState(() => isVoice = true),
                    ),
                  ],
                ),
                const SizedBox(height: HollowSpacing.md),
                HollowTextField(
                  controller: controller,
                  hintText: 'Channel name',
                  autofocus: true,
                  maxLength: 32,
                  prefixIcon: Icon(isVoice ? LucideIcons.volume2 : LucideIcons.hash),
                  onSubmitted: (_) => submit(),
                ),
              ],
            ),
            actions: [
              HollowButton.ghost(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              HollowButton.filled(
                onPressed: submit,
                child: const Text('Create'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _addCategory() {
    final controller = TextEditingController();
    showHollowDialog(
      context: context,
      builder: (ctx) => HollowDialog(
        title: 'New Category',
        content: HollowTextField(
          controller: controller,
          hintText: 'Category name',
          autofocus: true,
          maxLength: 32,
          onSubmitted: (_) {
            final name = controller.text.trim();
            if (name.isNotEmpty) {
              setState(() {
                _layout.add(CategoryItem(name));
                             });
            }
            Navigator.pop(ctx);
          },
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                setState(() {
                  _layout.add(CategoryItem(name));
                                 });
              }
              Navigator.pop(ctx);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _renameCategory(int index, String currentName) {
    final controller = TextEditingController(text: currentName);
    showHollowDialog(
      context: context,
      builder: (ctx) => HollowDialog(
        title: 'Rename Category',
        content: HollowTextField(
          controller: controller,
          hintText: 'Category name',
          autofocus: true,
          maxLength: 32,
          onSubmitted: (_) {
            final name = controller.text.trim();
            if (name.isNotEmpty) {
              setState(() {
                _layout[index] = CategoryItem(name);
                             });
            }
            Navigator.pop(ctx);
          },
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                setState(() {
                  _layout[index] = CategoryItem(name);
                                 });
              }
              Navigator.pop(ctx);
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  void _removeCategory(int index) {
    setState(() {
      _layout.removeAt(index);
         });
  }

  void _renameChannel(String channelId, String currentName) {
    final controller = TextEditingController(text: currentName);
    showHollowDialog(
      context: context,
      builder: (ctx) => HollowDialog(
        title: 'Rename Channel',
        content: HollowTextField(
          controller: controller,
          hintText: 'Channel name',
          autofocus: true,
          onSubmitted: (_) {
            final newName = controller.text.trim();
            if (newName.isNotEmpty && newName != currentName) {
              crdt_api.renameChannel(
                serverId: widget.serverId,
                channelId: channelId,
                newName: newName,
              );
            }
            Navigator.pop(ctx);
          },
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: () {
              final newName = controller.text.trim();
              if (newName.isNotEmpty && newName != currentName) {
                crdt_api.renameChannel(
                  serverId: widget.serverId,
                  channelId: channelId,
                  newName: newName,
                );
              }
              Navigator.pop(ctx);
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  void _deleteChannel(String channelId, String name) {
    showHollowDialog(
      context: context,
      builder: (ctx) => HollowDialog(
        title: 'Delete Channel',
        content: Text(
          'Are you sure you want to delete #$name? This cannot be undone.',
          style: HollowTypography.body,
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          HollowButton.danger(
            onPressed: () {
              crdt_api.removeChannel(
                serverId: widget.serverId,
                channelId: channelId,
              );
              setState(() {
                _layout.removeWhere(
                    (i) => i is ChannelItem && i.channelId == channelId);
              });
              Navigator.pop(ctx);
              HollowToast.show(
                context,
                'Channel #$name deleted',
                type: HollowToastType.info,
              );
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final channels = ref.watch(channelListProvider);

    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    final effective = _effectiveLayout(channels);
    // Sync local state if effective differs (new channels added/removed externally).
    // Auto-save so sidebar updates immediately without requiring manual Save.
    if (effective.length != _layout.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _layout = effective;
            _savedLayout = List.from(effective);
          });
          // Auto-save the layout so sidebar reflects the change.
          final jsonList = effective.map((item) {
            if (item is CategoryItem) {
              return {'type': 'category', 'name': item.name};
            } else if (item is ChannelItem) {
              return {'type': 'channel', 'channel_id': item.channelId};
            } else if (item is SeparatorItem) {
              return {'type': 'separator'};
            }
          }).toList();
          crdt_api.updateChannelLayout(
            serverId: widget.serverId,
            layoutJson: jsonEncode(jsonList),
          );
        }
      });
    }

    return Column(
      children: [
        // Header row with action buttons
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HollowSpacing.lg, HollowSpacing.md, HollowSpacing.lg, HollowSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Drag to reorder channels and categories',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                  ),
                ),
              ),
              HollowButton.ghost(
                onPressed: () {
                  setState(() {
                    _layout.add(const SeparatorItem());
                                     });
                },
                compact: true,
                icon: Icon(LucideIcons.minus, size: 14),
                child: const Text('Break'),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.ghost(
                onPressed: _addCategory,
                compact: true,
                icon: Icon(LucideIcons.folderPlus, size: 14),
                child: const Text('Category'),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.ghost(
                onPressed: _addChannel,
                compact: true,
                icon: Icon(LucideIcons.plus, size: 14),
                child: const Text('Channel'),
              ),
            ],
          ),
        ),

        Divider(height: 1, color: hollow.border),

        // Drag-and-drop list
        Expanded(
          child: _layout.isEmpty
              ? Center(
                  child: Text(
                    'No channels yet. Create one to get started.',
                    style: HollowTypography.body
                        .copyWith(color: hollow.textSecondary),
                  ),
                )
              : ReorderableListView.builder(
                  padding: const EdgeInsets.all(HollowSpacing.md),
                  itemCount: _layout.length,
                  buildDefaultDragHandles: false,
                  proxyDecorator: (child, index, animation) {
                    return AnimatedBuilder(
                      animation: animation,
                      builder: (ctx, child) => Material(
                        color: Colors.transparent,
                        elevation: 4,
                        shadowColor: Colors.black26,
                        borderRadius:
                            BorderRadius.circular(hollow.radiusMd),
                        child: child,
                      ),
                      child: child,
                    );
                  },
                  onReorder: (oldIndex, newIndex) {
                    setState(() {
                      if (newIndex > oldIndex) newIndex--;
                      final item = _layout.removeAt(oldIndex);
                      _layout.insert(newIndex, item);
                                         });
                  },
                  itemBuilder: (context, index) {
                    final item = _layout[index];
                    // Check if this channel is under a category.
                    // A separator breaks the category scope.
                    bool isUnderCategory = false;
                    if (item is ChannelItem) {
                      for (int i = index - 1; i >= 0; i--) {
                        if (_layout[i] is SeparatorItem) break;
                        if (_layout[i] is CategoryItem) {
                          isUnderCategory = true;
                          break;
                        }
                      }
                    }
                    // Is this the last channel before next category, separator, or end?
                    bool isLastInCategory = false;
                    if (isUnderCategory) {
                      isLastInCategory = index == _layout.length - 1 ||
                          _layout[index + 1] is CategoryItem ||
                          _layout[index + 1] is SeparatorItem;
                    }

                    if (item is SeparatorItem) {
                      return _SeparatorRow(
                        key: ValueKey('sep-$index'),
                        index: index,
                        onDelete: () {
                          setState(() {
                            _layout.removeAt(index);
                                                     });
                        },
                      );
                    } else if (item is CategoryItem) {
                      return _CategoryRow(
                        key: ValueKey('cat-$index-${item.name}'),
                        index: index,
                        name: item.name,
                        onRename: () =>
                            _renameCategory(index, item.name),
                        onDelete: () => _removeCategory(index),
                      );
                    } else if (item is ChannelItem) {
                      final info = channels[item.channelId];
                      final name = info?.name ?? item.channelId;
                      return _ChannelRow(
                        key: ValueKey('ch-${item.channelId}'),
                        index: index,
                        name: name,
                        isVoice: info?.channelType == ChannelType.voice,
                        indented: isUnderCategory,
                        isLast: isLastInCategory,
                        onRename: () =>
                            _renameChannel(item.channelId, name),
                        onDelete: () =>
                            _deleteChannel(item.channelId, name),
                      );
                    }
                    return const SizedBox.shrink(key: ValueKey('unknown'));
                  },
                ),
        ),

        // Save / Cancel buttons
        if (_dirty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HollowSpacing.lg, HollowSpacing.sm, HollowSpacing.lg, HollowSpacing.lg,
            ),
            child: Row(
              children: [
                Expanded(
                  child: HollowButton.ghost(
                    onPressed: () {
                      // Reload from DB to get current state
                      // (channels created/deleted are CRDT ops, can't undo).
                      setState(() {
                        _loaded = false;
                      });
                      _loadLayout();
                    },
                    expand: true,
                    icon: Icon(LucideIcons.x, size: 16),
                    child: const Text('Discard'),
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: HollowButton.filled(
                    onPressed: _save,
                    expand: true,
                    icon: Icon(LucideIcons.save, size: 16),
                    child: const Text('Save Layout'),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _CategoryRow extends StatelessWidget {
  final int index;
  final String name;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _CategoryRow({
    super.key,
    required this.index,
    required this.name,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm,
          vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: hollow.accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          border: Border.all(
            color: hollow.accent.withValues(alpha: 0.15),
          ),
        ),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: Icon(LucideIcons.gripVertical,
                  size: 16, color: hollow.textSecondary),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Icon(LucideIcons.folder, size: 16, color: hollow.accent),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Text(
                name.toUpperCase(),
                style: HollowTypography.caption.copyWith(
                  color: hollow.accent,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            HollowPressable(
              onTap: onRename,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child: Icon(LucideIcons.pencil,
                  size: 14, color: hollow.textSecondary),
            ),
            const SizedBox(width: HollowSpacing.xs),
            HollowPressable(
              onTap: onDelete,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child:
                  Icon(LucideIcons.trash2, size: 14, color: hollow.error),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelRow extends StatelessWidget {
  final int index;
  final String name;
  final bool isVoice;
  final bool indented;
  final bool isLast;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _ChannelRow({
    super.key,
    required this.index,
    required this.name,
    this.isVoice = false,
    this.indented = false,
    this.isLast = false,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
      child: Row(
        children: [
          if (indented) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 16,
              height: 32,
              child: CustomPaint(
                painter: _TreeConnectorPainter(
                  color: hollow.border,
                  isLast: isLast,
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm,
                vertical: HollowSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: hollow.elevated,
                borderRadius: BorderRadius.circular(hollow.radiusMd),
              ),
              child: Row(
                children: [
                  ReorderableDragStartListener(
                    index: index,
                    child: Icon(LucideIcons.gripVertical,
                        size: 16, color: hollow.textSecondary),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  Icon(isVoice ? LucideIcons.volume2 : LucideIcons.hash,
                      size: 16, color: hollow.textSecondary),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Text(
                      name,
                      style: HollowTypography.body
                          .copyWith(color: hollow.textPrimary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  HollowPressable(
                    onTap: onRename,
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    child: Icon(LucideIcons.pencil,
                        size: 14, color: hollow.textSecondary),
                  ),
                  const SizedBox(width: HollowSpacing.xs),
                  HollowPressable(
                    onTap: onDelete,
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    child:
                        Icon(LucideIcons.trash2, size: 14, color: hollow.error),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A separator row — thin divider that breaks the category scope.
class _SeparatorRow extends StatelessWidget {
  final int index;
  final VoidCallback onDelete;

  const _SeparatorRow({
    super.key,
    required this.index,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Icon(LucideIcons.gripVertical,
                size: 16, color: hollow.textSecondary),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Container(
              height: 1.5,
              color: hollow.border,
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowPressable(
            onTap: onDelete,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(HollowSpacing.xs),
            child: Icon(LucideIcons.x, size: 12, color: hollow.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Paints the tree connector line (├── or └──).
class _TreeConnectorPainter extends CustomPainter {
  final Color color;
  final bool isLast;

  _TreeConnectorPainter({required this.color, required this.isLast});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Color.lerp(color, Colors.white, 0.3)!
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    // Vertical line from top to middle (or full height if not last).
    final midY = size.height / 2;
    canvas.drawLine(
      Offset(0, 0),
      Offset(0, isLast ? midY : size.height),
      paint,
    );

    // Horizontal line from left to right at middle.
    canvas.drawLine(
      Offset(0, midY),
      Offset(size.width, midY),
      paint,
    );
  }

  @override
  bool shouldRepaint(_TreeConnectorPainter oldDelegate) =>
      color != oldDelegate.color || isLast != oldDelegate.isLast;
}

class _ChannelTypeChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _ChannelTypeChip({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: HollowDurations.fast,
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: isSelected ? hollow.accentMuted : hollow.surface,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          border: Border.all(
            color: isSelected ? hollow.accent : hollow.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14,
                color: isSelected ? hollow.accent : hollow.textSecondary),
            const SizedBox(width: HollowSpacing.xs),
            Text(
              label,
              style: HollowTypography.caption.copyWith(
                color: isSelected ? hollow.accent : hollow.textSecondary,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
