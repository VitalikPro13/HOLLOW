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
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:lucide_icons/lucide_icons.dart';

const _presetColors = <Color>[
  Color(0xFFEF4444), Color(0xFFF97316), Color(0xFFEAB308),
  Color(0xFF22C55E), Color(0xFF06B6D4), Color(0xFF3B82F6),
  Color(0xFF8B5CF6), Color(0xFFEC4899), Color(0xFF78909C),
];

Color _parseColor(String hex) {
  final cleaned = hex.replaceAll('#', '');
  if (cleaned.length == 6) return Color(int.parse('FF$cleaned', radix: 16));
  return const Color(0xFF78909C);
}

/// Labels tab — everyone can self-assign labels, MANAGE_ROLES holders can create/delete/manage.
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

  void _showCreateDialog() {
    var name = '';
    var selectedColor = _presetColors.first;

    showHollowDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => HollowDialog(
          title: 'Create Label',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HollowTextField(
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
                children: _presetColors.map((c) {
                  final isSelected = c == selectedColor;
                  return GestureDetector(
                    onTap: () => setDialogState(() => selectedColor = c),
                    child: Container(
                      width: 28, height: 28,
                      decoration: BoxDecoration(
                        color: c, shape: BoxShape.circle,
                        border: isSelected
                            ? Border.all(color: Colors.white, width: 2) : null,
                      ),
                    ),
                  );
                }).toList(),
              ),
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
                _createLabel(name.trim(), selectedColor);
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createLabel(String name, Color color) async {
    if (name.isEmpty) return;
    try {
      final hex = '#${color.value.toRadixString(16).padLeft(8, '0').substring(2)}';
      await crdt_api.createLabel(serverId: widget.serverId, name: name, color: hex);
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
    showHollowDialog(
      context: context,
      builder: (ctx) => _AssignDialog(
        serverId: widget.serverId,
        label: label,
        onDone: _loadLabels,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    // Reload when server state updates from remote peers (create/delete labels)
    ref.listen(serverMembersProvider(widget.serverId), (_, __) => _loadLabels());

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
        // Self-assign section — visible to everyone
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
              final c = _parseColor(l.color);
              final selected = _myLabelIds.contains(l.labelId);
              return GestureDetector(
                onTap: () => _toggleSelfLabel(l.labelId),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: selected ? c.withValues(alpha: 0.25) : hollow.elevated,
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                    border: Border.all(
                      color: selected ? c : hollow.border,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        selected ? LucideIcons.check : LucideIcons.circle,
                        size: 12,
                        color: c,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        l.name,
                        style: HollowTypography.body.copyWith(
                          color: selected ? c : hollow.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: HollowSpacing.xl),
        ],

        // Management section — MANAGE_ROLES only
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
                onPressed: _showCreateDialog,
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
                          color: _parseColor(label.color), shape: BoxShape.circle),
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      Expanded(
                        child: Text(
                          label.name,
                          style: HollowTypography.body.copyWith(
                            color: _parseColor(label.color),
                            fontWeight: FontWeight.w600),
                        ),
                      ),
                      HollowPressable(
                        onTap: () => _showAssignDialog(label),
                        borderRadius: BorderRadius.circular(hollow.radiusSm),
                        padding: const EdgeInsets.all(HollowSpacing.xs),
                        child: Icon(LucideIcons.userPlus, size: 14,
                            color: hollow.textSecondary),
                      ),
                      const SizedBox(width: HollowSpacing.xs),
                      HollowPressable(
                        onTap: () => _deleteLabel(label.labelId),
                        borderRadius: BorderRadius.circular(hollow.radiusSm),
                        padding: const EdgeInsets.all(HollowSpacing.xs),
                        child: Icon(LucideIcons.trash2, size: 14,
                            color: hollow.error),
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

  @override
  void initState() {
    super.initState();
    _loadAssignments();
  }

  void _loadAssignments() {
    final membersAsync = ref.read(serverMembersProvider(widget.serverId));
    membersAsync.whenData((members) {
      final assigned = <String>{};
      for (final m in members) {
        if (m.labels.any((l) => l.labelId == widget.label.labelId)) {
          assigned.add(m.peerId);
        }
      }
      if (mounted) setState(() => _assignedPeerIds = assigned);
    });
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
    final color = _parseColor(widget.label.color);

    return HollowDialog(
      title: 'Assign "${widget.label.name}"',
      content: SizedBox(
        width: 320,
        height: 300,
        child: membersAsync.when(
          data: (members) => ListView.builder(
            shrinkWrap: true,
            itemCount: members.length,
            itemBuilder: (_, i) {
              final m = members[i];
              final isAssigned = _assignedPeerIds.contains(m.peerId);
              final name = serverDisplayNameFor(profiles, m.peerId,
                  nickname: m.nickname);
              return ListTile(
                dense: true,
                leading: Container(
                  width: 10, height: 10,
                  decoration: BoxDecoration(
                    color: isAssigned ? color : Colors.transparent,
                    shape: BoxShape.circle,
                    border: Border.all(color: color, width: 1.5),
                  ),
                ),
                title: Text(name,
                    style: HollowTypography.body.copyWith(color: hollow.textPrimary)),
                onTap: () => _toggle(m.peerId),
              );
            },
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text('Error: $e'),
        ),
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
