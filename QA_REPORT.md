# Hollow Performance/Quality Audit — QA Report

**Date:** May 4, 2026
**Scope:** Full codebase audit across 5 domains (MLS+Crypto, UI Performance, Storage+CRDTs, Networking+WebRTC, Offline-to-Online)
**Status:** Tier 1-4 complete. Remaining items tracked below.

---

## Completed Fixes

### Tier 1 — Quick wins (all in swarm.rs Disconnected handler)
- [x] **H1 (CRITICAL):** `synced_peers.clear()` on WS disconnect — fixed all sync after network flaps
- [x] **M12:** CRDT SyncReq always plaintext after reconnection
- [x] **M13:** `mls_bootstrap_requested` 60s timeout (was permanent)
- [x] **M14:** Clear `key_request_in_flight` + `pending_messages` on disconnect

### Tier 2 — Important bugs
- [x] **H12+H13:** Edit/delete sync gap — `updated_at` column, sync query `OR updated_at >= ?`, message_id existence check before INSERT, edit/delete applied in sync batch receivers with event emissions
- [x] **H3:** HollowShell no longer watches full `chatProvider` — new `lastDmMessageProvider`
- [x] **H4:** `profileProvider` hoisted out of `itemBuilder` in both chat panes
- [x] **Relay backpressure:** 64KB→2MB soft, 256KB→4MB hard, stderr drop logging

### Tier 3 — Performance at scale
- [x] **H6+H7:** CrdtStore actor (`node/crdt_store.rs`) — one DB connection, batch-drain, 34 sync_handler sites refactored
- [x] **H5:** crdt_ops table pruning every 30min via `prune_ops(1000)` (ROW_NUMBER window function)
- [x] **H8:** MLS persistence via CryptoStore actor (20 call sites, no more per-call DB opens)
- [x] **H2:** Member panel virtualization — `_MemberListEntry` data class, truly lazy `ListView.builder`

### Tier 4 — Architectural scaling
- [x] **H9:** Vault coordinator separated from MLS coordinator (`elect_vault_coordinator` = 2nd-lowest peer). Adaptive MLS batch timer (2s→5s→10s based on queue depth)
- [x] **H10:** Relay topic-based channel routing — `0x07`/`0x08` frames, subscribe command, `send_mls_broadcast_topic()` for channel messages. Deployed to VPS
- [x] **H11:** Voice WebRTC hard caps — `maxVoicePcs=15`, `maxScreenShareOutgoing=5`, `maxScreenShareIncoming=3`

### Additional fixes discovered during implementation
- [x] **SFrame key initialization:** MLS epoch key now emitted on voice channel join + cached by Dart provider. `rotateKey` used instead of `setSharedKey`. `setKeyIndexForPeer` called after every cryptor creation. Fixed pre-existing black screen in voice channel screen share.

### Tier 5 — UI performance & lazy loading
- [x] **M1:** `_ServerMemberTile` + `_MemberTile` now use `.select()` on profileProvider — only affected peer's tile rebuilds
- [x] **M2:** HollowAvatar uses `listEquals` content check instead of `identical()` identity check — prevents re-decode on reference change
- [x] **M3:** HollowPressable skips AnimationController allocation in `subtle` mode — saves widget tree depth for list items
- [x] **M4:** Member panel filtering/grouping extracted into `_serverMemberEntriesProvider` computed provider — memoized, no per-build O(n) work
- [x] **M5+M11:** Lazy profile blob loading — startup loads metadata only (`getAllProfilesLight()`), avatars/banners load on-demand via `avatarProvider`/`bannerProvider`. HollowAvatar is now a ConsumerWidget.
- [x] **L1:** Channel sidebar `ListView(children:)` → `ListView.builder` for lazy rendering

### Tier 6 — Voice ghost cleanup
- [x] **M25+M29+L13:** Voice channel participants cleaned on PeerLeft (per-server) and WsEvent::Disconnected (retain only self). Fixes ghost participants after abrupt disconnect.

### Tier 7 — Storage hygiene
- [x] **M9:** O(n) duplicate detection in `apply_op` → HashSet dedup (lazy-init from op_log, rebuilt after compaction)
- [x] **M10:** In-memory HashMap eviction every 5 min: peer_rate_tokens, vc_signal_rate_tokens, decrypt_fail_cooldown, channel_sync_sent, pending_shard_assembly
- [x] **L2:** `banned_members` pruned (unbanned entries removed during op_log compaction)
- [x] **L3:** `channel_sync_sent` pruned in same eviction cycle (entries >30s removed)
- [x] **L5:** SQLCipher incremental auto-vacuum enabled + `incremental_vacuum(100)` on startup

### Tier 8 — Relay hardening
- [x] **M21:** Text frame 1 MB size cap added (text frames are only join/leave/subscribe JSON)
- [x] **L12:** Text frames now share same 1 MB cap; binary rate limit unchanged (100 burst/20 per sec). `maxPayloadLength` raised to 64 MB (was 10 MB) — lowering silently kills connections due to ChannelSyncBatch size

### Tier 9 — Targeted fixes + relay uncapping
- [x] **L8:** Ed25519 `verify()` → `verify_strict()` (rejects non-canonical signatures)
- [x] **L9:** Olm session pruning — `session_last_used` tracking + 7-day TTL prune every 5 min
- [x] **L11:** Gossip overlay `known_peers`/`neighbors`/`peer_scores`/`pending_relays` cleared on WS disconnect
- [x] **M26:** Pending friend requests restored from DB on startup (outgoing+pending loaded into HashMap)
- [x] **M27:** Banned user server removal — `is_banned()` check after `merge_ops` in plaintext SyncResponse handler + explicit `MemberBanned` arm in CrdtOpBroadcast (emits `MemberLeft` for local user)
- [x] **Relay uncapping:** Removed soft backpressure (was 2MB, silently dropped CRDT sync), removed binary rate limit (100 burst/20sec, blocked reconnection floods), raised `.maxBackpressure` to 64MB, raised `MAX_ROOMS_PER_PEER` to 10000
- [x] **RoomMembers SyncRequest → plaintext:** Fixed MLS epoch staleness blocking all CRDT sync after offline (was the root cause of server renames/bans not arriving)
- [x] **M29:** Voice channel state now syncs to newly-connecting peers (was relay backpressure dropping VoiceChannelJoin messages)

### Tier 10 — Design decisions (Bucket A)
- [x] **M15:** MLS recovery now targets lowest online CRDT member (coordinator election) instead of Owner-only. Recovery works regardless of Owner being online
- [x] **L6:** KeyPackage rejected from non-CRDT-members — prevents unauthorized MLS group joins (`[HOLLOW-SECURITY]` log on rejection)
- [x] **M6:** Closed — not an issue. Server avatars are already processed to 128×128 WebP (~3-8 KB base64), hard-capped at 100 KB. Negligible CRDT bloat
- [x] **L14:** Closed — deferred as feature addition, not a bug. Banning already handles invite abuse. Expiry/max-uses is a UX nicety for later
- [x] **M7:** Message retention policy — `retention_messages` CRDT setting (default 365d, options: permanent/30d/90d/180d/365d). Pruned every 30 min in rebalance timer. UI row in Storage Dashboard above Files
- [x] **M8:** Closed — op_log contains only server structure metadata (channel names, member list, roles, nicknames). No messages or keys. Relay uses TLS so wire-level encryption already covers it. MLS bootstraps immediately after. No real attack surface — relay is operator-controlled, in-memory only, no logging
- [x] **M22:** Closed — rate limiting removed intentionally (was breaking CRDT sync on reconnection bursts). 64 MB `maxBackpressure` is dead-connection detection, not rate limiting. Ed25519 auth + license key + banning at CRDT layer is the right defense model. Relay-level rate limiting hurts legit traffic more than it prevents abuse
- [x] **M17:** MLS ban/unban desync fixed — server rejoin now drops stale MLS group and sends fresh KeyPackage to coordinator (not owner). Root cause: rejoining peer kept stale MLS group from before ban, encrypted with wrong epoch, coordinator couldn't decrypt. Also fixed post-join KeyPackage target (was owner-only, now coordinator)
- [x] **Twitch settings toggle bug:** Save button now visible when toggling Twitch verification OFF (was hidden inside `if (_twitchEnabled)` block, making it impossible to disable)
- [x] **M30:** Closed — known limitation, deferred to pre-v1.0. Per-channel MLS subgroups required for true enforcement. UI filtering is the current barrier; topic routing adds a second layer. Not a realistic alpha-stage threat (requires 30+ hours of RE effort for marginal gain)
- [x] **MLS recovery skip for non-members:** Recovery KeyPackage no longer sent when local peer is not a CRDT member (fixes noisy REJECTED log after ban)
- [x] **File re-download on rejoin:** `get_missing_file_ids()` now checks disk (`~/.hollow/files/`) in addition to DB, preventing ~250 MB redundant WebRTC transfers after ban/unban cycles

### Tier 11 — Scaling fixes
- [x] **M19:** WS stream transfer now streams from disk via `BufReader` — no longer reads entire file (up to 34 MB) into memory. ~256 KB resident per transfer
- [x] **M20:** Gossip neighbor selection respects global WebRTC 50 cap as hard limit. `select_initial_neighbors()` returns empty at zero budget. `rotate_with_budget()` receives global count from swarm
- [x] **L4:** FTS5 full-text search indexes on `messages` and `channel_messages` tables. Content-sync triggers keep index in sync. Backfill on startup. Search functions use `MATCH` instead of `LIKE '%query%'`
- [x] **M24:** Deferred — resumption infrastructure in place (offset field in FileRequest, seek support in ws_stream_send, append logic in ws_stream_receive) but transfer state is in-memory only. Needs SQLCipher persistence for cross-restart resumption. Current behavior: interrupted transfers restart cleanly via re-request
- [x] **M16:** Targeted MLS messages converted to Olm+SendDirect — all 19 `send_mls_to_peer()` call sites now use `send_encrypted_message()` (Olm) + `SendDirect` (relay frame 0x04). O(1) delivery instead of O(n) broadcast. No MLS ratchet churn for targeted messages
- [x] **M18:** Gossip PeerExchange narrowed from `SendToRoom` (all members) to per-neighbor `SendDirect`. 12 messages max instead of n. Receiver-side neighbor validation was already in place
- [x] **M23:** Adaptive gossip exchange interval (120s/<100 members, 180s/100-499, 240s/500+). Interval recalculated after each exchange tick based on max server member count
- [x] **L7:** MLS recovery removals batched — new `remove_members_batch()` in mls_manager.rs. Stale members + recovery re-adds queued in `pending_mls_removals`, processed as single commit in batch timer. N recovering peers = 2 total epoch advances instead of 2N
- [x] **L10:** Data channel backpressure poll interval increased from 1ms to 5ms. flutter_webrtc doesn't expose `onBufferedAmountLow` callbacks; 5ms polling is adequate for 256 KB buffer drain cycles

### Storage hygiene
- [x] **Voice recording temp cleanup:** Temp `.ogg` files in `$APPDATA/Hollow/temp/` now deleted after successful send (both DM and channel paths)
- [x] **Early-arrival stream cleanup:** Orphaned early-arrival file streams (WebRTC bytes before FileHeader) pruned after 5 min TTL in eviction timer

---

## Remaining Items (not yet fixed)

### M28 — Notification system (partially complete)

**Done:**
- [x] Notification settings now persist across restarts (`loadAll` called at startup in `hollow_shell.dart`)
- [x] `UnreadState` extended with `channelMentionCounts` — separate @mention tracking
- [x] `recomputeServerUnread()` respects notification levels (All/Mentions/Nothing) via new `countUnreadChannelWithMentions()` Rust FFI
- [x] `ChannelNotificationHint` plaintext message — sender broadcasts hint via `SendToRoom` after every channel message
- [x] Unsubscribed channels correctly receive hints and respect Mentions Only / Nothing / All Messages settings
- [x] Mention badge (`@N`) on channel sidebar + server strip
- [x] Viewport-aware file downloads — files load on scroll proximity instead of bulk download after sync
- [x] `onChannelMessage()` accepts `isMention` flag, `markChannelSeen()` clears mention counts

**Remaining (needs deeper investigation):**
- [ ] Subscribed channel (the one you're viewing or auto-subscribed first channel) still counts ALL messages as unread when set to Mentions Only — the live `ChannelMessageReceived` path applies mention filtering but something in the flow still increments unread for non-mention messages
- [ ] Sync-based unread recomputation doesn't produce server badge counts — `recomputeServerUnread` runs and the FFI returns correct data, but the unread badge on the server icon doesn't appear after sync (DMs work correctly)

### New items discovered during QA work
- [x] Screen share caps raised to 15 outgoing / 10 incoming (was 5/3). True gossip relay deferred post-alpha — requires decrypt/re-encrypt at each hop (same as audio gossip), needs performance testing with real users. Transparent SFrame relay is not possible: WebRTC's `addTrack()` always decodes/re-encodes between PCs
- [x] Friend removal now delivered to offline peers — `pending_friend_removals` HashSet + DB persistence (status=`removed`), drained on PeerJoined/RoomMembers, mirrors the friend request pattern
- Note: Topic-routed channel notifications merged into M28 above

---

## Detailed Descriptions of Remaining Items

### M6: Server avatar in CRDT settings
Server avatar is stored as base64 in the CRDT `settings` HashMap (key `"server_avatar"`). At 133 KB per avatar, this bloats every ServerState JSON serialization. We tried a hot/cold split (separate `server_blobs` table) but reverted — CrdtStore actor writes asynchronously but `get_server_setting()` reads DB synchronously via FFI, causing race conditions. Needs a sync-safe read path before retrying.

### M7: No message retention policy
Messages accumulate indefinitely in SQLCipher tables (`messages`, `channel_messages`). At ~850 MB/server/year with active use, long-running nodes will consume significant disk. Needs a configurable retention policy (per-server? global? time-based? count-based?) — design decision required.

### M8: Full op_log sent as plaintext to new joiners
When a new peer joins a server, the CRDT SyncResponse includes the full op_log (up to 1000 ops, 300-500 KB) as plaintext JSON in a `HavenMessage::SyncResponse`. This is sent before MLS is established. Exposes server structure (channel names, member roles, nicknames) to anyone who can intercept the relay traffic. Should be encrypted or use a challenge-response pattern.

### M15: MLS recovery targets Owner, not coordinator
When MLS state is corrupted and recovery is triggered, the recovery request (`MlsRecoveryRequest`) is sent to the server Owner rather than the current MLS coordinator (`is_mls_coordinator()` = lowest online peer_id). If the Owner is offline, recovery fails. Should target the current coordinator.

### M16: Targeted MLS messages encrypt+broadcast to ALL
`send_mls_to_peer()` encrypts a message for a single target but the MLS protocol encrypts for the entire group. The encrypted ciphertext is then broadcast to ALL room members via the relay. Every member receives and attempts to decrypt a message intended for one peer. O(n) bandwidth per targeted send.

### M17: MLS commits only sent to online members
When the MLS coordinator creates a commit (add/remove member), it's only broadcast to currently online members via the relay. Offline peers never receive the commit and permanently fall behind in epoch. On reconnect, they can't decrypt any messages from the new epoch. Current workaround: MLS recovery re-adds them, but this creates churn.

### M18: Gossip PeerExchange broadcasts topology
`gossip_relay.rs` periodically sends `PeerExchange` messages containing neighbor lists to all room members. This exposes the gossip topology to every peer, which is unnecessary — each peer only needs to know its own neighbors. Wastes bandwidth at scale.

### M19: WS stream transfer reads entire file into memory
`ws_stream_transfer.rs:send_file_over_ws()` reads the entire file into memory with `std::fs::read()` before chunking. For files up to 34 MB (the max relay transfer size), this means 34 MB resident in memory during transfer. Should use streaming file I/O.

### M20: Gossip neighbor selection can exceed WebRTC cap
`gossip.rs` neighbor selection doesn't check the total WebRTC peer connection count. A node could end up with more gossip neighbors than `MAX_TOTAL_WEBRTC=50` allows, especially if it's in multiple servers with gossip mode active. Should coordinate with the voice channel PC count.

### M22: Relay drops messages under backpressure (no retry)
When a peer's outbound buffer exceeds 2 MB (soft limit), `send_to_peer()` silently drops the message and logs to stderr. The sender gets no indication. For critical messages (MLS commits, sync responses), this can cause permanent state divergence. Could add a priority system or retry queue for critical message types.

### M23: Background bandwidth at 1000+ members
Multiple background systems generate per-peer or per-room traffic: gossip PeerExchange, CRDT sync probes, profile broadcasts, MLS commits, voice channel state. At 1000+ members, the aggregate bandwidth from these background systems may saturate the relay connection. Needs measurement and tuning.

### M24: No file transfer resumption on WS disconnect
If a WS stream file transfer is in progress and the relay connection drops, the partial transfer is abandoned. `pending_ws_transfers` is cleaned up on disconnect (temp files deleted). No mechanism to resume from the last received chunk. WebRTC transfers have the same issue.

### M26: Pending friend requests not re-sent after app restart
`pending_friend_requests` HashMap in `swarm.rs` tracks friend requests that couldn't be delivered (peer offline). On peer reconnect, queued requests are sent. But on app restart, this in-memory map is empty — any pending requests from the previous session are lost. Needs persistence in SQLCipher.

### M27: Banned user retains server state
When a user is banned via CRDT `MemberBanned`, the ban takes effect immediately for online peers (UI filtering). But the banned user's local CRDT state and channel messages remain until they receive the ban op via sync. If the banned user is offline when banned, they retain full access until next sync. The UI should also enforce the ban locally on receipt.

### M28: @Mentions during offline sync don't trigger unread
When catching up on messages via sync after being offline, `@mention` patterns in received messages are not processed for mention-specific unread state. The `unread_provider.dart` only triggers mention highlighting for live-received messages, not bulk sync.

### M29: Voice channel state not synced to newly-connecting peers
When a peer connects and another peer is already in a voice channel, the existing peer re-broadcasts `VoiceChannelJoin` at `swarm.rs:1370-1390`. But this only fires during the `PeerJoined` handler, and the message may arrive before MLS key exchange completes (sent as plaintext to work around this, but timing is still fragile). The reconnecting peer may not see existing VC participants until someone leaves/rejoins.

### M30: Channel visibility not cryptographically enforced
Channel `visibility` (Everyone/Specific Roles) is UI-filtered only — all members still receive all messages via the server-wide MLS group. A member with a custom client could see "hidden" channels. True enforcement requires per-channel MLS subgroups (Option B in the design), which is a significant architectural change planned for pre-v1.0.

### L4: LIKE '%query%' search without FTS
Message search uses `WHERE text LIKE '%query%'` which is a full table scan. For large message histories (100K+ messages), this becomes slow. FTS5 virtual table would provide indexed full-text search. Low priority since search is infrequent.

### L6: KeyPackage accepted without CRDT membership
When the MLS coordinator receives a `MlsKeyPackage` from a peer, it's processed without verifying the peer is actually a CRDT member of the server. A non-member could potentially join the MLS group by sending a valid KeyPackage. Should check `server_state.members.contains_key(peer_id)` before processing.

### L7: Remove-then-add recovery creates 2 epochs
MLS recovery removes the stale member then re-adds them, advancing the epoch twice. All other members must process both commits. Could be optimized to a single epoch advance with a custom proposal, but OpenMLS may not support this directly.

### L8: Ed25519 verify() vs verify_strict()
`native_identity.rs` uses `ed25519_dalek::verify()` instead of `verify_strict()`. The non-strict version accepts some malleated signatures. Low risk since we're not using signatures for consensus, but `verify_strict()` is the recommended default.

### L9: Olm session count unbounded
`OlmManager` stores Olm sessions indefinitely. Over time with many peers, this grows without bound. Stale sessions (peers not seen in months) should be pruned. Low priority since Olm sessions are small (~2 KB each).

### L10: Data channel backpressure uses polling
WebRTC data channel send checks `bufferedAmount` in a polling loop with delays. Should use the `onBufferedAmountLow` callback for event-driven flow control. Current approach wastes CPU but works correctly.

### L11: Gossip overlay known_peers not cleared on disconnect
When WS disconnects, `gossip_overlays` are not cleared. On reconnect, stale peer entries may cause neighbor selection to target disconnected peers. Should clear or rebuild overlays on disconnect.

### L14: Server invites have no expiry
Server invite codes never expire. Once generated, an invite link works forever. Should add optional expiry (24h, 7d, never) and max-use counts.

---

## Positive Findings (things done well)

- Server switching is correctly batched (atomic provider writes)
- Chat messages properly capped at 200 with lazy `ScrollablePositionedList.builder`
- SharedTickers architecture — all decorative animations share a single ticker
- Strategic `RepaintBoundary` placement isolates repaint regions
- Ed25519/Olm/MLS library choices all provide constant-time guarantees
- Topic-based relay routing reduces per-channel bandwidth
- CrdtStore + CryptoStore actor pattern prevents DB connection churn
- Lazy avatar loading (avatarProvider) eliminates 80+ MB startup cost
