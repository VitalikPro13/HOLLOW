import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/pinned_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/core/time_labels.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart' show gifAwareImage;
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The pinned messages of one channel that are loaded in [messages], newest
/// first, and how many pins are not loaded (older than the loaded history).
({List<ChannelChatMessage> loaded, int missing}) resolvePinnedMessages(
    List<String> pinnedIds, List<ChannelChatMessage> messages) {
  final byId = {
    for (final m in messages)
      if (m.messageId != null) m.messageId!: m,
  };
  final loaded = [
    for (final id in pinnedIds)
      if (byId[id] != null) byId[id]!,
  ]..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return (loaded: loaded, missing: pinnedIds.length - loaded.length);
}

/// The line that owns up to pins the list cannot show yet.
String pinnedMissingLine(int missing) => missing == 1
    ? '1 more pinned message is further back in this channel.'
    : '$missing more pinned messages are further back in this channel.';

/// A channel's pinned messages: a dialog on desktop, a sheet on a phone
/// ([touch]). Tapping a row closes the list and calls [onJump] with that
/// message's id. [preview] is the row's text, so an album reads as the
/// whole album. Whoever may pin in the channel can unpin from a row.
void showPinnedMessages(
  BuildContext context, {
  required String serverId,
  required String channelId,
  required List<String> pinnedIds,
  required List<ChannelChatMessage> messages,
  required String Function(ChannelChatMessage msg) preview,
  required void Function(String messageId) onJump,
  bool touch = false,
}) {
  final resolved = resolvePinnedMessages(pinnedIds, messages);

  Widget list(BuildContext listContext) => _PinnedList(
        serverId: serverId,
        channelId: channelId,
        loaded: resolved.loaded,
        missing: resolved.missing,
        preview: preview,
        touch: touch,
        onTap: (id) {
          Navigator.of(listContext).pop();
          onJump(id);
        },
      );

  if (touch) {
    showHollowSheet(
      context: context,
      scrollControlled: true,
      maxHeightFactor: 0.8,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const HollowSheetTitle('Pinned messages'),
            Flexible(
              child: SingleChildScrollView(child: list(sheetContext)),
            ),
            const SizedBox(height: HollowSpacing.sm),
          ],
        ),
      ),
    );
    return;
  }
  showHollowDialog(
    context: context,
    builder: (dialogContext) => HollowDialog(
      title: 'Pinned messages',
      width: 420,
      showClose: true,
      content: list(dialogContext),
    ),
  );
}

/// Whether this device may pin and unpin in [serverId]: the same check the
/// message menus use.
bool canPinIn(WidgetRef ref, String serverId) =>
    !serverId.startsWith('conf:') &&
    (ref.watch(myPermissionsProvider(serverId)).whenOrNull(
            data: (perms) => (perms & Permission.manageChannels) != 0) ??
        false);

class _PinnedList extends ConsumerStatefulWidget {
  final String serverId;
  final String channelId;
  final List<ChannelChatMessage> loaded;
  final int missing;
  final String Function(ChannelChatMessage msg) preview;
  final bool touch;
  final ValueChanged<String> onTap;

  const _PinnedList({
    required this.serverId,
    required this.channelId,
    required this.loaded,
    required this.missing,
    required this.preview,
    required this.touch,
    required this.onTap,
  });

  @override
  ConsumerState<_PinnedList> createState() => _PinnedListState();
}

class _PinnedListState extends ConsumerState<_PinnedList> {
  /// Unpinned from here: gone from the list at once, back if the unpin fails.
  final _unpinned = <String>{};

  Future<void> _unpin(String messageId) async {
    final pins = ref.read(pinnedProvider.notifier);
    setState(() => _unpinned.add(messageId));
    pins.applyUnpin(widget.serverId, widget.channelId, messageId);
    try {
      await crdt_api.unpinMessage(
        serverId: widget.serverId,
        channelId: widget.channelId,
        messageId: messageId,
      );
      // The last pin gone: an empty list with its header button already
      // vanished is a dead end, so the list closes.
      final left = widget.loaded.where((m) => !_unpinned.contains(m.messageId));
      if (mounted && left.isEmpty && widget.missing == 0) {
        Navigator.of(context).maybePop();
      }
    } catch (e) {
      pins.applyPin(widget.serverId, widget.channelId, messageId);
      if (!mounted) return;
      setState(() => _unpinned.remove(messageId));
      HollowToast.show(
          context,
          friendlyError(e, fallback: "Couldn't unpin that message. Try again."),
          type: HollowToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final touch = widget.touch;
    final canUnpin = canPinIn(ref, widget.serverId);
    final loaded = [
      for (final m in widget.loaded)
        if (!_unpinned.contains(m.messageId)) m,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < loaded.length; i++) ...[
          if (i > 0) const HollowDivider(),
          PinnedMessageRow(
            key: ValueKey(loaded[i].messageId),
            serverId: widget.serverId,
            message: loaded[i],
            preview: widget.preview(loaded[i]),
            touch: touch,
            onTap: () => widget.onTap(loaded[i].messageId!),
            onUnpin:
                canUnpin ? () => _unpin(loaded[i].messageId!) : null,
          ),
        ],
        if (loaded.isEmpty && widget.missing == 0)
          const HollowEmptyState(dense: true, title: 'Nothing is pinned here'),
        if (widget.missing > 0)
          Padding(
            padding: EdgeInsets.fromLTRB(
              touch ? HollowSpacing.lg : 0,
              loaded.isEmpty ? 0 : HollowSpacing.md,
              touch ? HollowSpacing.lg : 0,
              0,
            ),
            child: Text(
              pinnedMissingLine(widget.missing),
              style: HollowTypography.bodySmall
                  .copyWith(color: hollow.textSecondary),
            ),
          ),
      ],
    );
  }
}

/// One pinned message: who sent it, when, and what it says, with an image's
/// thumbnail. The whole row jumps to the message. [onUnpin], when given, is a
/// grey Unpin on the row: on hover or keyboard focus on desktop, always there
/// on a phone.
class PinnedMessageRow extends ConsumerStatefulWidget {
  final String serverId;
  final ChannelChatMessage message;
  final String preview;
  final bool touch;
  final VoidCallback onTap;
  final VoidCallback? onUnpin;

  const PinnedMessageRow({
    super.key,
    required this.serverId,
    required this.message,
    required this.preview,
    required this.onTap,
    this.touch = false,
    this.onUnpin,
  });

  @override
  ConsumerState<PinnedMessageRow> createState() => _PinnedMessageRowState();
}

class _PinnedMessageRowState extends ConsumerState<PinnedMessageRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final message = widget.message;
    final touch = widget.touch;
    // The person, not a raw device id.
    final master = ref.watch(deviceLinkProvider).identityOf(message.senderId);
    final name = serverDisplayNameFor(
      ref.watch(profileProvider),
      master,
      nickname:
          ref.watch(serverNicknamesProvider(widget.serverId))[master] ?? '',
    );
    final attachment = message.fileAttachment;
    final image = attachment != null && attachment.isImage
        ? attachment.diskPath
        : null;
    final inset = HollowListRow.insetOf(touch: touch);

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HollowTypography.label.copyWith(
                  color: message.isMe
                      ? hollow.accentText
                      : nameColorFor(master, hollow),
                ),
              ),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Text(
              conversationTimeLabel(message.timestamp),
              style:
                  HollowTypography.caption.copyWith(color: hollow.textTertiary),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.xxs),
        if (image != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            child: gifAwareImage(image, height: 80),
          )
        else
          Text(
            widget.preview,
            style: (touch ? HollowTypography.bodyTouch : HollowTypography.body)
                .copyWith(
                    color: attachment != null
                        ? hollow.textSecondary
                        : hollow.textPrimary),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );

    final onUnpin = widget.onUnpin;
    final Widget? unpin = onUnpin == null
        ? null
        : AnimatedOpacity(
            // Hidden, never removed: it stays in the focus order, and a Tab
            // onto it is what shows it.
            opacity: touch || _hovered || _focused ? 1 : 0,
            duration: HollowDurations.fast,
            alwaysIncludeSemantics: true,
            child: HollowIconButton(
              icon: LucideIcons.pinOff,
              label: 'Unpin',
              size: touch ? 44 : 32,
              onPressed: onUnpin,
            ),
          );

    Widget row = HollowPressable(
      onTap: widget.onTap,
      subtle: true,
      semanticButton: false,
      semanticLabel: 'Pinned message from $name. Show it in the channel',
      borderRadius:
          touch ? BorderRadius.zero : BorderRadius.circular(hollow.radiusMd),
      padding:
          EdgeInsets.symmetric(horizontal: inset, vertical: HollowSpacing.sm),
      child: unpin == null
          ? content
          : Row(
              children: [
                Expanded(child: content),
                const SizedBox(width: HollowSpacing.sm),
                unpin,
              ],
            ),
    );
    // A desktop row sits on the dialog's text edge, its hover past it.
    if (!touch) row = HollowBleed(horizontal: inset, child: row);
    if (unpin == null) return row;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: row,
      ),
    );
  }
}
