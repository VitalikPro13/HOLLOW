# chat_pane_shared.dart -- Shared Chat-Pane Building Blocks

Primary file: `lib/src/ui/chat/chat_pane_shared.dart` (~660 lines). Created 2026-07-15 (Sonar item-3 session). The DM pane (`ChatPane`) and channel pane (`ChannelChatPane`) are structural twins; everything genuinely identical between them lives here so the twins cannot drift AND so Sonar CPD stops pairing them (memory s3776-build-method-decomposition rule 8). `chat_pane.dart` RE-EXPORTS the public helpers (`shouldGroup`, `shouldShowDateSeparator`, `DateSeparator`, `TypingIndicatorBar`, `TypingDots`) so existing consumers (mobile routes, archive viewers) keep importing `chat_pane.dart` unchanged.

**Rule for future work:** when adding UI that both panes need (or that mobile_chat_route duplicates), extend THIS file instead of copying between the panes. `mobile_chat_route.dart` ADOPTED it 2026-07-15 (its S3776 decomposition): imports this file directly (not the re-export) and uses `ChatReplyPreviewBar`, `StagedFilePreviewBar`, `StagedLinkArea`, `UnreadJumpPill`, `DateSeparator`, `shouldGroup`/`shouldShowDateSeparator`, `dateSeparatedChatRow`, `reversedChatList` (with `selectionArea: false`), `TypingIndicatorBar`, and `typingMastersFor`. All three chat surfaces now share one module.

## Moved helpers (were top-level in chat_pane.dart)

- `shouldGroup()` -- same-sender-within-5-min message grouping (DMs compare `isMe`; channels also `senderId`).
- `stickerTileCandidate()` / `stickerTilingFor()` -- whether a row may tile into its neighbours (sticker-only text, nothing else in the seam) and which seams actually tile. Feeds `tileWithPrev`/`tileWithNext` on both bubbles from all THREE panes; see wiki `emotes.md` > "Sticker Mosaics".
- `composerStickerButton()` -- third composer button beside emoji and GIF. PROVISIONAL placement: the button row is being rethought, so `StickerPickerBody` is host-agnostic and moving the panel is a change of host, not of picker.
- `shouldShowDateSeparator()` -- calendar-day change check.
- `DateSeparator` -- horizontal-rule date label ("Today"/"Yesterday"/"Month Day, Year").
- `TypingIndicatorBar` / `TypingDots` -- typing bar (1-3 names or "Several people"), dots ride `SharedTickers.typingDots`.

## Widgets

- `UnreadJumpPill` -- accent "N new messages" pill (replaced BOTH panes' private `_UnreadPill` copies). Props: `count`, `onTap`.
- `ChatReplyPreviewBar` -- reply-compose bar above the input (accent left border, sender line, optional 32px `gifAwareImage` thumb, cancel X). Props: `senderName`, `text`, `imagePath`, `onCancel`.
- `StagedFilePreviewBar` -- staged-attachment bar (48px thumb or file icon, name, remove X). Props: `filePath`, `fileName`, `isImage`, `onRemove`.
- `StagedLinkArea` -- renders `StagedHollowLinkCard` (hollow:// invite) OR `StagedLinkPreviewCard` (OG preview) OR `SizedBox.shrink()`. Props: `hollowLink`, `previewUrl`, `preview`, `previewLoading`, `onDismissHollowLink`, `onDismissPreview`. Both panes keep tiny `_dismissStagedHollowLink`/`_dismissStagedPreview` methods as the callbacks.
- `ChatOverlayToggleButton` -- the 24x48 chevron tab that pins/unpins the screen-share chat overlay. Used by ChatPane's screen-share layout AND both copies in voice_channel_pane.dart. Props: `overlaysVisible`, `pinned`, `onTap`, `onHoverEnter`, `onHoverExit`.

## Functions

- `gifAwareImage(path, {width, height})` -- `GifFileImage` for .gif else `Image.file`, BoxFit.cover (replaced both panes' private `_gifAwareImage`).
- `reversedChatList({context, listKey?, itemScrollController, itemPositionsListener, scrollOffsetController?, itemCount, indexByMessageId, itemBuilder, selectionArea = true, padding, scrollRail = true, onJumpToNewest?})` -- THE reversed-list shell: SelectionArea (context menu suppressed) > ScrollConfiguration (no scrollbars) > `ScrollablePositionedList.builder` with `reverse: true`, `initialScrollIndex: 0`, and the `findChildIndexCallback` keyed-row reuse logic. The vendored-list iron rules (feedback_reverse_chat_lists) now live in exactly ONE place; guarded by `test/widget/chat_list_element_reuse_test.dart`. Since 2026-07-26 the whole list is also wrapped in `ChatTextScale` — this is THE chokepoint for the "Chat Text Size" preference (issue #20), so DM, channel and mobile message surfaces scale together and cannot drift. Mobile passes `selectionArea: false` -- SelectionArea's touch long-press would fight `LongPressMessage` -- plus its own horizontal padding; `listKey`/`scrollOffsetController` are optional (mobile passes neither). Since 2026-08-21 (issue #54) it also hangs the scrollbar rail beside the list on DESKTOP via `chatListWithRail`; `onJumpToNewest` must be the pane's own `_scrollToBottom`, because the display list is frozen while reading and index 0 is not the newest message until that freeze is released.
- `typingMastersFor(WidgetRef ref, Set<String> typingPeers)` -- collapses typing DEVICE ids to masters and excludes anything that is "us" (the Step 9C/C1 robust self-filter: resolves-to-my-master OR sameIdentity OR one of `myDevicesProvider` OR the running device -- a cold-resolver sibling arrives as a raw device id, so a bare master compare misses it). Shared by `ChannelChatPane._buildTypingBar` and mobile `_TypingBar`; callers map the returned masters to display names themselves (channel pane uses server nicknames, mobile plain `displayNameFor`).
- `dateSeparatedChatRow({rowKey, timestamp, prevTimestamp, showHeader, child})` -- keyed row shell: computes showDate, adds group-header top padding, wraps in `KeyedSubtree(ValueKey(rowKey))` with optional `DateSeparator` above.
- `chatComposerField(hollow, {controller, focusNode, hintText, onChanged})` -- the `HollowTextField` composer (emote-aware controller, autofocus, 5-line cap, 4000-char limit, no counter), wrapped in `ChatTextScale` so you type at the size you read (mobile's own `_MobileInputBar` is wrapped the same way at its call site).
- `composerEmojiButton(hollow, {onOpen})` -- emoji-picker button; `onOpen` receives the button's own BuildContext for picker anchoring.
- `chatInputBarShell(hollow, {flushTop, child})` -- input-bar Container; `flushTop` drops the top border when a reply/staged/preview bar sits above.

## The scrollbar rail (issue #54, 2026-08-21)

The chat feed had no scrollbar and no way to jump. `ScrollablePositionedList` has no pixel offset a normal `Scrollbar` can map onto (its position is "item N, aligned so far into the viewport"), so this is an INDEX scrollbar.

- `ChatScrollRail({itemCount, controller, positions, onJumpToNewest?})` -- the rail: a draggable thumb plus a jump cap at each end. Desktop only; touch keeps fling scrolling and the unread pill (a 16px drag rail sits under the edge-swipe gesture and its caps are far under a comfortable tap target).
- `chatListWithRail({list, rail})` -- puts the rail in a column of its own to the RIGHT of the list. **Never a `Stack` overlay.** That shape was tried: it laid out and painted correctly and then never received a single pointer.
- `_RailMetrics.from(positions, itemCount)` -- thumb offset/extent from the visible index range; null when everything fits. Indexes are the REVERSED builder indexes (0 = newest, at the BOTTOM), so a HIGHER index is further UP the track. That inversion is where the bugs live: the first drag mapping was flipped and only `test/widget/chat_scroll_rail_test.dart` caught it.
- `kChatRailWidth` (22) / `kWindowEdgeDeadStrip` (8) -- the gutter, and the inert margin the rail keeps between its controls and the window's outer edge. The frameless window's resize border eats pointer events in those outer pixels (memory `feedback_window_edge_dead_strip`); a control centred in a rail that hugs the edge is simply dead while every widget test passes.
- Why the caps live in the gutter at all: the message hover action bar is an `OverlayEntry` centred on whatever row the pointer is over and right-aligned to it, so it covers anything floating INSIDE the list. The jump controls started as round buttons over the bottom-right of the list and the last message's bar sat on top of them.

The guest pane (`guest_chat_pane.dart`) builds its own list and calls `chatListWithRail` by hand; the DM, channel and mobile surfaces get it through `reversedChatList`.

## CPD-divergence convention

The channel pane calls the shared widgets through thin private wrappers (`_buildReplyPreviewBar()` etc.); the DM pane inlines the widget constructors in `_buildMessageArea`'s list. The differing call shapes keep the two build sequences token-divergent for Sonar CPD -- keep that asymmetry.
