import 'package:flutter/material.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/emoji_picker.dart';
import 'package:hollow/src/ui/chat/file_card_status.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/slashed_icon.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

const _kQuickReactionCount = 6;

void showMobileMessageActions({
  required BuildContext context,
  required String messageText,
  required String senderName,
  required String timestamp,
  required bool isMe,
  VoidCallback? onReply,
  VoidCallback? onEdit,
  VoidCallback? onDelete,
  VoidCallback? onCopy,
  VoidCallback? onDownload,
  void Function(String emoji)? onReaction,
  VoidCallback? onInfo,
  VoidCallback? onPin,
  bool isPinned = false,
  String? serverId,
  /// What the file row offers, mirroring the card. The caller reads it from
  /// `fileBarAction()` as the sheet opens.
  FileBarAction fileAction = FileBarAction.download,
  VoidCallback? onStopWaiting,
}) {
  showHollowSheet(
    context: context,
    // The emoji grid and long action lists exceed the default sheet cap on
    // short phones.
    scrollControlled: true,
    builder: (_) => _MessageActionsSheet(
      messageText: messageText,
      senderName: senderName,
      timestamp: timestamp,
      isMe: isMe,
      onReply: onReply,
      onEdit: onEdit,
      onDelete: onDelete,
      onCopy: onCopy,
      onDownload: onDownload,
      onReaction: onReaction,
      onInfo: onInfo,
      onPin: onPin,
      isPinned: isPinned,
      serverId: serverId,
      fileAction: fileAction,
      onStopWaiting: onStopWaiting,
    ),
  );
}

enum _SheetView { actions, allEmojis, deleteConfirm }

class _MessageActionsSheet extends StatefulWidget {
  final String messageText;
  final String senderName;
  final String timestamp;
  final bool isMe;
  final VoidCallback? onReply;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onCopy;
  final VoidCallback? onDownload;
  final void Function(String emoji)? onReaction;
  final VoidCallback? onInfo;
  final VoidCallback? onPin;
  final bool isPinned;
  final String? serverId;
  final FileBarAction fileAction;
  final VoidCallback? onStopWaiting;

  const _MessageActionsSheet({
    required this.messageText,
    required this.senderName,
    required this.timestamp,
    required this.isMe,
    this.onReply,
    this.onEdit,
    this.onDelete,
    this.onCopy,
    this.onDownload,
    this.onReaction,
    this.onInfo,
    this.onPin,
    this.isPinned = false,
    this.serverId,
    this.fileAction = FileBarAction.download,
    this.onStopWaiting,
  });

  @override
  State<_MessageActionsSheet> createState() => _MessageActionsSheetState();
}

class _MessageActionsSheetState extends State<_MessageActionsSheet> {
  _SheetView _view = _SheetView.actions;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Scrolls when the content is taller than the sheet cap.
            Flexible(
              child: SingleChildScrollView(
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  child: switch (_view) {
                    _SheetView.actions => _buildActionsView(hollow),
                    _SheetView.allEmojis => _buildAllEmojisView(hollow),
                    _SheetView.deleteConfirm => _buildDeleteConfirmView(hollow),
                  },
                ),
              ),
            ),

            const SizedBox(height: HollowSpacing.sm),
          ],
        ),
      ),
    );
  }

  /// The file row mirroring the card: Save File, Try again, a stop control, or
  /// nothing once retention has removed the file. Null offers no file row.
  Widget? _fileActionRow() {
    final action = widget.fileAction;
    final download = widget.onDownload;
    if (download == null || action == FileBarAction.none) return null;
    if (action == FileBarAction.stopWaiting) {
      final stop = widget.onStopWaiting;
      // A surface with no stop hook offers nothing, never a dead control.
      if (stop == null) return null;
      return _ActionRow(
        icon: LucideIcons.download,
        slashed: true,
        label: fileBarActionLabel(action),
        onTap: () {
          Navigator.pop(context);
          stop();
        },
      );
    }
    return _ActionRow(
      icon: LucideIcons.download,
      label: fileBarActionLabel(action, download: 'Save file'),
      onTap: () {
        Navigator.pop(context);
        download();
      },
    );
  }

  Widget _buildActionsView(HollowTheme hollow) {
    final fileRow = _fileActionRow();
    void run(VoidCallback action) {
      Navigator.pop(context);
      action();
    }

    // The same groups, in the same order, as the desktop message menu.
    final groups = <List<Widget>>[
      [
        if (widget.onReply != null)
          _ActionRow(
            icon: LucideIcons.reply,
            label: 'Reply',
            onTap: () => run(widget.onReply!),
          ),
      ],
      [
        if (widget.onCopy != null)
          _ActionRow(
            icon: LucideIcons.copy,
            label: 'Copy text',
            onTap: () => run(widget.onCopy!),
          ),
        ?fileRow,
        if (widget.onPin != null)
          _ActionRow(
            icon: widget.isPinned ? LucideIcons.pinOff : LucideIcons.pin,
            label: widget.isPinned ? 'Unpin message' : 'Pin message',
            onTap: () => run(widget.onPin!),
          ),
        if (widget.onEdit != null)
          _ActionRow(
            icon: LucideIcons.pencil,
            label: 'Edit message',
            onTap: () => run(widget.onEdit!),
          ),
      ],
      [
        if (widget.onInfo != null)
          _ActionRow(
            icon: LucideIcons.shieldCheck,
            label: 'Message proof',
            onTap: () => run(widget.onInfo!),
          ),
      ],
      [
        if (widget.onDelete != null)
          _ActionRow(
            icon: LucideIcons.trash2,
            label: 'Delete message',
            color: hollow.error,
            onTap: () => setState(() => _view = _SheetView.deleteConfirm),
          ),
      ],
    ].where((g) => g.isNotEmpty).toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _MessagePreview(
          senderName: widget.senderName,
          messageText: widget.messageText,
          timestamp: widget.timestamp,
        ),
        const SizedBox(height: HollowSpacing.md),
        if (widget.onReaction != null) ...[
          _QuickReactionsRow(
            onReaction: (emoji) {
              Navigator.pop(context);
              widget.onReaction!(emoji);
            },
            onMoreTap: () => setState(() => _view = _SheetView.allEmojis),
          ),
          const SizedBox(height: HollowSpacing.sm),
        ],
        for (final group in groups) ...[
          const HollowDivider(),
          const SizedBox(height: HollowSpacing.xs),
          ...group,
          const SizedBox(height: HollowSpacing.xs),
        ],
      ],
    );
  }

  Widget _buildAllEmojisView(HollowTheme hollow) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
          child: Row(
            children: [
              HollowIconButton(
                icon: LucideIcons.chevronLeft,
                label: 'Back',
                size: 44,
                onPressed: () => setState(() => _view = _SheetView.actions),
              ),
              const SizedBox(width: HollowSpacing.xs),
              Text(
                'Add a reaction',
                style: HollowTypography.subheading
                    .copyWith(color: hollow.textPrimary),
              ),
            ],
          ),
        ),
        const SizedBox(height: HollowSpacing.sm),
        SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.5,
          child: EmojiPickerBody(
            serverId: widget.serverId,
            onSelect: (emoji) {
              Navigator.pop(context);
              widget.onReaction!(emoji);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDeleteConfirmView(HollowTheme hollow) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Delete this message?',
            style:
                HollowTypography.subheading.copyWith(color: hollow.textPrimary),
          ),
          const SizedBox(height: HollowSpacing.xs),
          Text(
            "This can't be undone.",
            style: HollowTypography.bodyTouch
                .copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.lg),
          Row(
            children: [
              Expanded(
                child: HollowButton.ghost(
                  expand: true,
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: HollowButton.danger(
                  expand: true,
                  onPressed: () {
                    Navigator.pop(context);
                    widget.onDelete!();
                  },
                  child: const Text('Delete'),
                ),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.sm),
        ],
      ),
    );
  }
}

/// The message the sheet acts on, so a long press on the wrong row is caught
/// before anything happens to it.
class _MessagePreview extends StatelessWidget {
  final String senderName;
  final String messageText;
  final String timestamp;

  const _MessagePreview({
    required this.senderName,
    required this.messageText,
    required this.timestamp,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  senderName,
                  overflow: TextOverflow.ellipsis,
                  style: HollowTypography.label
                      .copyWith(color: hollow.textPrimary),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                timestamp,
                style: HollowTypography.monoSmall
                    .copyWith(color: hollow.textTertiary),
              ),
            ],
          ),
          if (messageText.isNotEmpty) ...[
            const SizedBox(height: HollowSpacing.xxs),
            Text(
              messageText,
              style: HollowTypography.bodyTouch
                  .copyWith(color: hollow.textSecondary),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

class _QuickReactionsRow extends StatelessWidget {
  final void Function(String emoji) onReaction;
  final VoidCallback onMoreTap;

  const _QuickReactionsRow({
    required this.onReaction,
    required this.onMoreTap,
  });

  static const double _size = 44;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    Widget cell({required String label, required VoidCallback onTap, required Widget child}) =>
        HollowPressable(
          onTap: onTap,
          semanticLabel: label,
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          backgroundColor: hollow.elevated,
          child: SizedBox.square(dimension: _size, child: Center(child: child)),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (int i = 0; i < _kQuickReactionCount; i++)
            cell(
              label: 'React ${kQuickReactionEmojis[i]}',
              onTap: () => onReaction(kQuickReactionEmojis[i]),
              child: Text(kQuickReactionEmojis[i],
                  style: HollowTypography.heading),
            ),
          cell(
            label: 'More reactions',
            onTap: onMoreTap,
            child: Icon(LucideIcons.smilePlus,
                size: 20, color: hollow.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  /// Cuts the icon the way Lucide's `*Off` glyphs are cut. Lucide has no
  /// `downloadOff`, and a `ban` or an `x` here would read as delete.
  final bool slashed;

  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.slashed = false,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final iconColor = color ?? hollow.textSecondary;
    return HollowPressable(
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
          child: Row(
            children: [
              if (slashed)
                SlashedIcon(
                  icon: icon,
                  size: 20,
                  color: iconColor,
                  // The sheet's own surface, so the slash cuts the glyph.
                  backgroundColor: hollow.overlay,
                )
              else
                Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: HollowSpacing.lg),
              Text(
                label,
                style: HollowTypography.bodyTouch
                    .copyWith(color: color ?? hollow.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
