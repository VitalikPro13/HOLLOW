import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_text_link.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/label_visuals.dart';
import 'package:hollow/src/ui/components/member_search_picker.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The server's labels, for staff to make and hand out. Wearing a label is on
/// the You group's Profile page.
class LabelsPage extends ConsumerWidget {
  final String serverId;
  const LabelsPage({super.key, required this.serverId});

  /// "Access · opens #patreon-lounge · 3 members".
  String _subtitle(crdt_api.LabelFfi label, Map<String, ChannelInfo> channels,
      List<crdt_api.MemberFfi> members) {
    final count = members
        .where((m) => m.labels.any((l) => l.labelId == label.labelId))
        .length;
    final people = '$count ${count == 1 ? 'member' : 'members'}';
    if (!label.access) return 'Anyone can wear it · $people';
    final opens = [
      for (final ch in channels.values)
        if (ch.visibilityLabels.contains(label.labelId)) '#${ch.name}',
    ];
    final where = switch (opens.length) {
      0 => 'no channels yet',
      1 => 'opens ${opens.first}',
      _ => 'opens ${opens.length} channels',
    };
    return 'Access · $where · $people';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final labelsAsync = ref.watch(serverLabelsProvider(serverId));
    final members =
        ref.watch(serverMembersProvider(serverId)).valueOrNull ?? const [];
    final channels = ref.watch(channelListProvider);
    final labels = labelsAsync.valueOrNull;

    return SettingsPage(
      title: 'Labels',
      intro: 'An access label opens restricted channels, and only staff hand '
          'it out. Anyone can wear the others.',
      children: [
        SettingsSection(
          title: 'Labels',
          count: labels == null ? null : '${labels.length}',
          action: HollowButton.ghost(
            compact: true,
            icon: const Icon(LucideIcons.plus),
            onPressed: () => showLabelEditDialog(context, serverId: serverId),
            child: const Text('New label'),
          ),
          children: [
            if (labels == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: HollowSpacing.lg),
                child: Center(child: HollowSpinner.medium()),
              )
            else if (labels.isEmpty)
              const HollowEmptyState(
                dense: true,
                title: 'No labels yet',
                description: 'New label makes the first one.',
              )
            else
              for (final label in labels)
                SettingsRow(
                  key: ValueKey(label.labelId),
                  title: label.name,
                  subtitle: _subtitle(label, channels, members),
                  leading: LabelDot(color: parseLabelColor(label.color)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      HollowButton.ghost(
                        compact: true,
                        semanticLabel: 'Give ${label.name} to members',
                        onPressed: () => showLabelAssignDialog(context,
                            serverId: serverId, label: label),
                        child: const Text('Give to members'),
                      ),
                      const SizedBox(width: HollowSpacing.xs),
                      Builder(
                        builder: (buttonContext) => HollowIconButton(
                          icon: LucideIcons.moreHorizontal,
                          label: 'More for ${label.name}',
                          onPressed: () => showHollowMenu(
                            context: buttonContext,
                            alignEnd: true,
                            anchor: overlayAnchorOf(buttonContext,
                                localOffset: Offset(
                                    buttonContext.size?.width ?? 0,
                                    buttonContext.size?.height ?? 0)),
                            builder: (_, _) => [
                              HollowMenuItem(
                                icon: LucideIcons.pencil,
                                label: 'Edit',
                                onTap: () => showLabelEditDialog(context,
                                    serverId: serverId, existing: label),
                              ),
                              HollowMenuItem(
                                icon: LucideIcons.trash2,
                                label: 'Delete',
                                isDanger: true,
                                onTap: () =>
                                    _delete(context, ref, label),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
        Text.rich(
          TextSpan(
            style: HollowTypography.bodySmall
                .copyWith(color: hollow.textSecondary),
            children: [
              const TextSpan(text: 'Wearing labels yourself lives in '),
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: HollowTextLink(
                  'Profile',
                  onTap: () => ref
                      .read(serverSettingsPageProvider.notifier)
                      .state = ServerSettingsPage.profile,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _delete(
      BuildContext context, WidgetRef ref, crdt_api.LabelFfi label) async {
    final ok = await showHollowConfirm(
      context: context,
      title: 'Delete ${label.name}?',
      message: "Everyone wearing it loses it. This can't be undone.",
      confirmLabel: 'Delete label',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    try {
      await crdt_api.deleteLabel(serverId: serverId, labelId: label.labelId);
      await Future.delayed(const Duration(milliseconds: 100));
      ref.invalidate(serverLabelsProvider(serverId));
      ref.invalidate(serverMembersProvider(serverId));
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(context, 'Could not delete the label: $e',
            type: HollowToastType.error);
      }
    }
  }
}

/// A label's colour, as a 12 px dot beside its name.
class LabelDot extends StatelessWidget {
  final Color color;
  const LabelDot({super.key, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// Makes a label, or edits [existing]. Access labels gate channels and only
/// staff can hand them out.
void showLabelEditDialog(BuildContext context,
    {required String serverId, crdt_api.LabelFfi? existing}) {
  showHollowDialog(
    context: context,
    builder: (_) => _LabelEditDialog(serverId: serverId, existing: existing),
  );
}

class _LabelEditDialog extends ConsumerStatefulWidget {
  final String serverId;
  final crdt_api.LabelFfi? existing;
  const _LabelEditDialog({required this.serverId, this.existing});

  @override
  ConsumerState<_LabelEditDialog> createState() => _LabelEditDialogState();
}

class _LabelEditDialogState extends ConsumerState<_LabelEditDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late Color _color = widget.existing != null
      ? parseLabelColor(widget.existing!.color)
      : kLabelPresetColors.first;
  late bool _access = widget.existing?.access ?? false;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() => _busy = true);
    final hex =
        '#${_color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
    try {
      final existing = widget.existing;
      if (existing == null) {
        await crdt_api.createLabel(
            serverId: widget.serverId,
            name: name,
            color: hex,
            access: _access);
      } else {
        await crdt_api.updateLabel(
            serverId: widget.serverId,
            labelId: existing.labelId,
            name: name,
            color: hex,
            access: _access);
      }
      await Future.delayed(const Duration(milliseconds: 100));
      ref.invalidate(serverLabelsProvider(widget.serverId));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      HollowToast.show(context, 'Could not save the label: $e',
          type: HollowToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowDialog(
      title: widget.existing == null ? 'New label' : 'Edit label',
      width: 420,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HollowTextField(
            controller: _name,
            hintText: 'Label name',
            autofocus: true,
            maxLength: 32,
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: HollowSpacing.md),
          const SettingsFieldLabel(label: 'Colour'),
          const SizedBox(height: HollowSpacing.sm),
          Wrap(
            spacing: HollowSpacing.sm,
            runSpacing: HollowSpacing.sm,
            children: [
              for (final c in kLabelPresetColors)
                HollowFocusRing(
                  enabled: true,
                  onActivate: () => setState(() => _color = c),
                  borderRadius: BorderRadius.circular(hollow.radiusXl),
                  child: Semantics(
                    button: true,
                    selected: c == _color,
                    label: 'Label colour',
                    child: GestureDetector(
                      onTap: () => setState(() => _color = c),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: c == _color
                              ? Border.all(color: hollow.textPrimary, width: 2)
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: HollowSpacing.md),
          const SettingsFieldLabel(label: 'Kind'),
          const SizedBox(height: HollowSpacing.sm),
          Row(
            children: [
              LabelTypeChip(
                icon: LucideIcons.tag,
                text: 'Anyone can wear it',
                selected: !_access,
                onTap: () => setState(() => _access = false),
              ),
              const SizedBox(width: HollowSpacing.sm),
              LabelTypeChip(
                icon: LucideIcons.lock,
                text: 'Access',
                selected: _access,
                onTap: () => setState(() => _access = true),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            _access
                ? 'It can open restricted channels, and only staff hand it out.'
                : 'Anyone here can wear it on their profile.',
            style:
                HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          loading: _busy,
          onPressed: _save,
          child: Text(widget.existing == null ? 'Create' : 'Save'),
        ),
      ],
    );
  }
}

/// Opens the "Give <label>" member picker. Public so the widget tests and the
/// screenshot harness can drive it without pumping the whole page.
Future<void> showLabelAssignDialog(
  BuildContext context, {
  required String serverId,
  required crdt_api.LabelFfi label,
  VoidCallback? onDone,
}) {
  return showHollowDialog(
    context: context,
    builder: (_) => _AssignDialog(serverId: serverId, label: label),
  ).then((_) => onDone?.call());
}

class _AssignDialog extends ConsumerStatefulWidget {
  final String serverId;
  final crdt_api.LabelFfi label;

  const _AssignDialog({required this.serverId, required this.label});

  @override
  ConsumerState<_AssignDialog> createState() => _AssignDialogState();
}

class _AssignDialogState extends ConsumerState<_AssignDialog> {
  Set<String> _assignedPeerIds = {};

  /// Seeded ONCE from the first member data and never re-derived: the refetch
  /// after a toggle races the queued CRDT write and returns the PREVIOUS value,
  /// which would visually revert the optimistic toggle.
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    ref.read(serverMembersProvider(widget.serverId)).whenData(_seed);
  }

  void _seed(List<crdt_api.MemberFfi> members) {
    if (_seeded) return;
    _seeded = true;
    final assigned = <String>{
      for (final m in members)
        if (m.labels.any((l) => l.labelId == widget.label.labelId)) m.peerId,
    };
    if (mounted) setState(() => _assignedPeerIds = assigned);
  }

  Future<void> _toggle(String peerId) async {
    final isAssigned = _assignedPeerIds.contains(peerId);
    try {
      if (isAssigned) {
        await crdt_api.unassignLabel(
            serverId: widget.serverId,
            labelId: widget.label.labelId,
            peerId: peerId);
        setState(() => _assignedPeerIds.remove(peerId));
      } else {
        await crdt_api.assignLabel(
            serverId: widget.serverId,
            labelId: widget.label.labelId,
            peerId: peerId);
        setState(() => _assignedPeerIds.add(peerId));
      }
      ref.invalidate(serverMembersProvider(widget.serverId));
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Could not change that: $e',
            type: HollowToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final membersAsync = ref.watch(serverMembersProvider(widget.serverId));
    final profiles = ref.watch(profileProvider);
    final color = parseLabelColor(widget.label.color);

    // Members may still be loading when the dialog opens.
    ref.listen(serverMembersProvider(widget.serverId), (_, next) {
      next.whenData(_seed);
    });

    return HollowDialog(
      title: 'Give ${widget.label.name}',
      showClose: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HollowDialogText(
              'Tap a member to give or take the label. Changes apply at once.'),
          const SizedBox(height: HollowSpacing.lg),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(HollowSpacing.lg),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
            ),
            child: membersAsync.when(
              data: (members) => MemberSearchPicker(
                members: members,
                maxListHeight: 280,
                nameOf: (m) => serverDisplayNameFor(profiles, m.peerId,
                    nickname: m.nickname),
                trailingOf: (m) {
                  final isAssigned = _assignedPeerIds.contains(m.peerId);
                  return Icon(
                    isAssigned ? LucideIcons.checkSquare : LucideIcons.square,
                    size: 20,
                    color: isAssigned ? color : hollow.textSecondary,
                    semanticLabel: isAssigned ? 'Has it' : 'Does not have it',
                  );
                },
                onTapMember: (m) => _toggle(m.peerId),
              ),
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: HollowSpacing.lg),
                child: Center(child: HollowSpinner.large()),
              ),
              error: (e, _) => Text('Could not load the members: $e',
                  style: HollowTypography.body.copyWith(color: hollow.error)),
            ),
          ),
        ],
      ),
    );
  }
}
