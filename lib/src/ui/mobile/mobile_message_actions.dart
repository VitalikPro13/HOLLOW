import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/emoji_picker.dart';
import 'package:hollow/src/ui/chat/file_card_status.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/slashed_icon.dart';
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
  /// What the file row offers, mirroring the card (tmp.txt item 1). The
  /// caller reads it from `fileBarAction()` as the sheet opens.
  FileBarAction fileAction = FileBarAction.download,
  VoidCallback? onStopWaiting,
}) {
  final hollow = HollowTheme.of(context);
  showModalBottomSheet(
    context: context,
    backgroundColor: hollow.surface,
    // The full emoji grid / long action lists can exceed the default sheet
    // cap on short phones — let the sheet size itself and scroll internally.
    isScrollControlled: true,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
    ),
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

            // Scrolls when the content (emoji grid, long action lists) is
            // taller than the sheet cap on short phones.
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

  /// The file row, mirroring the card (tmp.txt item 1): Save File, Try again,
  /// a stop control, or nothing at all once retention has removed the file.
  /// Null means the sheet offers no file row.
  Widget? _fileActionRow() {
    final action = widget.fileAction;
    final download = widget.onDownload;
    if (download == null || action == FileBarAction.none) return null;
    if (action == FileBarAction.stopWaiting) {
      final stop = widget.onStopWaiting;
      // A surface with no stop hook offers nothing rather than a control
      // that cannot fire.
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
      label: fileBarActionLabel(action, download: 'Save File'),
      onTap: () {
        Navigator.pop(context);
        download();
      },
    );
  }

  Widget _buildActionsView(HollowTheme hollow) {
    final fileRow = _fileActionRow();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Message preview
        _MessagePreview(
          senderName: widget.senderName,
          messageText: widget.messageText,
          timestamp: widget.timestamp,
        ),
        const SizedBox(height: HollowSpacing.md),

        // Quick reactions row
        if (widget.onReaction != null) ...[
          _QuickReactionsRow(
            onReaction: (emoji) {
              Navigator.pop(context);
              widget.onReaction!(emoji);
            },
            onMoreTap: () => setState(() => _view = _SheetView.allEmojis),
          ),
          const SizedBox(height: HollowSpacing.sm),
          Divider(height: 1, color: hollow.border),
        ],

        // Action rows
        if (widget.onReply != null)
          _ActionRow(
            icon: LucideIcons.reply,
            label: 'Reply',
            onTap: () {
              Navigator.pop(context);
              widget.onReply!();
            },
          ),
        if (widget.onEdit != null)
          _ActionRow(
            icon: LucideIcons.pencil,
            label: 'Edit Message',
            onTap: () {
              Navigator.pop(context);
              widget.onEdit!();
            },
          ),
        if (widget.onCopy != null)
          _ActionRow(
            icon: LucideIcons.copy,
            label: 'Copy Text',
            onTap: () {
              Navigator.pop(context);
              widget.onCopy!();
            },
          ),
        ?fileRow,
        if (widget.onInfo != null)
          _ActionRow(
            icon: LucideIcons.shieldCheck,
            label: 'Message Info',
            onTap: () {
              Navigator.pop(context);
              widget.onInfo!();
            },
          ),
        if (widget.onPin != null)
          _ActionRow(
            icon: LucideIcons.pin,
            label: widget.isPinned ? 'Unpin Message' : 'Pin Message',
            onTap: () {
              Navigator.pop(context);
              widget.onPin!();
            },
          ),
        if (widget.onDelete != null)
          _ActionRow(
            icon: LucideIcons.trash2,
            label: 'Delete Message',
            color: hollow.error,
            onTap: () => setState(() => _view = _SheetView.deleteConfirm),
          ),
      ],
    );
  }

  Widget _buildAllEmojisView(HollowTheme hollow) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Back button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
          child: Row(
            children: [
              HollowPressable(
                onTap: () => setState(() => _view = _SheetView.actions),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.chevronLeft, size: 16, color: hollow.textSecondary),
                    const SizedBox(width: 4),
                    Text('Back', style: HollowTypography.body.copyWith(color: hollow.textSecondary)),
                  ],
                ),
              ),
              const Spacer(),
              Text('Reactions', style: HollowTypography.body.copyWith(
                color: hollow.textPrimary,
                fontWeight: FontWeight.w600,
              )),
              const Spacer(),
              const SizedBox(width: 60),
            ],
          ),
        ),
        const SizedBox(height: HollowSpacing.md),

        // Full picker: Unicode + server + personal + FFZ emotes.
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
        children: [
          Icon(LucideIcons.alertTriangle, size: 32, color: hollow.error),
          const SizedBox(height: HollowSpacing.md),
          Text(
            'Delete this message?',
            style: HollowTypography.subheading.copyWith(color: hollow.textPrimary),
          ),
          const SizedBox(height: HollowSpacing.xs),
          Text(
            "This can't be undone.",
            style: HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.lg),
          Row(
            children: [
              Expanded(
                child: HollowButton.ghost(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: HollowSpacing.md),
              Expanded(
                child: HollowButton.danger(
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

// ─────────────────────────────────────────────────
// Message preview at top of sheet
// ─────────────────────────────────────────────────

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
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(HollowSpacing.sm),
        decoration: BoxDecoration(
          color: hollow.elevated,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          border: Border.all(color: hollow.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    senderName,
                    style: HollowTypography.caption.copyWith(
                      color: hollow.accent,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  timestamp,
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
            if (messageText.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                messageText,
                style: HollowTypography.body.copyWith(color: hollow.textPrimary),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// Quick reactions row (top 6 + "More..." pill)
// ─────────────────────────────────────────────────

class _QuickReactionsRow extends StatelessWidget {
  final void Function(String emoji) onReaction;
  final VoidCallback onMoreTap;

  const _QuickReactionsRow({
    required this.onReaction,
    required this.onMoreTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (int i = 0; i < _kQuickReactionCount; i++)
            HollowPressable(
              onTap: () => onReaction(kQuickReactionEmojis[i]),
              semanticLabel: 'React ${kQuickReactionEmojis[i]}',
              child: Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: hollow.elevated,
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                ),
                child: Text(kQuickReactionEmojis[i], style: const TextStyle(fontSize: 22)),
              ),
            ),
          HollowPressable(
            onTap: onMoreTap,
            semanticLabel: 'More reactions',
            child: Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: hollow.elevated,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
              ),
              child: Icon(LucideIcons.plus, size: 18, color: hollow.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// Single action row
// ─────────────────────────────────────────────────

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
            if (slashed)
              SlashedIcon(
                icon: icon,
                size: 18,
                color: c,
                // The sheet's own surface, so the slash cuts the glyph.
                backgroundColor: hollow.surface,
              )
            else
              Icon(icon, size: 18, color: c),
            const SizedBox(width: HollowSpacing.md),
            Text(label, style: HollowTypography.body.copyWith(color: c)),
          ],
        ),
      ),
    );
  }
}
