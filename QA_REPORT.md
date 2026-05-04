# Hollow Performance/Quality Audit — QA Report

**Date:** May 4, 2026
**Scope:** Full codebase audit across 5 domains (MLS+Crypto, UI Performance, Storage+CRDTs, Networking+WebRTC, Offline-to-Online)

## Cross-Agent Consensus (multiple agents independently flagged these)

### 1. `synced_peers` not cleared on WS disconnect
- **Flagged by:** Networking, MLS+Crypto, Offline-to-Online (3/5 agents)
- **Severity:** CRITICAL
- **Location:** `swarm.rs:1141-1152`
- **Fix:** One line — add `synced_peers.clear()` in the `Disconnected` handler
- **Impact:** After ANY network flap, zero sync happens with any previously-seen peer. CRDT state diverges, profiles go stale, MLS key exchange never retriggers.

### 2. Voice channel participants not cleaned on disconnect
- **Flagged by:** Networking, Offline-to-Online (2/5 agents)
- **Severity:** MEDIUM
- **Location:** `swarm.rs` PeerLeft + Disconnected handlers
- **Impact:** Ghost participants inflate counts, cause wrong mesh/gossip transitions, and trigger WebRTC connections to peers who left.

### 3. Profile provider watched too broadly (entire map)
- **Flagged by:** UI Performance (member tiles + message bubbles + startup load)
- **Severity:** HIGH (3 sub-findings)
- **Impact:** Every profile change rebuilds every visible member tile AND every visible chat message. At 2000 members this is severe.

---

## HIGH Severity Findings

| # | Domain | Title | Location | Status |
|---|--------|-------|----------|--------|
| H1 | **BUG** | `synced_peers` not cleared on disconnect | `swarm.rs:1141` | CONFIRMED |
| H2 | UI | Member panel pre-builds all widgets eagerly despite `ListView.builder` | `member_panel.dart:352-440` | CONFIRMED |
| H3 | UI | HollowShell watches entire `chatProvider` — every DM rebuilds the shell | `hollow_shell.dart:690` | CONFIRMED |
| H4 | UI | `profileProvider` watched inside `itemBuilder` — every profile change rebuilds all messages | `chat_pane.dart:1255`, `channel_chat_pane.dart:1577` | CONFIRMED |
| H5 | Storage | `crdt_ops` table grows unbounded (10-25 MB/server/year) | `messages.rs:900-917` | CONFIRMED |
| H6 | Storage | Full ServerState JSON (1.5-3 MB at 2k members) re-serialized on every single CRDT op (24 call sites) | `sync_handler.rs` (every handler) | CONFIRMED |
| H7 | MLS | `persist_mls_state` opens a new SQLCipher connection on every encrypt/decrypt/commit | `crypto_handler.rs:80-100` | CONFIRMED |
| H8 | MLS | MLS MemoryStorage grows unbounded with epoch count, serialized on every operation | `mls_manager.rs:131-145` | CONFIRMED |
| H9 | MLS | Single coordinator bottleneck — one node handles ALL MLS commits for 1000+ members (mitigated by 2s batch timer) | `crypto_handler.rs:115-143` | CONFIRMED |
| H10 | Network | Relay broadcast is O(n) per message, no batching for 1000+ member rooms | `ws_handler.cpp:209-344` | CONFIRMED |
| H11 | Network | Unbounded WebRTC peer connections in voice mesh — no hard cap (gossip mitigates audio, screen share fully uncapped) | `voice_channel_service.dart` | CONFIRMED |
| H12 | Offline | DM edits/deletes/reactions silently lost when peer is offline | `message_ops.rs:435-650` | CONFIRMED |
| H13 | Offline | Channel message edits/deletes to old messages not captured by sync (`WHERE timestamp >` ignores `edited_at`/`hidden_at`) | `messages.rs:1061-1076` | CONFIRMED |

## MEDIUM Severity Findings

| # | Domain | Title | Location | Status |
|---|--------|-------|----------|--------|
| M1 | UI | Each `_ServerMemberTile` watches entire profile map | `member_panel.dart:552` | |
| M2 | UI | HollowAvatar re-decodes image on every rebuild (reference check, not content) | `hollow_avatar.dart:109-163` | |
| M3 | UI | HollowPressable allocates AnimationController even in `subtle` mode (never used) | `hollow_pressable.dart:41-74` | |
| M4 | UI | Member panel re-filters/re-groups 2000 members on every provider change | `member_panel.dart:248-256` | |
| M5 | UI | All profiles (including avatar blobs, 80+ MB) loaded into memory at startup | `profile_provider.dart:14-25` | |
| M6 | Storage | Server avatar stored as base64 in CRDT settings (133 KB in every serialization) | `crdt.rs:364-368` | |
| M7 | Storage | No message retention policy (~850 MB/server/year) | `messages.rs` tables | |
| M8 | Storage | Full op_log (300-500 KB) sent as plaintext to new joiners | `swarm.rs:4918-4928` | |
| M9 | Storage | O(n) duplicate detection in `apply_op` — 500K comparisons during large syncs | `server_state.rs:222-226` | |
| M10 | Storage | Multiple in-memory HashMaps never evicted (rate tokens, cooldowns, shard assembly) | `swarm.rs:97-327` | |
| M11 | Storage | Profile storage loads all avatar/banner blobs for every peer | `messages.rs:1492-1603` | |
| M12 | MLS | CRDT SyncReq sent via MLS after reconnection — stale epoch causes silent failure | `swarm.rs:1268-1293` | |
| M13 | MLS | `mls_bootstrap_requested` has no timeout — blocks retry forever | `swarm.rs:297, 5353` | |
| M14 | MLS | No cleanup of `key_request_in_flight`, `pending_messages` on disconnect | `swarm.rs:97-104` | |
| M15 | MLS | MLS recovery only targets Owner, not current coordinator | `swarm.rs:5353-5378` | |
| M16 | MLS | Targeted MLS messages encrypt+broadcast to ALL members (O(n) per targeted send) | `crypto_handler.rs:186-213` | |
| M17 | MLS | Commits only sent to online members — offline peers permanently desync | `swarm.rs:2108-2123` | |
| M18 | Network | Gossip PeerExchange broadcasts full topology to all room members | `gossip_relay.rs:110-129` | |
| M19 | Network | WS stream transfer reads entire file (34 MB) into memory | documented in wiki | |
| M20 | Network | Gossip neighbor selection can exceed `MAX_TOTAL_WEBRTC=50` cap | `gossip.rs:237-265` | |
| M21 | Network | Relay has no text message size limit (10 MB * 1000 peers = DoS amplification) | `ws_handler.cpp:199-221` | |
| M22 | Network | Relay silently drops messages under 64 KB backpressure | `ws_handler.cpp:28-32` | |
| M23 | Network | Background bandwidth scales poorly at 1000+ members | across networking code | |
| M24 | Network | No file transfer resumption on WS disconnect | `swarm.rs:1144-1151` | |
| M25 | Offline | Voice channel participants not cleaned on disconnect | `swarm.rs:1396-1458` | |
| M26 | Offline | Pending friend requests not re-sent after app restart | `swarm.rs:289` | |
| M27 | Offline | Banned user retains server state until CRDT sync completes | `sync_handler.rs` | |
| M28 | Offline | @Mentions during offline sync don't trigger mention-specific unread state | `unread_provider.dart` | |
| M29 | Offline | Voice ghost participants — no heartbeat/timeout cleanup | `voice_handler.rs` | |
| M30 | MLS | Channel visibility not cryptographically enforced (known, pre-v1.0) | documented | |

## LOW Severity Findings

| # | Domain | Title | Location | Status |
|---|--------|-------|----------|--------|
| L1 | UI | Channel sidebar uses eager `ListView(children:)` | `channel_sidebar.dart:428-431` | |
| L2 | Storage | `banned_members` HashMap grows without bound | `server_state.rs:433-455` | |
| L3 | Storage | `channel_sync_sent` HashMap never pruned | `swarm.rs:~108` | |
| L4 | Storage | `LIKE '%query%'` search without FTS index | `messages.rs:2254, 2304` | |
| L5 | Storage | No VACUUM/auto-vacuum for SQLCipher | `messages.rs` open() | |
| L6 | MLS | KeyPackage accepted without CRDT membership verification | `swarm.rs:5792-5903` | |
| L7 | MLS | Remove-then-add recovery creates 2 epoch advances per peer | `swarm.rs:5863-5901` | |
| L8 | MLS | Ed25519 uses `verify()` not `verify_strict()` | `native_identity.rs:149` | |
| L9 | MLS | Olm session count unbounded, no stale pruning | `olm_manager.rs:12-19` | |
| L10 | Network | Data channel backpressure uses polling instead of callbacks | `webrtc_service.dart` | |
| L11 | Network | Gossip overlay `known_peers` not cleared on disconnect | `swarm.rs:1141-1152` | |
| L12 | Network | Relay rate limiter only applies to binary frames, not text | `ws_handler.cpp:414-486` | |
| L13 | Network | No timeout for stale voice channel participants | `voice_handler.rs` | |
| L14 | Offline | Server invites have no expiry mechanism | `sync_handler.rs` | |

## Positive Findings (things done well)

- Server switching is correctly batched (atomic provider writes)
- Chat messages properly capped at 200 with lazy `ScrollablePositionedList.builder`
- SharedTickers architecture — all decorative animations share a single ticker
- Strategic `RepaintBoundary` placement isolates repaint regions
- Ed25519/Olm/MLS library choices all provide constant-time guarantees

---

## Detailed Finding Descriptions

### H1: `synced_peers` not cleared on WS disconnect (CRITICAL)

When `WsEvent::Disconnected` fires, `ws_room_peers.clear()` is called but `synced_peers` is not. After auto-reconnect, `synced_peers.insert(peer_id)` returns `false` for all previously-synced peers, skipping the entire sync block: no CRDT sync, no channel message sync, no DM sync, no profile exchange, no key exchange.

**Fix:** Add `synced_peers.clear()` in the Disconnected handler.

### H2: Member panel pre-builds all widgets eagerly

`_ServerMemberContent.build()` iterates ALL members and creates `_ServerMemberTile` widget instances into a `List<Widget>`. This list is passed to `ListView.builder(itemBuilder: (_, i) => items[i])`. While `ListView.builder` lazily builds element trees, the widget objects are already instantiated up front. The role-grouped path wraps everything in `Column(children: items)` — fully eager.

**Fix:** Flatten into a unified index-based scheme with data objects, let `itemBuilder` create widgets on-demand.

### H3: HollowShell watches entire chatProvider

`HollowShell.build()` does `ref.watch(chatProvider)` which watches the entire `Map<String, List<ChatMessage>>`. Every DM message triggers a rebuild of the root layout widget. Only needed for last-message preview and markDmSeen.

**Fix:** Replace with a dedicated `lastMessagePreviewProvider`. Use `ref.read()` for markDmSeen (only in onTap).

### H4: profileProvider watched inside itemBuilder

In both DM and channel chat panes, `ref.watch(profileProvider)` is called inside `ScrollablePositionedList.builder`'s `itemBuilder`. Any profile update rebuilds the parent widget, re-evaluating all visible items. Message bubbles also independently watch the same provider.

**Fix:** Use `ref.watch(profileProvider.select((p) => p[senderId]))` per bubble, or pass profiles from parent.

### H5: crdt_ops table grows unbounded

Every CRDT operation is inserted into the `crdt_ops` SQLCipher table via `INSERT OR IGNORE`. The table is NEVER pruned (only deleted when a server is deleted). In-memory op_log is compacted to 1000, but the DB table grows forever. ~10-25 MB/server/year.

**Fix:** Periodic pruning — keep only the most recent 1000 ops per server.

### H6: Full ServerState re-serialized on every CRDT op

Every CRDT handler serializes the ENTIRE ServerState to JSON and writes to SQLCipher. For 2000 members: ~1.5-3 MB of JSON per write. This happens on every nickname change, label toggle, role change, etc.

**Fix:** Debounce with dirty flag + periodic flush. Long-term: split hot/cold fields into separate tables.

### H7: persist_mls_state opens new DB connection every call

Unlike Olm (dedicated CryptoStore actor with long-lived connection), `persist_mls_state()` opens a fresh `MessageStore::open()` on every call. Each open includes SQLCipher key derivation. Called 22+ times across the codebase, potentially hundreds of times per second with active traffic.

**Fix:** Create a dedicated MLS persistence actor like the Olm CryptoStore pattern.

### H8: MLS MemoryStorage grows unbounded

OpenMLS `MemoryStorage` accumulates key material across all epochs without pruning. The entire storage (all groups, all epochs) is serialized on every `persist_mls_state()` call. Grows linearly with epoch count across ALL servers.

**Fix:** Debounce persistence, investigate per-group isolation, explore OpenMLS epoch pruning APIs.

### H9: Single MLS coordinator bottleneck

`elect_coordinator()` picks the single lowest online peer_id. This one node handles ALL MLS KeyPackage processing, commit creation, Welcome distribution, and stale member cleanup. O(n*m) comparison in cleanup loop.

**Fix:** Sharded coordinator model (hash peer_id into N buckets). Acceptable for <200 members currently.

### H10: Relay broadcast O(n) per message

A single text message in a 1000-member room triggers 999 individual `send_to_peer` calls. No batching, no fan-out tree, no message coalescing. 10 simultaneous messages = 10,000 send calls.

**Fix:** Message coalescing for large rooms. Channel-based pub/sub topics. Long-term concern.

### H11: Unbounded WebRTC connections in voice mesh

No hard cap on total voice+screen share peer connections. Mesh mode (< 6 participants) creates N-1 PCs each. Gossip mode limits audio to 12 but screen share creates unlimited additional PCs. A user could maintain 20+ PCs.

**Fix:** Hard cap on total voice+screen PCs (e.g., 15 audio + 5 screen = 20 max). Degrade gracefully.

### H12: DM edits/deletes/reactions lost when peer offline (CONFIRMED)

When editing a DM while the peer is offline, the edit is saved locally but never transmitted. No queuing mechanism for edits/deletes/reactions. DM sync queries by original timestamp — edits to old messages are never captured.

**Fix:** Add `modified_at` column and `OR modified_at >= ?2` in sync queries. Or queue edits in `pending_messages`.

### H13: Channel edit/delete sync gap

Channel message sync uses `get_channel_messages_since()` which queries by original timestamp. An edit/delete to an old message is not included in sync responses for reconnecting peers.

**Fix:** Add `updated_at` column (MAX of timestamp, edited_at, hidden_at) and modify sync query.
