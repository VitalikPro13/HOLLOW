# chat_pane_shared.dart -- Shared Chat-Pane Building Blocks

Primary file: `lib/src/ui/chat/chat_pane_shared.dart` (~660 lines). Created 2026-07-15 (Sonar item-3 session). The DM pane (`ChatPane`) and channel pane (`ChannelChatPane`) are structural twins; everything genuinely identical between them lives here so the twins cannot drift AND so Sonar CPD stops pairing them (memory s3776-build-method-decomposition rule 8). `chat_pane.dart` RE-EXPORTS the public helpers (`shouldGroup`, `shouldShowDateSeparator`, `DateSeparator`, `TypingIndicatorBar`, `TypingDots`) so existing consumers (mobile routes, archive viewers) keep importing `chat_pane.dart` unchanged.

**Rule for future work:** when adding UI that both panes need (or that mobile_chat_route duplicates), extend THIS file instead of copying between the panes. mobile_chat_route.dart has NOT adopted it yet (planned with its S3776 decomposition).

## Moved helpers (were top-level in chat_pane.dart)

- `shouldGroup()` -- same-sender-within-5-min message grouping (DMs compare `isMe`; channels also `senderId`).
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
- `reversedChatList({context, listKey, itemScrollController, itemPositionsListener, scrollOffsetController, itemCount, indexByMessageId, itemBuilder})` -- THE reversed-list shell: SelectionArea (context menu suppressed) > ScrollConfiguration (no scrollbars) > `ScrollablePositionedList.builder` with `reverse: true`, `initialScrollIndex: 0`, and the `findChildIndexCallback` keyed-row reuse logic. The vendored-list iron rules (feedback_reverse_chat_lists) now live in exactly ONE place; guarded by `test/widget/chat_list_element_reuse_test.dart`.
- `dateSeparatedChatRow({rowKey, timestamp, prevTimestamp, showHeader, child})` -- keyed row shell: computes showDate, adds group-header top padding, wraps in `KeyedSubtree(ValueKey(rowKey))` with optional `DateSeparator` above.
- `chatComposerField(hollow, {controller, focusNode, hintText, onChanged})` -- the `HollowTextField` composer (emote-aware controller, autofocus, 5-line cap, 4000-char limit, no counter).
- `composerEmojiButton(hollow, {onOpen})` -- emoji-picker button; `onOpen` receives the button's own BuildContext for picker anchoring.
- `chatInputBarShell(hollow, {flushTop, child})` -- input-bar Container; `flushTop` drops the top border when a reply/staged/preview bar sits above.

## CPD-divergence convention

The channel pane calls the shared widgets through thin private wrappers (`_buildReplyPreviewBar()` etc.); the DM pane inlines the widget constructors in `_buildMessageArea`'s list. The differing call shapes keep the two build sequences token-divergent for Sonar CPD -- keep that asymmetry.
