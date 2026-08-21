import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/shared_tickers.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/chat/emote_composer.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/chat/message_text_parser.dart';
import 'package:hollow/src/ui/chat/staged_hollow_link_card.dart';
import 'package:hollow/src/ui/chat/staged_link_preview_card.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/ui_scale.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

// ---------------------------------------------------------------------------
// Shared building blocks for the chat panes — ChatPane (DMs) and
// ChannelChatPane are structural twins; everything that is genuinely
// identical between them lives here so the twins can't drift apart.
// chat_pane.dart re-exports the public helpers for the other consumers
// (mobile routes, archive viewers).
// ---------------------------------------------------------------------------

/// Bookkeeping for a link preview whose fetch was still in flight when the
/// user hit send (issue #45).
///
/// The compose box debounces 600 ms after the last keystroke and then fetches
/// OG metadata. Anyone who types a URL and sends immediately beat that fetch,
/// and the result used to be discarded by the stale-guard in `_fetchPreview`
/// — which is the whole "I never get link previews" complaint. The fetch was
/// always still running; nothing was listening for it.
///
/// [arm] records which message the in-flight fetch belongs to, and [claim]
/// hands that message id back exactly once when the fetch lands. All three
/// compose panes share this so the behavior cannot drift between them.
class LatePreviewAttacher {
  ({String url, String messageId})? _pending;

  /// Remember that [messageId] was sent while [url]'s fetch was in flight.
  /// Only one is tracked: a newer send supersedes an older pending one,
  /// matching the single-staged-preview model the composer already has.
  void arm(String url, String messageId) {
    _pending = (url: url, messageId: messageId);
  }

  /// Forget any pending attach (pane disposed, preview dismissed).
  void disarm() => _pending = null;

  /// The message id waiting on [url], or null if nothing is. Consumes the
  /// record, so a duplicate completion cannot attach twice.
  String? claim(String url) {
    final pending = _pending;
    if (pending == null || pending.url != url) return null;
    _pending = null;
    return pending.messageId;
  }

  /// Whether an attach is currently pending — exposed for tests.
  bool get isArmed => _pending != null;
}

/// The URL a just-sent message still owes a card for, or null if none.
///
/// A send outruns its preview two ways, and the slower one is the rarer one:
///
///  1. the debounced fetch is in flight — `stagedLoading` is true;
///  2. the fetch NEVER STARTED, because the user typed the URL and hit Enter
///     inside the 600 ms debounce window, so `_handleSend` cancelled the
///     timer before it fired.
///
/// (2) is what "I paste a link and send" actually looks like, so handling
/// only (1) would leave the common case exactly as broken as before.
///
/// Returns null when a card is already staged (it rides the message), when
/// previews are off, or for a Hollow deep link — those render from a locally
/// parsed card and must never trigger a fetch.
String? pendingPreviewUrl({
  required bool previewsEnabled,
  required bool alreadyStaged,
  required bool stagedLoading,
  required String? stagedUrl,
  required String text,
  required RegExp urlRegex,
}) {
  if (!previewsEnabled || alreadyStaged) return null;
  final url = stagedLoading ? stagedUrl : urlRegex.firstMatch(text)?.group(0);
  if (url == null) return null;
  // `hollow://` never goes near the network — the scheme check covers every
  // link shape, including ones `extractHollowLinks` doesn't recognise, and
  // the composer's URL regex matches the scheme on purpose.
  if (url.startsWith('hollow://') || extractHollowLinks(url).isNotEmpty) {
    return null;
  }
  return url;
}

/// Whether two consecutive messages should be grouped (same sender, within 5 min).
bool shouldGroup({
  required bool currentIsMe,
  required bool previousIsMe,
  required DateTime currentTime,
  required DateTime previousTime,
  String? currentSenderId,
  String? previousSenderId,
}) {
  // For DMs: just check isMe flag.
  // For channels: also check senderId.
  if (currentIsMe != previousIsMe) return false;
  if (currentSenderId != null &&
      previousSenderId != null &&
      currentSenderId != previousSenderId) {
    return false;
  }
  return currentTime.difference(previousTime).inMinutes.abs() < 5;
}

/// Whether a message may tile into its neighbours: it is nothing but a
/// sticker run, and nothing else is attached that would sit in the seam.
/// A reply header, a reaction bar, an "(edited)" suffix or a file card all
/// need the row's own padding back.
bool stickerTileCandidate({
  required String text,
  required bool hasReply,
  required bool hasReactions,
  required bool hasFile,
  required bool isEdited,
}) =>
    !hasReply &&
    !hasReactions &&
    !hasFile &&
    !isEdited &&
    isStickerOnlyMessage(text);

/// The one-block-asset-per-message rule (issue #36), shared by all three send
/// paths so it cannot drift between them.
///
/// Stickers and GIFs are the same visual class — a big block of media at a
/// fixed box — so they share one budget rather than one each: a message
/// carries at most ONE of either. Stacking them was the actual complaint, and
/// a per-kind cap would still allow a sticker and a GIF to stack.
///
/// Both pickers can only ever emit one per send, so this exists for the path
/// they do not own: a hand-typed or pasted `[a:s:…]` / `[a:g:…]`. Check it
/// against the EXPANDED wire text, and fail the send visibly with the
/// composer intact rather than silently trimming what the user wrote.
bool exceedsAssetLimit(String expandedText) =>
    countBlockAssetTokens(expandedText) > 1;

/// User-facing reason for a refused send, so all three panes say it the same.
const String kAssetLimitMessage = 'One sticker or GIF per message';

/// Which seams of a message are continued by its neighbours. A run tiles
/// only where BOTH rows are candidates and the rows are already grouped
/// (same author, within the grouping window) — the same rule that decides
/// whether the avatar repeats.
({bool prev, bool next}) stickerTilingFor({
  required bool selfIsSticker,
  required bool prevIsSticker,
  required bool groupedWithPrev,
  required bool nextIsSticker,
  required bool groupedWithNext,
}) =>
    selfIsSticker
        ? (
            prev: prevIsSticker && groupedWithPrev,
            next: nextIsSticker && groupedWithNext,
          )
        : (prev: false, next: false);

/// Whether a date separator should be shown between two timestamps.
bool shouldShowDateSeparator(DateTime current, DateTime? previous) {
  if (previous == null) return true; // First message always gets a date header.
  return current.year != previous.year ||
      current.month != previous.month ||
      current.day != previous.day;
}

/// ASOT-style date separator: ——— February 16, 2026 ———
class DateSeparator extends StatelessWidget {
  final DateTime date;
  const DateSeparator({super.key, required this.date});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDay = DateTime(date.year, date.month, date.day);
    final diff = today.difference(messageDay).inDays;

    final String label;
    if (diff == 0) {
      label = 'Today';
    } else if (diff == 1) {
      label = 'Yesterday';
    } else {
      const months = [
        'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December',
      ];
      label = '${months[date.month - 1]} ${date.day}, ${date.year}';
    }

    return Padding(
      padding: const EdgeInsets.only(
        top: HollowSpacing.md + 2,
        bottom: HollowSpacing.sm,
        left: HollowSpacing.lg,
        right: HollowSpacing.lg,
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              color: hollow.border,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
            child: Text(
              label,
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary.withValues(alpha: 0.6),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 1,
              color: hollow.border,
            ),
          ),
        ],
      ),
    );
  }
}

/// A gif-or-static thumbnail for a file on disk (gifs animate via
/// [GifFileImage], everything else through Image.file).
Widget gifAwareImage(String path, {double? width, double? height}) =>
    path.toLowerCase().endsWith('.gif')
        ? GifFileImage(
            diskPath: path, width: width, height: height, fit: BoxFit.cover)
        : Image.file(File(path),
            width: width, height: height, fit: BoxFit.cover);

/// Whether a [SelectionArea] wrapped AROUND a scrolling message list would
/// misbehave, so it must be scoped to the ROWS instead (issue #35).
///
/// Upstream cause, not ours: `_ScrollableSelectionContainerDelegate` (Flutter
/// 3.44 scrollable.dart) infers the selection edge by adding the scroll delta
/// in LOCAL space — `box.localToGlobal(local.translate(deltaToOrigin))` — then
/// subtracting the same delta in GLOBAL space. Our root `UiScale` transform
/// sits between the two, so the round trip leaves an error of
/// `scrollOffset * (scale - 1)`: exactly zero at 100%, and growing with how far
/// back the conversation is scrolled. Once that phantom edge lands in the 100px
/// auto-scroll zone, `EdgeDraggingAutoScroller` starts — and nothing in the
/// framework stops it on pointer-up (only a `pending` child result or `dispose`
/// calls `stopAutoScroll`), so it keeps running after the mouse is released.
/// A plain left-click jumped the viewport; a drag toward the top edge never
/// stopped. Long conversations full of stickers and GIFs scroll furthest,
/// which is why the report singled them out.
///
/// Scoping selection to the row removes the Scrollable from between the
/// `SelectableRegion` and the selectables, so that delegate never exists. The
/// cost is cross-message drag-selection, so it is spent ONLY where the bug is
/// real: at 100% the list keeps one SelectionArea and today's behaviour.
/// Delete this and go back to the unconditional wrap once upstream fixes the
/// transform math — guarded by test/widget/chat_selection_autoscroll_test.dart.
bool selectionMustBeScopedToRows(BuildContext context) {
  final scale = UiScaleInfo.maybeOf(context)?.effective ?? 1.0;
  return (scale - 1.0).abs() >= 0.001;
}

/// The chat surfaces' [SelectionArea] — no context menu (message actions own
/// that). [key] must forward the wrapped row's key when this is used per-row
/// inside a list builder: the wrapper is the widget the sliver sees, and
/// `findChildIndexCallback` reads that key.
Widget chatSelectionArea({Key? key, required Widget child}) => SelectionArea(
      key: key,
      contextMenuBuilder: (_, _) => const SizedBox.shrink(),
      child: child,
    );

/// The reversed chat list shell — this is where the vendored-list iron rules
/// live for BOTH panes (see feedback_reverse_chat_lists): `reverse: true`
/// with the newest message at builder index 0 pinned to the bottom edge (no
/// sentinel row, no index-based initial scroll, appends while following never
/// move the viewport), and [findChildIndexCallback] so keyed rows MOVE across
/// index slots instead of remounting when a new message shifts every revIndex
/// by one (full-list blink otherwise — guarded by
/// test/widget/chat_list_element_reuse_test.dart).
///
/// It is also the single chokepoint for the "chat text size" preference
/// (issue #20): the whole list is wrapped in [ChatTextScale], so DM, channel
/// and mobile message surfaces scale together and cannot drift apart.
Widget reversedChatList({
  required BuildContext context,
  Key? listKey,
  required ItemScrollController itemScrollController,
  required ItemPositionsListener itemPositionsListener,
  ScrollOffsetController? scrollOffsetController,
  required int itemCount,
  required Map<String, int> indexByMessageId,
  required Widget Function(BuildContext context, int revIndex) itemBuilder,
  // Mobile passes false: SelectionArea's touch long-press would fight the
  // LongPressMessage action-sheet gesture on every bubble.
  bool selectionArea = true,
  EdgeInsets padding = const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
  // The scrollbar + jump controls (issue #54). Off for surfaces that are not
  // a live feed.
  bool scrollRail = true,
  VoidCallback? onJumpToNewest,
}) {
  // Issue #35: scoped to the rows when scaled — see
  // [selectionMustBeScopedToRows].
  final perRowSelection = selectionArea && selectionMustBeScopedToRows(context);
  // Desktop only: the rail is a real column beside the list, not an overlay
  // on top of it. See [ChatScrollRail] for why that distinction is load
  // bearing.
  final showRail = scrollRail && !_isTouchForm;

  final list = ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
    child: ScrollablePositionedList.builder(
      key: listKey,
      itemScrollController: itemScrollController,
      itemPositionsListener: itemPositionsListener,
      scrollOffsetController: scrollOffsetController,
      reverse: true,
      initialScrollIndex: 0,
      initialAlignment: 0.0,
      padding: padding,
      itemCount: itemCount,
      findChildIndexCallback: (key) {
        if (key is! ValueKey<Object>) return null;
        final id = key.value;
        if (id is! String) return null;
        final i = indexByMessageId[id];
        if (i == null) return null;
        return itemCount - 1 - i;
      },
      itemBuilder: perRowSelection
          ? (context, revIndex) {
              final row = itemBuilder(context, revIndex);
              // Forward the row's ValueKey: the wrapper is the widget the
              // sliver sees, and findChildIndexCallback above reads that key
              // to MOVE rows across index slots instead of remounting them
              // (guarded by chat_list_element_reuse_test.dart).
              return chatSelectionArea(key: row.key, child: row);
            }
          : itemBuilder,
    ),
  );
  final scrollable =
      (!selectionArea || perRowSelection) ? list : chatSelectionArea(child: list);
  if (!showRail) return ChatTextScale(child: scrollable);
  return ChatTextScale(
    child: chatListWithRail(
      list: scrollable,
      rail: ChatScrollRail(
        itemCount: itemCount,
        controller: itemScrollController,
        positions: itemPositionsListener,
        onJumpToNewest: onJumpToNewest,
      ),
    ),
  );
}

/// Puts the scrollbar [rail] in a column of its own to the right of [list].
///
/// **Not a Stack overlay.** The obvious shape — `Stack([list,
/// Positioned.fill(rail)])` — lays out and PAINTS correctly (the rail's box
/// measured 584x171 at the right offset, the thumb and caps drew where they
/// should) and then never receives a single pointer: no hover, no tap, not
/// even a translucent `Listener` at its root firing. Every pointer over the
/// rail went to the scrollable underneath instead. A column cannot have that
/// argument with anything, and a reserved gutter is what the rest of the app
/// does now anyway (`HollowScrollBehavior`), so the rail lives in one.
Widget chatListWithRail({required Widget list, required Widget rail}) {
  return Row(
    // The Row is always inside a bounded box (the pane's Expanded), which is
    // what `stretch` needs — see feedback_dart_patterns.
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(child: list),
      SizedBox(width: kChatRailWidth, child: rail),
    ],
  );
}

/// Width of the chat's scrollbar column. The message list ends where this
/// begins, which buys two things: the rail never paints over a row's right
/// edge (the accent bar that marks your own messages lives exactly there),
/// and it is the one strip of the pane the message hover ACTION BAR cannot
/// reach — that bar right-aligns to `rowRight - HollowSpacing.md`, and it is
/// an OverlayEntry, so anything floating INSIDE the list gets covered by it
/// (issue #54 follow-up: the jump buttons started as round overlays over the
/// bottom-right of the list and the last message's bar sat on top of them).
const double kChatRailWidth = 22.0;

/// Dead strip along the window's outer edge, kept clear of anything clickable.
///
/// On Windows the frameless window's resize border lives INSIDE the client
/// area: `window_manager` answers WM_NCHITTEST with HTRIGHT there, so those
/// pixels never become a Flutter pointer event at all. Measured against a
/// real build: a click 14px in works, 10px in works, 8px in does nothing.
/// The chat is the rightmost pane whenever the member list is closed, so a
/// rail that hugged the edge had its whole middle — thumb and both caps —
/// inside that strip. It rendered perfectly and every widget test passed;
/// clicking it simply did nothing.
const double kWindowEdgeDeadStrip = 8.0;

/// Height reserved at each end of the rail for a jump cap. Reserved whether or
/// not the cap is showing, so the thumb's travel does not change as the caps
/// come and go.
const double _kCapExtent = 22.0;

/// True where a drag rail would fight the platform's own edge gestures.
bool get _isTouchForm => Platform.isAndroid || Platform.isIOS;

/// The chat feed's scrollbar and jump controls (issue #54: "the main feed
/// doesn't have a scrollbar or jump to top, jump to bottom").
///
/// [ScrollablePositionedList] has no pixel offset a normal [Scrollbar] could
/// map onto: its position is "item N, aligned so far into the viewport",
/// deliberately, because that is what keeps a list of variable-height messages
/// still while it grows at both ends. So this is an INDEX scrollbar — the
/// thumb spans the visible index range out of [itemCount] and a drag jumps to
/// the index under the pointer. With rows of different heights the thumb is an
/// estimate rather than a measurement; that is the honest trade for a list you
/// can prepend to without the view moving.
///
/// Indexes here are the REVERSED builder indexes the list itself uses: 0 is
/// the NEWEST message, pinned to the bottom (feedback_reverse_chat_lists), so
/// a HIGHER index is further UP the track.
///
/// The jump-to-top / jump-to-present controls are CAPS at the two ends of the
/// track, the way a native scrollbar puts its arrows there. They were round
/// floating buttons over the bottom-right of the list at first, and the hover
/// action bar of the last message sat on top of them: that bar is centred on
/// whatever row the pointer is over, so there is no spot inside the list it
/// cannot reach, and being an overlay it always wins the click.
///
/// Desktop only. On touch a 16px drag rail would sit under the platform's own
/// edge-swipe gesture and its caps would be far below a comfortable tap
/// target, so the mobile surfaces keep fling scrolling and the unread pill.
class ChatScrollRail extends StatefulWidget {
  final int itemCount;
  final ItemScrollController controller;
  final ItemPositionsListener positions;

  /// Releases the "frozen while reading" display cap and snaps to the newest
  /// message. The pane owns that state, so the rail cannot do it alone —
  /// jumping to index 0 of a frozen list lands on the wrong message.
  final VoidCallback? onJumpToNewest;

  const ChatScrollRail({
    super.key,
    required this.itemCount,
    required this.controller,
    required this.positions,
    this.onJumpToNewest,
  });

  @override
  State<ChatScrollRail> createState() => _ChatScrollRailState();
}

class _ChatScrollRailState extends State<ChatScrollRail> {
  bool _hovering = false;
  bool _dragging = false;

  /// Jumps so the message [fraction] down the track (0 = oldest) sits at the
  /// bottom edge of the viewport. The list clamps an out-of-range jump, which
  /// is what makes the two extremes land exactly on the first and last row.
  void _jumpToFraction(double fraction) {
    if (!widget.controller.isAttached || widget.itemCount == 0) return;
    final f = fraction.clamp(0.0, 1.0);
    final index = ((1.0 - f) * (widget.itemCount - 1)).round();
    widget.controller.jumpTo(index: index.clamp(0, widget.itemCount - 1));
  }

  void _jumpToOldest() {
    if (!widget.controller.isAttached || widget.itemCount == 0) return;
    widget.controller.jumpTo(index: widget.itemCount - 1);
  }

  void _jumpToNewest() {
    final release = widget.onJumpToNewest;
    if (release != null) {
      release();
      return;
    }
    if (widget.controller.isAttached) {
      widget.controller.jumpTo(index: 0, alignment: 0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return ValueListenableBuilder<Iterable<ItemPosition>>(
      valueListenable: widget.positions.itemPositions,
      builder: (context, positions, _) {
        final metrics = _RailMetrics.from(positions, widget.itemCount);
        if (metrics == null) return const SizedBox.shrink();
        return _rail(hollow, metrics);
      },
    );
  }

  /// Track plus the two caps, all inside the gutter.
  Widget _rail(HollowTheme hollow, _RailMetrics metrics) {
    return Padding(
      // Everything interactive stays [kWindowEdgeDeadStrip] clear of the
      // window's outer edge.
      padding: const EdgeInsets.only(right: kWindowEdgeDeadStrip),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: Stack(
          children: [
            // The track never runs under a cap: the ends are reserved either
            // way, so the thumb keeps the same travel as the caps appear.
            Positioned(
              top: _kCapExtent,
              bottom: _kCapExtent,
              left: 0,
              right: 0,
              child: _track(hollow, metrics),
            ),
            if (!metrics.atOldest)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: _kCapExtent,
                child: _RailCap(
                  hollow: hollow,
                  icon: LucideIcons.chevronsUp,
                  label: 'Jump to the oldest message',
                  tooltip: 'Jump to top',
                  onTap: _jumpToOldest,
                ),
              ),
            if (!metrics.atNewest)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: _kCapExtent,
                child: _RailCap(
                  hollow: hollow,
                  icon: LucideIcons.chevronsDown,
                  label: 'Jump to the newest message',
                  tooltip: 'Jump to present',
                  onTap: _jumpToNewest,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _track(HollowTheme hollow, _RailMetrics metrics) {
    final active = _hovering || _dragging;
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackHeight = constraints.maxHeight;
        final thumbHeight =
            (metrics.extent * trackHeight).clamp(28.0, trackHeight);
        // The thumb travels over `trackHeight - thumbHeight`, so its top is
        // scaled into that shorter run: otherwise the oldest page could
        // never be reached.
        final top = metrics.offset * (trackHeight - thumbHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) =>
              _jumpFromPointer(d.localPosition.dy, trackHeight, thumbHeight),
          onVerticalDragStart: (d) {
            setState(() => _dragging = true);
            _jumpFromPointer(d.localPosition.dy, trackHeight, thumbHeight);
          },
          onVerticalDragUpdate: (d) =>
              _jumpFromPointer(d.localPosition.dy, trackHeight, thumbHeight),
          onVerticalDragEnd: (_) => setState(() => _dragging = false),
          onVerticalDragCancel: () => setState(() => _dragging = false),
          child: Semantics(
            label: 'Message list scrollbar',
            child: Stack(
              children: [
                Positioned(
                  top: top,
                  height: thumbHeight,
                  // Centred in what is LEFT of the gutter once the window's
                  // dead edge strip is taken out, not in the gutter itself.
                  left: (constraints.maxWidth - 6) / 2,
                  width: 6,
                  child: AnimatedContainer(
                    duration: HollowDurations.fast,
                    decoration: BoxDecoration(
                      color: hollow.textSecondary
                          .withValues(alpha: active ? 0.55 : 0.28),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Maps a pointer on the track to a position, treating the pointer as the
  /// MIDDLE of the thumb so the list does not jump out from under the grab.
  ///
  /// The top of the track is the OLDEST end — the same direction
  /// [_RailMetrics.offset] measures — so the normalised pointer IS the
  /// fraction, with no inversion. (There was one here; it sent every drag the
  /// wrong way, which is what
  /// test/widget/chat_scroll_rail_test.dart now pins down.)
  void _jumpFromPointer(double dy, double trackHeight, double thumbHeight) {
    final travel = trackHeight - thumbHeight;
    if (travel <= 0) return;
    _jumpToFraction(((dy - thumbHeight / 2) / travel).clamp(0.0, 1.0));
  }

}

/// One end cap of the rail: scrollbar-arrow shaped, sized to the gutter, and
/// out of reach of the message action bar.
class _RailCap extends StatelessWidget {
  final HollowTheme hollow;
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;

  const _RailCap({
    required this.hollow,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return HollowTooltip(
      message: tooltip,
      child: HollowPressable(
        semanticLabel: label,
        onTap: onTap,
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        backgroundColor: hollow.elevated,
        padding: EdgeInsets.zero,
        child: Center(
          child: Icon(icon, size: 12, color: hollow.textSecondary),
        ),
      ),
    );
  }
}

/// Where the thumb sits and how big it is, derived from the visible index
/// range. Null when the whole conversation fits and there is nothing to
/// scroll.
class _RailMetrics {
  /// 0 = thumb at the top of its travel (oldest), 1 = at the bottom (newest).
  final double offset;

  /// Visible share of the conversation, 0..1.
  final double extent;
  final bool atNewest;
  final bool atOldest;

  const _RailMetrics({
    required this.offset,
    required this.extent,
    required this.atNewest,
    required this.atOldest,
  });

  static _RailMetrics? from(Iterable<ItemPosition> positions, int itemCount) {
    if (itemCount <= 1 || positions.isEmpty) return null;
    var minIndex = itemCount;
    var maxIndex = -1;
    for (final p in positions) {
      if (p.index < minIndex) minIndex = p.index;
      if (p.index > maxIndex) maxIndex = p.index;
    }
    if (maxIndex < 0) return null;
    final visible = (maxIndex - minIndex + 1).clamp(1, itemCount);
    if (visible >= itemCount) return null;
    // Reversed indexes: the higher the top-most visible index, the closer to
    // the OLDEST end, which is the TOP of the track.
    final aboveViewport = itemCount - 1 - maxIndex;
    final scrollable = itemCount - visible;
    return _RailMetrics(
      offset:
          scrollable <= 0 ? 0 : (aboveViewport / scrollable).clamp(0.0, 1.0),
      extent: visible / itemCount,
      atNewest: minIndex <= 0,
      atOldest: maxIndex >= itemCount - 1,
    );
  }
}

/// One keyed chat-row shell: optional date separator above, extra top padding
/// on group headers. ValueKey(messageId): rows hold per-item state (spoiler
/// reveal, hover, decoded frames) that must not shift onto a different
/// message on delete/trim.
Widget dateSeparatedChatRow({
  required Object rowKey,
  required DateTime timestamp,
  required DateTime? prevTimestamp,
  required bool showHeader,
  required Widget child,
}) {
  final showDate = shouldShowDateSeparator(timestamp, prevTimestamp);
  final messageWidget = showHeader
      ? Padding(
          padding: const EdgeInsets.only(top: HollowSpacing.sm + 2),
          child: child,
        )
      : child;
  return KeyedSubtree(
    key: ValueKey<Object>(rowKey),
    child: showDate
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DateSeparator(date: timestamp),
              messageWidget,
            ],
          )
        : messageWidget,
  );
}

/// Reply-target preview bar shown above the input while composing a reply.
class ChatReplyPreviewBar extends StatelessWidget {
  final String? senderName;
  final String? text;
  final String? imagePath;
  final VoidCallback onCancel;

  const ChatReplyPreviewBar({
    super.key,
    required this.senderName,
    required this.text,
    required this.imagePath,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final path = imagePath;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.xs + 2,
      ),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(
          top: BorderSide(color: hollow.border),
          left: BorderSide(color: hollow.accent, width: 3),
        ),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.reply, size: 14, color: hollow.accent),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Replying to ${senderName ?? ''}',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.accent,
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                  ),
                ),
                Row(
                  children: [
                    if (path != null && File(path).existsSync()) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: gifAwareImage(path, width: 32, height: 32),
                      ),
                      const SizedBox(width: HollowSpacing.xs),
                    ],
                    Expanded(
                      child: Text(
                        text ?? '',
                        style: HollowTypography.body.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 12,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          HollowPressable(
            semanticLabel: 'Cancel reply',
            onTap: onCancel,
            padding: const EdgeInsets.all(HollowSpacing.xs),
            child: Icon(LucideIcons.x, size: 16, color: hollow.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Staged (picked but unsent) file attachment preview above the input bar.
class StagedFilePreviewBar extends StatelessWidget {
  final String filePath;
  final String? fileName;
  final bool isImage;
  final VoidCallback onRemove;

  const StagedFilePreviewBar({
    super.key,
    required this.filePath,
    required this.fileName,
    required this.isImage,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
          HollowSpacing.md, HollowSpacing.sm, HollowSpacing.md, 0),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(top: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          if (isImage)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: gifAwareImage(filePath, width: 48, height: 48),
            )
          else
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: hollow.elevated,
                borderRadius: BorderRadius.circular(6),
              ),
              child:
                  Icon(LucideIcons.file, color: hollow.textSecondary, size: 20),
            ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              fileName ?? '',
              style:
                  HollowTypography.caption.copyWith(color: hollow.textPrimary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          HollowPressable(
            semanticLabel: 'Remove attachment',
            onTap: onRemove,
            padding: const EdgeInsets.all(HollowSpacing.xs),
            child: Icon(LucideIcons.x, size: 16, color: hollow.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Staged link card area: a Hollow invite card when the composed URL is a
/// hollow:// link, else the OG link-preview card while one is staged.
/// Renders nothing when no URL is staged.
class StagedLinkArea extends StatelessWidget {
  final HollowLink? hollowLink;
  final String? previewUrl;
  final network_api.LinkPreviewRef? preview;
  final bool previewLoading;
  final VoidCallback onDismissHollowLink;
  final VoidCallback onDismissPreview;

  const StagedLinkArea({
    super.key,
    required this.hollowLink,
    required this.previewUrl,
    required this.preview,
    required this.previewLoading,
    required this.onDismissHollowLink,
    required this.onDismissPreview,
  });

  @override
  Widget build(BuildContext context) {
    final link = hollowLink;
    if (link != null) {
      return StagedHollowLinkCard(link: link, onDismiss: onDismissHollowLink);
    }
    final url = previewUrl;
    if (url != null) {
      return StagedLinkPreviewCard(
        url: url,
        preview: preview,
        loading: previewLoading,
        onDismiss: onDismissPreview,
      );
    }
    return const SizedBox.shrink();
  }
}

/// Input-bar container: flush against a preview/reply bar above (no double
/// border), separated by the standard border otherwise.
Widget chatInputBarShell(HollowTheme hollow,
    {required bool flushTop, required Widget child}) {
  return Container(
    padding: const EdgeInsets.symmetric(
      horizontal: HollowSpacing.md,
      vertical: HollowSpacing.sm,
    ),
    decoration: BoxDecoration(
      color: hollow.surface,
      border: Border(
        top: flushTop ? BorderSide.none : BorderSide(color: hollow.border),
      ),
    ),
    child: child,
  );
}

/// The composer text field shared by both panes (emote-aware controller,
/// 5-line cap, 4000-char limit). Carries the chat text scale too — reading
/// messages at 150% and typing the reply at 100% helps nobody. The mobile
/// composer (`_MobileInputBar`) wraps itself the same way.
Widget chatComposerField(
  HollowTheme hollow, {
  required EmoteComposerController controller,
  required FocusNode focusNode,
  required String hintText,
  required ValueChanged<String> onChanged,
}) {
  return ChatTextScale(
    child: HollowTextField(
      controller: controller,
      focusNode: focusNode,
      hintText: hintText,
      autofocus: true,
      maxLines: 5,
      minLines: 1,
      maxLength: 4000,
      showCounter: false,
      style: HollowTypography.body.copyWith(color: hollow.textPrimary),
      borderRadius: hollow.radiusLg,
      onChanged: onChanged,
    ),
  );
}

/// Emoji-picker button for the composer row. [onOpen] receives the button's
/// own BuildContext so the picker can anchor to it.
Widget composerEmojiButton(HollowTheme hollow,
    {required void Function(BuildContext btnCtx) onOpen}) {
  return Builder(
    builder: (btnCtx) => HollowPressable(
      semanticLabel: 'Insert emoji',
      onTap: () => onOpen(btnCtx),
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      padding: const EdgeInsets.all(HollowSpacing.sm),
      child: Icon(
        LucideIcons.smile,
        color: hollow.textSecondary,
        size: 20,
      ),
    ),
  );
}

/// GIF-picker button for the composer row — a "GIF" text badge (no icon set
/// carries a GIF glyph). [onOpen] receives the button's own BuildContext so
/// the picker can anchor to it.
Widget composerGifButton(HollowTheme hollow,
    {required void Function(BuildContext btnCtx) onOpen}) {
  return Builder(
    builder: (btnCtx) => HollowPressable(
      semanticLabel: 'Insert GIF',
      onTap: () => onOpen(btnCtx),
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      padding: const EdgeInsets.all(HollowSpacing.sm),
      child: Container(
        height: 20,
        padding: const EdgeInsets.symmetric(horizontal: 3),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: hollow.textSecondary, width: 1.5),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          'GIF',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
            fontSize: 9,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
            height: 1.0,
          ),
        ),
      ),
    ),
  );
}

/// Sticker-picker button for the composer row. [onOpen] receives the button's
/// own BuildContext so the picker can anchor to it.
///
/// A third composer button is PROVISIONAL — the row is getting crowded and
/// Vitalik wants to rethink emoji/GIF/sticker placement as a whole. Until
/// then this is the discoverable option, and `StickerPickerBody` is
/// host-agnostic so moving the panel later touches only its host.
Widget composerStickerButton(HollowTheme hollow,
    {required void Function(BuildContext btnCtx) onOpen}) {
  return Builder(
    builder: (btnCtx) => HollowPressable(
      semanticLabel: 'Insert sticker',
      onTap: () => onOpen(btnCtx),
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      padding: const EdgeInsets.all(HollowSpacing.sm),
      child: Icon(
        LucideIcons.sticker,
        color: hollow.textSecondary,
        size: 20,
      ),
    ),
  );
}

/// The chat-overlay pin toggle shown at the edge of the screen-share chat
/// overlay (DM pane and voice channel pane).
class ChatOverlayToggleButton extends StatelessWidget {
  final bool overlaysVisible;
  final bool pinned;
  final VoidCallback onTap;
  final VoidCallback onHoverEnter;
  final VoidCallback onHoverExit;

  const ChatOverlayToggleButton({
    super.key,
    required this.overlaysVisible,
    required this.pinned,
    required this.onTap,
    required this.onHoverEnter,
    required this.onHoverExit,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return AnimatedOpacity(
      opacity: overlaysVisible ? 1.0 : 0.0,
      duration: HollowDurations.normal,
      child: IgnorePointer(
        ignoring: !overlaysVisible,
        child: MouseRegion(
          onEnter: (_) => onHoverEnter(),
          onExit: (_) => onHoverExit(),
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              width: 24,
              height: 48,
              decoration: BoxDecoration(
                color: hollow.surface.withValues(alpha: 0.88),
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(8),
                ),
                border: Border(
                  left: BorderSide(
                    color: hollow.border.withValues(alpha: 0.5),
                  ),
                  top: BorderSide(
                    color: hollow.border.withValues(alpha: 0.5),
                  ),
                  bottom: BorderSide(
                    color: hollow.border.withValues(alpha: 0.5),
                  ),
                ),
              ),
              child: Icon(
                pinned ? LucideIcons.chevronRight : LucideIcons.chevronLeft,
                size: 14,
                color: hollow.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Floating pill that appears when scrolled away from the bottom.
class UnreadJumpPill extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const UnreadJumpPill({super.key, required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final label = count == 1 ? '1 new message' : '$count new messages';
    return HollowPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      backgroundColor: hollow.accent,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.xs + 2,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.arrowDown, size: 14, color: hollow.textOnAccent),
          const SizedBox(width: HollowSpacing.xs),
          Text(
            label,
            style: HollowTypography.caption.copyWith(
              color: hollow.textOnAccent,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// Collapse a set of typing peer ids to MASTER identities, excluding every
/// id that is "us". Robust self-filter (Step 9C/C1): a sibling device typing
/// must never render as "you are typing" on our OTHER device. The typist id
/// reaching here is collapsed to master in Rust ONLY IF the sibling's device
/// id is warm in the resolver; if it isn't, it arrives as a raw DEVICE id and
/// a bare `master != myMaster` check misses it. So exclude a typist that
/// resolves to our master OR is one of OUR OWN known device ids OR is this
/// running device — i.e. anything `sameIdentity` to us by any path.
Set<String> typingMastersFor(WidgetRef ref, Set<String> typingPeers) {
  final links = ref.watch(deviceLinkProvider);
  final myMaster = links.identityOf(ref.watch(identityProvider).peerId ?? '');
  final myDeviceIds =
      ref.watch(myDevicesProvider).map((d) => d.peerId).toSet();
  final myRunningDevice = ref.watch(localDevicePeerIdProvider).valueOrNull;
  bool isMe(String pid) =>
      links.identityOf(pid) == myMaster ||
      links.sameIdentity(pid, myMaster) ||
      myDeviceIds.contains(pid) ||
      (myRunningDevice != null && pid == myRunningDevice);
  return typingPeers
      .where((pid) => !isMe(pid))
      .map((pid) => links.identityOf(pid))
      .toSet();
}

/// Typing indicator bar shown above the input area.
/// Displays up to 3 names, or "Several people are typing..." for 4+.
class TypingIndicatorBar extends StatelessWidget {
  final List<String> names;

  const TypingIndicatorBar({super.key, required this.names});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final String text;
    if (names.length == 1) {
      text = '${names[0]} is typing';
    } else if (names.length == 2) {
      text = '${names[0]} and ${names[1]} are typing';
    } else if (names.length == 3) {
      text = '${names[0]}, ${names[1]}, and ${names[2]} are typing';
    } else {
      text = 'Several people are typing';
    }

    return Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
      alignment: Alignment.centerLeft,
      color: hollow.surface,
      child: Row(
        children: [
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontStyle: FontStyle.italic,
                fontSize: 11,
              ),
            ),
          ),
          const SizedBox(width: HollowSpacing.xs),
          TypingDots(color: hollow.textSecondary),
        ],
      ),
    );
  }
}

/// Animated bouncing dots for typing indicators.
/// Uses [SharedTickers.typingDots] instead of per-instance controller.
class TypingDots extends StatelessWidget {
  final Color color;

  const TypingDots({super.key, required this.color});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: SharedTickers.instance.typingDots,
      builder: (context, value, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final delay = i * 0.2;
            final t = (value - delay).clamp(0.0, 1.0);
            final bounce = t < 0.5
                ? (t * 2) // 0→1
                : (1 - (t - 0.5) * 2); // 1→0
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 1),
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.4 + bounce * 0.6),
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}
