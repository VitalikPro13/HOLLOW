import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/access_label_picker.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';

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
/// of them, inside the dialog: "Apply" loads until the last write lands.
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
  // The container, not [ref]: a menu that opened this may be gone by the
  // time the writes run.
  final read = ProviderScope.containerOf(context, listen: false).read;

  final result = await showCategoryBulkAccessDialog(
    context,
    serverId: serverId,
    categoryName: categoryName,
    channelCount: channelIds.length,
    onApply: (access) => applyCategoryBulkAccess(
      read: read,
      serverId: serverId,
      channelIds: channelIds,
      access: access,
    ),
  );
  if (result == null || !context.mounted) return;
  HollowToast.show(
      context,
      channelIds.length == 1
          ? 'Access changed on 1 channel'
          : 'Access changed on ${channelIds.length} channels',
      type: HollowToastType.success);
}

/// Writes [access] to each of [channelIds], optimistically, one at a time.
/// Throws a [FriendlyException] naming the channels that did not change; the
/// others keep their new setting.
Future<void> applyCategoryBulkAccess({
  required ProviderRead read,
  required String serverId,
  required List<String> channelIds,
  required CategoryBulkAccess access,
}) async {
  final notifier = read(channelListProvider.notifier);
  final failed = <String>[];

  for (final id in channelIds) {
    final info = read(channelListProvider)[id];
    if (info == null) continue;
    final prev = info;
    try {
      if (access.changeVisibility) {
        if (access.visLabels.isNotEmpty) {
          notifier.updateChannel(
              id,
              (ch) => ch.copyWith(
                  visibilityLabels: access.visLabels, visibility: 'admin'));
          await crdt_api.setChannelVisibilityLabels(
            serverId: serverId,
            channelId: id,
            labels: access.visLabels,
          );
        } else {
          notifier.updateChannel(
              id,
              (ch) => ch.copyWith(
                  visibility: access.visMode, visibilityLabels: const []));
          await crdt_api.setChannelVisibility(
            serverId: serverId,
            channelId: id,
            visibility: access.visMode,
          );
        }
      }
      // Voice channels have no posting gate to set.
      if (access.changePosting && info.channelType != ChannelType.voice) {
        if (access.postLabels.isNotEmpty) {
          notifier.updateChannel(
              id,
              (ch) => ch.copyWith(
                  postingLabels: access.postLabels, posting: 'admin'));
          await crdt_api.setChannelPostingLabels(
            serverId: serverId,
            channelId: id,
            labels: access.postLabels,
          );
        } else {
          notifier.updateChannel(
              id,
              (ch) => ch.copyWith(
                  posting: access.postMode, postingLabels: const []));
          await crdt_api.setChannelPosting(
            serverId: serverId,
            channelId: id,
            posting: access.postMode,
          );
        }
      }
    } catch (_) {
      notifier.updateChannel(id, (_) => prev);
      failed.add('#${prev.name}');
    }
  }

  if (failed.isNotEmpty) {
    throw FriendlyException("${failed.join(', ')} didn't change. Try again.");
  }
}

/// Picks access settings to stamp onto every channel of a category. With
/// [onApply] the dialog runs it before closing; without, it only picks. Null on
/// cancel.
Future<CategoryBulkAccess?> showCategoryBulkAccessDialog(
  BuildContext context, {
  required String serverId,
  required String categoryName,
  required int channelCount,
  Future<void> Function(CategoryBulkAccess access)? onApply,
}) {
  return showHollowDialog<CategoryBulkAccess>(
    context: context,
    builder: (_) => _CategoryBulkAccessDialog(
      serverId: serverId,
      categoryName: categoryName,
      channelCount: channelCount,
      onApply: onApply,
    ),
  );
}

class _CategoryBulkAccessDialog extends StatefulWidget {
  final String serverId;
  final String categoryName;
  final int channelCount;
  final Future<void> Function(CategoryBulkAccess access)? onApply;

  const _CategoryBulkAccessDialog({
    required this.serverId,
    required this.categoryName,
    required this.channelCount,
    required this.onApply,
  });

  @override
  State<_CategoryBulkAccessDialog> createState() =>
      _CategoryBulkAccessDialogState();
}

class _CategoryBulkAccessDialogState extends State<_CategoryBulkAccessDialog>
    with HollowDialogAction {
  bool _changeVisibility = false;
  String _visMode = 'everyone';
  List<String> _visLabels = const [];
  bool _changePosting = false;
  String _postMode = 'everyone';
  List<String> _postLabels = const [];

  CategoryBulkAccess get _access => CategoryBulkAccess(
        changeVisibility: _changeVisibility,
        visMode: _visMode,
        visLabels: _visLabels,
        changePosting: _changePosting,
        postMode: _postMode,
        postLabels: _postLabels,
      );

  Future<void> _apply() async {
    final access = _access;
    final onApply = widget.onApply;
    if (onApply != null && !await runDialogAction(() => onApply(access))) {
      return;
    }
    if (mounted) Navigator.of(context).pop(access);
  }

  @override
  Widget build(BuildContext context) {
    final canApply = _changeVisibility || _changePosting;
    final n = widget.channelCount;

    return HollowDialog(
      title: 'Set access for ${widget.categoryName}',
      width: 480,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowDialogText(
            'Changes the $n channel${n == 1 ? '' : 's'} in this category now. '
            "Nothing stays linked, so a channel added later won't follow this "
            'setting.',
          ),
          const SizedBox(height: HollowSpacing.md),
          ..._section(
            title: 'Change who can see them',
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
          ..._section(
            title: 'Change who can post',
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
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: canApply ? _apply : null,
          loading: actionRunning,
          child: Text('Apply to $n'),
        ),
      ],
    );
  }

  Future<void> _pickLabels({required bool forVisibility}) async {
    final picked = await showAccessLabelPicker(
      context: context,
      serverId: widget.serverId,
      gate: forVisibility ? AccessLabelGate.see : AccessLabelGate.post,
      target: 'the channels in ${widget.categoryName}',
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

  /// One switch row, with the tier chips under it once it is on.
  List<Widget> _section({
    required String title,
    required bool enabled,
    required ValueChanged<bool> onToggled,
    required String mode,
    required List<String> labels,
    required ValueChanged<String> onMode,
    required VoidCallback onCustom,
  }) {
    final locked = actionRunning;
    return [
      SettingsSwitchRow(
        title: title,
        value: enabled,
        onChanged: locked ? null : onToggled,
      ),
      if (enabled) ...[
        Wrap(
          spacing: HollowSpacing.sm,
          runSpacing: HollowSpacing.sm,
          children: [
            for (final (value, text) in const [
              ('everyone', 'Everyone'),
              ('moderator', 'Mod+'),
              ('admin', 'Admin+'),
            ])
              HollowChip(
                label: text,
                selected: labels.isEmpty && mode == value,
                onTap: locked ? null : () => onMode(value),
              ),
            HollowChip(
              label: labels.isEmpty
                  ? 'Labels…'
                  : labels.length == 1
                      ? '1 label'
                      : '${labels.length} labels',
              selected: labels.isNotEmpty,
              onTap: locked ? null : onCustom,
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.sm),
      ],
    ];
  }
}
