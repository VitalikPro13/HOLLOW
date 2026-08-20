import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/channel_layout.dart';
import 'package:hollow/src/core/moderation_format.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/settings/access_label_picker.dart';
import 'package:hollow/src/ui/settings/category_bulk_access_dialog.dart';
import 'package:hollow/src/ui/settings/channel_grants_dialog.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
  bool get _dirty => !_sameLayout(_layout, _savedLayout);

  static bool _sameLayout(List<LayoutItem> a, List<LayoutItem> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.runtimeType != y.runtimeType) return false;
      if (x is CategoryItem && y is CategoryItem && x.name != y.name) {
        return false;
      }
      if (x is ChannelItem && y is ChannelItem && x.channelId != y.channelId) {
        return false;
      }
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    _loadLayout();
  }

  Future<void> _loadLayout() async {
    try {
      final json = await crdt_api.getChannelLayout(serverId: widget.serverId);
      final layout = parseLayoutJson(json);
      if (mounted) {
        // Compute effective layout (includes newly created channels)
        // and use it as both current and saved baseline.
        final channels = ref.read(channelListProvider);
        final effective = effectiveLayoutFrom(layout, channels);
        setState(() { _layout = effective; _savedLayout = List.from(effective); _loaded = true; });
      }
    } catch (_) {
      if (mounted) {
        final channels = ref.read(channelListProvider);
        final effective = effectiveLayoutFrom([], channels);
        setState(() { _layout = effective; _savedLayout = List.from(effective); _loaded = true; });
      }
    }
  }

  /// Build the effective layout: current layout + any channels not yet in it.
  /// Shared with the sidebar's context menus (`effectiveLayoutFrom`) so both
  /// surfaces place unplaced channels identically.
  List<LayoutItem> _effectiveLayout(Map<String, ChannelInfo> channels) {
    return effectiveLayoutFrom(_layout, channels);
  }

  /// The tab's only layout writer.
  ///
  /// Routes through [ChannelLayoutNotifier.mutate] whenever this tab is
  /// editing the SELECTED server, so the write is normalised, published to the
  /// sidebar immediately, and shielded from the DB reload a server event would
  /// otherwise land on top of it. Settings opened for a non-selected server
  /// (mobile route, chats-tab long-press) has no provider to publish to and
  /// writes directly.
  void _writeLayout(List<LayoutItem> layout) {
    if (ref.read(selectedServerProvider) == widget.serverId) {
      ref.read(channelLayoutProvider.notifier).mutate(
            widget.serverId,
            ref.read(channelListProvider),
            (_) => List<LayoutItem>.from(layout),
          );
      return;
    }
    try {
      crdt_api
          .updateChannelLayout(
            serverId: widget.serverId,
            layoutJson: layoutToJson(layout),
          )
          .catchError((_) {});
    } catch (_) {}
  }

  void _save() {
    _writeLayout(_layout);

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
            title: 'New channel',
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
        title: 'New category',
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
        title: 'Rename category',
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

  /// Commit a channel-property CRDT write; on failure revert the optimistic
  /// provider update (done at the call site BEFORE the FFI, per convention)
  /// and toast — otherwise a dead node leaves the control lying silently.
  Future<void> _commitChannelProp(
      Future<void> Function() commit, VoidCallback revert) async {
    try {
      await commit();
    } catch (_) {
      revert();
      if (mounted) {
        HollowToast.show(context, 'Could not update channel',
            type: HollowToastType.error);
      }
    }
  }

  /// Open the access-label picker for a channel's visibility or posting
  /// gate. Optimistic: label list + the Rust-side Admin+ tier stamp are
  /// reflected immediately, both reverted on failure.
  Future<void> _editGateLabels(String channelId, ChannelInfo? info,
      {required bool forVisibility}) async {
    final initial = (forVisibility
            ? info?.visibilityLabels
            : info?.postingLabels) ??
        const <String>[];
    final picked = await showAccessLabelPicker(
      context: context,
      serverId: widget.serverId,
      title: forVisibility ? 'Custom visibility' : 'Custom posting',
      initial: initial.toSet(),
    );
    if (picked == null || !mounted) return;

    final channels = ref.read(channelListProvider.notifier);
    final prevLabels = List<String>.from(initial);
    final prevVis = info?.visibility ?? 'everyone';
    final prevPost = info?.posting ?? 'everyone';
    final labels = picked.toList();

    channels.updateChannel(channelId, (ch) {
      if (forVisibility) {
        return ch.copyWith(
          visibilityLabels: labels,
          // Mirror the Rust handler's old-client stamp.
          visibility: labels.isEmpty ? prevVis : 'admin',
        );
      }
      return ch.copyWith(
        postingLabels: labels,
        posting: labels.isEmpty ? prevPost : 'admin',
      );
    });
    await _commitChannelProp(
      () => forVisibility
          ? crdt_api.setChannelVisibilityLabels(
              serverId: widget.serverId,
              channelId: channelId,
              labels: labels,
            )
          : crdt_api.setChannelPostingLabels(
              serverId: widget.serverId,
              channelId: channelId,
              labels: labels,
            ),
      () => channels.updateChannel(channelId, (ch) {
        if (forVisibility) {
          return ch.copyWith(
              visibilityLabels: prevLabels, visibility: prevVis);
        }
        return ch.copyWith(postingLabels: prevLabels, posting: prevPost);
      }),
    );
  }

  /// Category bulk-apply: stamp visibility/posting access onto every channel
  /// under the category (forward-scan from the category's index in the live
  /// layout until the next Category/Separator — the inverse of the sidebar's
  /// backward scan, so membership matches what users see). Anchored on
  /// INDEX, never the category NAME (duplicate names are legal). Sequential
  /// per-channel writes with per-channel optimistic+revert; the summary
  /// toast never implies rollback of ops that already landed.
  Future<void> _bulkApplyAccess(int categoryIndex, String categoryName) async {
    final channels = ref.read(channelListProvider);
    final targetIds = <String>[];
    for (var i = categoryIndex + 1; i < _layout.length; i++) {
      final item = _layout[i];
      if (item is CategoryItem || item is SeparatorItem) break;
      if (item is ChannelItem) {
        // Public channels have no access gates (plaintext by design).
        final info = channels[item.channelId];
        if (info != null && !info.isPublic) targetIds.add(item.channelId);
      }
    }
    // Dialog + per-channel writes are shared with the sidebar's category
    // right-click menu (issue #61).
    await runCategoryBulkAccess(
      context: context,
      ref: ref,
      serverId: widget.serverId,
      categoryName: categoryName,
      channelIds: targetIds,
    );
  }

  /// Picking a plain tier on a label-gated channel widens access — confirm
  /// before silently clearing the gate (a 4-item menu tap is easy to
  /// fat-finger on a security setting).
  Future<bool> _confirmClearLabelGate(String channelName, String tier) async {
    final confirmed = await showHollowDialog<bool>(
      context: context,
      builder: (ctx) => HollowDialog(
        title: 'Remove label requirement?',
        content: Text(
          '#$channelName will use tier-based access '
          '(${switch (tier) { 'moderator' => 'Mod+', 'admin' => 'Admin+', _ => 'Everyone' }}) '
          'instead of its access labels.',
          style: HollowTypography.body.copyWith(
            color: HollowTheme.of(ctx).textSecondary,
          ),
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// Awaited rename with an error toast — a bare fire-and-forget here
  /// rejected unhandled on a dead node with zero user feedback.
  Future<void> _commitRename(String channelId, String newName) async {
    try {
      await crdt_api.renameChannel(
        serverId: widget.serverId,
        channelId: channelId,
        newName: newName,
      );
    } catch (_) {
      if (mounted) {
        HollowToast.show(context, 'Could not rename channel',
            type: HollowToastType.error);
      }
    }
  }

  void _renameChannel(String channelId, String currentName) {
    final controller = TextEditingController(text: currentName);
    showHollowDialog(
      context: context,
      builder: (ctx) => HollowDialog(
        title: 'Rename channel',
        content: HollowTextField(
          controller: controller,
          hintText: 'Channel name',
          autofocus: true,
          onSubmitted: (_) {
            final newName = controller.text.trim();
            if (newName.isNotEmpty && newName != currentName) {
              _commitRename(channelId, newName);
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
                _commitRename(channelId, newName);
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
        title: 'Delete channel',
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
            onPressed: () async {
              Navigator.pop(ctx);
              setState(() {
                _layout.removeWhere(
                    (i) => i is ChannelItem && i.channelId == channelId);
              });
              try {
                await crdt_api.removeChannel(
                  serverId: widget.serverId,
                  channelId: channelId,
                );
              } catch (_) {
                if (mounted) {
                  // Re-sync the optimistically-pruned layout from the DB.
                  setState(() => _loaded = false);
                  _loadLayout();
                  HollowToast.show(context, 'Could not delete channel',
                      type: HollowToastType.error);
                }
                return;
              }
              if (mounted) {
                HollowToast.show(
                  context,
                  'Channel #$name deleted',
                  type: HollowToastType.info,
                );
              }
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
    final allLabels = ref.watch(serverLabelsProvider(widget.serverId))
            .valueOrNull ??
        const <crdt_api.LabelFfi>[];

    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    // Adopt layout edits made OUTSIDE this editor — the sidebar's category
    // right-click menu writes through `channelLayoutProvider`, and without
    // this the tab kept showing its stale snapshot until you switched tabs.
    // Only while the user has no unsaved edits of their own: their in-progress
    // drag always outranks an incoming change.
    if (!_dirty && ref.watch(selectedServerProvider) == widget.serverId) {
      final incoming =
          effectiveLayoutFrom(parseLayoutJson(ref.watch(channelLayoutProvider)),
              channels);
      if (!_sameLayout(incoming, _savedLayout)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _dirty) return;
          setState(() {
            _layout = incoming;
            _savedLayout = List.from(incoming);
          });
        });
      }
    }

    final effective = _effectiveLayout(channels);
    // Sync local state if effective differs (new channels added/removed
    // externally). Auto-save so the sidebar updates without a manual Save.
    // Guard: skip when channels map is empty (server deselected / switching).
    if (channels.isNotEmpty && effective.length != _layout.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // RECOMPUTE rather than reusing the value captured during build. The
        // adopt-external-changes callback above may have replaced `_layout`
        // since, and writing the pre-adoption value here would undo the very
        // edit we just took in — which is how a category created in the
        // sidebar came back reverted.
        final channelsNow = ref.read(channelListProvider);
        if (channelsNow.isEmpty) return;
        final fresh = _effectiveLayout(channelsNow);
        if (_sameLayout(fresh, _layout)) return;
        setState(() {
          _layout = fresh;
          _savedLayout = List.from(fresh);
        });
        _writeLayout(fresh);
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
                icon: const Icon(LucideIcons.minus, size: 14),
                child: const Text('Break'),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.ghost(
                onPressed: _addCategory,
                compact: true,
                icon: const Icon(LucideIcons.folderPlus, size: 14),
                child: const Text('Category'),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.ghost(
                onPressed: _addChannel,
                compact: true,
                icon: const Icon(LucideIcons.plus, size: 14),
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
                  onReorderItem: (oldIndex, newIndex) {
                    setState(() {
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
                        onBulkAccess: () =>
                            _bulkApplyAccess(index, item.name),
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
                        serverId: widget.serverId,
                        channelId: item.channelId,
                        visibility: info?.visibility ?? 'everyone',
                        posting: info?.posting ?? 'everyone',
                        visibilityLabels:
                            info?.visibilityLabels ?? const [],
                        postingLabels: info?.postingLabels ?? const [],
                        allLabels: allLabels,
                        isPublic: info?.isPublic ?? false,
                        slowModeSecs: info?.slowModeSecs ?? 0,
                        mediaOnly: info?.mediaOnly ?? false,
                        onVisibilityLabelsPressed: () => _editGateLabels(
                            item.channelId, info,
                            forVisibility: true),
                        onPostingLabelsPressed: () => _editGateLabels(
                            item.channelId, info,
                            forVisibility: false),
                        onManageGrants: () => showChannelGrantsDialog(
                          context,
                          serverId: widget.serverId,
                          channelId: item.channelId,
                          channelName: name,
                        ),
                        onSlowModeChanged: (secs) async {
                          final channels =
                              ref.read(channelListProvider.notifier);
                          final prev = info?.slowModeSecs ?? 0;
                          channels.updateChannel(
                            item.channelId,
                            (ch) => ch.copyWith(slowModeSecs: secs),
                          );
                          await _commitChannelProp(
                            () => crdt_api.setChannelSlowMode(
                              serverId: widget.serverId,
                              channelId: item.channelId,
                              seconds: secs,
                            ),
                            () => channels.updateChannel(
                              item.channelId,
                              (ch) => ch.copyWith(slowModeSecs: prev),
                            ),
                          );
                        },
                        onMediaOnlyToggled: () {
                          final channels =
                              ref.read(channelListProvider.notifier);
                          final newVal = !(info?.mediaOnly ?? false);
                          channels.updateChannel(
                            item.channelId,
                            (ch) => ch.copyWith(mediaOnly: newVal),
                          );
                          _commitChannelProp(
                            () => crdt_api.setChannelMediaOnly(
                              serverId: widget.serverId,
                              channelId: item.channelId,
                              mediaOnly: newVal,
                            ),
                            () => channels.updateChannel(
                              item.channelId,
                              (ch) => ch.copyWith(mediaOnly: !newVal),
                            ),
                          );
                        },
                        onVisibilityChanged: (v) async {
                          final hadLabels =
                              info?.visibilityLabels.isNotEmpty ?? false;
                          if (hadLabels &&
                              !await _confirmClearLabelGate(name, v)) {
                            return;
                          }
                          final channels =
                              ref.read(channelListProvider.notifier);
                          final prev = info?.visibility ?? 'everyone';
                          final prevLabels =
                              info?.visibilityLabels ?? const <String>[];
                          // The Rust tier handler clears any label gate too —
                          // mirror that optimistically.
                          channels.updateChannel(
                            item.channelId,
                            (ch) => ch.copyWith(
                                visibility: v, visibilityLabels: const []),
                          );
                          await _commitChannelProp(
                            () => crdt_api.setChannelVisibility(
                              serverId: widget.serverId,
                              channelId: item.channelId,
                              visibility: v,
                            ),
                            () => channels.updateChannel(
                              item.channelId,
                              (ch) => ch.copyWith(
                                  visibility: prev,
                                  visibilityLabels: prevLabels),
                            ),
                          );
                        },
                        onPostingChanged: (v) async {
                          final hadLabels =
                              info?.postingLabels.isNotEmpty ?? false;
                          if (hadLabels &&
                              !await _confirmClearLabelGate(name, v)) {
                            return;
                          }
                          final channels =
                              ref.read(channelListProvider.notifier);
                          final prev = info?.posting ?? 'everyone';
                          final prevLabels =
                              info?.postingLabels ?? const <String>[];
                          channels.updateChannel(
                            item.channelId,
                            (ch) => ch.copyWith(
                                posting: v, postingLabels: const []),
                          );
                          await _commitChannelProp(
                            () => crdt_api.setChannelPosting(
                              serverId: widget.serverId,
                              channelId: item.channelId,
                              posting: v,
                            ),
                            () => channels.updateChannel(
                              item.channelId,
                              (ch) => ch.copyWith(
                                  posting: prev, postingLabels: prevLabels),
                            ),
                          );
                        },
                        onPublicToggled: () {
                          final channels =
                              ref.read(channelListProvider.notifier);
                          final newVal = !(info?.isPublic ?? false);
                          channels.updateChannel(
                            item.channelId,
                            (ch) => ch.copyWith(isPublic: newVal),
                          );
                          _commitChannelProp(
                            () => crdt_api.setChannelPublic(
                              serverId: widget.serverId,
                              channelId: item.channelId,
                              isPublic: newVal,
                            ),
                            () => channels.updateChannel(
                              item.channelId,
                              (ch) => ch.copyWith(isPublic: !newVal),
                            ),
                          );
                        },
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
                    icon: const Icon(LucideIcons.x, size: 16),
                    child: const Text('Discard'),
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: HollowButton.filled(
                    onPressed: _save,
                    expand: true,
                    icon: const Icon(LucideIcons.save, size: 16),
                    child: const Text('Save layout'),
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
  final VoidCallback onBulkAccess;

  const _CategoryRow({
    super.key,
    required this.index,
    required this.name,
    required this.onRename,
    required this.onDelete,
    required this.onBulkAccess,
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
              child: HollowTooltip(
                message: 'Drag to reorder',
                child: Semantics(
                  label: 'Drag to reorder category',
                  child: Icon(LucideIcons.gripVertical,
                      size: 16, color: hollow.textSecondary),
                ),
              ),
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
            HollowTooltip(
              message: 'Apply access to all channels',
              child: HollowPressable(
                onTap: onBulkAccess,
                semanticLabel:
                    'Apply access settings to all channels in category',
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(LucideIcons.shieldCheck,
                    size: 14, color: hollow.textSecondary),
              ),
            ),
            const SizedBox(width: HollowSpacing.xs),
            HollowTooltip(
              message: 'Rename category',
              child: HollowPressable(
                onTap: onRename,
                semanticLabel: 'Rename category',
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(LucideIcons.pencil,
                    size: 14, color: hollow.textSecondary),
              ),
            ),
            const SizedBox(width: HollowSpacing.xs),
            HollowTooltip(
              message: 'Delete category',
              child: HollowPressable(
                onTap: onDelete,
                semanticLabel: 'Delete category',
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child:
                    Icon(LucideIcons.trash2, size: 14, color: hollow.error),
              ),
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
  final VoidCallback onPublicToggled;
  final VoidCallback onMediaOnlyToggled;
  final Future<void> Function(String) onVisibilityChanged;
  final Future<void> Function(String) onPostingChanged;
  final Future<void> Function(int) onSlowModeChanged;
  final VoidCallback onVisibilityLabelsPressed;
  final VoidCallback onPostingLabelsPressed;
  final VoidCallback onManageGrants;
  final String serverId;
  final String channelId;
  final String visibility;
  final String posting;
  final List<String> visibilityLabels;
  final List<String> postingLabels;
  final List<crdt_api.LabelFfi> allLabels;
  final bool isPublic;
  final int slowModeSecs;
  final bool mediaOnly;

  const _ChannelRow({
    super.key,
    required this.index,
    required this.name,
    this.isVoice = false,
    this.indented = false,
    this.isLast = false,
    required this.onRename,
    required this.onDelete,
    required this.onPublicToggled,
    required this.onMediaOnlyToggled,
    required this.onVisibilityChanged,
    required this.onPostingChanged,
    required this.onSlowModeChanged,
    required this.onVisibilityLabelsPressed,
    required this.onPostingLabelsPressed,
    required this.onManageGrants,
    required this.serverId,
    required this.channelId,
    this.visibility = 'everyone',
    this.posting = 'everyone',
    this.visibilityLabels = const [],
    this.postingLabels = const [],
    this.allLabels = const [],
    this.isPublic = false,
    this.slowModeSecs = 0,
    this.mediaOnly = false,
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
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _TreeConnectorPainter(
                    color: hollow.border,
                    isLast: isLast,
                  ),
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
                    child: HollowTooltip(
                      message: 'Drag to reorder',
                      child: Semantics(
                        label: 'Drag to reorder channel',
                        child: Icon(LucideIcons.gripVertical,
                            size: 16, color: hollow.textSecondary),
                      ),
                    ),
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
                  HollowTooltip(
                    message: 'Who can see this channel',
                    child: _AccessChip(
                      icon: LucideIcons.eye,
                      value: visibility,
                      gateLabels: visibilityLabels,
                      allLabels: allLabels,
                      onChanged: onVisibilityChanged,
                      onCustomPressed: onVisibilityLabelsPressed,
                    ),
                  ),
                  const SizedBox(width: 4),
                  HollowTooltip(
                    message: 'Who can post',
                    child: _AccessChip(
                      icon: LucideIcons.messageSquare,
                      value: posting,
                      gateLabels: postingLabels,
                      allLabels: allLabels,
                      onChanged: onPostingChanged,
                      onCustomPressed: onPostingLabelsPressed,
                    ),
                  ),
                  if (!isVoice) ...[
                    const SizedBox(width: 4),
                    HollowTooltip(
                      message: 'Minimum delay between each member\'s messages',
                      child: _SlowModeChip(
                        seconds: slowModeSecs,
                        onChanged: onSlowModeChanged,
                      ),
                    ),
                    const SizedBox(width: 4),
                    HollowTooltip(
                      message: mediaOnly
                          ? 'Media-only is on: only images, GIFs and videos can be posted'
                          : 'Restrict this channel to images, GIFs and videos only',
                      child: HollowPressable(
                        onTap: onMediaOnlyToggled,
                        semanticLabel: mediaOnly
                            ? 'Allow all message types, currently media-only'
                            : 'Make channel media-only, currently allows all messages',
                        borderRadius: BorderRadius.circular(hollow.radiusSm),
                        padding: const EdgeInsets.all(HollowSpacing.xs),
                        child: Icon(
                          LucideIcons.image,
                          size: 14,
                          color:
                              mediaOnly ? hollow.accent : hollow.textSecondary,
                        ),
                      ),
                    ),
                    // Public toggle is TEXT-ONLY (#44): a public voice channel
                    // is rejected by Rust and would only ghost-flash in the
                    // browser (its list responders filter voice out).
                    const SizedBox(width: 4),
                    HollowTooltip(
                      message: isPublic
                          ? 'Public: anyone can read this channel without joining the server'
                          : 'Publish this channel so anyone can read it without joining',
                      child: HollowPressable(
                        onTap: onPublicToggled,
                        semanticLabel: isPublic
                            ? 'Make channel private, currently public'
                            : 'Make channel public, currently private',
                        borderRadius: BorderRadius.circular(hollow.radiusSm),
                        padding: const EdgeInsets.all(HollowSpacing.xs),
                        child: Icon(
                          LucideIcons.globe,
                          size: 14,
                          color: isPublic ? hollow.accent : hollow.textSecondary,
                        ),
                      ),
                    ),
                  ],
                  if (!isPublic) ...[
                    const SizedBox(width: HollowSpacing.xs),
                    HollowTooltip(
                      message: 'Give a member time-limited access to this channel',
                      child: HollowPressable(
                        onTap: onManageGrants,
                        semanticLabel: 'Manage temporary access for channel',
                        borderRadius: BorderRadius.circular(hollow.radiusSm),
                        padding: const EdgeInsets.all(HollowSpacing.xs),
                        child: Icon(LucideIcons.userPlus,
                            size: 14, color: hollow.textSecondary),
                      ),
                    ),
                  ],
                  const SizedBox(width: HollowSpacing.xs),
                  HollowTooltip(
                    message: 'Rename channel',
                    child: HollowPressable(
                      onTap: onRename,
                      semanticLabel: 'Rename channel',
                      borderRadius: BorderRadius.circular(hollow.radiusSm),
                      padding: const EdgeInsets.all(HollowSpacing.xs),
                      child: Icon(LucideIcons.pencil,
                          size: 14, color: hollow.textSecondary),
                    ),
                  ),
                  const SizedBox(width: HollowSpacing.xs),
                  HollowTooltip(
                    message: 'Delete channel',
                    child: HollowPressable(
                      onTap: onDelete,
                      semanticLabel: 'Delete channel',
                      borderRadius: BorderRadius.circular(hollow.radiusSm),
                      padding: const EdgeInsets.all(HollowSpacing.xs),
                      child: Icon(LucideIcons.trash2,
                          size: 14, color: hollow.error),
                    ),
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
            child: HollowTooltip(
              message: 'Drag to reorder',
              child: Semantics(
                label: 'Drag to reorder separator',
                child: Icon(LucideIcons.gripVertical,
                    size: 16, color: hollow.textSecondary),
              ),
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Container(
              height: 1.5,
              color: hollow.border,
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowTooltip(
            message: 'Delete separator',
            child: HollowPressable(
              onTap: onDelete,
              semanticLabel: 'Delete separator',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child: Icon(LucideIcons.x, size: 12, color: hollow.textSecondary),
            ),
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
      const Offset(0, 0),
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
    return HollowFocusRing(
      enabled: true,
      onActivate: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      child: GestureDetector(
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
      ),
    );
  }
}

/// Compact dropdown chip for channel visibility or posting mode. When a
/// label gate is active (`gateLabels` non-empty), the chip shows the label
/// name (or a count) and the menu highlights Custom.
class _AccessChip extends StatelessWidget {
  final IconData icon;
  final String value;
  final List<String> gateLabels;
  final List<crdt_api.LabelFfi> allLabels;
  final Future<void> Function(String) onChanged;
  final VoidCallback onCustomPressed;

  const _AccessChip({
    required this.icon,
    required this.value,
    required this.gateLabels,
    required this.allLabels,
    required this.onChanged,
    required this.onCustomPressed,
  });

  bool get _gated => gateLabels.isNotEmpty;

  String get _label {
    if (_gated) {
      if (gateLabels.length == 1) {
        final match = allLabels
            .where((l) => l.labelId == gateLabels.first)
            .firstOrNull;
        return match?.name ?? '1 label';
      }
      return '${gateLabels.length} labels';
    }
    return switch (value) {
      'moderator' => 'Mod+',
      'admin' => 'Admin+',
      _ => 'All',
    };
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final isRestricted = _gated || value != 'everyone';

    return PopupMenuButton<String>(
      tooltip: '',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      color: hollow.elevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        side: BorderSide(color: hollow.border),
      ),
      onSelected: (v) {
        if (v == 'custom') {
          onCustomPressed();
        } else {
          onChanged(v);
        }
      },
      itemBuilder: (_) => [
        _accessItem('everyone', 'Everyone', hollow),
        _accessItem('moderator', 'Mod+', hollow),
        _accessItem('admin', 'Admin+', hollow),
        _accessItem('custom', 'Custom…', hollow),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: isRestricted
              ? hollow.warning.withValues(alpha: 0.15)
              : hollow.border.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_gated ? LucideIcons.shieldCheck : icon, size: 10,
                color: isRestricted ? hollow.warning : hollow.textSecondary),
            const SizedBox(width: 3),
            // Label names are free-form user content — cap the chip width.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 90),
              child: Text(
                _label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  color: isRestricted ? hollow.warning : hollow.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<String> _accessItem(
      String val, String label, HollowTheme hollow) {
    final selected = val == 'custom' ? _gated : (!_gated && val == value);
    return PopupMenuItem(
      value: val,
      child: Text(
        label,
        style: HollowTypography.body.copyWith(
          color: selected ? hollow.accent : hollow.textPrimary,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
  }
}

/// The slow-mode duration options offered in channel settings.
const kSlowModeOptions = [0, 5, 10, 30, 60, 300, 900, 3600];

class _SlowModeChip extends StatelessWidget {
  final int seconds;
  final Future<void> Function(int) onChanged;

  const _SlowModeChip({required this.seconds, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final active = seconds > 0;

    return PopupMenuButton<int>(
      tooltip: '',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      color: hollow.elevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        side: BorderSide(color: hollow.border),
      ),
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final s in kSlowModeOptions)
          PopupMenuItem(
            value: s,
            child: Text(
              s == 0 ? 'Off' : slowModeDurationLabel(s),
              style: HollowTypography.body.copyWith(
                color: s == seconds ? hollow.accent : hollow.textPrimary,
                fontWeight: s == seconds ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: active
              ? hollow.warning.withValues(alpha: 0.15)
              : hollow.border.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.timer, size: 10,
                color: active ? hollow.warning : hollow.textSecondary),
            const SizedBox(width: 3),
            Text(
              slowModeDurationLabel(seconds),
              style: TextStyle(
                fontSize: 10,
                color: active ? hollow.warning : hollow.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
