import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_shadows.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/emoji_picker.dart';
import 'package:hollow/src/ui/chat/gif_picker.dart';
import 'package:hollow/src/ui/chat/message_text_parser.dart';
import 'package:hollow/src/ui/chat/sticker_picker.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/overlay_hosts.dart';
import 'package:hollow/src/ui/components/popup_animator.dart';

enum ExpressionTab { emoji, gifs, stickers }

/// The tab the picker reopens on, for this run of the app.
ExpressionTab _lastTab = ExpressionTab.emoji;

/// The composer's one picker for everything that is not typed: emoji, GIFs and
/// stickers, one tab each.
///
/// An emoji goes into the text and closes the picker. A GIF or sticker SENDS
/// on its own and the picker stays open (issue #36), so a run of stickers is a
/// run of clicks. [assets] false leaves only emoji, where a surface cannot
/// send a block asset.
void showExpressionPicker({
  required BuildContext context,
  required Offset anchorPosition,
  required void Function(String emoji) onEmoji,
  required void Function(String token) onAsset,
  Future<void> Function(String path, String fileName)? onSharePack,
  String? serverId,
  bool assets = true,
}) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  final anim = PopupAnimationController();
  // A dialog route renders BEHIND a raw OverlayEntry, so the picker steps
  // aside while one of the emoji tab's own dialogs runs (#76).
  final hidden = ValueNotifier<bool>(false);

  // A rapid double pick fires twice before the removal frame builds, and a
  // second remove() on a removed entry crashes.
  var removed = false;
  void teardown() {
    if (removed) return;
    removed = true;
    OverlayHosts.unregister(entry);
    anim.dismiss(() {
      entry.remove();
      entry.dispose();
      hidden.dispose();
    });
  }

  entry = OverlayEntry(
    builder: (_) => anim.wrapEntry(_PickerHost(
      anchorPosition: anchorPosition,
      anim: anim,
      hidden: hidden,
      onDismiss: teardown,
      child: ExpressionPanel(
        serverId: serverId,
        assets: assets,
        hidden: hidden,
        onEmoji: (emoji) {
          final first = !removed;
          teardown();
          if (first) onEmoji(emoji);
        },
        onAsset: onAsset,
        onSharePack: onSharePack == null
            ? null
            : (path, name) async {
                // Sharing sends, so the panel closes rather than floating
                // over the message that just landed behind it.
                teardown();
                await onSharePack(path, name);
              },
      ),
    )),
  );

  overlay.insert(entry);
  OverlayHosts.register(entry, teardown);
}

/// Places the panel above its button, flipping below when there is no room,
/// behind a barrier that closes it.
class _PickerHost extends StatelessWidget {
  final Offset anchorPosition;
  final PopupAnimationController anim;
  final ValueNotifier<bool> hidden;
  final VoidCallback onDismiss;
  final Widget child;

  const _PickerHost({
    required this.anchorPosition,
    required this.anim,
    required this.hidden,
    required this.onDismiss,
    required this.child,
  });

  static const double _width = 360;
  static const double _height = 440;
  static const double _margin = HollowSpacing.sm;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final screen = MediaQuery.of(context).size;
    final width =
        screen.width < _width + 2 * _margin ? screen.width - 2 * _margin : _width;
    final height = screen.height < _height + 4 * _margin
        ? screen.height - 4 * _margin
        : _height;

    // Right edges line up with the opening button.
    final left = (anchorPosition.dx - width)
        .clamp(_margin, screen.width - width - _margin);
    var top = anchorPosition.dy - height - _margin;
    final flippedBelow = top < _margin;
    if (flippedBelow) {
      top = (anchorPosition.dy + 4 * _margin).clamp(
          _margin, (screen.height - height - _margin).clamp(_margin, double.infinity));
    }

    return ValueListenableBuilder<bool>(
      valueListenable: hidden,
      builder: (_, offstage, content) =>
          Offstage(offstage: offstage, child: content),
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onDismiss,
            ),
          ),
          Positioned(
            left: left,
            top: top,
            child: PopupAnimator(
              controller: anim,
              rise: true,
              alignment:
                  flippedBelow ? Alignment.topRight : Alignment.bottomRight,
              child: Container(
                width: width,
                height: height,
                decoration: BoxDecoration(
                  color: hollow.overlay,
                  borderRadius: BorderRadius.circular(hollow.radiusLg),
                  border: Border.all(color: hollow.border),
                  boxShadow: HollowShadows.float,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(hollow.radiusLg),
                  child: child,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The three tabs themselves, for a host that places them: the desktop
/// popover, or the phone composer where the panel takes the keyboard's place.
class ExpressionPanel extends StatefulWidget {
  final String? serverId;
  final bool assets;

  /// Set by the desktop overlay, which must step aside for a dialog; a sheet
  /// is a route and dialogs already land above it.
  final ValueNotifier<bool>? hidden;
  final void Function(String emoji) onEmoji;
  final void Function(String token) onAsset;
  final Future<void> Function(String path, String fileName)? onSharePack;

  const ExpressionPanel({
    super.key,
    required this.serverId,
    required this.assets,
    this.hidden,
    required this.onEmoji,
    required this.onAsset,
    required this.onSharePack,
  });

  @override
  State<ExpressionPanel> createState() => ExpressionPanelState();
}

class ExpressionPanelState extends State<ExpressionPanel> {
  late ExpressionTab _tab = widget.assets ? _lastTab : ExpressionTab.emoji;

  void _pick(ExpressionTab tab) {
    setState(() => _tab = tab);
    _lastTab = tab;
  }

  @override
  Widget build(BuildContext context) {
    // Only the open tab is built: the GIF tab talks to the proxy the moment it
    // exists, and nobody asked for that from the emoji tab.
    final body = switch (_tab) {
      ExpressionTab.emoji => EmojiPickerBody(
          key: const ValueKey(ExpressionTab.emoji),
          serverId: widget.serverId,
          onSelect: widget.onEmoji,
          onModalFlow: widget.hidden == null
              ? null
              : (busy) => widget.hidden!.value = busy,
        ),
      ExpressionTab.gifs => GifPickerBody(
          key: const ValueKey(ExpressionTab.gifs),
          serverId: widget.serverId,
          onSelect: widget.onAsset,
        ),
      ExpressionTab.stickers => StickerPickerBody(
          key: const ValueKey(ExpressionTab.stickers),
          serverId: widget.serverId,
          onSelect: widget.onAsset,
          onSharePack: widget.onSharePack,
        ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.assets) ...[
          _Tabs(selected: _tab, onPick: _pick),
          const HollowDivider(),
        ],
        Expanded(child: body),
      ],
    );
  }
}

/// The picker's three kinds, as tabs with the accent bar under the open one.
/// Tabs rather than chips: each body carries its own row of chips below, and
/// two chip rows stacked read as one confused row.
class _Tabs extends StatelessWidget {
  final ExpressionTab selected;
  final ValueChanged<ExpressionTab> onPick;

  const _Tabs({required this.selected, required this.onPick});

  static const _labels = {
    ExpressionTab.emoji: 'Emoji',
    ExpressionTab.gifs: 'GIFs',
    ExpressionTab.stickers: 'Stickers',
  };

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return SizedBox(
      height: isTouchForm ? 48 : 40,
      child: Row(
        children: [
          for (final tab in ExpressionTab.values)
            Expanded(
              child: Semantics(
                selected: tab == selected,
                child: HollowPressable(
                  semanticLabel: _labels[tab],
                  onTap: () => onPick(tab),
                  child: Stack(
                    children: [
                      Center(
                        child: Text(
                          _labels[tab]!,
                          style: HollowTypography.label.copyWith(
                            color: tab == selected
                                ? hollow.textPrimary
                                : hollow.textSecondary,
                          ),
                        ),
                      ),
                      if (tab == selected)
                        Positioned(
                          left: HollowSpacing.lg,
                          right: HollowSpacing.lg,
                          bottom: 0,
                          height: 2,
                          child: ColoredBox(color: hollow.accent),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
