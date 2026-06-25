import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
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

  static const _presetColors = [
    Color(0xFFE53935), Color(0xFFFB8C00), Color(0xFFFDD835),
    Color(0xFF43A047), Color(0xFF00ACC1), Color(0xFF1E88E5),
    Color(0xFF8E24AA), Color(0xFFEC407A), Color(0xFF78909C),
  ];

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
            // Header
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
                      onTap: () => _showCreateDialog(context),
                      semanticLabel: 'Create label',
                      borderRadius: BorderRadius.circular(hollow.radiusMd),
                      padding: const EdgeInsets.all(HollowSpacing.sm),
                      child: Icon(LucideIcons.plus, size: 22, color: hollow.accent),
                    ),
                ],
              ),
            ),

            // Content
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
                            // Self-assign section
                            _SelfAssignSection(
                              labels: _labels,
                              members: _members,
                              myPeerId: myPeerId,
                              serverId: widget.serverId,
                              onReload: _reload,
                            ),

                            // Management section
                            if (canManage) ...[
                              const SizedBox(height: HollowSpacing.xl),
                              _ManageSection(
                                labels: _labels,
                                members: _members,
                                serverId: widget.serverId,
                                onReload: _reload,
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

  void _showCreateDialog(BuildContext context) {
    final nameController = TextEditingController();
    var selectedColor = _presetColors[5]; // default blue

    showHollowDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final hollow = HollowTheme.of(ctx);
          return HollowDialog(
            title: 'New Label',
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
                  children: _presetColors.map((c) => GestureDetector(
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
                    await crdt_api.createLabel(
                      serverId: widget.serverId, name: name, color: hex,
                    );
                    await _reload();
                    if (mounted) {
                      HollowToast.show(context, 'Label created',
                          type: HollowToastType.success);
                    }
                  } catch (e) {
                    if (mounted) {
                      HollowToast.show(context, 'Failed to create label',
                          type: HollowToastType.error);
                    }
                  }
                },
                child: const Text('Create'),
              ),
            ],
          );
        },
      ),
    );
  }
}

Color _parseLabelColor(String hex) {
  final cleaned = hex.replaceFirst('#', '');
  if (cleaned.length == 6) return Color(int.parse('FF$cleaned', radix: 16));
  if (cleaned.length == 8) return Color(int.parse(cleaned, radix: 16));
  return const Color(0xFF78909C);
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
            final color = _parseLabelColor(label.color);
            final isAssigned = myLabelIds.contains(label.labelId);
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
                } catch (_) {}
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
                    // Larger Text (a11y P3): free-form label name — ellipsize
                    // so it can't overflow the chip Row at high text scale.
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

  const _ManageSection({
    required this.labels,
    required this.members,
    required this.serverId,
    required this.onReload,
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
                    color: _parseLabelColor(label.color),
                    shape: BoxShape.circle,
                  ),
                ),
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
    final color = _parseLabelColor(widget.label.color);

    return HollowDialog(
      title: 'Assign "${widget.label.name}"',
      content: SizedBox(
        width: double.maxFinite,
        height: 300,
        child: ListView.builder(
          itemCount: widget.members.length,
          itemBuilder: (context, index) {
            final m = widget.members[index];
            final name = displayNameFor(profiles, m.peerId);
            final isAssigned = _assigned.contains(m.peerId);

            return HollowPressable(
              onTap: () => _toggle(m.peerId),
              subtle: true,
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm, vertical: HollowSpacing.sm,
              ),
              child: Row(
                children: [
                  HollowAvatar(peerId: m.peerId, size: 32),
                  const SizedBox(width: HollowSpacing.md),
                  Expanded(
                    child: Text(name, style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                    )),
                  ),
                  Icon(
                    isAssigned ? LucideIcons.checkSquare : LucideIcons.square,
                    size: 20,
                    color: isAssigned ? color : hollow.textSecondary,
                  ),
                ],
              ),
            );
          },
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
