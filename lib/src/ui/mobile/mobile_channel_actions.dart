import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/server_settings/delete_channel_confirm.dart';
import 'package:hollow/src/ui/settings/access_label_picker.dart';
import 'package:hollow/src/ui/settings/channel_grants_dialog.dart';
import 'package:hollow/src/ui/shell/channel_context_menus.dart'
    show accessTierLabel, confirmClearLabelGate, renameChannelFlow;
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The phone's long-press sheet for a channel: the desktop channel menu's rows.
/// A voice channel has nothing for someone who cannot manage it (no messages
/// to read or mute), so it opens no sheet at all.
void showMobileChannelActions({
  required BuildContext context,
  required String serverId,
  required ChannelInfo channel,
  required bool canManage,
  VoidCallback? onChanged,
}) {
  if (!canManage && channel.channelType == ChannelType.voice) return;
  showHollowSheet(
    context: context,
    scrollControlled: true,
    builder: (_) => _ChannelActionsSheet(
      hostContext: context,
      serverId: serverId,
      channel: channel,
      canManage: canManage,
      onChanged: onChanged,
    ),
  );
}

enum _SheetView { actions, visibility, posting }

class _ChannelActionsSheet extends ConsumerStatefulWidget {
  /// The screen that opened the sheet: dialogs and toasts started from a row
  /// outlive the sheet, so they run against it.
  final BuildContext hostContext;
  final String serverId;
  final ChannelInfo channel;
  final bool canManage;
  final VoidCallback? onChanged;

  const _ChannelActionsSheet({
    required this.hostContext,
    required this.serverId,
    required this.channel,
    required this.canManage,
    this.onChanged,
  });

  @override
  ConsumerState<_ChannelActionsSheet> createState() =>
      _ChannelActionsSheetState();
}

class _ChannelActionsSheetState extends ConsumerState<_ChannelActionsSheet> {
  _SheetView _view = _SheetView.actions;
  late String _visibility;
  late String _posting;
  late List<String> _visibilityLabels;
  late List<String> _postingLabels;

  @override
  void initState() {
    super.initState();
    _visibility = widget.channel.visibility;
    _posting = widget.channel.posting;
    _visibilityLabels = List.of(widget.channel.visibilityLabels);
    _postingLabels = List.of(widget.channel.postingLabels);
  }

  BuildContext get _host => widget.hostContext;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSize(
            duration: HollowDurations.fast,
            curve: HollowCurves.enter,
            child: switch (_view) {
              _SheetView.actions => _buildActionsView(),
              _SheetView.visibility => _buildAccessView(
                  'Visibility', _visibility, _setVisibility,
                  gateLabels: _visibilityLabels,
                  onCustom: () => _editGateLabels(forVisibility: true)),
              _SheetView.posting => _buildAccessView(
                  'Who can post', _posting, _setPosting,
                  gateLabels: _postingLabels,
                  onCustom: () => _editGateLabels(forVisibility: false)),
            },
          ),
          const SizedBox(height: HollowSpacing.sm),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String label, VoidCallback onTap,
      {String? trailing}) {
    final hollow = HollowTheme.of(context);
    return HollowListRow(
      touch: true,
      title: label,
      leading: Icon(icon, size: 20, color: hollow.textSecondary),
      trailing: trailing == null
          ? null
          : Text(trailing,
              style: HollowTypography.bodySmall
                  .copyWith(color: hollow.textSecondary)),
      onTap: onTap,
    );
  }

  /// A row that closes the sheet, then acts on the screen beneath it.
  Widget _closingRow(IconData icon, String label, VoidCallback onTap) =>
      _row(icon, label, () {
        Navigator.pop(context);
        onTap();
      });

  String _accessSummary(String tier, List<String> labels) => labels.isNotEmpty
      ? '${labels.length} label${labels.length == 1 ? '' : 's'}'
      : accessTierLabel(tier);

  Widget _buildActionsView() {
    final channel = widget.channel;
    final isVoice = channel.channelType == ChannelType.voice;
    final notifications = ref.read(notificationSettingsProvider.notifier);
    ref.watch(notificationSettingsProvider);
    final isMuted =
        notifications.channelOverride(widget.serverId, channel.channelId) ==
            ChannelNotificationLevel.nothing;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        HollowSheetTitle(channel.name),
        // A voice channel carries no messages, so read state and muting mean
        // nothing for it.
        if (!isVoice) ...[
          _closingRow(LucideIcons.checkCheck, 'Mark as read', _markRead),
          _closingRow(
            isMuted ? LucideIcons.bell : LucideIcons.bellOff,
            isMuted ? 'Unmute channel' : 'Mute channel',
            () => notifications.setChannelOverride(
              widget.serverId,
              channel.channelId,
              isMuted
                  ? ChannelNotificationLevel.inherit
                  : ChannelNotificationLevel.nothing,
            ),
          ),
        ],
        if (widget.canManage) ...[
          if (!isVoice) const HollowDivider(),
          _closingRow(LucideIcons.pencil, 'Rename channel', () {
            renameChannelFlow(_host, ref, widget.serverId, channel,
                onRenamed: widget.onChanged);
          }),
          _row(
            LucideIcons.eye,
            'Visibility',
            () => setState(() => _view = _SheetView.visibility),
            trailing: _accessSummary(_visibility, _visibilityLabels),
          ),
          if (!isVoice)
            _row(
              LucideIcons.messageSquare,
              'Who can post',
              () => setState(() => _view = _SheetView.posting),
              trailing: _accessSummary(_posting, _postingLabels),
            ),
          if (!channel.isPublic)
            _closingRow(LucideIcons.userPlus, 'Temporary access', () {
              showChannelGrantsDialog(
                _host,
                serverId: widget.serverId,
                channelId: channel.channelId,
                channelName: channel.name,
              );
            }),
          const HollowDivider(),
          _closingRow(LucideIcons.trash2, 'Delete channel', _delete),
        ],
      ],
    );
  }

  void _markRead() {
    final key = '${widget.serverId}:${widget.channel.channelId}';
    final msgs = ref.read(channelChatProvider)[key];
    final latestId =
        (msgs != null && msgs.isNotEmpty) ? msgs.last.messageId : null;
    ref
        .read(unreadProvider.notifier)
        .markChannelSeen(widget.serverId, widget.channel.channelId, latestId);
  }

  Future<void> _delete() async {
    final onChanged = widget.onChanged;
    final deleted = await confirmDeleteChannel(
      _host,
      serverId: widget.serverId,
      channelId: widget.channel.channelId,
      channelName: widget.channel.name,
    );
    if (deleted) onChanged?.call();
  }

  Widget _buildAccessView(
    String title,
    String currentValue,
    void Function(String) onSelect, {
    required List<String> gateLabels,
    required VoidCallback onCustom,
  }) {
    final hollow = HollowTheme.of(context);
    final gated = gateLabels.isNotEmpty;
    // A label gate outranks the tier, so no tier reads as chosen while one is
    // set.
    Widget option(String label, bool selected, VoidCallback onTap) =>
        HollowListRow(
          touch: true,
          title: label,
          selected: selected,
          trailing: selected
              ? Icon(LucideIcons.check, size: 20, color: hollow.accentText)
              : null,
          onTap: onTap,
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              HollowSpacing.xs, 0, HollowSpacing.lg, HollowSpacing.xs),
          child: Row(
            children: [
              HollowIconButton(
                icon: LucideIcons.arrowLeft,
                label: 'Back',
                size: 44,
                onPressed: () => setState(() => _view = _SheetView.actions),
              ),
              const SizedBox(width: HollowSpacing.xs),
              Expanded(
                child: Text(
                  title,
                  style: HollowTypography.subheading
                      .copyWith(color: hollow.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        for (final tier in const ['everyone', 'moderator', 'admin'])
          option(accessTierLabel(tier), !gated && currentValue == tier,
              () => onSelect(tier)),
        option(
          gated
              ? 'Edit access labels (${gateLabels.length})'
              : 'Require access labels',
          gated,
          onCustom,
        ),
      ],
    );
  }

  /// Opens the access-label picker for this channel. Setting labels stamps the
  /// tier to Admin and above Rust-side.
  Future<void> _editGateLabels({required bool forVisibility}) async {
    final initial = forVisibility ? _visibilityLabels : _postingLabels;
    final picked = await showAccessLabelPicker(
      context: context,
      serverId: widget.serverId,
      gate: forVisibility ? AccessLabelGate.see : AccessLabelGate.post,
      target: '#${widget.channel.name}',
      initial: initial.toSet(),
    );
    if (picked == null || !mounted) return;
    final labels = picked.toList();
    try {
      if (forVisibility) {
        await crdt_api.setChannelVisibilityLabels(
          serverId: widget.serverId,
          channelId: widget.channel.channelId,
          labels: labels,
        );
      } else {
        await crdt_api.setChannelPostingLabels(
          serverId: widget.serverId,
          channelId: widget.channel.channelId,
          labels: labels,
        );
      }
    } catch (_) {
      _failed();
      return;
    }
    if (!mounted) return;
    setState(() {
      if (forVisibility) {
        _visibilityLabels = labels;
        if (labels.isNotEmpty) _visibility = 'admin';
      } else {
        _postingLabels = labels;
        if (labels.isNotEmpty) _posting = 'admin';
      }
    });
    widget.onChanged?.call();
  }

  void _failed() {
    if (mounted) {
      HollowToast.show(context, 'Could not update channel',
          type: HollowToastType.error);
    }
  }

  Future<void> _setVisibility(String value) async {
    // A plain tier clears any label gate; Rust authors that op too.
    if (_visibilityLabels.isNotEmpty &&
        !await confirmClearLabelGate(context,
            channelName: widget.channel.name,
            tier: value,
            forVisibility: true)) {
      return;
    }
    try {
      await crdt_api.setChannelVisibility(
        serverId: widget.serverId,
        channelId: widget.channel.channelId,
        visibility: value,
      );
    } catch (_) {
      _failed();
      return;
    }
    if (!mounted) return;
    setState(() {
      _visibility = value;
      _visibilityLabels = const [];
    });
    widget.onChanged?.call();
  }

  Future<void> _setPosting(String value) async {
    if (_postingLabels.isNotEmpty &&
        !await confirmClearLabelGate(context,
            channelName: widget.channel.name,
            tier: value,
            forVisibility: false)) {
      return;
    }
    try {
      await crdt_api.setChannelPosting(
        serverId: widget.serverId,
        channelId: widget.channel.channelId,
        posting: value,
      );
    } catch (_) {
      _failed();
      return;
    }
    if (!mounted) return;
    setState(() {
      _posting = value;
      _postingLabels = const [];
    });
    widget.onChanged?.call();
  }
}
