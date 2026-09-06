import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/label_visuals.dart';
import 'package:hollow/src/ui/components/member_search_picker.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Labels tab: everyone can self-assign, MANAGE_ROLES holders can manage.
class LabelsTab extends ConsumerStatefulWidget {
  final String serverId;

  const LabelsTab({super.key, required this.serverId});

  @override
  ConsumerState<LabelsTab> createState() => _LabelsTabState();
}

class _LabelsTabState extends ConsumerState<LabelsTab> {
  List<crdt_api.LabelFfi>? _labels;
  Set<String> _myLabelIds = {};

  @override
  void initState() {
    super.initState();
    _loadLabels();
  }

  Future<void> _loadLabels() async {
    try {
      final list = await crdt_api.getServerLabels(serverId: widget.serverId);
      final members = await crdt_api.getServerMembers(serverId: widget.serverId);
      final localPeerId = ref.read(identityProvider).peerId ?? '';
      final me = members.where((m) => m.peerId == localPeerId).firstOrNull;
      final myIds = me?.labels.map((l) => l.labelId).toSet() ?? <String>{};
      if (mounted) {
        setState(() {
          _labels = list;
          _myLabelIds = myIds;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _labels = []);
    }
  }

  Future<void> _toggleSelfLabel(String labelId) async {
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    if (localPeerId.isEmpty) return;
    final hasIt = _myLabelIds.contains(labelId);
    try {
      if (hasIt) {
        await crdt_api.unassignLabel(
          serverId: widget.serverId,
          labelId: labelId,
          peerId: localPeerId,
        );
        setState(() => _myLabelIds.remove(labelId));
      } else {
        await crdt_api.assignLabel(
          serverId: widget.serverId,
          labelId: labelId,
          peerId: localPeerId,
        );
        setState(() => _myLabelIds.add(labelId));
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
      }
    }
  }

  /// Creates or edits a label. The Cosmetic/Access choice is part of the same
  /// dialog: access labels gate channels and are staff-assignable only.
  void _showLabelDialog({crdt_api.LabelFfi? existing}) {
    var name = existing?.name ?? '';
    var selectedColor = existing != null
        ? parseLabelColor(existing.color)
        : kLabelPresetColors.first;
    var access = existing?.access ?? false;
    final nameController = TextEditingController(text: name);

    showHollowDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => HollowDialog(
          title: existing == null ? 'Create label' : 'Edit label',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HollowTextField(
                controller: nameController,
                hintText: 'Label name',
                autofocus: true,
                onChanged: (v) => name = v,
              ),
              const SizedBox(height: HollowSpacing.md),
              Text('Color', style: HollowTypography.label),
              const SizedBox(height: HollowSpacing.sm),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: kLabelPresetColors.map((c) {
                  final isSelected = c == selectedColor;
                  return HollowFocusRing(
                    enabled: true,
                    onActivate: () => setDialogState(() => selectedColor = c),
                    borderRadius: BorderRadius.circular(14),
                    child: GestureDetector(
                      onTap: () => setDialogState(() => selectedColor = c),
                      child: Container(
                        width: 28, height: 28,
                        decoration: BoxDecoration(
                          color: c, shape: BoxShape.circle,
                          border: isSelected
                              ? Border.all(color: Colors.white, width: 2) : null,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: HollowSpacing.md),
              Text('Type', style: HollowTypography.label),
              const SizedBox(height: HollowSpacing.sm),
              Row(
                children: [
                  LabelTypeChip(
                    icon: LucideIcons.tag,
                    text: 'Cosmetic',
                    selected: !access,
                    onTap: () => setDialogState(() => access = false),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  LabelTypeChip(
                    icon: LucideIcons.shieldCheck,
                    text: 'Access',
                    selected: access,
                    onTap: () => setDialogState(() => access = true),
                  ),
                ],
              ),
              const SizedBox(height: HollowSpacing.sm),
              Builder(builder: (ctx) {
                final hollow = HollowTheme.of(ctx);
                return Text(
                  access
                      ? 'Can gate channels; only staff can assign it.'
                      : 'Anyone can add it to their own profile.',
                  style: HollowTypography.bodySmall.copyWith(
                    color: hollow.textSecondary,
                  ),
                );
              }),
            ],
          ),
          actions: [
            HollowButton.ghost(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            HollowButton.filled(
              onPressed: () {
                Navigator.of(ctx).pop();
                _saveLabel(existing, name.trim(), selectedColor, access);
              },
              child: Text(existing == null ? 'Create' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveLabel(
      crdt_api.LabelFfi? existing, String name, Color color, bool access) async {
    if (name.isEmpty) return;
    try {
      final hex = '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
      if (existing == null) {
        await crdt_api.createLabel(
            serverId: widget.serverId, name: name, color: hex, access: access);
      } else {
        await crdt_api.updateLabel(
            serverId: widget.serverId,
            labelId: existing.labelId,
            name: name,
            color: hex,
            access: access);
      }
      await Future.delayed(const Duration(milliseconds: 100));
      _loadLabels();
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
      }
    }
  }

  Future<void> _deleteLabel(String labelId) async {
    try {
      await crdt_api.deleteLabel(serverId: widget.serverId, labelId: labelId);
      await Future.delayed(const Duration(milliseconds: 100));
      _loadLabels();
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
      }
    }
  }

  void _showAssignDialog(crdt_api.LabelFfi label) {
    showLabelAssignDialog(
      context,
      serverId: widget.serverId,
      label: label,
      onDone: _loadLabels,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    // Remote peers create and delete labels too.
    ref.listen(serverMembersProvider(widget.serverId), (_, _) => _loadLabels());

    final labels = _labels;
    final canManage =
        (ref.watch(myPermissionsProvider(widget.serverId)).valueOrNull ?? 0) &
            Permission.manageRoles != 0;

    if (labels == null) return const Center(child: CircularProgressIndicator());

    if (labels.isEmpty && !canManage) {
      return Center(
        child: Text(
          'No labels available yet',
          style: HollowTypography.body.copyWith(color: hollow.textSecondary),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.xl),
      children: [
        if (labels.isNotEmpty) ...[
          Text(
            'Pick your labels',
            style: HollowTypography.subheading.copyWith(
              color: hollow.textPrimary, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            'Tap to add or remove labels from your profile',
            style: HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.md),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: labels.map((l) {
              final selected = _myLabelIds.contains(l.labelId);
              // Access labels are staff-assigned, so activation ANNOUNCES why
              // instead of silently doing nothing.
              if (l.access) {
                return HollowTooltip(
                  message: 'Access labels are assigned by staff',
                  child: LabelChip(
                    label: l,
                    selected: selected,
                    locked: true,
                    onTap: () => HollowToast.show(
                        context, 'Access labels are assigned by staff'),
                  ),
                );
              }
              return LabelChip(
                label: l,
                selected: selected,
                onTap: () => _toggleSelfLabel(l.labelId),
              );
            }).toList(),
          ),
          const SizedBox(height: HollowSpacing.xl),
        ],

        if (canManage) ...[
          Row(
            children: [
              Icon(LucideIcons.settings, size: 16, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                'Manage Labels',
                style: HollowTypography.subheading.copyWith(
                  color: hollow.textPrimary, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              HollowButton.filled(
                compact: true,
                onPressed: _showLabelDialog,
                icon: const Icon(LucideIcons.plus),
                child: const Text('New'),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.md),
          if (labels.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(HollowSpacing.xl),
                child: Text(
                  'No labels yet. Create one to get started.',
                  style: HollowTypography.body.copyWith(color: hollow.textSecondary),
                ),
              ),
            )
          else
            for (final label in labels)
              Padding(
                padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.md, vertical: HollowSpacing.sm),
                  decoration: BoxDecoration(
                    color: hollow.elevated,
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 14, height: 14,
                        decoration: BoxDecoration(
                          color: parseLabelColor(label.color), shape: BoxShape.circle),
                      ),
                      if (label.access) ...[
                        const SizedBox(width: HollowSpacing.xs),
                        HollowTooltip(
                          message: 'Access label: gates channels',
                          child: Icon(LucideIcons.shieldCheck, size: 14,
                              color: parseLabelColor(label.color)),
                        ),
                      ],
                      const SizedBox(width: HollowSpacing.sm),
                      Expanded(
                        child: Text(
                          label.name,
                          style: HollowTypography.body.copyWith(
                            color: parseLabelColor(label.color),
                            fontWeight: FontWeight.w600),
                        ),
                      ),
                      HollowTooltip(
                        message: 'Assign to members',
                        child: HollowPressable(
                          semanticLabel: 'Assign to members',
                          onTap: () => _showAssignDialog(label),
                          borderRadius: BorderRadius.circular(hollow.radiusSm),
                          padding: const EdgeInsets.all(HollowSpacing.xs),
                          child: Icon(LucideIcons.userPlus, size: 14,
                              color: hollow.textSecondary),
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.xs),
                      HollowTooltip(
                        message: 'Edit label',
                        child: HollowPressable(
                          semanticLabel: 'Edit label',
                          onTap: () => _showLabelDialog(existing: label),
                          borderRadius: BorderRadius.circular(hollow.radiusSm),
                          padding: const EdgeInsets.all(HollowSpacing.xs),
                          child: Icon(LucideIcons.pencil, size: 14,
                              color: hollow.textSecondary),
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.xs),
                      HollowTooltip(
                        message: 'Delete label',
                        child: HollowPressable(
                          semanticLabel: 'Delete label',
                          onTap: () => _deleteLabel(label.labelId),
                          borderRadius: BorderRadius.circular(hollow.radiusSm),
                          padding: const EdgeInsets.all(HollowSpacing.xs),
                          child: Icon(LucideIcons.trash2, size: 14,
                              color: hollow.error),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ],
    );
  }
}

/// Opens the "Assign <label>" member picker. Public so the widget tests and the
/// screenshot harness can drive it without pumping the whole Labels tab, whose
/// load path calls FFI directly.
Future<void> showLabelAssignDialog(
  BuildContext context, {
  required String serverId,
  required crdt_api.LabelFfi label,
  VoidCallback? onDone,
}) {
  return showHollowDialog(
    context: context,
    builder: (_) => _AssignDialog(
      serverId: serverId,
      label: label,
      onDone: onDone ?? () {},
    ),
  );
}

class _AssignDialog extends ConsumerStatefulWidget {
  final String serverId;
  final crdt_api.LabelFfi label;
  final VoidCallback onDone;

  const _AssignDialog({
    required this.serverId,
    required this.label,
    required this.onDone,
  });

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
    _loadAssignments();
  }

  void _loadAssignments() {
    final membersAsync = ref.read(serverMembersProvider(widget.serverId));
    membersAsync.whenData(_seedAssignments);
  }

  void _seedAssignments(List<crdt_api.MemberFfi> members) {
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
          peerId: peerId,
        );
        setState(() => _assignedPeerIds.remove(peerId));
      } else {
        await crdt_api.assignLabel(
          serverId: widget.serverId,
          labelId: widget.label.labelId,
          peerId: peerId,
        );
        setState(() => _assignedPeerIds.add(peerId));
      }
      ref.invalidate(serverMembersProvider(widget.serverId));
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final membersAsync = ref.watch(serverMembersProvider(widget.serverId));
    final profiles = ref.watch(profileProvider);
    final color = parseLabelColor(widget.label.color);

    // Members may still be loading when the dialog opens, so the first data to
    // arrive is what seeds the checkmarks.
    ref.listen(serverMembersProvider(widget.serverId), (_, next) {
      next.whenData(_seedAssignments);
    });

    return HollowDialog(
      title: 'Assign "${widget.label.name}"',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tap a member to add or remove the label. Changes apply '
            'immediately.',
            style: HollowTypography.bodySmall.copyWith(
              color: hollow.textSecondary,
            ),
          ),
          const SizedBox(height: HollowSpacing.lg),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(HollowSpacing.lg),
            decoration: BoxDecoration(
              color: hollow.surface.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              border: Border.all(color: hollow.border),
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
                    semanticLabel: isAssigned ? 'Assigned' : 'Not assigned',
                  );
                },
                onTapMember: (m) => _toggle(m.peerId),
              ),
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: HollowSpacing.lg),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Text('Error: $e'),
            ),
          ),
        ],
      ),
      actions: [
        HollowButton.filled(
          onPressed: () {
            widget.onDone();
            Navigator.of(context).pop();
          },
          child: const Text('Done'),
        ),
      ],
    );
  }
}
