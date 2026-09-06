import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/label_visuals.dart';
import 'package:hollow/src/ui/components/member_search_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class MobileLabelsRoute extends ConsumerStatefulWidget {
  final String serverId;

  const MobileLabelsRoute({super.key, required this.serverId});

  @override
  ConsumerState<MobileLabelsRoute> createState() => _MobileLabelsRouteState();
}

class _MobileLabelsRouteState extends ConsumerState<MobileLabelsRoute> {
  List<crdt_api.LabelFfi> _labels = [];
  List<crdt_api.MemberFfi> _members = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final labels = await crdt_api.getServerLabels(serverId: widget.serverId);
      final members = await crdt_api.getServerMembers(serverId: widget.serverId);
      if (mounted) {
        setState(() {
          _labels = labels;
          _members = members;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final perms = ref.watch(myPermissionsProvider(widget.serverId)).valueOrNull ?? 0;
    final canManage = (perms & Permission.manageRoles) != 0;
    final myPeerId = ref.watch(identityProvider).peerId ?? '';

    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm, vertical: HollowSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: hollow.surface,
                border: Border(bottom: BorderSide(color: hollow.border)),
              ),
              child: Row(
                children: [
                  HollowPressable(
                    onTap: () => Navigator.pop(context),
                    semanticLabel: 'Back',
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                    padding: const EdgeInsets.all(HollowSpacing.sm),
                    child: Icon(LucideIcons.arrowLeft, size: 22, color: hollow.textPrimary),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Text('Labels', style: HollowTypography.heading.copyWith(
                      color: hollow.textPrimary,
                    )),
                  ),
                  if (canManage)
                    HollowPressable(
                      onTap: () => _showLabelDialog(context),
                      semanticLabel: 'Create label',
                      borderRadius: BorderRadius.circular(hollow.radiusMd),
                      padding: const EdgeInsets.all(HollowSpacing.sm),
                      child: Icon(LucideIcons.plus, size: 22, color: hollow.accent),
                    ),
                ],
              ),
            ),

            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _labels.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(LucideIcons.tag, size: 40,
                                  color: hollow.textSecondary.withValues(alpha: 0.4)),
                              const SizedBox(height: HollowSpacing.md),
                              Text('No labels yet',
                                  style: HollowTypography.body.copyWith(
                                    color: hollow.textSecondary,
                                  )),
                            ],
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.all(HollowSpacing.lg),
                          children: [
                            _SelfAssignSection(
                              labels: _labels,
                              members: _members,
                              myPeerId: myPeerId,
                              serverId: widget.serverId,
                              onReload: _reload,
                            ),

                            if (canManage) ...[
                              const SizedBox(height: HollowSpacing.xl),
                              _ManageSection(
                                labels: _labels,
                                members: _members,
                                serverId: widget.serverId,
                                onReload: _reload,
                                onEdit: (label) => _showLabelDialog(
                                    context, existing: label),
                              ),
                            ],
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }

  /// Creates a label, or edits [existing]. Access labels gate channels and are
  /// staff-assigned only.
  void _showLabelDialog(BuildContext context, {crdt_api.LabelFfi? existing}) {
    final nameController = TextEditingController(text: existing?.name ?? '');
    var selectedColor = existing != null
        ? parseLabelColor(existing.color)
        : kLabelPresetColors[5]; // default blue
    var access = existing?.access ?? false;

    showHollowDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final hollow = HollowTheme.of(ctx);
          return HollowDialog(
            title: existing == null ? 'New Label' : 'Edit Label',
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HollowTextField(
                  controller: nameController,
                  hintText: 'Label name',
                  maxLength: 24,
                  showCounter: true,
                  autofocus: true,
                ),
                const SizedBox(height: HollowSpacing.lg),
                Text('Color', style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                )),
                const SizedBox(height: HollowSpacing.sm),
                Wrap(
                  spacing: HollowSpacing.sm,
                  runSpacing: HollowSpacing.sm,
                  children: kLabelPresetColors.map((c) => GestureDetector(
                    onTap: () => setDialogState(() => selectedColor = c),
                    child: Container(
                      width: 32, height: 32,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: c == selectedColor
                            ? Border.all(color: Colors.white, width: 2)
                            : null,
                      ),
                    ),
                  )).toList(),
                ),
                const SizedBox(height: HollowSpacing.lg),
                Text('Type', style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                )),
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
                Text(
                  access
                      ? 'Can gate channels; only staff can assign it.'
                      : 'Anyone can add it to their own profile.',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                  ),
                ),
              ],
            ),
            actions: [
              HollowButton.ghost(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              HollowButton.filled(
                onPressed: () async {
                  final name = nameController.text.trim();
                  if (name.isEmpty) return;
                  Navigator.pop(ctx);
                  try {
                    final hex = '#${selectedColor.toARGB32().toRadixString(16).substring(2)}';
                    if (existing == null) {
                      await crdt_api.createLabel(
                        serverId: widget.serverId, name: name, color: hex,
                        access: access,
                      );
                    } else {
                      await crdt_api.updateLabel(
                        serverId: widget.serverId, labelId: existing.labelId,
                        name: name, color: hex, access: access,
                      );
                    }
                    await _reload();
                    // `context` is the helper's parameter, not this State's, so
                    // the guard has to name the element used for the toast.
                    if (context.mounted) {
                      HollowToast.show(context,
                          existing == null ? 'Label created' : 'Label updated',
                          type: HollowToastType.success);
                    }
                  } catch (e) {
                    if (context.mounted) {
                      HollowToast.show(context, 'Failed to save label',
                          type: HollowToastType.error);
                    }
                  }
                },
                child: Text(existing == null ? 'Create' : 'Save'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SelfAssignSection extends StatelessWidget {
  final List<crdt_api.LabelFfi> labels;
  final List<crdt_api.MemberFfi> members;
  final String myPeerId;
  final String serverId;
  final VoidCallback onReload;

  const _SelfAssignSection({
    required this.labels,
    required this.members,
    required this.myPeerId,
    required this.serverId,
    required this.onReload,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final myMember = members.where((m) => m.peerId == myPeerId).firstOrNull;
    final myLabelIds = myMember?.labels.map((l) => l.labelId).toSet() ?? <String>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Your Labels', style: HollowTypography.body.copyWith(
          color: hollow.textSecondary, fontWeight: FontWeight.w600,
        )),
        const SizedBox(height: HollowSpacing.sm),
        Text('Tap to toggle labels on yourself.',
            style: HollowTypography.caption.copyWith(color: hollow.textSecondary)),
        const SizedBox(height: HollowSpacing.md),
        Wrap(
          spacing: HollowSpacing.sm,
          runSpacing: HollowSpacing.sm,
          children: labels.map((label) {
            final color = parseLabelColor(label.color);
            final isAssigned = myLabelIds.contains(label.labelId);
            // Access labels are staff-assigned, so activation says why rather
            // than silently doing nothing.
            if (label.access) {
              return LabelChip(
                label: label,
                selected: isAssigned,
                locked: true,
                onTap: () => HollowToast.show(
                    context, 'Access labels are assigned by staff'),
              );
            }
            return HollowPressable(
              onTap: () async {
                try {
                  if (isAssigned) {
                    await crdt_api.unassignLabel(
                      serverId: serverId, labelId: label.labelId, peerId: myPeerId,
                    );
                  } else {
                    await crdt_api.assignLabel(
                      serverId: serverId, labelId: label.labelId, peerId: myPeerId,
                    );
                  }
                  onReload();
                } catch (_) {
                  if (context.mounted) {
                    HollowToast.show(context, 'Could not update label',
                        type: HollowToastType.error);
                  }
                }
              },
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.md, vertical: HollowSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: isAssigned ? color.withValues(alpha: 0.2) : Colors.transparent,
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  border: Border.all(
                    color: isAssigned ? color : color.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isAssigned ? LucideIcons.check : LucideIcons.circle,
                      size: 14, color: color,
                    ),
                    const SizedBox(width: HollowSpacing.xs),
                    // A free-form label name overflows the chip Row at a high
                    // text scale unless it ellipsizes.
                    Flexible(
                      child: Text(label.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HollowTypography.bodySmall.copyWith(
                            color: color, fontWeight: FontWeight.w500,
                          )),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _ManageSection extends ConsumerWidget {
  final List<crdt_api.LabelFfi> labels;
  final List<crdt_api.MemberFfi> members;
  final String serverId;
  final VoidCallback onReload;
  final void Function(crdt_api.LabelFfi) onEdit;

  const _ManageSection({
    required this.labels,
    required this.members,
    required this.serverId,
    required this.onReload,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Manage Labels', style: HollowTypography.body.copyWith(
          color: hollow.textSecondary, fontWeight: FontWeight.w600,
        )),
        const SizedBox(height: HollowSpacing.md),
        for (final label in labels) ...[
          Container(
            margin: const EdgeInsets.only(bottom: HollowSpacing.sm),
            padding: const EdgeInsets.all(HollowSpacing.md),
            decoration: BoxDecoration(
              color: hollow.surface,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              border: Border.all(color: hollow.border),
            ),
            child: Row(
              children: [
                Container(
                  width: 16, height: 16,
                  decoration: BoxDecoration(
                    color: parseLabelColor(label.color),
                    shape: BoxShape.circle,
                  ),
                ),
                if (label.access) ...[
                  const SizedBox(width: HollowSpacing.xs),
                  Icon(LucideIcons.shieldCheck, size: 15,
                      color: parseLabelColor(label.color)),
                ],
                const SizedBox(width: HollowSpacing.md),
                Expanded(
                  child: Text(label.name, style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                  )),
                ),
                HollowPressable(
                  onTap: () => _showAssignDialog(context, ref, label),
                  semanticLabel: 'Assign label to members',
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Icon(LucideIcons.userPlus, size: 16, color: hollow.textSecondary),
                ),
                const SizedBox(width: HollowSpacing.xs),
                HollowPressable(
                  onTap: () => onEdit(label),
                  semanticLabel: 'Edit label',
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Icon(LucideIcons.pencil, size: 16, color: hollow.textSecondary),
                ),
                const SizedBox(width: HollowSpacing.xs),
                HollowPressable(
                  onTap: () => _deleteLabel(context, label),
                  semanticLabel: 'Delete label',
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Icon(LucideIcons.trash2, size: 16, color: hollow.error),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _deleteLabel(BuildContext context, crdt_api.LabelFfi label) async {
    try {
      await crdt_api.deleteLabel(serverId: serverId, labelId: label.labelId);
      onReload();
      if (context.mounted) {
        HollowToast.show(context, 'Label deleted', type: HollowToastType.success);
      }
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(context, 'Failed to delete', type: HollowToastType.error);
      }
    }
  }

  void _showAssignDialog(BuildContext context, WidgetRef ref, crdt_api.LabelFfi label) {
    showHollowDialog(
      context: context,
      builder: (_) => _AssignDialog(
        label: label,
        members: members,
        serverId: serverId,
        onReload: onReload,
      ),
    );
  }
}

class _AssignDialog extends ConsumerStatefulWidget {
  final crdt_api.LabelFfi label;
  final List<crdt_api.MemberFfi> members;
  final String serverId;
  final VoidCallback onReload;

  const _AssignDialog({
    required this.label,
    required this.members,
    required this.serverId,
    required this.onReload,
  });

  @override
  ConsumerState<_AssignDialog> createState() => _AssignDialogState();
}

class _AssignDialogState extends ConsumerState<_AssignDialog> {
  final Set<String> _assigned = {};

  @override
  void initState() {
    super.initState();
    for (final m in widget.members) {
      if (m.labels.any((l) => l.labelId == widget.label.labelId)) {
        _assigned.add(m.peerId);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final color = parseLabelColor(widget.label.color);

    return HollowDialog(
      title: 'Assign "${widget.label.name}"',
      content: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(HollowSpacing.lg),
        decoration: BoxDecoration(
          color: hollow.surface.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          border: Border.all(color: hollow.border),
        ),
        child: MemberSearchPicker(
          members: widget.members,
          maxListHeight: 300,
          nameOf: (m) => displayNameFor(profiles, m.peerId),
          trailingOf: (m) {
            final isAssigned = _assigned.contains(m.peerId);
            return Icon(
              isAssigned ? LucideIcons.checkSquare : LucideIcons.square,
              size: 20,
              color: isAssigned ? color : hollow.textSecondary,
              semanticLabel: isAssigned ? 'Assigned' : 'Not assigned',
            );
          },
          onTapMember: (m) => _toggle(m.peerId),
        ),
      ),
      actions: [
        HollowButton.filled(
          onPressed: () {
            Navigator.pop(context);
            widget.onReload();
          },
          child: const Text('Done'),
        ),
      ],
    );
  }

  Future<void> _toggle(String peerId) async {
    final isAssigned = _assigned.contains(peerId);
    setState(() {
      if (isAssigned) {
        _assigned.remove(peerId);
      } else {
        _assigned.add(peerId);
      }
    });
    try {
      if (isAssigned) {
        await crdt_api.unassignLabel(
          serverId: widget.serverId, labelId: widget.label.labelId, peerId: peerId,
        );
      } else {
        await crdt_api.assignLabel(
          serverId: widget.serverId, labelId: widget.label.labelId, peerId: peerId,
        );
      }
      ref.invalidate(serverMembersProvider(widget.serverId));
    } catch (_) {
      setState(() {
        if (isAssigned) {
          _assigned.add(peerId);
        } else {
          _assigned.remove(peerId);
        }
      });
    }
  }
}
