import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/hover_scope.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/slashed_icon.dart';
import 'package:hollow/src/ui/chat/emoji_picker.dart';
import 'package:hollow/src/ui/chat/emote_image.dart';
import 'package:hollow/src/ui/chat/file_card_status.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Coordinates action bar visibility so only one message shows its bar.
class MessageActionBarController extends ChangeNotifier {
  VoidCallback? _activeClose;
  Object? _activeKey;

  void claim(Object key, VoidCallback forceClose) {
    if (_activeKey == key) return;
    _activeClose?.call();
    _activeKey = key;
    _activeClose = forceClose;
  }

  void release(Object key) {
    if (_activeKey == key) {
      _activeKey = null;
      _activeClose = null;
    }
  }

  /// Dismisses the active hover overlay, on scroll for instance.
  void dismissAll() {
    _activeClose?.call();
    _activeKey = null;
    _activeClose = null;
  }
}

/// Provides the shared controller; goes above the message list.
class MessageActionBarScope extends StatefulWidget {
  final Widget child;
  const MessageActionBarScope({super.key, required this.child});

  @override
  State<MessageActionBarScope> createState() => _MessageActionBarScopeState();

  static MessageActionBarController? of(BuildContext context) {
    return context
        .findAncestorStateOfType<_MessageActionBarScopeState>()
        ?._controller;
  }
}

class _MessageActionBarScopeState extends State<MessageActionBarScope> {
  final _controller = MessageActionBarController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Wraps a message with its hover highlight and action bar.
///
/// Both are Overlay entries, so they never touch the message's layout.
class MessageHoverWrapper extends ConsumerStatefulWidget {
  final Widget child;
  final bool isMe;
  final String? messageId;
  final String currentText;
  final bool isEditing;
  final VoidCallback? onEditStart;
  final void Function(String newText)? onEditSubmit;
  final VoidCallback? onEditCancel;
  final VoidCallback? onDelete;
  final VoidCallback? onReply;
  final void Function(String emoji)? onReaction;
  final VoidCallback? onPin;
  final VoidCallback? onDownload;
  final VoidCallback? onCopy;
  final VoidCallback? onCopyImage;
  final VoidCallback? onInfo;

  /// Affects wording only: [onPin] is a toggle either way, and surfaces with no
  /// pins leave this false.
  final bool isPinned;

  /// This message's file, when it has one. The bar mirrors the CARD through
  /// `fileBarAction()`, because offering Download while the card says "waiting
  /// for a peer" is a button that visibly does nothing. Surfaces with no live
  /// transfers leave it null and keep the plain Download.
  final FileAttachment? fileAttachment;

  const MessageHoverWrapper({
    super.key,
    required this.child,
    required this.isMe,
    this.messageId,
    required this.currentText,
    this.isEditing = false,
    this.onEditStart,
    this.onEditSubmit,
    this.onEditCancel,
    this.onDelete,
    this.onReply,
    this.onReaction,
    this.onPin,
    this.onDownload,
    this.onCopy,
    this.onCopyImage,
    this.onInfo,
    this.isPinned = false,
    this.fileAttachment,
  });

  @override
  ConsumerState<MessageHoverWrapper> createState() =>
      _MessageHoverWrapperState();
}

class _MessageHoverWrapperState extends ConsumerState<MessageHoverWrapper> {
  bool _hovered = false;
  bool _barHovered = false;

  /// Row-hover for descendants (see [HoverScope]), so an animated avatar or
  /// frame plays while the pointer is anywhere over the MESSAGE. A notifier,
  /// because this wrapper drives its overlays without rebuilding.
  final ValueNotifier<bool> _rowHovered = ValueNotifier<bool>(false);
  OverlayEntry? _highlightEntry;
  OverlayEntry? _actionBarEntry;
  Timer? _dismissTimer;
  late TextEditingController _editController;
  late FocusNode _editFocusNode;
  final GlobalKey _messageKey = GlobalKey();
  MessageActionBarController? _controller;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController(text: widget.currentText);
    _editFocusNode = FocusNode(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onEditCancel?.call();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.enter) {
          if (HardwareKeyboard.instance.isShiftPressed) {
            final sel = _editController.selection;
            final text = _editController.text;
            final newText = text.replaceRange(sel.start, sel.end, '\n');
            _editController.value = TextEditingValue(
              text: newText,
              selection: TextSelection.collapsed(offset: sel.start + 1),
            );
            return KeyEventResult.handled;
          }
          final trimmed = _editController.text.trim();
          if (trimmed.isNotEmpty && trimmed != widget.currentText) {
            widget.onEditSubmit?.call(trimmed);
          } else {
            widget.onEditCancel?.call();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
    );
    if (widget.isEditing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _editFocusNode.requestFocus();
        _editController.selection = TextSelection.collapsed(
          offset: _editController.text.length,
        );
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller = MessageActionBarScope.of(context);
  }

  @override
  void didUpdateWidget(MessageHoverWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isEditing && !oldWidget.isEditing) {
      _dismissNow();
      _editController.text = widget.currentText;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _editFocusNode.requestFocus();
        _editController.selection = TextSelection.collapsed(
          offset: _editController.text.length,
        );
      });
    }
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _controller?.release(this);
    _removeOverlays();
    _editController.dispose();
    _editFocusNode.dispose();
    _rowHovered.dispose();
    super.dispose();
  }

  /// What the bar and menu offer for this message's file, mirroring the card.
  ///
  /// `read`, not `watch`: the bar is built the moment the pointer arrives, and
  /// watching the transfer map would rebuild every row in the pane on every
  /// chunk of every unrelated download.
  FileBarAction _fileAction() {
    final attachment = widget.fileAttachment;
    if (attachment == null) return FileBarAction.download;
    return fileBarAction(
      attachment: attachment,
      transfer: ref.read(fileTransferProvider)[attachment.fileId],
    );
  }

  /// Cancels the outstanding ask and lets the card fall back to its plain
  /// Download button without waiting for the next event.
  Future<void> _stopWaitingForFile(String fileId) async {
    try {
      await ref.read(fileTransferProvider.notifier).stopWaitingForFile(fileId);
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(context, 'Could not stop the request: $e',
          type: HollowToastType.error);
    }
  }

  /// The stop tap for the bar and menu, null when there is no file to stop
  /// asking for.
  VoidCallback? _stopWaitingTap() {
    final attachment = widget.fileAttachment;
    if (attachment == null) return null;
    return () {
      _dismissNow();
      _stopWaitingForFile(attachment.fileId);
    };
  }

  void _showOverlays() {
    if (_highlightEntry != null) return;

    final renderBox =
        _messageKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final overlay = Overlay.of(context);
    final overlayBox =
        overlay.context.findRenderObject() as RenderBox?;
    if (overlayBox == null) return;

    final size = renderBox.size;
    final offset = renderBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    final hollow = HollowTheme.of(context);
    final screenWidth = overlayBox.size.width;

    _highlightEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: offset.dx,
        top: offset.dy,
        width: size.width,
        height: size.height,
        child: IgnorePointer(
          child: Container(
            color: hollow.textPrimary.withValues(alpha: 0.03),
          ),
        ),
      ),
    );

    final hasAnyAction = (widget.isMe && widget.messageId != null) ||
        widget.onReply != null ||
        widget.onReaction != null ||
        widget.onDownload != null ||
        widget.onCopy != null ||
        widget.onCopyImage != null ||
        widget.onInfo != null;
    if (hasAnyAction) {
      final double barTop = offset.dy + (size.height / 2) - 14;
      final double barRight =
          screenWidth - (offset.dx + size.width) + HollowSpacing.md;

      _actionBarEntry = OverlayEntry(
        builder: (context) => Positioned(
          top: barTop,
          right: barRight,
          child: MouseRegion(
            onEnter: (_) => _onBarEnter(),
            onExit: (_) => _onBarExit(),
            child: _ActionBarContent(
              hollow: hollow,
              onCopy: widget.onCopy != null
                  ? () {
                      _dismissNow();
                      widget.onCopy?.call();
                    }
                  : null,
              onReaction: widget.onReaction != null
                  ? (globalPosition) {
                      _dismissNow();
                      showEmojiPicker(
                        context: context,
                        anchorPosition: globalPosition,
                        serverId: EmoteScope.of(context)?.serverId,
                        onSelect: (emoji) => widget.onReaction?.call(emoji),
                      );
                    }
                  : null,
              onReply: widget.onReply != null
                  ? () {
                      _dismissNow();
                      widget.onReply?.call();
                    }
                  : null,
              onEdit: widget.onEditStart != null
                  ? () {
                      _dismissNow();
                      widget.onEditStart?.call();
                    }
                  : null,
              onDelete: widget.onDelete != null
                  ? () {
                      _dismissNow();
                      widget.onDelete?.call();
                    }
                  : null,
              onPin: widget.onPin != null
                  ? () {
                      _dismissNow();
                      widget.onPin?.call();
                    }
                  : null,
              onDownload: widget.onDownload != null
                  ? () {
                      _dismissNow();
                      widget.onDownload?.call();
                    }
                  : null,
              // The bar says what the card says.
              fileAction: _fileAction(),
              onStopWaiting: _stopWaitingTap(),
              onCopyImage: widget.onCopyImage != null
                  ? () {
                      _dismissNow();
                      widget.onCopyImage?.call();
                    }
                  : null,
              onInfo: widget.onInfo != null
                  ? () {
                      _dismissNow();
                      widget.onInfo?.call();
                    }
                  : null,
              // Without this button the rest of the menu is reachable only by
              // right-clicking.
              onMore: (globalPosition) =>
                  _openContextMenu(globalPosition),
            ),
          ),
        ),
      );
    }

    overlay.insert(_highlightEntry!);
    if (_actionBarEntry != null) {
      overlay.insert(_actionBarEntry!);
    }
  }

  void _removeOverlays() {
    _highlightEntry?.remove();
    _highlightEntry?.dispose();
    _highlightEntry = null;
    _actionBarEntry?.remove();
    _actionBarEntry?.dispose();
    _actionBarEntry = null;
  }

  void _scheduleDismiss() {
    _dismissTimer?.cancel();
    _dismissTimer = Timer(const Duration(milliseconds: 60), () {
      if (!_hovered && !_barHovered) {
        _controller?.release(this);
        _removeOverlays();
        if (mounted) setState(() {});
      }
    });
  }

  void _dismissNow() {
    _dismissTimer?.cancel();
    _hovered = false;
    _barHovered = false;
    _controller?.release(this);
    _removeOverlays();
  }

  void _forceClose() {
    _dismissTimer?.cancel();
    _hovered = false;
    _barHovered = false;
    _removeOverlays();
    if (mounted) setState(() {});
  }

  void _onBarEnter() {
    _barHovered = true;
    _dismissTimer?.cancel();
  }

  void _onBarExit() {
    _barHovered = false;
    _scheduleDismiss();
  }

  void _onMessageEnter() {
    _rowHovered.value = true;
    if (widget.isEditing) return;
    _dismissTimer?.cancel();
    _controller?.claim(this, _forceClose);
    _hovered = true;
    _showOverlays();
  }

  void _onMessageExit() {
    _rowHovered.value = false;
    _hovered = false;
    _scheduleDismiss();
  }

  /// Opens the right-click menu at the pointer.
  ///
  /// Every row is built from the callbacks this wrapper already holds, so each
  /// surface gets the menu without touching its call site and no row can offer
  /// an action the surface did not wire up.
  void _openContextMenu(Offset globalPosition) {
    if (widget.isEditing) return;
    // Window coordinates are not overlay coordinates under interface zoom.
    final anchor = overlayPositionOf(context, globalPosition);
    if (_buildMenuEntries(anchor).isEmpty) return;
    _dismissNow();
    showHollowMenu(
      context: context,
      anchor: anchor,
      builder: (_, _) => _buildMenuEntries(anchor),
    );
  }

  /// [anchor] is the pointer position in overlay space. A row opening a second
  /// popup anchors to IT, never to this widget's context: the wrapper's render
  /// box is the whole message row, whose origin is at the far left of the pane.
  List<HollowMenuEntry> _buildMenuEntries(Offset anchor) {
    // Grouped then joined with dividers, so an absent group leaves no doubled
    // or dangling separator.
    final groups = <List<HollowMenuEntry>>[];

    final onReaction = widget.onReaction;
    if (onReaction != null) {
      groups.add([
        HollowMenuCustom(_QuickReactionStrip(onSelect: onReaction)),
        HollowMenuItem(
          icon: LucideIcons.smilePlus,
          label: 'Add reaction',
          onTap: () => showEmojiPicker(
            context: context,
            anchorPosition: anchor,
            serverId: EmoteScope.of(context)?.serverId,
            onSelect: onReaction,
          ),
        ),
      ]);
    }

    if (widget.onReply != null) {
      groups.add([
        HollowMenuItem(
          icon: LucideIcons.reply,
          label: 'Reply',
          onTap: widget.onReply,
        ),
      ]);
    }

    final fileAction = _fileAction();
    final edit = <HollowMenuEntry>[
      if (widget.onCopy != null)
        HollowMenuItem(
          icon: LucideIcons.copy,
          label: 'Copy text',
          onTap: widget.onCopy,
        ),
      if (widget.onCopyImage != null)
        HollowMenuItem(
          icon: LucideIcons.image,
          label: 'Copy image',
          onTap: widget.onCopyImage,
        ),
      // Same rule as the hover bar: a row that re-asks for a file nobody can
      // serve is the button that does nothing, one layer down.
      if (widget.onDownload != null && fileAction != FileBarAction.none)
        HollowMenuItem(
          icon: LucideIcons.download,
          label: fileBarActionLabel(fileAction),
          onTap: fileAction == FileBarAction.stopWaiting
              ? _stopWaitingTap()
              : widget.onDownload,
        ),
      if (widget.onPin != null)
        HollowMenuItem(
          icon: widget.isPinned ? LucideIcons.pinOff : LucideIcons.pin,
          label: widget.isPinned ? 'Unpin message' : 'Pin message',
          onTap: widget.onPin,
        ),
      if (widget.onEditStart != null)
        HollowMenuItem(
          icon: LucideIcons.pencil,
          label: 'Edit message',
          onTap: widget.onEditStart,
        ),
    ];
    if (edit.isNotEmpty) groups.add(edit);

    if (widget.onDelete != null) {
      groups.add([
        HollowMenuItem(
          icon: LucideIcons.trash2,
          label: 'Delete message',
          isDanger: true,
          onTap: widget.onDelete,
        ),
      ]);
    }

    final messageId = widget.messageId;
    final meta = <HollowMenuEntry>[
      if (widget.onInfo != null)
        HollowMenuItem(
          icon: LucideIcons.shieldCheck,
          label: 'Message proof',
          onTap: widget.onInfo,
        ),
      if (messageId != null)
        HollowMenuItem(
          icon: LucideIcons.fingerprint,
          label: 'Copy message ID',
          onTap: () => _copyMessageId(messageId),
        ),
    ];
    if (meta.isNotEmpty) groups.add(meta);

    final entries = <HollowMenuEntry>[];
    for (final group in groups) {
      if (entries.isNotEmpty) entries.add(const HollowMenuDivider());
      entries.addAll(group);
    }
    return entries;
  }

  Future<void> _copyMessageId(String messageId) async {
    await Clipboard.setData(ClipboardData(text: messageId));
    if (!mounted) return;
    HollowToast.show(context, 'Message ID copied',
        type: HollowToastType.success);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isEditing) {
      return _buildEditView(HollowTheme.of(context));
    }

    return GestureDetector(
      // Right-click opens the full message menu (issue #61).
      onSecondaryTapUp: (details) => _openContextMenu(details.globalPosition),
      child: MouseRegion(
        onEnter: (_) => _onMessageEnter(),
        onExit: (_) => _onMessageExit(),
        child: KeyedSubtree(
          key: _messageKey,
          child: HoverScope(hovered: _rowHovered, child: widget.child),
        ),
      ),
    );
  }

  Widget _buildEditView(HollowTheme hollow) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.xs,
      ),
      color: hollow.textPrimary.withValues(alpha: 0.03),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _editController,
            focusNode: _editFocusNode,
            style: HollowTypography.body.copyWith(color: hollow.textPrimary),
            maxLines: 5,
            minLines: 1,
            decoration: InputDecoration(
              filled: true,
              fillColor: hollow.elevated,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm,
                vertical: HollowSpacing.sm,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                borderSide: BorderSide(color: hollow.accent),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                borderSide: BorderSide(color: hollow.accent),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                borderSide: BorderSide(color: hollow.accent, width: 1.5),
              ),
            ),
            onTapOutside: (_) => widget.onEditCancel?.call(),
          ),
          const SizedBox(height: 4),
          Text(
            'escape to cancel  •  enter to save  •  shift+enter for new line',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary.withValues(alpha: 0.5),
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

/// The action bar's buttons.
class _ActionBarContent extends StatelessWidget {
  final HollowTheme hollow;
  final VoidCallback? onCopy;
  final void Function(Offset globalPosition)? onReaction;
  final VoidCallback? onReply;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onPin;
  final VoidCallback? onDownload;
  final VoidCallback? onCopyImage;
  final VoidCallback? onInfo;

  /// What the file control offers, mirroring the card.
  final FileBarAction fileAction;

  /// The [FileBarAction.stopWaiting] tap.
  final VoidCallback? onStopWaiting;

  /// Opens the full message menu, receiving the button's WINDOW position, the
  /// same thing a right click hands over.
  final void Function(Offset globalPosition)? onMore;

  const _ActionBarContent({
    required this.hollow,
    this.onCopy,
    this.onReaction,
    this.onReply,
    this.onEdit,
    this.onDelete,
    this.onPin,
    this.onDownload,
    this.onCopyImage,
    this.onInfo,
    this.fileAction = FileBarAction.download,
    this.onStopWaiting,
    this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        border: Border.all(color: hollow.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onDownload != null)
            _FileActionButton(
              hollow: hollow,
              action: fileAction,
              onDownload: onDownload,
              onStopWaiting: onStopWaiting,
            ),
          if (onCopy != null)
            HollowPressable(
              onTap: onCopy,
              semanticLabel: 'Copy',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(
                LucideIcons.copy,
                size: 14,
                color: hollow.textSecondary,
              ),
            ),
          if (onCopyImage != null)
            HollowPressable(
              onTap: onCopyImage,
              semanticLabel: 'Copy image',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(
                LucideIcons.image,
                size: 14,
                color: hollow.textSecondary,
              ),
            ),
          if (onReaction != null)
            _EmojiButton(hollow: hollow, onReaction: onReaction!),
          if (onReply != null)
            HollowPressable(
              onTap: onReply,
              semanticLabel: 'Reply',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(
                LucideIcons.reply,
                size: 14,
                color: hollow.textSecondary,
              ),
            ),
          if (onInfo != null)
            HollowPressable(
              onTap: onInfo,
              semanticLabel: 'View message proof',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(
                LucideIcons.shieldCheck,
                size: 14,
                color: hollow.textSecondary,
              ),
            ),
          if (onPin != null)
            HollowPressable(
              onTap: onPin,
              semanticLabel: 'Pin message',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(
                LucideIcons.pin,
                size: 14,
                color: hollow.textSecondary,
              ),
            ),
          if (onEdit != null)
            HollowPressable(
              onTap: onEdit,
              semanticLabel: 'Edit message',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(
                LucideIcons.pencil,
                size: 14,
                color: hollow.textSecondary,
              ),
            ),
          if (onDelete != null)
            HollowPressable(
              onTap: onDelete,
              semanticLabel: 'Delete message',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(
                LucideIcons.trash2,
                size: 14,
                color: hollow.error,
              ),
            ),
          if (onMore != null)
            _MoreButton(hollow: hollow, onMore: onMore!),
        ],
      ),
    );
  }
}

/// The bar's file control, mirroring the card.
///
/// Download and Try again are one action under two words; stop is a different
/// action and gets a different glyph, because Download while the ask is queued
/// re-issues a request that visibly does nothing.
class _FileActionButton extends StatelessWidget {
  final HollowTheme hollow;
  final FileBarAction action;
  final VoidCallback? onDownload;
  final VoidCallback? onStopWaiting;

  const _FileActionButton({
    required this.hollow,
    required this.action,
    required this.onDownload,
    required this.onStopWaiting,
  });

  @override
  Widget build(BuildContext context) {
    if (action == FileBarAction.none) return const SizedBox.shrink();
    final stop = action == FileBarAction.stopWaiting;
    final onTap = stop ? onStopWaiting : onDownload;
    // A surface with no stop hook offers nothing rather than a control that
    // cannot fire.
    if (onTap == null) return const SizedBox.shrink();
    final label = fileBarActionLabel(action);
    return HollowTooltip(
      message: label,
      child: HollowPressable(
        onTap: onTap,
        semanticLabel: label,
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        padding: const EdgeInsets.all(6),
        child: stop
            ? SlashedIcon(
                icon: LucideIcons.download,
                size: 14,
                color: hollow.accent,
                // The bar's own surface, so the slash cuts the glyph.
                backgroundColor: hollow.elevated,
              )
            : Icon(
                LucideIcons.download,
                size: 14,
                color: hollow.accent,
              ),
      ),
    );
  }
}

/// Overflow button: the whole message menu without a right click. Captures its
/// own position, or the menu opens at the far-left origin of the message row.
class _MoreButton extends StatelessWidget {
  final HollowTheme hollow;
  final void Function(Offset globalPosition) onMore;

  const _MoreButton({required this.hollow, required this.onMore});

  @override
  Widget build(BuildContext context) {
    return HollowPressable(
      semanticLabel: 'More message actions',
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.all(6),
      onTap: () {
        final box = context.findRenderObject() as RenderBox?;
        final position = box == null
            ? Offset.zero
            : box.localToGlobal(Offset(0, box.size.height));
        onMore(position);
      },
      child: Icon(
        LucideIcons.moreHorizontal,
        size: 14,
        color: hollow.textSecondary,
      ),
    );
  }
}

/// The one-click reaction row at the top of the message context menu, on the
/// same [kQuickReactionEmojis] the mobile action sheet uses so the two cannot
/// drift. The hover bar's smiley opens the full picker instead.
class _QuickReactionStrip extends StatelessWidget {
  final void Function(String emoji) onSelect;

  const _QuickReactionStrip({required this.onSelect});

  static const _count = 6;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (var i = 0; i < _count; i++)
          HollowPressable(
            onTap: () {
              HollowMenuScope.dismiss(context);
              onSelect(kQuickReactionEmojis[i]);
            },
            semanticLabel: 'React ${kQuickReactionEmojis[i]}',
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            child: Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              child: Text(
                kQuickReactionEmojis[i],
                style: const TextStyle(fontSize: 17),
              ),
            ),
          ),
      ],
    );
  }
}

/// Emoji button that captures its own position for the picker anchor.
class _EmojiButton extends StatelessWidget {
  final HollowTheme hollow;
  final void Function(Offset globalPosition) onReaction;

  const _EmojiButton({
    required this.hollow,
    required this.onReaction,
  });

  @override
  Widget build(BuildContext context) {
    return HollowPressable(
      onTap: () {
        onReaction(overlayAnchorOf(context));
      },
      semanticLabel: 'Add reaction',
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.all(6),
      child: Icon(
        LucideIcons.smile,
        size: 14,
        color: hollow.textSecondary,
      ),
    );
  }
}
