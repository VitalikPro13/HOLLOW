import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/channel_layout.dart';
import 'package:hollow/src/core/moderation_format.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_shadows.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/dialogs/create_channel_dialog.dart';
import 'package:hollow/src/ui/server_settings/delete_channel_confirm.dart';
import 'package:hollow/src/ui/settings/access_label_picker.dart';
import 'package:hollow/src/ui/settings/category_bulk_access_dialog.dart';
import 'package:hollow/src/ui/settings/channel_access_pickers.dart';
import 'package:hollow/src/ui/settings/channel_grants_dialog.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Who a tier or a label gate lets in, as the channel row says it.
String _gateName(String tier, List<String> gateLabels,
    List<crdt_api.LabelFfi> labels) {
  if (gateLabels.isNotEmpty) {
    if (gateLabels.length == 1) {
      return labels
              .where((l) => l.labelId == gateLabels.first)
              .firstOrNull
              ?.name ??
          '1 label';
    }
    return '${gateLabels.length} labels';
  }
  return switch (tier) {
    'moderator' => 'Mod+',
    'admin' => 'Admin+',
    _ => 'Everyone',
  };
}

/// What sets [channel] apart from a default channel, joined by " · ". A
/// default channel says nothing: status by exception.
String channelSummary(
  ChannelInfo channel, {
  List<crdt_api.LabelFfi> labels = const [],
  int grants = 0,
}) {
  final voice = channel.channelType == ChannelType.voice;
  final parts = <String>[
    if (channel.visibility != 'everyone' || channel.visibilityLabels.isNotEmpty)
      '${_gateName(channel.visibility, channel.visibilityLabels, labels)} can see',
    if (!voice) ...[
      if (channel.posting != 'everyone' || channel.postingLabels.isNotEmpty)
        '${_gateName(channel.posting, channel.postingLabels, labels)} can post',
      if (channel.slowModeSecs > 0)
        'Slow ${slowModeDurationLabel(channel.slowModeSecs)}',
      if (channel.mediaOnly) 'Media only',
      if (channel.isPublic) 'Public',
    ],
    if (grants > 0)
      '$grants ${grants == 1 ? 'member' : 'members'} with temporary access',
  ];
  return parts.join(' · ');
}

/// The channel list as the sidebar shows it, to reorder and to open a channel
/// in. Order, categories and dividers are staged for Save layout; everything
/// about one channel writes at once, reverting if the write fails.
class ChannelsPage extends ConsumerStatefulWidget {
  final String serverId;
  const ChannelsPage({super.key, required this.serverId});

  @override
  ConsumerState<ChannelsPage> createState() => _ChannelsPageState();
}

class _ChannelsPageState extends ConsumerState<ChannelsPage> {
  String? _open;

  String get _sid => widget.serverId;

  ChannelLayoutDraftNotifier get _draft =>
      ref.read(channelLayoutDraftProvider(_sid).notifier);

  List<LayoutItem> _shown() => _draft.shown(
      ref.read(channelListProvider), ref.read(channelLayoutProvider));

  void _stage(void Function(List<LayoutItem> layout) edit) {
    final layout = List<LayoutItem>.from(_shown());
    edit(layout);
    _draft.stage(layout);
  }

  void _newCategory() {
    promptForName(
      context: context,
      title: 'New category',
      hintText: 'Category name',
      initial: '',
      confirmLabel: 'Add',
      onSubmit: (name) => _stage((l) => l.add(CategoryItem(name))),
    );
  }

  void _renameCategory(int index, String current) {
    promptForName(
      context: context,
      title: 'Rename category',
      hintText: 'Category name',
      initial: current,
      confirmLabel: 'Rename',
      onSubmit: (name) => _stage((l) => l[index] = CategoryItem(name)),
    );
  }

  Future<void> _deleteCategory(int index, String name) async {
    final ok = await showHollowConfirm(
      context: context,
      title: 'Delete the $name category?',
      message: 'Its channels stay in the list. Nothing is deleted until you '
          'save the layout.',
      confirmLabel: 'Delete category',
      destructive: true,
    );
    if (ok) _stage((l) => l.removeAt(index));
  }

  Future<void> _bulkAccess(int index, String name) async {
    final channels = ref.read(channelListProvider);
    final layout = _shown();
    final ids = <String>[];
    // Forward from the category's INDEX to the next category or divider: names
    // may repeat, and this is the scope the sidebar draws.
    for (var i = index + 1; i < layout.length; i++) {
      final item = layout[i];
      if (item is CategoryItem || item is SeparatorItem) break;
      if (item is ChannelItem) {
        final info = channels[item.channelId];
        if (info != null && !info.isPublic) ids.add(item.channelId);
      }
    }
    await runCategoryBulkAccess(
      context: context,
      ref: ref,
      serverId: _sid,
      categoryName: name,
      channelIds: ids,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final touch = SettingsDensity.touchOf(context);
    final channels = ref.watch(channelListProvider);
    final saved = ref.watch(channelLayoutProvider);
    ref.watch(channelLayoutDraftProvider(_sid));
    final layout = _draft.shown(channels, saved);
    final labels =
        ref.watch(serverLabelsProvider(_sid)).valueOrNull ?? const [];

    final toolbar = Wrap(
      spacing: HollowSpacing.sm,
      runSpacing: HollowSpacing.sm,
      children: [
        HollowButton.ghost(
          compact: true,
          icon: const Icon(LucideIcons.plus),
          onPressed: () => showCreateChannelDialog(context, _sid),
          child: const Text('New channel'),
        ),
        HollowButton.ghost(
          compact: true,
          onPressed: _newCategory,
          child: const Text('New category'),
        ),
        HollowButton.ghost(
          compact: true,
          onPressed: () => _stage((l) => l.add(const SeparatorItem())),
          child: const Text('Divider'),
        ),
      ],
    );

    return SettingsPage(
      title: 'Channels',
      intro: touch
          ? 'Hold a channel to drag it. Tap one for who can see it, who can '
              'post and the rest.'
          : 'Drag to reorder. Click a channel for who can see it, who can '
              'post and the rest.',
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            toolbar,
            const SizedBox(height: HollowSpacing.md),
            if (layout.isEmpty)
              const HollowEmptyState(
                dense: true,
                title: 'No channels yet',
                description: 'New channel adds the first one.',
              )
            else
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: layout.length,
                proxyDecorator: (child, _, _) => DecoratedBox(
                  decoration: BoxDecoration(
                    color: hollow.overlay,
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                    boxShadow: HollowShadows.float,
                  ),
                  child: child,
                ),
                onReorderItem: (from, to) => _stage((l) {
                  final item = l.removeAt(from);
                  l.insert(to, item);
                }),
                itemBuilder: (context, index) {
                  final item = layout[index];
                  if (item is SeparatorItem) {
                    return _DividerRow(
                      key: ValueKey('sep-$index'),
                      index: index,
                      onRemove: () => _stage((l) => l.removeAt(index)),
                    );
                  }
                  if (item is CategoryItem) {
                    return _CategoryRow(
                      key: ValueKey('cat-$index-${item.name}'),
                      index: index,
                      name: item.name,
                      onBulkAccess: () => _bulkAccess(index, item.name),
                      onRename: () => _renameCategory(index, item.name),
                      onDelete: () => _deleteCategory(index, item.name),
                    );
                  }
                  final id = (item as ChannelItem).channelId;
                  final info = channels[id];
                  var underCategory = false;
                  for (var i = index - 1; i >= 0; i--) {
                    if (layout[i] is SeparatorItem) break;
                    if (layout[i] is CategoryItem) {
                      underCategory = true;
                      break;
                    }
                  }
                  return _ChannelEntry(
                    key: ValueKey('ch-$id'),
                    index: index,
                    serverId: _sid,
                    channelId: id,
                    info: info,
                    labels: labels,
                    indented: underCategory,
                    open: _open == id,
                    onToggle: () =>
                        setState(() => _open = _open == id ? null : id),
                  );
                },
              ),
          ],
        ),
      ],
    );
  }
}

/// The grip that starts a drag: at once under a pointer, after a hold on
/// touch so a scroll never grabs a row.
class _Grip extends StatelessWidget {
  final int index;
  final String label;
  const _Grip({required this.index, required this.label});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final icon = Semantics(
      label: label,
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xs),
        child: Icon(LucideIcons.gripVertical,
            size: 14, color: hollow.textTertiary),
      ),
    );
    if (SettingsDensity.touchOf(context)) {
      return ReorderableDelayedDragStartListener(index: index, child: icon);
    }
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: ReorderableDragStartListener(index: index, child: icon),
    );
  }
}

/// Shows its [child] actions under the pointer or keyboard focus only; they
/// keep their space so hover never moves the row.
class _HoverReveal extends StatefulWidget {
  final Widget row;
  final Widget actions;
  const _HoverReveal({required this.row, required this.actions});

  @override
  State<_HoverReveal> createState() => _HoverRevealState();
}

class _HoverRevealState extends State<_HoverReveal> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final show = _hover || _focus || SettingsDensity.touchOf(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Row(
        children: [
          Expanded(child: widget.row),
          Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (f) => setState(() => _focus = f),
            child: AnimatedOpacity(
              opacity: show ? 1 : 0,
              duration: HollowDurations.fast,
              child: widget.actions,
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  final int index;
  final String name;
  final VoidCallback onBulkAccess;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _CategoryRow({
    super.key,
    required this.index,
    required this.name,
    required this.onBulkAccess,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.md),
      child: SizedBox(
        height: 36,
        child: _HoverReveal(
          row: Row(
            children: [
              _Grip(index: index, label: 'Drag the $name category'),
              const SizedBox(width: HollowSpacing.xs),
              Expanded(
                child: Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: HollowTypography.label
                      .copyWith(color: hollow.textSecondary),
                ),
              ),
            ],
          ),
          actions: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              HollowButton.ghost(
                compact: true,
                semanticLabel: 'Set access for every channel in $name',
                onPressed: onBulkAccess,
                child: const Text('Set access for all'),
              ),
              const SizedBox(width: HollowSpacing.xs),
              Builder(
                builder: (buttonContext) => HollowIconButton(
                  icon: LucideIcons.moreHorizontal,
                  label: 'More for the $name category',
                  onPressed: () => showHollowMenu(
                    context: buttonContext,
                    alignEnd: true,
                    anchor: overlayAnchorOf(buttonContext,
                        localOffset: Offset(buttonContext.size?.width ?? 0,
                            buttonContext.size?.height ?? 0)),
                    builder: (_, _) => [
                      HollowMenuItem(
                          icon: LucideIcons.pencil,
                          label: 'Rename',
                          onTap: onRename),
                      HollowMenuItem(
                        icon: LucideIcons.trash2,
                        label: 'Delete category',
                        isDanger: true,
                        onTap: onDelete,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DividerRow extends StatelessWidget {
  final int index;
  final VoidCallback onRemove;

  const _DividerRow({super.key, required this.index, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: _HoverReveal(
        row: Row(
          children: [
            _Grip(index: index, label: 'Drag the divider'),
            const SizedBox(width: HollowSpacing.xs),
            const Expanded(child: HollowDivider()),
          ],
        ),
        actions: HollowIconButton(
          icon: LucideIcons.x,
          label: 'Remove divider',
          onPressed: onRemove,
        ),
      ),
    );
  }
}

/// One channel: its row, and under it the panel when open. One reorderable
/// item, so a drag carries the open panel with it.
class _ChannelEntry extends ConsumerWidget {
  final int index;
  final String serverId;
  final String channelId;
  final ChannelInfo? info;
  final List<crdt_api.LabelFfi> labels;
  final bool indented;
  final bool open;
  final VoidCallback onToggle;

  const _ChannelEntry({
    super.key,
    required this.index,
    required this.serverId,
    required this.channelId,
    required this.info,
    required this.labels,
    required this.indented,
    required this.open,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final touch = SettingsDensity.touchOf(context);
    final channel = info;
    if (channel == null) return const SizedBox.shrink();
    final voice = channel.channelType == ChannelType.voice;
    final grants = ref
            .watch(channelGrantsProvider(
                (serverId: serverId, channelId: channelId)))
            .valueOrNull
            ?.length ??
        0;
    final summary = channelSummary(channel,
        labels: labels, grants: channel.isPublic ? 0 : grants);
    final name = Text(
      channel.name,
      overflow: TextOverflow.ellipsis,
      style: (touch ? HollowTypography.bodyTouch : HollowTypography.body)
          .copyWith(color: hollow.textPrimary),
    );
    final quiet = Text(
      summary,
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
      style: HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
    );

    final row = HollowPressable(
      onTap: onToggle,
      subtle: true,
      semanticButton: false,
      semanticLabel: '${channel.name}${summary.isEmpty ? '' : ', $summary'}. '
          '${open ? 'Close its settings' : 'Open its settings'}',
      backgroundColor: open ? hollow.elevated : null,
      hoverColor: hollow.elevated,
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      padding: const EdgeInsets.only(right: HollowSpacing.sm),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: touch ? 52 : 40),
        child: Row(
          children: [
            _Grip(index: index, label: 'Drag ${channel.name}'),
            const SizedBox(width: HollowSpacing.xs),
            Icon(voice ? LucideIcons.volume2 : LucideIcons.hash,
                size: 16, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: touch
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [name, if (summary.isNotEmpty) quiet],
                    )
                  // One line: the summary follows the name and yields first.
                  : Text.rich(
                      TextSpan(children: [
                        TextSpan(text: channel.name, style: name.style),
                        if (summary.isNotEmpty)
                          TextSpan(
                              text: '   $summary', style: quiet.style),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
            const SizedBox(width: HollowSpacing.sm),
            AnimatedRotation(
              turns: open ? 0.25 : 0,
              duration: HollowDurations.fast,
              child: Icon(LucideIcons.chevronRight,
                  size: 16, color: hollow.textTertiary),
            ),
          ],
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.only(
          left: indented ? HollowSpacing.lg : 0, bottom: HollowSpacing.xxs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          row,
          // Opening a channel switches what the region shows: instant.
          if (open)
            _ChannelPanel(
              serverId: serverId,
              channel: channel,
              labels: labels,
              grants: grants,
            ),
        ],
      ),
    );
  }
}

/// Everything about one channel, raised under its row. Each control writes at
/// once over an optimistic update, reverting if the write fails.
class _ChannelPanel extends ConsumerWidget {
  final String serverId;
  final ChannelInfo channel;
  final List<crdt_api.LabelFfi> labels;
  final int grants;

  const _ChannelPanel({
    required this.serverId,
    required this.channel,
    required this.labels,
    required this.grants,
  });

  String get _id => channel.channelId;

  /// Updates the row now and commits; [revert] undoes the update on failure.
  Future<void> _commit(BuildContext context, WidgetRef ref,
      ChannelInfo Function(ChannelInfo) apply,
      Future<void> Function() write) async {
    final list = ref.read(channelListProvider.notifier);
    final before = ref.read(channelListProvider)[_id];
    list.updateChannel(_id, apply);
    try {
      await write();
    } catch (_) {
      if (before != null) list.updateChannel(_id, (_) => before);
      if (context.mounted) {
        HollowToast.show(context, 'Could not update the channel',
            type: HollowToastType.error);
      }
    }
  }

  /// A plain tier on a label-gated channel widens who gets in, so ask first.
  Future<bool> _confirmClearLabels(BuildContext context) =>
      showHollowConfirm(
        context: context,
        title: 'Stop using labels here?',
        message: '#${channel.name} will go by role again, and its access '
            'labels stop counting.',
        confirmLabel: 'Stop using labels',
      );

  Future<void> _setTier(BuildContext context, WidgetRef ref, String tier,
      {required bool see}) async {
    final hadLabels =
        see ? channel.visibilityLabels.isNotEmpty : channel.postingLabels.isNotEmpty;
    if (hadLabels && !await _confirmClearLabels(context)) return;
    if (!context.mounted) return;
    await _commit(
      context,
      ref,
      // Rust's tier handler clears a label gate too.
      (ch) => see
          ? ch.copyWith(visibility: tier, visibilityLabels: const [])
          : ch.copyWith(posting: tier, postingLabels: const []),
      () => see
          ? crdt_api.setChannelVisibility(
              serverId: serverId, channelId: _id, visibility: tier)
          : crdt_api.setChannelPosting(
              serverId: serverId, channelId: _id, posting: tier),
    );
  }

  Future<void> _pickLabels(BuildContext context, WidgetRef ref,
      {required bool see}) async {
    final initial = see ? channel.visibilityLabels : channel.postingLabels;
    final picked = await showAccessLabelPicker(
      context: context,
      serverId: serverId,
      gate: see ? AccessLabelGate.see : AccessLabelGate.post,
      target: '#${channel.name}',
      initial: initial.toSet(),
    );
    if (picked == null || !context.mounted) return;
    final ids = picked.toList();
    await _commit(
      context,
      ref,
      // Mirrors the Rust handler's stamp for old clients.
      (ch) => see
          ? ch.copyWith(
              visibilityLabels: ids,
              visibility: ids.isEmpty ? ch.visibility : 'admin')
          : ch.copyWith(
              postingLabels: ids,
              posting: ids.isEmpty ? ch.posting : 'admin'),
      () => see
          ? crdt_api.setChannelVisibilityLabels(
              serverId: serverId, channelId: _id, labels: ids)
          : crdt_api.setChannelPostingLabels(
              serverId: serverId, channelId: _id, labels: ids),
    );
  }

  void _rename(BuildContext context, WidgetRef ref) {
    final channels = ref.read(channelListProvider.notifier);
    promptForName(
      context: context,
      title: 'Rename channel',
      hintText: 'Channel name',
      initial: channel.name,
      confirmLabel: 'Rename',
      onSubmit: (name) async {
        if (name == channel.name) return;
        await crdt_api.renameChannel(
            serverId: serverId, channelId: _id, newName: name);
        channels.onChannelRenamed(serverId, _id, name);
      },
    );
  }

  Future<void> _delete(BuildContext context) => confirmDeleteChannel(
        context,
        serverId: serverId,
        channelId: _id,
        channelName: channel.name,
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final voice = channel.channelType == ChannelType.voice;
    return Container(
      margin: const EdgeInsets.only(top: HollowSpacing.xxs, bottom: HollowSpacing.sm),
      padding: const EdgeInsets.fromLTRB(
          HollowSpacing.lg, HollowSpacing.xs, HollowSpacing.lg, HollowSpacing.md),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SettingsRow(
            title: 'Who can see it',
            trailing: ChannelAccessPicker(
              icon: LucideIcons.eye,
              semanticLabel: 'Who can see #${channel.name}',
              value: channel.visibility,
              gateLabels: channel.visibilityLabels,
              allLabels: labels,
              onChanged: (t) => _setTier(context, ref, t, see: true),
              onCustomPressed: () => _pickLabels(context, ref, see: true),
            ),
          ),
          // Posting, slow mode, media-only and public are text-only: Rust
          // never consults them for a voice join, and rejects a public one.
          if (!voice) ...[
            SettingsRow(
              title: 'Who can post',
              trailing: ChannelAccessPicker(
                icon: LucideIcons.messageSquare,
                semanticLabel: 'Who can post in #${channel.name}',
                value: channel.posting,
                gateLabels: channel.postingLabels,
                allLabels: labels,
                onChanged: (t) => _setTier(context, ref, t, see: false),
                onCustomPressed: () => _pickLabels(context, ref, see: false),
              ),
            ),
            SettingsRow(
              title: 'Slow mode',
              subtitle: "The wait between one person's messages",
              trailing: SlowModePicker(
                seconds: channel.slowModeSecs,
                onChanged: (s) => _commit(
                  context,
                  ref,
                  (ch) => ch.copyWith(slowModeSecs: s),
                  () => crdt_api.setChannelSlowMode(
                      serverId: serverId, channelId: _id, seconds: s),
                ),
              ),
            ),
            SettingsSwitchRow(
              title: 'Media only',
              subtitle: 'Images, GIFs and videos, no text posts',
              value: channel.mediaOnly,
              onChanged: (v) => _commit(
                context,
                ref,
                (ch) => ch.copyWith(mediaOnly: v),
                () => crdt_api.setChannelMediaOnly(
                    serverId: serverId, channelId: _id, mediaOnly: v),
              ),
            ),
            SettingsSwitchRow(
              title: 'Public',
              subtitle: 'Anyone can read it without joining the server',
              value: channel.isPublic,
              onChanged: (v) => _commit(
                context,
                ref,
                (ch) => ch.copyWith(isPublic: v),
                () => crdt_api.setChannelPublic(
                    serverId: serverId, channelId: _id, isPublic: v),
              ),
            ),
          ],
          // A public channel has no gate to open.
          if (!channel.isPublic)
            SettingsRow(
              title: 'Temporary access',
              subtitle: grants == 0
                  ? 'Let one member in for a while, without a label'
                  : grants == 1
                      ? '1 member has it for now'
                      : '$grants members have it for now',
              trailing: HollowButton.ghost(
                compact: true,
                semanticLabel: 'Give temporary access to #${channel.name}',
                onPressed: () => showChannelGrantsDialog(
                  context,
                  serverId: serverId,
                  channelId: _id,
                  channelName: channel.name,
                ),
                child: const Text('Give access'),
              ),
            ),
          const SizedBox(height: HollowSpacing.sm),
          Row(
            children: [
              HollowButton.ghost(
                compact: true,
                semanticLabel: 'Rename #${channel.name}',
                onPressed: () => _rename(context, ref),
                child: const Text('Rename'),
              ),
              const Spacer(),
              HollowButton.outline(
                danger: true,
                compact: true,
                semanticLabel: 'Delete #${channel.name}',
                onPressed: () => _delete(context),
                child: const Text('Delete channel'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
