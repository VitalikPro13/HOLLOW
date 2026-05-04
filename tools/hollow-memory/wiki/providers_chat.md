# Chat Providers — DM and Channel Message State

This document covers every chat-related Dart provider, model, and utility: DM chat state, channel chat state, typing indicators, pinned messages, message text parsing, and the underlying data models.

---

## ChatMessage Model

**File:** `lib/src/core/models/chat_message.dart`
**Class:** `ChatMessage` (plain Dart class, not immutable/freezed)

### Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `text` | `String` | required | Message body text |
| `isMe` | `bool` | required | Whether the local user sent this message |
| `timestamp` | `DateTime` | `DateTime.now()` | Message creation time; initially Dart-side, later hydrated to Rust's signed value |
| `signature` | `String?` | null | Ed25519 signature over canonical signing payload |
| `publicKey` | `String?` | null | Sender's public key for signature verification |
| `messageId` | `String?` | null | 32-char hex ID (16 random bytes) |
| `editedAt` | `DateTime?` | null | Timestamp of last edit, null if never edited |
| `hiddenAt` | `DateTime?` | null | Timestamp of soft-deletion |
| `replyToMid` | `String?` | null | Message ID this is a reply to |
| `reactions` | `Map<String, List<String>>` | `const {}` | Emoji string to list of reactor peer IDs |
| `fileAttachment` | `FileAttachment?` | null | Attached file metadata, null for text-only |
| `linkPreview` | `network_api.LinkPreviewRef?` | null | OG link preview data for the first URL |

### Constructor

`ChatMessage({required text, required isMe, timestamp?, signature?, publicKey?, messageId?, editedAt?, hiddenAt?, replyToMid?, reactions?, fileAttachment?, linkPreview?})`

- `timestamp` defaults to `DateTime.now()` if not provided.
- `reactions` defaults to `const {}` if null.

### copyWith()

Returns a new `ChatMessage` with specified fields overridden. Preserves `isMe`, `messageId`, and `replyToMid` from the original (not overridable via copyWith). All other fields are nullable-overridable.

---

## ChannelChatMessage Model

**File:** `lib/src/core/models/channel_chat_message.dart`
**Class:** `ChannelChatMessage` (plain Dart class)

Identical to `ChatMessage` with one addition:

| Field | Type | Description |
|---|---|---|
| `senderId` | `String` | Peer ID of the message sender (required) |

All other fields, constructor pattern, defaults, and `copyWith()` behavior are identical to `ChatMessage`. The `senderId` is preserved in `copyWith()` (not overridable).

The key difference: DM messages use `isMe` alone to determine authorship (the other party is always the peer). Channel messages need `senderId` because multiple peers participate.

---

## FileAttachment Model

**File:** `lib/src/core/models/file_attachment.dart`
**Class:** `FileAttachment` (plain Dart class with `const` constructor)

### Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `fileId` | `String` | required | Unique file identifier (same as messageId for sender-side) |
| `fileName` | `String` | required | Original filename |
| `fileExt` | `String` | required | File extension |
| `mimeType` | `String` | required | MIME type string |
| `sizeBytes` | `int` | required | Total file size in bytes |
| `isImage` | `bool` | required | Whether the file is an image (for inline rendering) |
| `width` | `int?` | null | Image width in pixels |
| `height` | `int?` | null | Image height in pixels |
| `totalChunks` | `int` | required | Total expected chunks for transfer |
| `chunksReceived` | `int` | 0 | Chunks received so far |
| `isComplete` | `bool` | false | Whether transfer is complete |
| `diskPath` | `String?` | null | Local filesystem path to the downloaded file |
| `videoThumb` | `network_api.VideoThumbRef?` | null | Video thumbnail back-reference; when non-null, the attachment is a thumbnail image for a vault-stored video identified by `videoThumb.cid` |
| `expiredAt` | `int?` | null | Timestamp when file expired (shard retention) |

### Computed Properties

- `isExpired` (getter) — returns `true` if `expiredAt != null`
- `progress` (getter) — returns `chunksReceived / totalChunks` (0.0 if totalChunks is 0)
- `formattedSize` (getter) — returns human-readable size string: B, KB, or MB

### copyWith()

Only allows overriding: `chunksReceived`, `isComplete`, `diskPath`, `videoThumb`, `expiredAt`. All identity fields (`fileId`, `fileName`, `fileExt`, `mimeType`, `sizeBytes`, `isImage`, `width`, `height`, `totalChunks`) are preserved from the original.

---

## chatProvider — DM Message State

**File:** `lib/src/core/providers/chat_provider.dart`
**Provider:** `chatProvider` — `NotifierProvider<ChatNotifier, Map<String, List<ChatMessage>>>`
**State shape:** `Map<String, List<ChatMessage>>` where key is the peer ID and value is a chronologically sorted list of messages for that DM conversation.

### Constants

- `_maxMessages = 200` — maximum messages kept in memory per conversation. Oldest are trimmed when exceeded.

### Message ID Generation

`generateMessageId()` — top-level function, also imported by `ChannelChatNotifier`.
- Uses `Random.secure()` to generate 16 cryptographically random bytes.
- Converts to 32-character lowercase hex string.
- Matches Rust's 16-byte random message ID format.

### _addMessage(peerId, message)

Private helper. Appends `message` to the list for `peerId`. If the list exceeds `_maxMessages` (200), trims from the front (oldest messages dropped). Creates a shallow copy of the state map and the list to trigger Riverpod rebuild.

### sendMessage(peerId, text, {replyToMid?, linkPreview?})

**Optimistic send flow:**
1. Reads `networkServiceProvider` from ref.
2. Generates a new message ID via `generateMessageId()`.
3. Calls `networkService.sendMessage(peerId, text, messageId, replyToMid?, linkPreview?)` — FFI call to Rust. Rust persists to SQLCipher with its own timestamp and signs the message.
4. Creates a `ChatMessage` with `isMe: true`, `timestamp: DateTime.now()` (optimistic, will be hydrated later), and the generated `messageId`.
5. Calls `_addMessage()` to add to in-memory state immediately.

**Critical timing note:** The Dart-side `DateTime.now()` timestamp is a placeholder. The real signed timestamp comes back via the `MessageSent` event and is applied by `hydrateSignature()`. This two-step flow ensures instant UI feedback while maintaining signature correctness.

### receiveMessage(fromPeer, text, timestamp, messageId, replyToMid, {linkPreview?, signature?, publicKey?})

Called from the event stream handler when a `DirectMessage` network event arrives.
1. Converts `timestamp` (int, milliseconds since epoch) to `DateTime`.
2. Creates a `ChatMessage` with `isMe: false`. Empty strings for `messageId` and `replyToMid` are converted to null.
3. Calls `_addMessage()`. No DB save here — Rust already persisted before emitting the event.

### hydrateSignature(peerId, messageId, timestampMs, signature?, publicKey?)

Called from the `MessageSent` event handler after Rust has signed and persisted the message.
1. Finds the message by `messageId` in the peer's list.
2. Overwrites `timestamp` with `DateTime.fromMillisecondsSinceEpoch(timestampMs)` — the exact Rust `SystemTime::now()` value that the signature was computed over.
3. Sets `signature` and `publicKey`.

**Why this matters:** Without timestamp hydration, the Dart verifier reconstructs the canonical signing payload with a slightly different millisecond value (coarse OS timer resolution on VMs), which breaks Ed25519 signature verification.

### editMessage(peerId, messageId, newText)

1. Calls `network_api.editDmMessage(peerId, messageId, newText)` — direct FFI, no service wrapper.
2. Does NOT update in-memory state. The UI update happens when the `DmMessageEdited` event arrives and calls `applyEdit()`.

### applyEdit(peerId, messageId, newText, editedAtMs, {signature?, publicKey?})

Called from the `DmMessageEdited` event handler.
1. Finds message by `messageId` in the peer's list.
2. Uses `copyWith()` to update `text`, `editedAt`, `signature`, and `publicKey`.
3. Signature and publicKey are updated so that the Message Proof dialog verifies against the edit's signature, not the original message's.

### deleteMessage(peerId, messageId)

1. Calls `network_api.deleteDmMessage(peerId, messageId)` — direct FFI.
2. UI update happens via the `DmMessageDeleted` event calling `applyDelete()`.

### applyDelete(peerId, messageId, deletedAtMs)

Called from the `DmMessageDeleted` event handler.
1. Filters out the message with matching `messageId` from the peer's list.
2. If no message was found (lengths match), returns early without state update.
3. Note: this is a hard removal from in-memory state, not a soft-hide.

### addReaction(peerId, messageId, emoji)

1. **Client-side limit check:** Reads `identityProvider` to get local peer ID. Counts how many distinct emoji the local user has already reacted with on this message (excluding the requested emoji). If >= 3, returns immediately without sending.
2. Calls `network_api.addDmReaction(peerId, messageId, emoji)` — direct FFI.
3. In-memory state update happens via event handler calling `applyAddReaction()`.

### removeReaction(peerId, messageId, emoji)

Calls `network_api.removeDmReaction(peerId, messageId, emoji)` — direct FFI. State update via event.

### applyAddReaction(peerId, messageId, emoji, reactorPeerId)

Called from the `DmReactionAdded` event handler.
1. Deep-copies the reactions map for the target message.
2. If `reactorPeerId` is already in the list for this `emoji`, returns (no duplicate).
3. Appends `reactorPeerId` to the emoji's reactor list.
4. Creates a new message via `copyWith(reactions: ...)`.

### applyRemoveReaction(peerId, messageId, emoji, reactorPeerId)

Called from the `DmReactionRemoved` event handler.
1. Deep-copies the reactions map.
2. Removes `reactorPeerId` from the emoji's reactor list.
3. If the list becomes empty, removes the emoji key entirely from the map.

### addSendFailure(toPeer, error)

Creates a local-only system message with text `[Failed to send: $error]` and `isMe: true`. No messageId, no signature, no persistence. Displayed inline in the chat as a failure indicator.

### loadHistory(peerId)

**Full history load from SQLCipher with reaction and file attachment hydration.**

1. Calls `storageService.loadMessages(peerId, limit: 200)` — FFI to load stored messages.
2. Collects all non-null `messageId` values and calls `storage_api.loadReactions(messageIds)` to bulk-load reactions. Builds a `reactionsMap: Map<String, Map<String, List<String>>>` (messageId -> emoji -> [peerIds]).
3. Collects unique `fileId` values and calls `storage_api.getFileMetadata(fileId)` for each to build a `fileMap: Map<String, FileAttachment>`.
4. Maps stored records to `ChatMessage` objects, attaching reactions and file attachments by ID lookup.
5. **Merge with in-memory state:** Preserves any in-memory messages (by messageId) that are NOT in the DB snapshot. This covers two races: (a) a message arrives mid-load, and (b) optimistic in-flight sends that haven't round-tripped through Rust yet.
6. Sorts merged list by timestamp (ascending — oldest first).
7. On failure, prints debug message but does not throw.

### loadLastMessagePreviews(peerIds)

Used by the home dashboard to show DM conversation previews.
1. Iterates `peerIds`, skipping any peer already in state (already has messages loaded).
2. For each, calls `storageService.loadMessages(peerId, limit: 1)` to load just the last message.
3. Creates a single-element list with a minimal `ChatMessage` (text, isMe, timestamp, messageId only — no reactions, no file attachments).
4. Batch-updates state once at the end if any new previews were loaded.

### clearPeerCache(peerId)

Removes the peer's message list from state. Forces a full `loadHistory()` reload on next view.

### addFileMessage(peerId, messageId, fileName, sizeBytes, ext, isImage, localPath, {text})

**Optimistic file message (sender side).**
1. Creates a `ChatMessage` with `isMe: true`, the given `messageId`, and a `FileAttachment` with:
   - `fileId` = `messageId`
   - `isComplete: true` (sender already has the file)
   - `diskPath` = `localPath`
   - `totalChunks: 0` (not tracked for sender)
   - `mimeType: 'application/octet-stream'` (generic)
2. Calls `_addMessage()` for instant UI feedback.

### updateFileAttachment(peerId, fileId, attachment)

Updates the `FileAttachment` on an existing message in-memory. Matches by `fileAttachment?.fileId == fileId` (not by messageId). Used when a file transfer completes or progress updates, e.g., when `FileCompleted` event arrives with final disk path and dimensions.

---

## channelChatProvider — Channel (Server) Message State

**File:** `lib/src/core/providers/channel_chat_provider.dart`
**Provider:** `channelChatProvider` — `NotifierProvider<ChannelChatNotifier, Map<String, List<ChannelChatMessage>>>`
**State shape:** `Map<String, List<ChannelChatMessage>>` where key is `"serverId:channelId"` and value is a chronologically sorted list of messages.

### Constants

- `_maxMessages = 200` — same cap as DM provider.

### _key(serverId, channelId)

Returns `'$serverId:$channelId'` — the composite key for state lookup.

### _addMessage(serverId, channelId, message)

Same pattern as DM's `_addMessage`: appends, trims if > 200, shallow-copies state.

### sendMessage(serverId, channelId, text, {replyToMid?, linkPreview?})

**Optimistic send flow (parallel to DM):**
1. Reads `networkServiceProvider` and `identityProvider` (for local peerId).
2. Generates message ID via `generateMessageId()` (imported from chat_provider.dart).
3. Calls `networkService.sendChannelMessage(serverId, channelId, text, messageId, replyToMid?, linkPreview?)` — FFI. Rust generates the timestamp and persists.
4. Creates a `ChannelChatMessage` with `senderId: localPeerId`, `isMe: true`, `timestamp: DateTime.now()` (optimistic).
5. Calls `_addMessage()`.

### receiveMessage(serverId, channelId, fromPeer, text, timestampMs, messageId, replyToMid, {linkPreview?, signature?, publicKey?})

Called from the `ChannelMessage` event handler.
1. Converts `timestampMs` to DateTime.
2. **Extra deduplication:** Checks if an identical message already exists in-memory (same `senderId`, `text`, and `timestamp`). Skips if duplicate found. This is a safety net beyond Rust's own deduplication.
3. Empty strings for `messageId`/`replyToMid` are converted to null.
4. Calls `_addMessage()`. No DB save — Rust already persisted.

### hydrateSignature(serverId, channelId, messageId, timestampMs, signature?, publicKey?)

Identical pattern to DM's `hydrateSignature`. Called from the `ChannelMessageSent` event. Overwrites optimistic Dart timestamp with Rust's signed timestamp, sets signature and publicKey.

### editMessage(serverId, channelId, messageId, newText)

Calls `network_api.editChannelMessage(serverId, channelId, messageId, newText)` — direct FFI. UI update via event.

### applyEdit(serverId, channelId, messageId, newText, editedAtMs, {signature?, publicKey?})

Called from `ChannelMessageEdited` event. Same pattern as DM: updates text, editedAt, signature, publicKey via `copyWith()`.

### deleteMessage(serverId, channelId, messageId)

Calls `network_api.deleteChannelMessage(serverId, channelId, messageId)` — direct FFI. UI update via event.

### applyDelete(serverId, channelId, messageId, deletedAtMs)

Called from `ChannelMessageDeleted` event. Same hard-removal pattern as DM.

### addReaction(serverId, channelId, messageId, emoji)

Same client-side 3-emoji-per-user limit check as DM. Calls `network_api.addChannelReaction(serverId, channelId, messageId, emoji)`.

### removeReaction(serverId, channelId, messageId, emoji)

Calls `network_api.removeChannelReaction(serverId, channelId, messageId, emoji)`.

### applyAddReaction(serverId, channelId, messageId, emoji, reactorPeerId)

Same deep-copy-and-append pattern as DM. Deduplicates by checking if `reactorPeerId` already in list.

### applyRemoveReaction(serverId, channelId, messageId, emoji, reactorPeerId)

Same remove-and-cleanup pattern as DM.

### loadHistory(serverId, channelId)

**Full history load with sync request.**

1. **Fires sync request first:** Calls `network_api.requestChannelSync(serverId, channelId)` (non-awaited, fire-and-forget). This asks connected peers to send any messages the local node is missing. New messages arrive later via `MessageSyncCompleted` -> cache clear -> reload cycle.
2. Loads from DB via `storageService.loadChannelMessages(serverId, channelId, limit: 200)`.
3. Bulk-loads reactions via `storage_api.loadReactions(messageIds)`.
4. Loads file attachments via `storage_api.getFileMetadata(fileId)` for each unique fileId.
5. Maps to `ChannelChatMessage` objects with reactions and file attachments.
6. **Merge:** Same carry-over logic as DM — preserves in-memory messages not in DB snapshot, sorts by timestamp.

**Difference from DM loadHistory:** Channel version fires a sync request at the start.

### reloadReactions(serverId, channelId)

Reloads ONLY reactions from DB for current in-memory messages.
1. Collects all messageIds from current in-memory state.
2. Calls `storage_api.loadReactions(messageIds)`.
3. Rebuilds reactions map and applies to all messages via `copyWith(reactions: ...)`.
4. Does NOT trigger a sync request — safe to call from sync completion handlers without creating infinite loops.

### mergeFromDb(serverId, channelId)

**Non-destructive merge of DB contents with live in-memory messages.**

Unlike `loadHistory()`, this method preserves live-delivered messages that arrived between sync completion and the reload. Used after `MessageSyncCompleted` to incorporate synced messages without losing real-time ones.

1. Loads up to 200 messages from DB with full reaction and file attachment hydration (same pattern as `loadHistory`).
2. Builds a set of DB message IDs for deduplication.
3. Identifies "live-only" messages: in-memory messages whose `messageId` is NOT in the DB result set.
4. Merges: all DB messages + live-only messages.
5. Sorts by timestamp ascending.
6. Caps at `_maxMessages` (200), trimming oldest if needed.

**When to use `mergeFromDb()` vs `loadHistory()`:**
- `loadHistory()` — initial channel open. Fires sync request.
- `mergeFromDb()` — after sync completion. Does NOT fire sync request. Preserves live messages.

### clearServerCache(serverId)

Removes ALL channel message lists for the given server. Uses `removeWhere` with prefix match `'$serverId:'`.

### addFileMessage(serverId, channelId, messageId, fileName, sizeBytes, ext, isImage, localPath, {text})

Same pattern as DM's `addFileMessage` but reads `identityProvider` to set `senderId` on the `ChannelChatMessage`.

---

## typingProvider — Typing Indicators

**File:** `lib/src/core/providers/typing_provider.dart`
**Provider:** `typingProvider` — `NotifierProvider<TypingNotifier, Map<String, Set<String>>>`
**State shape:** `Map<String, Set<String>>` where key is the context key and value is the set of peer IDs currently typing in that context.

### Key Format

- **DMs:** key = peer ID (the other peer's ID)
- **Channels:** key = `"serverId:channelId"`

### Internal Timer Map

`_timers: Map<String, Map<String, Timer>>` — nested map of context key -> peer ID -> expiry Timer. Not part of Riverpod state; managed internally for auto-expiry.

### setTyping(key, peerId)

Marks a peer as typing in the given context.
1. Cancels any existing timer for this peer in this context (prevents stale expiry from firing).
2. Adds `peerId` to the Set for `key` in state.
3. Sets a 5-second expiry `Timer`. When it fires, calls `clearTyping(key, peerId)`.

Each typing indicator event from the network resets the 5-second window. If no new event arrives within 5 seconds, the indicator auto-clears.

### clearTyping(key, peerId)

Removes a single peer's typing indicator.
1. Cancels and removes the timer for this peer.
2. Removes `peerId` from the set for `key`.
3. If the set becomes empty, removes the key entirely from state.

### clearContext(key)

Clears ALL typing indicators for a context (e.g., when switching channels).
1. Cancels all timers for the context key.
2. Removes the key from the timer map and from state.

### Ephemeral Nature

Typing state is purely ephemeral — no DB persistence, no sync. It's driven entirely by incoming typing indicator network events. The 5-second auto-expiry ensures stale indicators don't linger even if a "stopped typing" event is lost.

---

## pinnedProvider — Pinned Messages

**File:** `lib/src/core/providers/pinned_provider.dart`
**Provider:** `pinnedProvider` — `NotifierProvider<PinnedNotifier, Map<String, List<String>>>`
**State shape:** `Map<String, List<String>>` where key is `"serverId:channelId"` and value is an ordered list of pinned message IDs.

### loadPins(serverId, channelId)

1. Calls `crdt_api.getPinnedMessages(serverId, channelId)` — FFI into the CRDT layer to read pinned message IDs from server state.
2. Replaces the list for this channel in state.
3. On failure, prints debug message.

### applyPin(serverId, channelId, messageId)

Called from a pin event handler.
1. Checks if `messageId` is already in the list (deduplication).
2. If not, appends it to the list.

### applyUnpin(serverId, channelId, messageId)

Called from an unpin event handler.
1. Filters out the `messageId` from the list.
2. If the list becomes empty, removes the key from state entirely.

### Data Source

Pinned messages are stored in the CRDT-managed `ServerState`, not in the message DB. The `crdt_api.getPinnedMessages()` call reads from the CRDT layer, which is synchronized across all server members via the CRDT sync protocol. Pin/unpin operations are CRDT operations that propagate to all members.

---

## MessageText — Message Text Parser and Renderer

**File:** `lib/src/ui/chat/message_text_parser.dart`
**Widget:** `MessageText` (StatelessWidget)
**Helper:** `buildMessageText()` (top-level function, convenience wrapper)

### Purpose

Parses message text containing lightweight markup into styled Flutter `InlineSpan` trees for rendering. Used by both DM and channel message bubbles.

### Supported Markup

| Syntax | Rendering |
|---|---|
| `**bold**` or `__bold__` | Bold (FontWeight.w700) |
| `*italic*` or `_italic_` | Italic (FontStyle.italic) |
| `~~strikethrough~~` | Strikethrough (TextDecoration.lineThrough) |
| `` `inline code` `` | Mono font, 13px, background pill with border |
| ` ```code blocks``` ` | Full-width container, mono font, background + border, multi-line |
| `\|\|spoiler\|\|` | Hidden text (tap to reveal/hide) |
| `http(s)://` or `hollow://` URLs | Clickable, accent-colored, underlined |
| `@everyone` | Highlighted mention pill (accent background + bold) |
| `@displayName` | Highlighted mention pill, longest-match against `memberNames` set |

### MessageText Widget

**Constructor props:**
- `text` (String, required) — raw message text
- `baseStyle` (TextStyle?) — override base text style; defaults to `HollowTypography.body` with `hollow.textPrimary` color
- `suffixSpans` (List<InlineSpan>?) — additional spans appended after parsed content (used for edited indicators, etc.)
- `memberNames` (Set<String>?) — set of display names for @mention matching

**Build logic:**
1. Checks if text contains triple-backtick code blocks via `RegExp(r'```(\w*)\n?([\s\S]*?)```')`.
2. If code blocks found: delegates to `_buildWithCodeBlocks()` which splits the text into segments, rendering code blocks as `Container` widgets with mono font and inline text as parsed spans.
3. If no code blocks: calls `_parseInline()` directly and wraps in `Text.rich(TextSpan(children: spans))`.

### buildMessageText(text, context, {baseStyle?, suffixSpans?, memberNames?})

Top-level convenience function that creates and returns a `MessageText` widget.

### _parseInline(text, style, hollow, {depth, memberNames})

Core recursive inline parser. Returns `List<InlineSpan>`.

**Recursion depth limit:** 10 levels. Beyond that, returns plain `TextSpan`.

**Parsing order (priority):**

1. **URL detection** — checked FIRST, before any markup. Uses `_looksLikeUrlStart()` for fast prefix check, then matches against `_inlineUrlRegex`. URLs are rendered as `WidgetSpan` containing a `GestureDetector` + `MouseRegion` with click cursor. Tapping opens the URL via `url_launcher` in external application mode. This ordering prevents URLs containing underscores/asterisks (e.g., Wikipedia links) from being mis-parsed as italic/bold.

2. **@mentions** — checks for `@` character. Matches `@everyone` literally, or longest-match against `memberNames` set. Rendered as a `WidgetSpan` with a pill background (`accent` at 15% alpha, 3px border radius) and bold accent-colored text.

3. **Bold** (`**...**`) — finds opening `**`, searches for closing `**`. Content between is recursively parsed with `FontWeight.w700` added to style.

4. **Strikethrough** (`~~...~~`) — same pattern, applies `TextDecoration.lineThrough`.

5. **Spoiler** (`||...||`) — rendered as a `WidgetSpan` containing `_SpoilerText` stateful widget (see below).

6. **Inline code** (`` `...` ``) — rendered as a `WidgetSpan` with background container, border, mono font at 13px.

7. **Italic** (`*...*` or `_..._`) — single asterisk checks that next char is not also `*` (to avoid consuming bold). Single underscore additionally requires word boundary: must be preceded by space (or start of string) and followed by space (or end of string), preventing mid-word underscores in URLs/identifiers from triggering italic.

8. **Plain text** — any character not matching the above is buffered and flushed as a `TextSpan`.

### _looksLikeUrlStart(text, start)

Fast check: first character is `h`/`H`, and lowercase substring starting at `start` begins with `http://`, `https://`, or `hollow://`. Avoids running the full regex on every character.

### _inlineUrlRegex

`RegExp(r'(?:https?|hollow)://[^\s<>"' "'" r')\]}]+')` — matches URLs starting with `http://`, `https://`, or `hollow://`, continuing until whitespace or certain delimiter characters.

### _findClosing(text, marker, from)

Finds the next occurrence of a single-character `marker` starting from `from`. Returns -1 if the closing marker is immediately at `from` (prevents empty matches like `**`).

### _flushBuffer(buffer, spans, style)

If the StringBuffer has content, creates a `TextSpan` with the buffered text and the current style, adds it to the spans list, and clears the buffer.

### _openUrl(url)

Parses the URL string, launches via `url_launcher` with `LaunchMode.externalApplication`. Silently catches errors.

### _SpoilerText Widget

**File:** `lib/src/ui/chat/message_text_parser.dart` (private class)
**Type:** `StatefulWidget`

Renders spoiler text that is hidden by default and toggles on tap.

**Props:** `text`, `style`, `hollow`

**State:** `_revealed` (bool, default false)

**Rendering:**
- **Hidden:** Background color = `hollow.textSecondary` (solid opaque), text color = `Colors.transparent`. The text is present but invisible; the container's background covers it.
- **Revealed:** Background color = `hollow.elevated`, text color = `hollow.textPrimary`.
- Tap toggles `_revealed`. Uses `AnimatedContainer` with 200ms duration for smooth color transition.
- Container has 4px horizontal and 1px vertical padding with 3px border radius.

### _buildWithCodeBlocks(text, pattern, style, hollow, suffixSpans)

Handles messages containing triple-backtick code blocks.
1. Iterates all regex matches for ` ```(\w*)\n?([\s\S]*?)``` `.
2. Text before each code block is parsed inline and added as a `Text.rich` widget.
3. Each code block is rendered as a full-width `Container` with `hollow.background` fill, `hollow.border` border, 6px border radius, 8px padding, mono font at 13px. Trailing newline is stripped from code content.
4. Text after the last code block is parsed inline, with `suffixSpans` appended to the final segment.
5. If the result is a single widget, returns it directly. Otherwise wraps in a `Column` with `CrossAxisAlignment.start`.
6. The first capture group `(\w*)` captures the optional language identifier after the opening backticks, but it is currently unused (no syntax highlighting).

---

## Event Flow Summary

### DM Message Send/Receive Cycle

1. **User sends:** `chatProvider.sendMessage()` -> FFI `sendMessage()` -> optimistic `ChatMessage` added with Dart timestamp.
2. **Rust processes:** Signs message, persists to SQLCipher, sends over network, emits `MessageSent` event.
3. **Event handler:** Calls `chatProvider.hydrateSignature()` -> overwrites Dart timestamp with Rust's signed timestamp, sets signature + publicKey.
4. **Remote receives:** Rust receives, verifies signature, persists, emits `DirectMessage` event.
5. **Event handler:** Calls `chatProvider.receiveMessage()` -> adds to in-memory state.

### Channel Message Send/Receive Cycle

1. **User sends:** `channelChatProvider.sendMessage()` -> FFI `sendChannelMessage()` -> optimistic `ChannelChatMessage` added.
2. **Rust processes:** Signs, persists, broadcasts via MLS, emits `ChannelMessageSent` event.
3. **Event handler:** Calls `channelChatProvider.hydrateSignature()`.
4. **Remote receives:** Rust receives via MLS, verifies, persists, emits `ChannelMessage` event.
5. **Event handler:** Calls `channelChatProvider.receiveMessage()`.

### Edit/Delete Cycle (both DM and Channel)

1. **User edits/deletes:** `editMessage()`/`deleteMessage()` -> direct FFI call.
2. **Rust processes:** Persists change, broadcasts, emits event.
3. **Event handler:** Calls `applyEdit()`/`applyDelete()` -> modifies/removes from in-memory state.
4. No optimistic update — UI waits for the event round-trip.

### Reaction Cycle (both DM and Channel)

1. **User reacts:** `addReaction()`/`removeReaction()` -> client-side limit check (3 distinct emoji per user per message) -> FFI call.
2. **Rust processes:** Persists, broadcasts, emits event.
3. **Event handler:** Calls `applyAddReaction()`/`applyRemoveReaction()`.
4. No optimistic update — UI waits for the event round-trip.

### History Load Cycle

1. **Channel opened:** `channelChatProvider.loadHistory()` fires `requestChannelSync()` (non-blocking), then loads from DB.
2. **Sync completes:** `MessageSyncCompleted` event -> `channelChatProvider.mergeFromDb()` (preserves live messages).
3. **DM opened:** `chatProvider.loadHistory()` loads from DB only (no sync request for DMs).

### State Mutation Pattern

All state mutations follow the same immutable-update pattern:
1. Copy the outer map: `Map.of(state)`
2. Copy the inner list: `List<T>.from(current)`
3. Modify the copy (add/remove/replace element)
4. Assign to `state` to trigger Riverpod rebuild

This ensures reference equality checks detect changes and widgets rebuild correctly.
