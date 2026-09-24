import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/theme/hollow_shadows.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/hover_scope.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/overlay_hosts.dart';
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
/// The row paints its own highlight behind the message, so it scrolls with it
/// and costs no layout. The bar floats in the Overlay, linked to the row by a
/// [LayerLink] so the compositor carries it along on scroll.
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

  /// The pointer is on the row OR on its bar: leaving the row for the bar
  /// must not drop the highlight.
  final ValueNotifier<bool> _highlighted = ValueNotifier<bool>(false);
  final LayerLink _link = LayerLink();
  OverlayEntry? _actionBarEntry;
  Timer? _dismissTimer;
  late TextEditingController _editController;
  late FocusNode _editFocusNode;
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
    _highlighted.dispose();
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

  bool get _hasAnyAction =>
      (widget.isMe && widget.messageId != null) ||
      widget.onReply != null ||
      widget.onReaction != null ||
      widget.onDownload != null ||
      widget.onCopy != null ||
      widget.onCopyImage != null ||
      widget.onInfo != null;

  /// Where the bar may paint, in overlay space: the message list plus the
  /// bar's overhang above it, so the top row's bar is not cut in half and no
  /// bar ever floats over the composer.
  Rect _barClip(RenderBox overlayBox) {
    final viewport =
        Scrollable.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.hasSize) {
      return Offset.zero & overlayBox.size;
    }
    final r = viewport.localToGlobal(Offset.zero, ancestor: overlayBox) &
        viewport.size;
    return Rect.fromLTRB(r.left, r.top - kActionBarHeight / 2, r.right, r.bottom);
  }

  void _showBar() {
    if (_actionBarEntry != null || !_hasAnyAction) return;
    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (overlayBox == null || !overlayBox.hasSize) return;
    final clip = _barClip(overlayBox);

    _actionBarEntry = OverlayEntry(
      builder: (entryContext) => Positioned.fromRect(
        rect: clip,
        child: ClipRect(
          child: Stack(
            children: [
              CompositedTransformFollower(
                link: _link,
                showWhenUnlinked: false,
                // Straddles the row's top edge, so on a one-line row it never
                // covers the message's own text.
                targetAnchor: Alignment.topRight,
                followerAnchor: Alignment.centerRight,
                offset: const Offset(-HollowSpacing.lg, 0),
                child: MouseRegion(
                  onEnter: (_) => _onBarEnter(),
                  onExit: (_) => _onBarExit(),
                  child: _ActionBarContent(
                    // Read at build, not at hover: a theme switch while the
                    // bar is up repaints it too.
                    hollow: HollowTheme.of(entryContext),
                    onQuickReaction: widget.onReaction != null
                        ? (emoji) {
                            _dismissNow();
                            widget.onReaction?.call(emoji);
                          }
                        : null,
                    onReaction: widget.onReaction != null
                        ? (anchor) {
                            _dismissNow();
                            showEmojiPicker(
                              context: context,
                              anchorPosition: anchor,
                              serverId: EmoteScope.of(context)?.serverId,
                              onSelect: (emoji) =>
                                  widget.onReaction?.call(emoji),
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
                    // Without this button the rest of the menu is reachable
                    // only by right-clicking.
                    onMore: (anchor) => _openMenuAt(anchor, alignEnd: true),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    overlay.insert(_actionBarEntry!);
    OverlayHosts.register(this, _removeOverlays);
  }

  void _removeOverlays() {
    OverlayHosts.unregister(this);
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
        _highlighted.value = false;
      }
    });
  }

  void _dismissNow() {
    _dismissTimer?.cancel();
    _hovered = false;
    _barHovered = false;
    _controller?.release(this);
    _removeOverlays();
    _highlighted.value = false;
  }

  void _forceClose() {
    _dismissTimer?.cancel();
    _hovered = false;
    _barHovered = false;
    _removeOverlays();
    _highlighted.value = false;
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
    _highlighted.value = true;
    _showBar();
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
    // Window coordinates are not overlay coordinates under interface zoom.
    _openMenuAt(overlayPositionOf(context, globalPosition));
  }

  /// [anchor] is already in overlay space. [alignEnd] makes it the menu's
  /// top-right corner, for a trigger at the right of the row.
  void _openMenuAt(Offset anchor, {bool alignEnd = false}) {
    if (widget.isEditing) return;
    if (_buildMenuEntries(anchor).isEmpty) return;
    _dismissNow();
    showHollowMenu(
      context: context,
      anchor: anchor,
      alignEnd: alignEnd,
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
        child: CompositedTransformTarget(
          link: _link,
          child: ValueListenableBuilder<bool>(
            valueListenable: _highlighted,
            builder: (context, lit, child) => DecoratedBox(
              decoration: BoxDecoration(
                color: lit ? HollowTheme.of(context).rowHover : null,
              ),
              child: child,
            ),
            child: HoverScope(hovered: _rowHovered, child: widget.child),
          ),
        ),
      ),
    );
  }

  Widget _buildEditView(HollowTheme hollow) {
    OutlineInputBorder border(Color color) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          borderSide: BorderSide(color: color),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.xs,
      ),
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
                horizontal: HollowSpacing.md,
                vertical: HollowSpacing.sm,
              ),
              border: border(hollow.border),
              enabledBorder: border(hollow.border),
              focusedBorder: border(hollow.accent),
            ),
            onTapOutside: (_) => widget.onEditCancel?.call(),
          ),
          const SizedBox(height: HollowSpacing.xs),
          Text(
            'Enter to save, Escape to cancel, Shift+Enter for a new line',
            style: HollowTypography.caption.copyWith(color: hollow.textTertiary),
          ),
        ],
      ),
    );
  }
}

/// Height of the hover bar; it straddles its row's top edge by half.
const double kActionBarHeight = 32;

/// How many one-click reactions lead the hover bar.
const int _kBarQuickReactions = 3;

/// The action bar's buttons. Everything else lives in the More menu, which is
/// the same menu a right click opens.
class _ActionBarContent extends StatelessWidget {
  final HollowTheme hollow;
  final void Function(String emoji)? onQuickReaction;
  final void Function(Offset anchor)? onReaction;
  final VoidCallback? onReply;
  final VoidCallback? onEdit;
  final void Function(Offset anchor) onMore;

  const _ActionBarContent({
    required this.hollow,
    this.onQuickReaction,
    this.onReaction,
    this.onReply,
    this.onEdit,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final quick = onQuickReaction;
    return Container(
      height: kActionBarHeight,
      padding: const EdgeInsets.all(HollowSpacing.xxs),
      decoration: BoxDecoration(
        color: hollow.overlay,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
        boxShadow: HollowShadows.float,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (quick != null) ...[
            for (var i = 0; i < _kBarQuickReactions; i++)
              _BarButton(
                hollow: hollow,
                label: 'React ${kQuickReactionEmojis[i]}',
                onTap: (_) => quick(kQuickReactionEmojis[i]),
                child: Text(
                  kQuickReactionEmojis[i],
                  style: HollowTypography.body,
                ),
              ),
            Container(
              width: 1,
              height: HollowSpacing.lg,
              margin: const EdgeInsets.symmetric(horizontal: HollowSpacing.xxs),
              color: hollow.border,
            ),
          ],
          if (onReaction != null)
            _BarButton(
              hollow: hollow,
              label: 'Add reaction',
              icon: LucideIcons.smilePlus,
              onTap: onReaction!,
            ),
          if (onReply != null)
            _BarButton(
              hollow: hollow,
              label: 'Reply',
              icon: LucideIcons.reply,
              onTap: (_) => onReply!(),
            ),
          if (onEdit != null)
            _BarButton(
              hollow: hollow,
              label: 'Edit message',
              icon: LucideIcons.pencil,
              onTap: (_) => onEdit!(),
            ),
          _BarButton(
            hollow: hollow,
            label: 'More message actions',
            icon: LucideIcons.moreHorizontal,
            // The menu opens under the button, not at the row's far left.
            anchorBelow: true,
            onTap: onMore,
          ),
        ],
      ),
    );
  }
}

/// One square button on the hover bar. [onTap] receives the button's own
/// anchor in overlay space, for anything it opens.
class _BarButton extends StatelessWidget {
  final HollowTheme hollow;
  final String label;
  final IconData? icon;
  final Widget? child;
  final bool anchorBelow;
  final void Function(Offset anchor) onTap;

  const _BarButton({
    required this.hollow,
    required this.label,
    required this.onTap,
    this.icon,
    this.child,
    this.anchorBelow = false,
  });

  @override
  Widget build(BuildContext context) {
    final side = kActionBarHeight - 2 * HollowSpacing.xxs - 2;
    return HollowTooltip(
      message: label,
      child: HollowPressable(
        semanticLabel: label,
        borderRadius: BorderRadius.circular(hollow.radiusXs),
        onTap: () {
          final box = context.findRenderObject() as RenderBox?;
          onTap(overlayAnchorOf(
            context,
            localOffset: anchorBelow && box != null
                ? Offset(box.size.width, box.size.height)
                : Offset.zero,
          ));
        },
        child: SizedBox.square(
          dimension: side,
          child: Center(
            child: child ??
                Icon(icon, size: 16, color: hollow.textSecondary),
          ),
        ),
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
            borderRadius: BorderRadius.circular(hollow.radiusMd),
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
