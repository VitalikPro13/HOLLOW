import 'package:flutter/material.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:lucide_icons_flutter/lucide_icons.dart';

void showMobileChannelActions({
  required BuildContext context,
  required String serverId,
  required ChannelInfo channel,
  required bool canManage,
  VoidCallback? onChanged,
}) {
  final hollow = HollowTheme.of(context);
  showModalBottomSheet(
    context: context,
    backgroundColor: hollow.surface,
    isScrollControlled: true,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
    ),
    builder: (_) => _ChannelActionsSheet(
      serverId: serverId,
      channel: channel,
      canManage: canManage,
      onChanged: onChanged,
    ),
  );
}

enum _SheetView { actions, deleteConfirm, visibility, posting }

class _ChannelActionsSheet extends StatefulWidget {
  final String serverId;
  final ChannelInfo channel;
  final bool canManage;
  final VoidCallback? onChanged;

  const _ChannelActionsSheet({
    required this.serverId,
    required this.channel,
    required this.canManage,
    this.onChanged,
  });

  @override
  State<_ChannelActionsSheet> createState() => _ChannelActionsSheetState();
}

class _ChannelActionsSheetState extends State<_ChannelActionsSheet> {
  _SheetView _view = _SheetView.actions;
  late String _visibility;
  late String _posting;

  @override
  void initState() {
    super.initState();
    _visibility = widget.channel.visibility;
    _posting = widget.channel.posting;
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: HollowSpacing.sm),
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: hollow.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: HollowSpacing.sm),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: switch (_view) {
              _SheetView.actions => _buildActionsView(hollow),
              _SheetView.deleteConfirm => _buildDeleteConfirmView(hollow),
              _SheetView.visibility => _buildAccessView(
                  hollow, 'Visibility', _visibility, _setVisibility),
              _SheetView.posting => _buildAccessView(
                  hollow, 'Who Can Post', _posting, _setPosting),
            },
          ),
          const SizedBox(height: HollowSpacing.sm),
        ],
      ),
    );
  }

  Widget _buildActionsView(HollowTheme hollow) {
    final isVoice = widget.channel.channelType == ChannelType.voice;
    final icon = isVoice ? LucideIcons.volume2 : LucideIcons.hash;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
          child: Row(
            children: [
              Icon(icon, size: 18, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  widget.channel.name,
                  style: HollowTypography.heading.copyWith(color: hollow.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: HollowSpacing.lg),
        if (widget.canManage) ...[
          _ActionRow(
            icon: LucideIcons.pencil,
            label: 'Rename Channel',
            onTap: () {
              Navigator.pop(context);
              _showRenameDialog();
            },
          ),
          _ActionRow(
            icon: LucideIcons.eye,
            label: 'Visibility',
            trailing: _accessLabel(_visibility),
            onTap: () => setState(() => _view = _SheetView.visibility),
          ),
          _ActionRow(
            icon: LucideIcons.messageSquare,
            label: 'Who Can Post',
            trailing: _accessLabel(_posting),
            onTap: () => setState(() => _view = _SheetView.posting),
          ),
          const SizedBox(height: HollowSpacing.sm),
          Divider(
            height: 1,
            color: hollow.border,
            indent: HollowSpacing.lg,
            endIndent: HollowSpacing.lg,
          ),
          const SizedBox(height: HollowSpacing.sm),
          _ActionRow(
            icon: LucideIcons.trash2,
            label: 'Delete Channel',
            color: hollow.error,
            onTap: () => setState(() => _view = _SheetView.deleteConfirm),
          ),
        ],
      ],
    );
  }

  void _showRenameDialog() {
    final controller = TextEditingController(text: widget.channel.name);
    showHollowDialog(
      context: context,
      builder: (ctx) => Center(
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.xl),
          child: Material(
            color: Colors.transparent,
            child: Builder(builder: (ctx2) {
              final hollow = HollowTheme.of(ctx2);
              Future<void> submit() async {
                final name = controller.text.trim();
                if (name.isEmpty || name == widget.channel.name) {
                  Navigator.pop(ctx2);
                  return;
                }
                Navigator.pop(ctx2);
                try {
                  await crdt_api.renameChannel(
                    serverId: widget.serverId,
                    channelId: widget.channel.channelId,
                    newName: name,
                  );
                } catch (_) {
                  if (mounted) {
                    HollowToast.show(context, 'Could not rename channel',
                        type: HollowToastType.error);
                  }
                  return;
                }
                widget.onChanged?.call();
                if (mounted) {
                  HollowToast.show(context, 'Channel renamed',
                      type: HollowToastType.success);
                }
              }

              return Container(
                constraints: const BoxConstraints(maxWidth: 360),
                padding: const EdgeInsets.all(HollowSpacing.xl),
                decoration: BoxDecoration(
                  color: hollow.elevated,
                  borderRadius: BorderRadius.circular(hollow.radiusLg),
                  border: Border.all(color: hollow.border),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Rename Channel',
                        style: HollowTypography.heading
                            .copyWith(color: hollow.textPrimary)),
                    const SizedBox(height: HollowSpacing.md),
                    HollowTextField(
                      controller: controller,
                      hintText: 'Channel name',
                      autofocus: true,
                      maxLength: 32,
                      onSubmitted: (_) => submit(),
                    ),
                    const SizedBox(height: HollowSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: HollowButton.ghost(
                            onPressed: () => Navigator.pop(ctx2),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: HollowSpacing.md),
                        Expanded(
                          child: HollowButton.filled(
                            onPressed: submit,
                            child: const Text('Rename'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _buildDeleteConfirmView(HollowTheme hollow) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.alertTriangle, size: 32, color: hollow.error),
          const SizedBox(height: HollowSpacing.md),
          Text(
            'Delete #${widget.channel.name}?',
            style: HollowTypography.heading.copyWith(color: hollow.textPrimary),
          ),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            'This cannot be undone.',
            style: HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.lg),
          Row(
            children: [
              Expanded(
                child: HollowButton.ghost(
                  onPressed: () => setState(() => _view = _SheetView.actions),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: HollowSpacing.md),
              Expanded(
                child: HollowButton.danger(
                  onPressed: _doDelete,
                  child: const Text('Delete'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAccessView(
    HollowTheme hollow,
    String title,
    String currentValue,
    void Function(String) onSelect,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
          child: _BackHeader(
            label: title,
            onBack: () => setState(() => _view = _SheetView.actions),
          ),
        ),
        const SizedBox(height: HollowSpacing.sm),
        _AccessOptionRow(
          label: 'Everyone',
          isSelected: currentValue == 'everyone',
          onTap: () => onSelect('everyone'),
        ),
        _AccessOptionRow(
          label: 'Moderator+',
          isSelected: currentValue == 'moderator',
          onTap: () => onSelect('moderator'),
        ),
        _AccessOptionRow(
          label: 'Admin+',
          isSelected: currentValue == 'admin',
          onTap: () => onSelect('admin'),
        ),
      ],
    );
  }

  Future<void> _doDelete() async {
    Navigator.pop(context);
    try {
      await crdt_api.removeChannel(
        serverId: widget.serverId,
        channelId: widget.channel.channelId,
      );
    } catch (_) {
      if (mounted) {
        HollowToast.show(context, 'Could not delete channel',
            type: HollowToastType.error);
      }
      return;
    }
    widget.onChanged?.call();
    if (mounted) {
      HollowToast.show(context, 'Channel deleted', type: HollowToastType.success);
    }
  }

  Future<void> _setVisibility(String value) async {
    try {
      await crdt_api.setChannelVisibility(
        serverId: widget.serverId,
        channelId: widget.channel.channelId,
        visibility: value,
      );
    } catch (_) {
      if (mounted) {
        HollowToast.show(context, 'Could not update channel',
            type: HollowToastType.error);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _visibility = value);
    widget.onChanged?.call();
  }

  Future<void> _setPosting(String value) async {
    try {
      await crdt_api.setChannelPosting(
        serverId: widget.serverId,
        channelId: widget.channel.channelId,
        posting: value,
      );
    } catch (_) {
      if (mounted) {
        HollowToast.show(context, 'Could not update channel',
            type: HollowToastType.error);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _posting = value);
    widget.onChanged?.call();
  }

  static String _accessLabel(String value) {
    return switch (value) {
      'moderator' => 'Mod+',
      'admin' => 'Admin+',
      _ => 'Everyone',
    };
  }
}

// ─────────────────────────────────────────────────
// Reusable sheet components
// ─────────────────────────────────────────────────

class _BackHeader extends StatelessWidget {
  final String label;
  final VoidCallback onBack;

  const _BackHeader({required this.label, required this.onBack});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      children: [
        HollowPressable(
          onTap: onBack,
          semanticLabel: 'Back',
          padding: const EdgeInsets.all(HollowSpacing.xs),
          child: Icon(LucideIcons.arrowLeft, size: 20, color: hollow.textPrimary),
        ),
        const SizedBox(width: HollowSpacing.sm),
        Text(
          label,
          style: HollowTypography.heading.copyWith(color: hollow.textPrimary),
        ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final String? trailing;

  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final c = color ?? hollow.textPrimary;
    return HollowPressable(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.lg,
          vertical: HollowSpacing.sm + 2,
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: c),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: Text(label, style: HollowTypography.body.copyWith(color: c)),
            ),
            if (trailing != null)
              Text(
                trailing!,
                style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
              ),
          ],
        ),
      ),
    );
  }
}

class _AccessOptionRow extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _AccessOptionRow({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.lg,
          vertical: HollowSpacing.md,
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? LucideIcons.checkCircle2 : LucideIcons.circle,
              size: 20,
              color: isSelected ? hollow.accent : hollow.textSecondary,
            ),
            const SizedBox(width: HollowSpacing.md),
            Text(
              label,
              style: HollowTypography.body.copyWith(
                color: isSelected ? hollow.accent : hollow.textPrimary,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
