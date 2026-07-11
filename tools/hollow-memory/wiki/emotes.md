# Custom Emotes and FFZ Integration

End-to-end map of the custom emote system (shipped 2026-07-10). Architecture rationale in memory `project_custom_emotes_ffz`.

## Wire Token

`[e:name:hash]` — inline in message text AND as reaction "emoji" strings. name = 2-24 of `[a-z0-9_]`, hash = full SHA-256 hex (64 lowercase) of the processed WebP bytes. Grammar in TWO places, keep in sync:
- Rust: `node/emotes.rs:parse_emote_token()` / `crdt/mod.rs:valid_emote_name()/valid_emote_hash()`
- Dart: `lib/src/ui/chat/emote_image.dart:emoteTokenRegex` / `parseEmoteToken()`

Old clients render the raw token as text (graceful degradation). Token built by FFI `emotes.rs:emote_token()` (sync).

## Rust: Processing and Storage

**`node/image_convert.rs:process_emote_image(data) -> (webp_bytes, animated)`** — stills ≤64px lossy WebP Q90 ≤32KB; GIF → frame-resized animated WebP Q75 ≤256KB; already-animated WebP passthrough under 256KB cap (container + first-frame verified; the image crate can't re-encode animation). Re-encoding at authoring = sanitization.

**SQLCipher tables** (`storage/messages.rs`):
- `emote_blobs (hash PK, bytes, animated, added_at)` — content-addressed cache, shared across servers/DMs. CRUD: `save_emote_blob` / `load_emote_blob` / `has_emote_blob`.
- `personal_emotes (name PK, hash, animated, source, added_at)` — the user's global set; `source` = `upload` | `ffz:<id>`. LOCAL only (no sibling sync yet). CRUD: `add/remove/list_personal_emotes`.

## Rust: Server Sets (CRDT)

`CrdtPayload::EmojiAdded { name, hash, animated }` / `EmojiRemoved { name }` → `ServerState.emotes: HashMap<name, EmoteInfo>` (`#[serde(default)]`, cap `MAX_SERVER_EMOTES = 50` at authoring AND apply). Gated by `Permission::MANAGE_EMOTES` (1<<7, Admin+ default). Authoring: `sync_handler.rs:handle_emote_op()` (mirror of handle_label_op: apply → CrdtStore persist → ServerUpdated → MLS broadcast + plaintext twin). Ingest arms in BOTH permission matrices (`handle_envelope_crdt_op` + swarm CrdtOpBroadcast) validate name/hash grammar too. Accessor: `ServerState::emotes_list()`.

## Rust: Byte Replication (pull-based)

Bytes NEVER ride the CRDT, message envelopes, or relay rings. Module **`node/emotes.rs`**:
- `NodeCommand::RequestEmotes { hashes, server_id, peer_hint }` → `handle_request_emotes()`: filters already-cached/already-requested (per-connection `requested_emote_hashes` set in swarm.rs, cleared on WS Disconnected), sends `HavenMessage::EmoteRequest { hashes }` to the DM sender's devices (`send_raw_to_identity`) or ONE online server-room member — never a broadcast.
- Inbound `EmoteRequest` → `handle_emote_request()`: answers with whatever subset is cached, as `EmoteAssets { bundle_json }` (the showcase bundle codec `api/showcase.rs:encode/decode_asset_bundle` — JSON map hash→base64, receiver-verified).
- Inbound `EmoteAssets` → `handle_emote_assets()`: verifies sha256 == hash (via bundle codec), RIFF/WEBP magic, ≤256KB cap → `save_emote_blob` → emits `NetworkEvent::EmoteAssetsReceived { hashes }`.
- Reactions: `valid_reaction_emoji()` (≤10-byte Unicode OR emote token) enforced at `message_ops.rs:handle_envelope_add_reaction` (choke point for MLS/Olm/public paths) + the swarm AddReaction arm.

Offline-only holder → token renders as `:name:` text until they return.

## FFI (`api/emotes.rs` → generated `lib/src/rust/api/emotes.dart`)

`process_and_store_emote(raw)` → ProcessedEmote{hash,animated}; `get_emote_bytes(hash)`; `request_emotes(...)`; personal CRUD (`add/remove/list_personal_emotes` — names normalized to lowercase, grammar-validated); server set (`get_server_emotes`, `add_server_emote` [requires blob cached locally], `remove_server_emote`); FFZ (`ffz_search(q)`, `ffz_curated()` [default view], `ffz_global()` [fallback], `ffz_import_emote(image_url)` — REFUSES any URL not on `https://hollow.anonlisten.com/ffz/emotes/`).

## Website Proxy (authoring-time only)

`WholesomeStoryAday/!hollow-website/ffz/search.php` (deploy: `/public_html/hollow/ffz/`) — POST-only, modes `q=` (search, 30d TTL) / `curated=1` (the picker's DEFAULT view: ~110 hardcoded popular emotes `[id,name,owner,animated,usage]` — zero FFZ API cost, images CDN-fetched ≤`CURATED_FILL_CAP`(30)/request until warm) / `global=1` (FFZ global sets, 7d TTL — legacy, kept as client fallback for an old proxy that answers `[]` to curated). SQLite `ffz.db` write-through; images cached to `ffz/emotes/{id}.{png|gif|webp}` (stills = FFZ CDN size 2 PNG; animated prefers the `.gif` variant so the app re-encodes, WebP fallback accepted as-is). FFZ unauthenticated limit = 120 points/min per IP, shared by ALL users through the proxy → caching is load-bearing; on 429 stores a Retry-After backoff (`meta.backoff_until`) and serves stale. `.htaccess` denies ffz.db, hard-caches images. Users NEVER contact FFZ; viewers never contact even the proxy.

## Dart Surfaces

- **`core/providers/emote_provider.dart`** — `emoteBytesProvider(hash)` (FutureProvider.family), `serverEmotesProvider(serverId)` (invalidated on ServerUpdated in event_provider `_refreshServerState`), `personalEmotesProvider`, `requestEmoteOnce()` (session-deduped fire-and-forget; sync try/catch AND .catchError). `EmoteAssetsReceived` event → `clearRequestedEmotes` + invalidate per-hash providers.
- **`ui/chat/emote_image.dart`** — `EmoteScope` InheritedWidget (serverId/peerHint pull context; wrapped around ChatPane, ChannelChatPane, MobileChatRoute body) + `EmoteImage` (renders cached bytes via Image.memory gaplessPlayback; missing → `:name:` fallback + requestEmoteOnce).
- **`ui/chat/emoji_picker.dart`** — unified picker (see ui_message_bubbles.md > EmojiPicker) + shared authoring helpers `pickAndProcessEmoteImage()` / `promptEmoteName()`. Removal UX = `_showEmoteContextMenu` (right-click OR long-press, anchored `showDialog` transparent-barrier menu — picker stays open behind it; NO confirm dialog): Mine tab → "Remove from my emotes"; Recently-used cells in the Emoji tab → "Remove from recents" (`_removeRecentEmoji` persists). FFZ tab empty-search default = `ffzCurated()` → falls back to `ffzGlobal()` on `[]` (old proxy).
- **Unicode tofu fix** — bundled `assets/fonts/NotoColorEmoji.ttf` (10.2MB, CBDT) as `kEmojiFontFallback` in `hollow_typography.dart` `_base`, active ONLY on Windows/Linux (Win10 Segoe UI Emoji stops at Emoji ~12; picker data is Unicode 16). Flows through ThemeData.textTheme → DefaultTextStyle everywhere (no `inherit: false` in lib/). macOS/iOS/Android keep native emoji fonts. **The committed font is SUBSET emoji-only** (`scripts/subset_emoji_font.py` drops codepoints < U+00A9): upstream Noto maps space/CR/#/*/digits with emoji-wide advances, and a fallback next to `fontFamily: null` serves them — unsubset it explodes word spacing app-wide. Rerun the script after any upstream font refresh.
- **Context menu z-order** — the picker is a raw OverlayEntry above navigator routes, so `showDialog` renders BEHIND it; `_showEmoteContextMenu` inserts its own topmost OverlayEntry (double-remove guarded) instead.
- **`ui/chat/message_text_parser.dart`** — `_TokenKind.customEmote` WidgetSpan; **`reaction_bar.dart`** renders token reactions as EmoteImage pills.
- **`ui/settings/emotes_tab.dart`** — server settings Emotes tab (view for all, add/remove gated on `Permission.manageEmotes`, 50 cap); registered in `server_settings_panel.dart`.
- Composer entry points: desktop emoji button in chat_pane + channel_chat_pane (`_openComposerEmojiPicker`/`_insertEmojiAtCursor`), mobile `_showEmojiSheet` (EmojiPickerBody bottom sheet).

## Tests

- Harness: `test_harness.rs:server_emote_replicates_and_bytes_pull_on_demand` (metadata replication, byte pull + verification, permission rejection, removal convergence).
- Widget: `test/widget/emoji_picker_crash_test.dart` (search typing, double-tap teardown guard, tab switching, HollowTextField-in-overlay component guard).

## Composer Integration (shipped 2026-07-11)

**`ui/chat/emote_composer.dart`** — three pieces:
- `EmoteComposerController extends TextEditingController`: emotes render INLINE in the input bar. Each inserted emote = ONE private-use char (U+E000+, allocated per instance) mapped to (name, hash); `buildTextSpan` swaps mapped chars for `WidgetSpan(EmoteImage)` — the 1-char ↔ 1-WidgetSpan LENGTH MATCH is load-bearing (a widget replacing the 70-char token desyncs caret/selection). `expandedText()` produces `[e:name:hash]` wire tokens; unmapped PUA chars (foreign paste) are stripped. `clear()` wipes the map. **EVERY send site must read `expandedText()`, never `.text`** — chat_pane `_handleSend`/`_sendStagedFile`, channel_chat_pane ditto, mobile_chat_route `_handleSend`. Picker insertion goes through `displayTextFor()` (token → placeholder).
- `scanEmoteShortcode()` / `acceptEmoteSuggestion()`: shared `:query` trigger logic (colon at start/after whitespace, 2+ `[a-zA-Z0-9_]` chars; custom emotes first, then Unicode by name, cap 8).
- `EmoteAutocomplete`: desktop overlay (mention-overlay pattern — CompositedTransformFollower; channel pane SHARES `_mentionLayerLink`, DM pane got its own `_composerLayerLink`). Key routing: pane `Focus.onKeyEvent` calls `handleKey` (arrows/Enter/Tab/Escape) BEFORE `handleChatInputKey`. Mobile = Column-child panel above the input bar (mention-panel pattern: `_emoteCandidates`/`_buildEmotePanel` in mobile_chat_route).

**Mobile server-emote management**: `ui/mobile/mobile_emotes_route.dart` (port of desktop EmotesTab), NavRow in mobile_server_settings_route Management block — visible to all, add/remove gated on MANAGE_EMOTES inside.

Tests: `test/emote_composer_test.dart` (expansion, placeholder mapping, trigger rules, acceptance).

## Known Follow-ups

Stickers (same stack, bigger caps, standalone render); personal-emote sibling sync.
