import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/settings/access_label_picker.dart';

/// What the category bulk-access dialog resolved to. `visLabels`/`postLabels`
/// non-empty means Custom (label-gated) mode for that dimension.
class CategoryBulkAccess {
  final bool changeVisibility;
  final String visMode;
  final List<String> visLabels;
  final bool changePosting;
  final String postMode;
  final List<String> postLabels;

  const CategoryBulkAccess({
    required this.changeVisibility,
    required this.visMode,
    required this.visLabels,
    required this.changePosting,
    required this.postMode,
    required this.postLabels,
  });
}

/// Shows the bulk-access dialog for [channelIds] and applies the result to all
/// of them.
///
/// Shared by the Channels settings editor and the sidebar's category
/// right-click menu (issue #61), so the two cannot drift on what "apply to the
/// category" means. The caller resolves the channel set, because each surface
/// reads the layout from a different place. Each channel is updated
/// optimistically and rolled back individually, so one failure never leaves the
/// list showing a change that did not happen.
Future<void> runCategoryBulkAccess({
  required BuildContext context,
  required WidgetRef ref,
  required String serverId,
  required String categoryName,
  required List<String> channelIds,
}) async {
  if (channelIds.isEmpty) {
    HollowToast.show(context, 'No channels in this category');
    return;
  }

  final result = await showCategoryBulkAccessDialog(
    context,
    serverId: serverId,
    categoryName: categoryName,
    channelCount: channelIds.length,
  );
  if (result == null || !context.mounted) return;

  final notifier = ref.read(channelListProvider.notifier);
  final failed = <String>[];

  for (final id in channelIds) {
    final info = ref.read(channelListProvider)[id];
    if (info == null) continue;
    final prev = info;
    try {
      if (result.changeVisibility) {
        if (result.visLabels.isNotEmpty) {
          notifier.updateChannel(
              id,
              (ch) => ch.copyWith(
                  visibilityLabels: result.visLabels, visibility: 'admin'));
          await crdt_api.setChannelVisibilityLabels(
            serverId: serverId,
            channelId: id,
            labels: result.visLabels,
          );
        } else {
          notifier.updateChannel(
              id,
              (ch) => ch.copyWith(
                  visibility: result.visMode, visibilityLabels: const []));
          await crdt_api.setChannelVisibility(
            serverId: serverId,
            channelId: id,
            visibility: result.visMode,
          );
        }
      }
      // Voice channels have no posting gate to set.
      if (result.changePosting && info.channelType != ChannelType.voice) {
        if (result.postLabels.isNotEmpty) {
          notifier.updateChannel(
              id,
              (ch) => ch.copyWith(
                  postingLabels: result.postLabels, posting: 'admin'));
          await crdt_api.setChannelPostingLabels(
            serverId: serverId,
            channelId: id,
            labels: result.postLabels,
          );
        } else {
          notifier.updateChannel(
              id,
              (ch) => ch.copyWith(
                  posting: result.postMode, postingLabels: const []));
          await crdt_api.setChannelPosting(
            serverId: serverId,
            channelId: id,
            posting: result.postMode,
          );
        }
      }
    } catch (_) {
      notifier.updateChannel(id, (_) => prev);
      failed.add(prev.name);
    }
  }

  if (!context.mounted) return;
  if (failed.isEmpty) {
    HollowToast.show(context, 'Access applied to ${channelIds.length} channels',
        type: HollowToastType.success);
  } else {
    HollowToast.show(
        context,
        'Applied to ${channelIds.length - failed.length} of '
        '${channelIds.length} channels. Failed: '
        "${failed.map((n) => '#$n').join(', ')}",
        type: HollowToastType.error);
  }
}

/// Picks access settings to stamp onto every channel of a category. Pure UI:
/// the caller resolves the channel set and does the writes. Null on cancel.
Future<CategoryBulkAccess?> showCategoryBulkAccessDialog(
  BuildContext context, {
  required String serverId,
  required String categoryName,
  required int channelCount,
}) {
  return showHollowDialog<CategoryBulkAccess>(
    context: context,
    builder: (_) => _CategoryBulkAccessDialog(
      serverId: serverId,
      categoryName: categoryName,
      channelCount: channelCount,
    ),
  );
}

class _CategoryBulkAccessDialog extends StatefulWidget {
  final String serverId;
  final String categoryName;
  final int channelCount;

  const _CategoryBulkAccessDialog({
    required this.serverId,
    required this.categoryName,
    required this.channelCount,
  });

  @override
  State<_CategoryBulkAccessDialog> createState() =>
      _CategoryBulkAccessDialogState();
}

class _CategoryBulkAccessDialogState extends State<_CategoryBulkAccessDialog> {
  bool _changeVisibility = false;
  String _visMode = 'everyone';
  List<String> _visLabels = const [];
  bool _changePosting = false;
  String _postMode = 'everyone';
  List<String> _postLabels = const [];

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final canApply = _changeVisibility || _changePosting;

    return HollowDialog(
      title: 'Apply access: ${widget.categoryName}',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Applies to ${widget.channelCount} '
            'channel${widget.channelCount == 1 ? '' : 's'} in this '
            'category. Each channel keeps its own setting afterwards. '
            'Nothing stays linked to the category.',
            style: HollowTypography.bodySmall.copyWith(
              color: hollow.textSecondary,
            ),
          ),
          const SizedBox(height: HollowSpacing.lg),
          _section(
            hollow: hollow,
            title: 'Change visibility',
            subtitle: 'Who can see these channels',
            enabled: _changeVisibility,
            onToggled: (v) => setState(() => _changeVisibility = v),
            mode: _visMode,
            labels: _visLabels,
            onMode: (m) => setState(() {
              _visMode = m;
              _visLabels = const [];
            }),
            onCustom: () => _pickLabels(forVisibility: true),
          ),
          const SizedBox(height: HollowSpacing.md),
          _section(
            hollow: hollow,
            title: 'Change posting',
            subtitle: 'Who can send messages',
            enabled: _changePosting,
            onToggled: (v) => setState(() => _changePosting = v),
            mode: _postMode,
            labels: _postLabels,
            onMode: (m) => setState(() {
              _postMode = m;
              _postLabels = const [];
            }),
            onCustom: () => _pickLabels(forVisibility: false),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: canApply
              ? () => Navigator.of(context).pop(CategoryBulkAccess(
                    changeVisibility: _changeVisibility,
                    visMode: _visMode,
                    visLabels: _visLabels,
                    changePosting: _changePosting,
                    postMode: _postMode,
                    postLabels: _postLabels,
                  ))
              : null,
          child: Text('Apply to ${widget.channelCount}'),
        ),
      ],
    );
  }

  Future<void> _pickLabels({required bool forVisibility}) async {
    final picked = await showAccessLabelPicker(
      context: context,
      serverId: widget.serverId,
      title: forVisibility ? 'Custom visibility' : 'Custom posting',
      initial: (forVisibility ? _visLabels : _postLabels).toSet(),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() {
      if (forVisibility) {
        _visLabels = picked.toList();
        _visMode = 'custom';
      } else {
        _postLabels = picked.toList();
        _postMode = 'custom';
      }
    });
  }

  /// One grouped section card, with the tier chips revealed inside the same card
  /// when enabled so nothing floats at an arbitrary x-position.
  Widget _section({
    required HollowTheme hollow,
    required String title,
    required String subtitle,
    required bool enabled,
    required ValueChanged<bool> onToggled,
    required String mode,
    required List<String> labels,
    required ValueChanged<String> onMode,
    required VoidCallback onCustom,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(HollowSpacing.lg),
      decoration: BoxDecoration(
        color: hollow.surface.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: HollowSpacing.xxs),
                    Text(
                      subtitle,
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: HollowSpacing.md),
              HollowToggle(
                value: enabled,
                onChanged: onToggled,
                semanticLabel: title,
              ),
            ],
          ),
          if (enabled) ...[
            const SizedBox(height: HollowSpacing.md),
            Wrap(
              spacing: HollowSpacing.sm,
              runSpacing: HollowSpacing.sm,
              children: [
                for (final (value, text) in const [
                  ('everyone', 'Everyone'),
                  ('moderator', 'Mod+'),
                  ('admin', 'Admin+'),
                ])
                  _modeChip(hollow, text,
                      selected: labels.isEmpty && mode == value,
                      onTap: () => onMode(value)),
                _modeChip(
                  hollow,
                  labels.isEmpty ? 'Custom…' : '${labels.length} labels',
                  selected: labels.isNotEmpty,
                  onTap: onCustom,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _modeChip(HollowTheme hollow, String text,
      {required bool selected, required VoidCallback onTap}) {
    return HollowFocusRing(
      enabled: true,
      onActivate: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? hollow.accent.withValues(alpha: 0.15)
                : hollow.elevated,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            border:
                Border.all(color: selected ? hollow.accent : hollow.border),
          ),
          child: Text(
            text,
            style: HollowTypography.bodySmall.copyWith(
              color: selected ? hollow.accentText : hollow.textPrimary,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}
