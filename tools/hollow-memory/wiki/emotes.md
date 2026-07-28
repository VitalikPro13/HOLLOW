# Custom Emotes and FFZ Integration

End-to-end map of the custom emote system (shipped 2026-07-10). Architecture rationale in memory `project_custom_emotes_ffz`. Generalized into the ASSET RAIL 2026-07-28 (see the section below) — banners/stickers/GIFs ride the same replication machinery.

## Asset Rail (generalized blob transport, 2026-07-28)

The emote byte-replication system is now the generic content-addressed asset rail (`node/assets.rs` + the emote wire path). Epic: memory `project-asset-rail-epic`.

- **Kinds** `AssetKind::{Emote, Banner, Sticker, Gif, Avatar}` — differ ONLY in receipt cap (`recv_cap`: 256 KB / 1 MB / 512 KB / 2 MB / 512 KB) and per-request hash bound (`max_request_hashes`: 20 / 2 / 8 / 4 / 4). `emote_blobs.kind` TEXT column (additive migration, default 'emote') records what a blob was pulled AS. `Avatar` = the ANIMATED server-icon variant (see "Animated Server Icons" below).
- **Kind never rides the wire.** Requesting side records hash→kind in swarm's `requested_asset_kinds: HashMap<String, AssetKind>` (replaced `requested_emote_hashes`; same lifecycle, cleared on `WsEvent::Disconnected`). `handle_emote_assets` accepts ONLY hashes present in that map and sizes the cap from the RECORDED kind — unsolicited bundles are dropped wholesale (cache-stuffing gate, new in this phase), and an invalid answer frees the slot for retry.
- **Responder reply budget** `MAX_BUNDLE_REPLY_BYTES` = 8 MB (with GIFs cached, the old 20-hash bound alone could balloon a bundle to ~40 MB).
- **Wire token** `[a:kind:hash:w:h]` (kind `s`|`g`, hash 64-hex, dims 1..=4096) — dual-defined: Rust `node/emotes.rs::parse_asset_token`, Dart `emote_image.dart::assetTokenRegex`/`parseAssetToken`. Emotes keep `[e:name:hash]` untouched. w/h let receivers reserve the EXACT box pre-pull (no reflow). `emote_tokens_to_shortcodes` (Rust + Dart) maps asset tokens → `[GIF]`/`[Sticker]` for plain-text notification surfaces.
- **Render** `message_text_parser.dart` `_TokenKind.asset` → `ChatAssetImage` (emote_image.dart): token alone on its own line = block (GIF ≤480px / sticker ≤160px wide, never upscaled past source, interface-scale only — NOT chat text scale, same rule as attachments); inline = 2 line-heights riding the text scaler. Missing blob = sized placeholder + `requestAssetOnce(hash, kind: ...)` (emote_provider.dart, shares the session dedup set + `EmoteAssetsReceived` invalidation).
- **FFI** `request_assets(hashes, kind, server_id, peer_hint)` beside `request_emotes` (which is now the emote-kind shorthand). `NodeCommand::RequestEmotes` gained a `kind` field.
- **Storage Manager**: `StorageBreakdown.asset_blob_bytes/count`; "Emotes & GIFs" segment + cleanup-menu action (`clear_unreferenced_asset_blobs`); cap slider (default 512 MB, key `asset_cache_cap_mb`, desktop + mobile) enforced via `enforce_storage_caps` (new `asset_cap_mb` arg) on FileCompleted AND EmoteAssetsReceived. LRU-evict by `added_at` (`evict_asset_blobs`, 0.8 hysteresis) — hashes referenced by personal_emotes / server CRDT emotes / `server_banner` settings are NEVER evicted (`referenced_asset_hashes`).
- **Harness tests**: `asset_cap_enforced_per_kind` (300 KB blob refused as emote, accepted as gif — proves the cap follows OUR recorded kind and failed receipts retry), `asset_request_not_answered_for_unrequested_hash` (unsolicited valid bundle dropped; uses `MockRelay::inject_direct`). Widget: `test/widget/asset_token_render_test.dart`.

## Server Banners (issue #25, asset-rail Phase 2, 2026-07-28)

First consumer of the generalized rail beyond emotes. The CRDT carries ONLY the hash: `settings["server_banner"]` = 64-hex SHA-256 (`""` = cleared), `settings["server_banner_animated"]` = `"1"|""` — plain `ServerSettingChanged` ops, MANAGE_SERVER-gated at author AND ingest, ZERO new swarm/sync_handler plumbing. Bytes live in `emote_blobs` with `kind='banner'` and pull on demand at `AssetKind::Banner` (1 MB cap).

- **Processing** `image_convert::process_server_banner_image(data) -> (webp, animated)`: 3:1 center crop → 960x320 lossy Q80; GIF → per-frame crop/resize animated WebP ≤1MB; animated-WebP passthrough ≤1MB; still ≤150KB. Thumb helper `process_server_banner_thumb` → 400x133 ≤40KB still. SIDE FIX in the same pass: `process_avatar_image` + profile `process_banner_image` switched from LOSSLESS `write_to(WebP)` to lossy Q80 (`encode_lossy_webp_via_animation`) — lossless size is content-dependent, photographic uploads randomly blew the caps and failed at authoring.
- **FFI** (`api/crdt.rs` beside the avatar trio): `set_server_banner` (process → `save_asset_blob(kind='banner')` → two `update_server_setting` writes, animated flag FIRST so the hash write lands complete), `clear_server_banner`, `get_server_banner -> Option<ServerBannerData{hash, animated, bytes: Option}>` (`bytes: None` = pull needed).
- **Dart** `server_banner_provider.dart`: `ServerBannerNotifier` (Map serverId → `ServerBannerEntry{bytes, hash, animated}`) — avatar-notifier clone incl. `applyLocalWrite` optimistic seed + `_writeGen`/`_writePending`; on hash-without-blob it fires `requestAssetOnce(hash, kind:'banner')` and records hash→serverId in `_pendingPulls`; `onAssetsReceived` (wired in event_provider's `EmoteAssetsReceived` arm) reloads the matching server. Loads on ServerUpdated + SyncCompleted + boot `loadAll` (hollow_shell).
- **Header UI** `channel_sidebar.dart _buildHeader`: no banner = unchanged 48px; banner = 120px, `AnimatedGifImage` background under a bottom-up scrim toward `hollow.surface` (alpha-0 surface color, never `Colors.transparent`), name + 3 action icons overlaid. Switcher key = `'header-$label-${banner.hash}'` so re-uploads crossfade. Animation gate = `windowFocusedProvider` via the new `AnimatedGifImage.animate` flag (reduce-motion stays internal to the widget; selected+mounted implied — the sidebar renders only the selected server). Polish rules (2026-07-28 review): scrim is a 6-stop eased ramp ending at FULL alpha (coarse stops band on dark themes; <1.0 leaves a banner sliver reading as a line), NO bottom border in banner mode, banner+scrim bleed 1px right over the sidebar's border column via `Positioned(right:-1)`+`Clip.none` (Container insets children by its border), and BOTH header variants pad right=sm so the action icons column-align with the channel header's "+".
- **Authoring**: desktop `overview_tab.dart` "Server Banner" block under the icon block (crop 3:1; GIF/animated-WebP picks BYPASS the crop dialog — it flattens to a still — with a 2 MB pre-check); mobile `mobile_server_settings_route.dart` tap-to-upload/hold-to-clear tile. Both stage optimistically + spinner + toasts.
- **Public browse**: `PublicChannelListResponse` gained `#[serde(default)] server_banner_thumb_b64` — a 400x133 STILL thumb (never the full blob; pre-join wire path to strangers), built by `assets::public_banner_thumb` on the responder + the local RequestPublicChannels shortcut; requester refuses >80 KB b64. Dart: `guestServerBannerProvider` (RAM), rendered as a still 3:1 strip atop the expanded guest section in `guest_server_sidebar.dart` (guest thumb ?? member banner, `animate:false`).
- **Eviction safety**: `referenced_asset_hashes` already keeps `settings["server_banner"]` hashes (pre-wired in Phase 1).
- **Tests**: harness `server_banner_hash_replicates_and_bytes_pull_on_demand` (setting converges, bytes never ride the CRDT, rail pull byte-exact, clear converges; seed tags 85/86) + `banner_write_rejected_without_manage_server` (author-side Error + owner-state absence; tags 87/88). Widget: `test/widget/banner_header_test.dart` (48px home / 48px no-banner / 120px + hash key with banner).

## Animated Server Icons (asset-rail follow-up, 2026-07-28)

Same split as banners, applied to the server icon. The still 128px WebP stays base64 INSIDE `settings["server_avatar"]` (old clients + the public-sync thumb read only it — never bloat this with animation); an animated upload ADDITIONALLY writes `settings["server_avatar_anim"]` = 64-hex SHA-256 (`""` = still-only/cleared), blob in `emote_blobs` with `kind='avatar'`, pulled at `AssetKind::Avatar` (512 KB cap).

- **Processing** `image_convert::process_server_avatar_anim(data) -> Vec<u8>`: square per-frame center crop → 128x128 animated WebP Q80 ≤512KB (GIF branch); animated-WebP passthrough ≤512KB; errors on still input — the caller gates on `image_convert::is_animated_image` (GIF8 or RIFF/WEBP/VP8X+ANIM-flag).
- **FFI** (`api/crdt.rs`): `set_server_avatar` now splits still + anim — anim hash written FIRST so the still write (which drives ServerUpdated → UI reloads) lands with its companion in place; a STILL upload writes `server_avatar_anim=""` (replaces any previous animated icon). `clear_server_avatar` clears both. Reader `get_server_avatar_anim -> Option<ServerAvatarAnimData{hash, bytes: Option}>` (`bytes: None` = pull needed).
- **Eviction safety**: `referenced_asset_hashes` (api/storage.rs) pins BOTH `server_banner` and `server_avatar_anim` settings hashes.
- **Dart** `server_avatar_anim_provider.dart`: `ServerAvatarAnimNotifier` — banner-notifier clone (same `_writeGen`/`_writePending`/`_pendingPulls`, same-hash short-circuit, `requestAssetOnce(kind:'avatar')`, `onAssetsReceived` wired in event_provider's `EmoteAssetsReceived` arm; loads on ServerUpdated + SyncCompleted + boot `loadAll` in hollow_shell).
- **Render** — shared `ui/components/server_icon_image.dart` `ServerIconImage{serverId, size, isSelected, fallback, borderRadius}`: anim entry > still > fallback; `animate = (ownHover || isSelected) && windowFocusedProvider` (reduce-motion internal to AnimatedGifImage; frame 0 while gated). Sites: server_strip 44px (`isSelected`), bottom_bar dock 38px (`isSelected || isRightPaneServer`), mobile chats row 44px (`isExpanded` = watched, no hover on touch), authoring tiles desktop 48/mobile 80 (`isSelected:true` — the tile counts as watched; staged picks render via bare AnimatedGifImage). Folder cells + guest 20px sidebar avatar stay STILL (read `serverAvatarProvider` directly).
- **Authoring**: animated picks (GIF/animated WebP) BYPASS the crop dialog in BOTH `overview_tab._pickServerAvatar` and mobile `_pickAvatar` (2 MB pre-check; cropper flattens to a still PNG); both seed `serverAvatarProvider` AND `serverAvatarAnimProvider` optimistically (still pick seeds anim with null = clears).
- **Tests**: harness `server_avatar_anim_hash_replicates_and_bytes_pull_on_demand` (seed tags 89/95; in-memory 2-frame GIF via image::codecs::gif::GifEncoder → hash converges, rail pull byte-exact at AssetKind::Avatar, clear converges). Widget `test/widget/server_icon_anim_test.dart` (fallback / still-only / anim-wins-idle / selected-animates / unfocused-pauses / hover-gates).

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

`ffz/` **in the HOLLOW repo** (canonical since 2026-07-28; deploy: `/public_html/hollow/ffz/` — the old WholesomeStoryAday copy is superseded). `search.php` POST-only, modes `q=` (search, 30d TTL) / `curated=1` (the picker's DEFAULT view: ~110 hardcoded popular emotes `[id,name,owner,animated,usage]` — zero FFZ API cost, ALL rows returned instantly) / `global=1` (FFZ global sets, 7d TTL — legacy, kept as client fallback for an old proxy that answers `[]` to curated). **Metadata and media are separate requests (v2, Phase 0 of the asset-rail epic):** search responses return image URLs unconditionally and never download inline; `fetch.php` is the read-through media cache (only ids in `ffz.db` are fetchable — never an open proxy; atomic tmp+rename; 404 = short negative cache), and the `.htaccess` `!-f` rewrite serves warm files straight from Apache with no PHP. `ext` column is OWNED by fetch.php after first insert (animated gif→webp CDN fallback learning) — search-side upserts never touch it. `SEARCH_VER=2` (sync with `FFZ_SCHEMA_VER` in api/emotes.rs). Same retrofit applied to `igdb/` (v11, plus an `images` registry table carrying the IGDB size slug). FFZ unauthenticated limit = 120 points/min per IP, shared by ALL users through the proxy → caching is load-bearing; on 429 stores a Retry-After backoff (`meta.backoff_until`) and serves stale (image CDN fetches don't spend points). `.htaccess` denies ffz.db + `.tmp.` files, hard-caches images. Users NEVER contact FFZ; viewers never contact even the proxy.

## Dart Surfaces

- **`core/providers/emote_provider.dart`** — `emoteBytesProvider(hash)` (FutureProvider.family), `serverEmotesProvider(serverId)` (invalidated on ServerUpdated in event_provider `_refreshServerState`), `personalEmotesProvider`, `requestEmoteOnce()` (session-deduped fire-and-forget; sync try/catch AND .catchError). `EmoteAssetsReceived` event → `clearRequestedEmotes` + invalidate per-hash providers.
- **`ui/chat/emote_image.dart`** — `EmoteScope` InheritedWidget (serverId/peerHint pull context; wrapped around ChatPane, ChannelChatPane, MobileChatRoute body) + `EmoteImage` (renders cached bytes via Image.memory gaplessPlayback; missing → `:name:` fallback + requestEmoteOnce).
- **`ui/chat/emoji_picker.dart`** — unified picker (see ui_message_bubbles.md > EmojiPicker) + shared authoring helpers `pickAndNameEmote()` (pick → name dialog opens INSTANTLY with raw-bytes preview, WebP encode runs in a tracked background future, Save awaits it under a spinner, '' pop sentinel = processing failed → caller toasts) / `promptEmoteName()` (hash-preview variant, FFZ fallback). Removal UX = `_showEmoteContextMenu` (right-click OR long-press, anchored `showDialog` transparent-barrier menu — picker stays open behind it; NO confirm dialog): Mine tab → "Remove from my emotes"; Recently-used cells in the Emoji tab → "Remove from recents" (`_removeRecentEmoji` persists). FFZ tab empty-search default = `ffzCurated()` → falls back to `ffzGlobal()` on `[]` (old proxy).
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

## Notification Previews (2026-07-11)

Every notification surface must run message text through one of two `emote_image.dart` helpers — never print raw text (tokens show as `[e:name:<64-hex>]` garbage):
- **In-app (renders images):** `emotePreviewSpans(text, style)` → `TextSpan` pieces + `WidgetSpan(EmoteImage)` sized to the line. Used by desktop `NotificationOverlay._MessageRow` + `MobileInChatBanner`, each wrapped in `EmoteScope(serverId: card.serverId, peerHint: card.peerId)` — the message is from a chat the user does NOT have open, so bytes are usually uncached; shows `:name:` and flips to the image when the pull lands.
- **Plain text (OS toasts / push):** `emoteTokensToShortcodes(text)` → `:name:`. Choke points: `DesktopNotificationService.showDm/showChannel`; mobile `_showNotification`/`_showChannelNotification` in push_notification_service (covers lifecycle-background + FCM fetch paths). iOS killed-state NSE bodies come from Rust: `node/emotes.rs::emote_tokens_to_shortcodes` (manual scanner over `parse_emote_token`, unit-tested) applied in `push_enrich.rs` where the NSE JSON is built.

**Picker keyboard (mobile):** the search field's autofocus is DESKTOP-ONLY (`autofocus: !(Platform.isAndroid || Platform.isIOS)`) — on mobile it summoned the software keyboard over the sheet (and defeated the composer's pre-open `unfocus()` in `_showEmojiSheet`). Search focuses on tap.

## Known Follow-ups

Stickers (same stack, bigger caps, standalone render); personal-emote sibling sync.
