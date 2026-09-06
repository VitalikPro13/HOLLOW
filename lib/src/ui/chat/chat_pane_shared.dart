import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/shared_tickers.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/contrast.dart';
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
import 'package:hollow/src/ui/components/hollow_scroll_behavior.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/ui_scale.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

// Shared building blocks for the chat panes: ChatPane (DMs) and
// ChannelChatPane are structural twins, so everything identical between them
// lives here and cannot drift. chat_pane.dart re-exports the public helpers.

/// Bookkeeping for a link preview whose fetch was still in flight when the user
/// hit send (issue #45).
///
/// Sending inside the composer's 600 ms debounce used to leave the landing
/// fetch with nobody listening. [claim] hands the message id back exactly once,
/// and all three compose panes share this so the behaviour cannot drift.
class LatePreviewAttacher {
  ({String url, String messageId})? _pending;

  /// Remembers that [messageId] was sent while [url]'s fetch was in flight.
  /// Only one is tracked, so a newer send supersedes an older pending one.
  void arm(String url, String messageId) {
    _pending = (url: url, messageId: messageId);
  }

  /// Forget any pending attach (pane disposed, preview dismissed).
  void disarm() => _pending = null;

  /// The message id waiting on [url], or null. Consumes the record, so a
  /// duplicate completion cannot attach twice.
  String? claim(String url) {
    final pending = _pending;
    if (pending == null || pending.url != url) return null;
    _pending = null;
    return pending.messageId;
  }

  /// Whether an attach is pending; exposed for tests.
  bool get isArmed => _pending != null;
}

/// The URL a just-sent message still owes a card for, or null if none.
///
/// A send outruns its preview two ways: the debounced fetch is in flight, or it
/// never started because Enter came inside the 600 ms window. The second is
/// what "paste a link and send" looks like, so both have to be covered.
/// Returns null when a card is already staged, when previews are off, and for a
/// Hollow deep link, which renders locally and must never trigger a fetch.
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
  // `hollow://` never goes near the network, and the scheme check covers link
  // shapes `extractHollowLinks` does not recognise.
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
  if (currentIsMe != previousIsMe) return false;
  if (currentSenderId != null &&
      previousSenderId != null &&
      currentSenderId != previousSenderId) {
    return false;
  }
  return currentTime.difference(previousTime).inMinutes.abs() < 5;
}

/// Whether a message may tile into its neighbours: a bare sticker run with
/// nothing else attached. A reply header, a reaction bar, an "(edited)" suffix
/// or a file card all need the row's own padding back.
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
/// Stickers and GIFs share ONE budget rather than one each, because a per-kind
/// cap would still let a sticker and a GIF stack. The pickers emit one per
/// send, so this covers the hand-typed or pasted `[a:s:…]` / `[a:g:…]`: check
/// the EXPANDED wire text and fail the send visibly, never trim it silently.
bool exceedsAssetLimit(String expandedText) =>
    countBlockAssetTokens(expandedText) > 1;

/// User-facing reason for a refused send, so all three panes say it the same.
const String kAssetLimitMessage = 'One sticker or GIF per message';

/// Which seams of a message are continued by its neighbours. A run tiles only
/// where BOTH rows are candidates and already grouped, the same rule that
/// decides whether the avatar repeats.
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
  if (previous == null) return true;
  return current.year != previous.year ||
      current.month != previous.month ||
      current.day != previous.day;
}

/// "Today", "Yesterday", or "February 16, 2026", shared by the date separator
/// and the unread line when the two merge.
String chatDayLabel(DateTime date) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final messageDay = DateTime(date.year, date.month, date.day);
  final diff = today.difference(messageDay).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  return '${months[date.month - 1]} ${date.day}, ${date.year}';
}

/// ASOT-style date separator: ——— February 16, 2026 ———
///
/// The only thing in a chat that draws all the way across, so an unbalanced
/// gutter shows up at its two ends: with the rail holding [kChatRailWidth] of
/// the right edge, symmetric padding leaves the rule visibly off-centre.
/// [endInset] gives that width back; lists with no rail keep it symmetric.
class DateSeparator extends StatelessWidget {
  final DateTime date;

  /// Padding on the rule's right end. Defaults to matching the left.
  final double endInset;

  const DateSeparator({
    super.key,
    required this.date,
    this.endInset = HollowSpacing.lg,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final label = chatDayLabel(date);

    return Padding(
      padding: EdgeInsets.only(
        top: HollowSpacing.md + 2,
        bottom: HollowSpacing.sm,
        left: HollowSpacing.lg,
        right: endInset,
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

/// Chronological index of the row the "new messages" line goes above, or null
/// when this visit has no line to draw (issue #54).
///
/// [entrySeenId] is `unreadMarkerProvider`'s pointer to the last message read
/// before this visit: null means no line, the empty string means the
/// conversation was never read. An unrecognised pointer is older than the
/// 200-row window, so everything loaded counts as new. Your own messages never
/// open the run, because sending is not arriving.
int? unreadDividerIndex({
  required int count,
  required String? entrySeenId,
  required String? Function(int index) messageIdAt,
  required bool Function(int index) isMineAt,
}) {
  if (entrySeenId == null || count == 0) return null;
  var start = 0;
  if (entrySeenId.isNotEmpty) {
    for (var i = count - 1; i >= 0; i--) {
      if (messageIdAt(i) == entrySeenId) {
        start = i + 1;
        break;
      }
    }
  }
  for (var i = start; i < count; i++) {
    if (!isMineAt(i)) return i;
  }
  return null;
}

/// The "new messages" line: a rule in [HollowTheme.error] with a badge at its
/// right end, above the first message that arrived while you were away.
///
/// The badge is the app's own unread pill rather than a word in red, so it
/// reads as the same thing the sidebar and dock badges mean. A non-null [date]
/// MERGES the day separator into this rule: coming back the next day is the
/// ordinary way to see the line at all, and two full-width rules 30px apart
/// read as a mistake. Deliberately not centred, merged or not, because a
/// centred label reads as another date. The label colour is lifted to 4.5:1
/// against the pane; the raw error red fails as small text on the light theme.
class UnreadDivider extends StatelessWidget {
  /// Matches [DateSeparator.endInset] so the two line up when they do not
  /// merge.
  final double endInset;

  /// The day this row starts when the date separator merges in; null leaves
  /// the line standing alone.
  final DateTime? date;

  const UnreadDivider({super.key, this.endInset = HollowSpacing.lg, this.date});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final line = hollow.error.withValues(alpha: 0.75);
    final label = Contrast.ensureContrast(hollow.error, hollow.background,
        targetRatio: 4.5);
    final day = date == null ? null : chatDayLabel(date!);
    return Padding(
      padding: EdgeInsets.only(
        // Merged, this rule is also the day separator, so it takes that
        // separator's breathing room above.
        top: day == null ? HollowSpacing.sm : HollowSpacing.md + 2,
        bottom: HollowSpacing.xxs,
        left: HollowSpacing.lg,
        right: endInset,
      ),
      child: Semantics(
        header: true,
        label: day == null ? 'New messages' : 'New messages, $day',
        child: ExcludeSemantics(
          child: Row(
            children: [
              Expanded(child: Container(height: 1, color: line)),
              if (day != null) ...[
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
                  child: Text(
                    day,
                    style: HollowTypography.caption.copyWith(
                      color: label,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(child: Container(height: 1, color: line)),
              ],
              Padding(
                padding: const EdgeInsets.only(left: HollowSpacing.sm),
                child: Container(
                  height: 14,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: hollow.error,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: const Text(
                    'New',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      height: 1,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A gif-or-static thumbnail for a file on disk.
Widget gifAwareImage(String path, {double? width, double? height}) =>
    path.toLowerCase().endsWith('.gif')
        ? GifFileImage(
            diskPath: path, width: width, height: height, fit: BoxFit.cover)
        : Image.file(File(path),
            width: width, height: height, fit: BoxFit.cover);

/// Whether a [SelectionArea] wrapped AROUND a scrolling message list would
/// misbehave, so it must be scoped to the ROWS instead (issue #35).
///
/// Upstream, not ours: Flutter's scrollable selection delegate adds the scroll
/// delta in LOCAL space and subtracts it in GLOBAL space, and the root
/// `UiScale` transform between the two leaves an error of
/// `scrollOffset * (scale - 1)`. The phantom edge lands in the auto-scroll zone
/// and `EdgeDraggingAutoScroller` never stops on pointer-up. Scoping to the row
/// removes the Scrollable from between the region and the selectables, at the
/// cost of cross-message drag-selection, so it is spent only at scales where
/// the bug is real. Delete once upstream fixes the transform math; guarded by
/// test/widget/chat_selection_autoscroll_test.dart.
bool selectionMustBeScopedToRows(BuildContext context) {
  final scale = UiScaleInfo.maybeOf(context)?.effective ?? 1.0;
  return (scale - 1.0).abs() >= 0.001;
}

/// The chat surfaces' [SelectionArea], with no context menu because message
/// actions own that. Per-row inside a list builder [key] MUST forward the
/// wrapped row's key: the wrapper is the widget the sliver sees, and
/// `findChildIndexCallback` reads that key.
Widget chatSelectionArea({Key? key, required Widget child}) => SelectionArea(
      key: key,
      contextMenuBuilder: (_, _) => const SizedBox.shrink(),
      child: child,
    );

/// The reversed chat list shell, where the iron rules live for BOTH panes (see
/// feedback_reverse_chat_lists): `reverse: true` with the newest message at
/// builder index 0 pinned to the bottom, and [findChildIndexCallback] so keyed
/// rows MOVE across index slots instead of remounting when a new message shifts
/// every revIndex by one (guarded by
/// test/widget/chat_list_element_reuse_test.dart).
///
/// Also the one chokepoint for the chat text size preference (issue #20): the
/// list is wrapped in [ChatTextScale], so DM, channel and mobile surfaces scale
/// together.
Widget reversedChatList({
  required BuildContext context,
  Key? listKey,
  required ItemScrollController itemScrollController,
  required ItemPositionsListener itemPositionsListener,
  ScrollOffsetController? scrollOffsetController,
  required int itemCount,
  required Map<String, int> indexByMessageId,
  required Widget Function(BuildContext context, int revIndex) itemBuilder,
  // Mobile passes false: the touch long-press would fight the action sheet's
  // gesture on every bubble.
  bool selectionArea = true,
  EdgeInsets padding = const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
  // The scrollbar and jump controls (issue #54), off for surfaces that are not
  // a live feed.
  bool scrollRail = true,
  VoidCallback? onJumpToNewest,
  // REVERSED index of the row the "new messages" line sits above (issue #54).
  int? unreadRevIndex,
}) {
  // Issue #35: scoped to the rows when scaled.
  final perRowSelection = selectionArea && selectionMustBeScopedToRows(context);
  // Desktop only, and a real column beside the list rather than an overlay on
  // top of it; see [chatListWithRail].
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
              // Forward the row's ValueKey: findChildIndexCallback above reads
              // that key to move rows instead of remounting them.
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
        unreadRevIndex: unreadRevIndex,
      ),
    ),
  );
}

/// Puts the scrollbar [rail] in a column of its own to the right of [list].
///
/// NOT a Stack overlay: `Stack([list, Positioned.fill(rail)])` paints correctly
/// and then never receives a pointer, because every pointer over the rail goes
/// to the scrollable underneath. A column cannot have that argument, and a
/// reserved gutter is what the rest of the app does (`HollowScrollBehavior`).
Widget chatListWithRail({required Widget list, required Widget rail}) {
  return Row(
    // `stretch` needs a bounded box, which the pane's Expanded provides
    // (feedback_dart_patterns).
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(child: list),
      SizedBox(width: kChatRailWidth, child: rail),
    ],
  );
}

/// Width of the chat's scrollbar column: the [kScrollGutter] every other
/// scrollable reserves, plus the unusable [kWindowEdgeDeadStrip].
///
/// The list ends where this begins, which buys the one strip of the pane the
/// message hover action bar cannot reach: that bar is an OverlayEntry centred
/// on whatever row the pointer is over, so anything floating INSIDE the list
/// ends up under it (issue #54).
const double kChatRailWidth = kWindowEdgeDeadStrip + kScrollGutter;

/// Dead strip along the window's outer edge, kept clear of anything clickable.
///
/// The frameless window's resize border lives INSIDE the client area, and
/// `window_manager` answers WM_NCHITTEST there, so those pixels never become a
/// Flutter pointer event: a control hugging the edge renders perfectly, passes
/// every widget test and does nothing when clicked.
const double kWindowEdgeDeadStrip = 8.0;

/// Width of the accent pill that marks your own messages.
const double kOwnMessageBarWidth = 3.0;

/// How far that pill floats inside the chat's left edge.
///
/// Not zero: flush against the edge it welds itself to the divider against the
/// channel list and reads as a highlight on the PANEL rather than a mark on the
/// message. Inside the row's padding it sits in the left margin, opposite the
/// rail's groove in the right one.
const double kOwnMessageBarInset = HollowSpacing.xs;

/// Height of a jump cap: the cap already fills the rail's live width, so height
/// is the only dimension left to make it a comfortable target.
const double _kCapExtent = 22.0;

/// Gap between a cap and the track. Load bearing, not decoration: it is what
/// proves the painted track stops where the thumb's travel stops, instead of
/// showing scroll room that does not exist.
const double kRailSegmentGap = HollowSpacing.xs;

/// Resting fill shared by all three segments of the rail: roughly a third of
/// the thumb's contrast, so cap and track read as one control without running a
/// grey stripe down the chat. Below this it vanishes at 1x.
Color railSegmentFill(HollowTheme hollow, {required bool active}) =>
    hollow.textSecondary.withValues(alpha: active ? 0.18 : 0.10);

/// Right-end padding for a full-width chat rule on a list that carries the
/// rail: [kChatRailWidth] already sits between the list and the pane edge, so
/// the rule needs only a hair more to keep off the groove.
const double kChatRuleEndInset = HollowSpacing.xxs;

/// Height of the unread mark on the track. Any taller and it reads as a second,
/// stubbier thumb rather than as a line.
const double kRailUnreadMarkHeight = 3.0;

/// How far from the unread mark a tap still counts as aiming at it.
const double kRailUnreadSnap = 8.0;

/// Clearance between the rail and the chrome above and below it. Without it the
/// caps sit flush against the header's and composer's borders, which reads as
/// two controls jammed into the corners of the message area.
const double kRailEndInset = HollowSpacing.sm;

/// True where a drag rail would fight the platform's own edge gestures.
bool get _isTouchForm => Platform.isAndroid || Platform.isIOS;

/// The chat feed's scrollbar and jump controls (issue #54).
///
/// [ScrollablePositionedList] has no pixel offset a [Scrollbar] could map onto,
/// so this is an INDEX scrollbar: the thumb spans the visible index range out
/// of [itemCount] and a drag jumps to the index under the pointer. With rows of
/// different heights the thumb is an estimate, which is the trade for a list
/// you can prepend to without the view moving. Indexes are the REVERSED builder
/// indexes (feedback_reverse_chat_lists), so a HIGHER index is further UP.
///
/// The jump controls are CAPS at the ends of the track, where a native
/// scrollbar puts its arrows, rather than buttons floating inside the list,
/// which the message hover bar covers. Desktop only: on touch a drag rail would
/// sit under the platform's edge-swipe gesture.
class ChatScrollRail extends StatefulWidget {
  final int itemCount;
  final ItemScrollController controller;
  final ItemPositionsListener positions;

  /// Releases the "frozen while reading" display cap and snaps to the newest
  /// message. The pane owns that state, and jumping to index 0 of a frozen list
  /// lands on the wrong message.
  final VoidCallback? onJumpToNewest;

  /// REVERSED index of the row under the "new messages" line, or null when this
  /// visit has no line. A tap near the mark snaps onto it.
  final int? unreadRevIndex;

  const ChatScrollRail({
    super.key,
    required this.itemCount,
    required this.controller,
    required this.positions,
    this.onJumpToNewest,
    this.unreadRevIndex,
  });

  @override
  State<ChatScrollRail> createState() => _ChatScrollRailState();
}

class _ChatScrollRailState extends State<ChatScrollRail> {
  bool _hovering = false;
  bool _dragging = false;

  /// Jumps so the message [fraction] down the track (0 = oldest) sits at the
  /// viewport's bottom edge. The list clamps an out-of-range jump, which lands
  /// the two extremes exactly on the first and last row.
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

  /// Lands the unread line in the upper-middle of the viewport, like the
  /// reply-jump, so the first new message reads downward from there.
  void _jumpToUnread() {
    final index = widget.unreadRevIndex;
    if (index == null || !widget.controller.isAttached) return;
    widget.controller.jumpTo(
      index: index.clamp(0, widget.itemCount - 1),
      alignment: 0.6,
    );
  }

  /// Where the unread mark sits on a track of [trackHeight], or null when there
  /// is nothing to mark.
  ///
  /// The mark is a LOCATOR, so it maps onto the WHOLE track rather than onto
  /// the thumb's travel, which in a barely-overflowing list squeezes every
  /// position into the remainder. Jumping stays exact either way.
  double? _unreadCentre(double trackHeight) {
    final index = widget.unreadRevIndex;
    if (index == null || widget.itemCount <= 1) return null;
    final fraction =
        (1.0 - index / (widget.itemCount - 1)).clamp(0.0, 1.0);
    // Keep the whole target on the track; at either extreme half of it would
    // hang off the end.
    final limit = trackHeight - kRailUnreadSnap;
    if (limit <= kRailUnreadSnap) return trackHeight / 2;
    return (fraction * trackHeight).clamp(kRailUnreadSnap, limit);
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

  /// Cap, track, cap: three segments of one width in one column.
  ///
  /// The caps are ALWAYS drawn, dimmed and inert at the end they point to,
  /// because showing and hiding them resizes the track and shifts the thumb.
  /// Inert means no `onTap` and no semantic label, so nothing announces a dead
  /// button.
  Widget _rail(HollowTheme hollow, _RailMetrics metrics) {
    return Padding(
      // Everything interactive stays [kWindowEdgeDeadStrip] clear of the
      // window's outer edge.
      padding: const EdgeInsets.only(
        right: kWindowEdgeDeadStrip,
        top: kRailEndInset,
        bottom: kRailEndInset,
      ),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: Column(
          children: [
            _RailCap(
              hollow: hollow,
              icon: LucideIcons.chevronsUp,
              label: 'Jump to the oldest message',
              tooltip: 'Jump to top',
              onTap: _jumpToOldest,
              enabled: !metrics.atOldest,
            ),
            const SizedBox(height: kRailSegmentGap),
            Expanded(child: _track(hollow, metrics)),
            const SizedBox(height: kRailSegmentGap),
            _RailCap(
              hollow: hollow,
              icon: LucideIcons.chevronsDown,
              label: 'Jump to the newest message',
              tooltip: 'Jump to present',
              onTap: _jumpToNewest,
              enabled: !metrics.atNewest,
            ),
          ],
        ),
      ),
    );
  }

  Widget _track(HollowTheme hollow, _RailMetrics metrics) {
    final active = _hovering || _dragging;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: railSegmentFill(hollow, active: active),
        borderRadius: BorderRadius.circular(kScrollGutter / 2),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final trackHeight = constraints.maxHeight;
          final thumbHeight =
              (metrics.extent * trackHeight).clamp(28.0, trackHeight);
          // The thumb's top is scaled into `trackHeight - thumbHeight`, its
          // real travel, or the oldest page could never be reached.
          final top = metrics.offset * (trackHeight - thumbHeight);
          final unreadCentre = _unreadCentre(trackHeight);
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
                  // A real control, not paint, so it can be hit, hovered and
                  // reached by a screen reader. A drag starting here still
                  // drags: the track's recognizer beats a child's tap once the
                  // pointer moves.
                  if (unreadCentre != null)
                    Positioned(
                      top: unreadCentre - kRailUnreadSnap,
                      height: kRailUnreadSnap * 2,
                      left: 0,
                      right: 0,
                      child: HollowTooltip(
                        message: 'Jump to new messages',
                        child: HollowPressable(
                          semanticLabel: 'Jump to the first unread message',
                          onTap: _jumpToUnread,
                          child: Center(
                            child: Container(
                              height: kRailUnreadMarkHeight,
                              decoration: BoxDecoration(
                                color: hollow.error,
                                borderRadius: BorderRadius.circular(
                                    kRailUnreadMarkHeight / 2),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    top: top,
                    height: thumbHeight,
                    // Centred in its track, which is flush against the live
                    // edge of the gutter, so the thumb lands where every other
                    // scrollbar in the app draws one.
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
      ),
    );
  }

  /// Maps a pointer on the track to a position, treating the pointer as the
  /// MIDDLE of the thumb so the list does not jump out from under the grab.
  ///
  /// The top of the track is the OLDEST end, the direction
  /// [_RailMetrics.offset] measures, so the normalised pointer IS the fraction
  /// and inverting it sends every drag the wrong way
  /// (test/widget/chat_scroll_rail_test.dart).
  void _jumpFromPointer(double dy, double trackHeight, double thumbHeight) {
    final travel = trackHeight - thumbHeight;
    if (travel <= 0) return;
    // The mark is 3px of a 10px gutter, too small to hit exactly, so anything
    // within [kRailUnreadSnap] snaps to the message rather than to the
    // pointer's fraction.
    final centre = _unreadCentre(trackHeight);
    if (centre != null && (dy - centre).abs() <= kRailUnreadSnap) {
      _jumpToUnread();
      return;
    }
    _jumpToFraction(((dy - thumbHeight / 2) / travel).clamp(0.0, 1.0));
  }

}

/// One end cap of the rail: a chevron on a pill the width of the gutter,
/// matching the track's fill so the two read as one segmented control.
///
/// [enabled] false is the "you are already there" state: the pill stays (that
/// is what holds the track's length still) and it stops being a button, with no
/// `onTap`, tooltip or semantic label, so nothing offers a dead action.
class _RailCap extends StatelessWidget {
  final HollowTheme hollow;
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;

  const _RailCap({
    required this.hollow,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(kScrollGutter / 2);
    final pill = SizedBox(
      height: _kCapExtent,
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: railSegmentFill(hollow, active: false),
          borderRadius: radius,
        ),
        child: HollowPressable(
          semanticLabel: enabled ? label : null,
          onTap: enabled ? onTap : null,
          disabled: !enabled,
          // `backgroundColor: null` rests at the hover colour with ZERO ALPHA
          // rather than `Colors.transparent`, so the lift never lerps through
          // black (feedback_hover_state_patterns).
          borderRadius: radius,
          padding: EdgeInsets.zero,
          child: Center(
            // EXACTLY the pill's width: an icon box wider than the pill is
            // clamped to it and the glyph ends up off-centre. Widget tests
            // cannot catch that, because the test font draws every glyph as a
            // filled box.
            child: Icon(icon, size: kScrollGutter, color: hollow.textSecondary),
          ),
        ),
      ),
    );
    return enabled ? HollowTooltip(message: tooltip, child: pill) : pill;
  }
}

/// Where the thumb sits and how big it is, from the visible index range. Null
/// when the whole conversation fits.
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
    // Reversed indexes: a higher top-most visible index is closer to the
    // OLDEST end, which is the TOP of the track.
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
/// on group headers. Keyed by message id because rows hold per-item state
/// (spoiler reveal, hover, decoded frames) that must not shift onto another
/// message on a delete or trim.
Widget dateSeparatedChatRow({
  required Object rowKey,
  required DateTime timestamp,
  required DateTime? prevTimestamp,
  required bool showHeader,
  required Widget child,
  // True where [reversedChatList] hangs a rail, so the date rule can give that
  // width back out of its right end and stay level.
  bool railGutter = false,
  // The first row that arrived while the reader was away, so the "new
  // messages" line goes above it (issue #54).
  bool unreadDivider = false,
}) {
  final showDate = shouldShowDateSeparator(timestamp, prevTimestamp);
  final messageWidget = showHeader
      ? Padding(
          padding: const EdgeInsets.only(top: HollowSpacing.sm + 2),
          child: child,
        )
      : child;
  final endInset =
      railGutter && !_isTouchForm ? kChatRuleEndInset : HollowSpacing.lg;
  // A row carrying BOTH becomes one rule, not two (see [UnreadDivider.date]).
  return KeyedSubtree(
    key: ValueKey<Object>(rowKey),
    child: showDate || unreadDivider
        ? Column(
            mainAxisSize: MainAxisSize.min,
            // STRETCH, not the default centre: a grouped continuation
            // shrink-wraps, and this Column exists only because the row
            // carries a separator, so centring would push it mid-pane.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showDate && !unreadDivider)
                DateSeparator(date: timestamp, endInset: endInset),
              if (unreadDivider)
                UnreadDivider(
                  endInset: endInset,
                  date: showDate ? timestamp : null,
                ),
              messageWidget,
            ],
          )
        : messageWidget,
  );
}

/// Wraps a chat row with the accent pill that marks it as YOURS.
///
/// The pill runs the row's FULL height on purpose: a grouped run is several
/// rows whose boxes touch, and any vertical inset breaks the run into a dashed
/// line. It is positioned rather than a [Border], which insets its Container's
/// child and moved every own-message avatar off everyone else's alignment.
class OwnMessageMarker extends StatelessWidget {
  final Widget child;

  const OwnMessageMarker({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Stack(
      children: [
        // Non-positioned, so the Stack sizes to the row. Never let this become
        // a conditional `SizedBox.shrink()` or the row collapses
        // (feedback_stack_nonpositioned_child_collapse).
        child,
        Positioned(
          left: kOwnMessageBarInset,
          top: 0,
          bottom: 0,
          width: kOwnMessageBarWidth,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: hollow.accent,
              borderRadius: BorderRadius.circular(kOwnMessageBarWidth / 2),
            ),
          ),
        ),
      ],
    );
  }
}

/// Yours gets the pill and everyone else's row comes back untouched, so
/// `find.byType(OwnMessageMarker)` is exactly the set of own-message rows.
Widget markedAsOwn({required bool isMe, required Widget row}) =>
    isMe ? OwnMessageMarker(child: row) : row;

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

/// Staged link card area: a Hollow invite card for a hollow:// link, else the
/// OG preview card, and nothing when no URL is staged.
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

/// Input-bar container: flush against a preview or reply bar above so the two
/// borders do not double, separated by the standard border otherwise.
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

/// The composer text field shared by both panes. Carries the chat text scale
/// too, since reading at 150% and typing the reply at 100% helps nobody.
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

/// Emoji-picker button. [onOpen] receives the button's own BuildContext so the
/// picker can anchor to it.
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

/// GIF-picker button, a text badge because no icon set carries a GIF glyph.
/// [onOpen] receives the button's own BuildContext so the picker can anchor.
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

/// Sticker-picker button. [onOpen] receives the button's own BuildContext so
/// the picker can anchor to it.
///
/// A third composer button is PROVISIONAL; `StickerPickerBody` is host-agnostic
/// so moving the panel later touches only its host.
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

/// Collapses typing peer ids to MASTER identities, excluding every id that is
/// "us".
///
/// Rust collapses a typist to master only while the sibling's device id is warm
/// in the resolver, so a raw DEVICE id can arrive and a bare
/// `master != myMaster` check would render a sibling as "you are typing". The
/// filter therefore excludes anything `sameIdentity` to us by any path.
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

/// Typing indicator bar shown above the input area: up to 3 names, then
/// "Several people are typing...".
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

/// Animated bouncing dots for typing indicators, on the shared ticker rather
/// than a controller per instance.
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
                ? (t * 2)
                : (1 - (t - 0.5) * 2);
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
