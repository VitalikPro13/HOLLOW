import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/chat/emoji_picker.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Coordinates action bar visibility across all messages in a list.
/// Only one message can show its action bar at a time.
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

  /// Dismiss the active hover overlay (e.g., on scroll).
  void dismissAll() {
    _activeClose?.call();
    _activeKey = null;
    _activeClose = null;
  }
}

/// Place this above the message ListView to provide the shared controller.
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

/// Wraps a message widget with hover-triggered overlays:
/// - A highlight overlay (tint + teal right border for own messages)
/// - An action bar overlay (edit button)
///
/// Both are Overlay entries — they float on top and never touch the
/// message's layout. The message container stays completely clean.
class MessageHoverWrapper extends StatefulWidget {
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
  });

  @override
  State<MessageHoverWrapper> createState() => _MessageHoverWrapperState();
}

class _MessageHoverWrapperState extends State<MessageHoverWrapper> {
  bool _hovered = false;
  bool _barHovered = false;
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
        // Enter to save, Shift+Enter for newline.
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
    super.dispose();
  }

  void _showOverlays() {
    if (_highlightEntry != null) return;

    final renderBox =
        _messageKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final size = renderBox.size;
    final offset = renderBox.localToGlobal(Offset.zero);
    final hollow = HollowTheme.of(context);
    final screenWidth = MediaQuery.of(context).size.width;

    // --- Highlight overlay (exact match with message rect) ---
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

    // --- Action bar overlay (top-right of message) ---
    final hasAnyAction = (widget.isMe && widget.messageId != null) ||
        widget.onReply != null ||
        widget.onReaction != null ||
        widget.onDownload != null ||
        widget.onCopy != null ||
        widget.onCopyImage != null ||
        widget.onInfo != null;
    if (hasAnyAction) {
      // Vertically center the action bar on the right side of the message.
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
            ),
          ),
        ),
      );
    }

    final overlay = Overlay.of(context);
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
    if (widget.isEditing) return;
    _dismissTimer?.cancel();
    _controller?.claim(this, _forceClose);
    _hovered = true;
    _showOverlays();
  }

  void _onMessageExit() {
    _hovered = false;
    _scheduleDismiss();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isEditing) {
      return _buildEditView(HollowTheme.of(context));
    }

    return GestureDetector(
      onSecondaryTap: widget.onInfo != null
          ? () {
              _dismissNow();
              widget.onInfo?.call();
            }
          : null,
      child: MouseRegion(
        onEnter: (_) => _onMessageEnter(),
        onExit: (_) => _onMessageExit(),
        child: KeyedSubtree(
          key: _messageKey,
          child: widget.child,
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

/// The action bar content — emoji + reply + edit + delete buttons.
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
            HollowPressable(
              onTap: onDownload,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(
                LucideIcons.download,
                size: 14,
                color: hollow.accent,
              ),
            ),
          if (onCopy != null)
            HollowPressable(
              onTap: onCopy,
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
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(
                LucideIcons.trash2,
                size: 14,
                color: hollow.error,
              ),
            ),
        ],
      ),
    );
  }
}

/// Emoji button that captures its global position for the picker anchor.
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
        final box = context.findRenderObject() as RenderBox?;
        final position = box?.localToGlobal(Offset.zero) ?? Offset.zero;
        onReaction(position);
      },
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
