# Performance Audit — July 2026

> **STATUS 2026-07-03: IMPLEMENTED.** The full fix pass landed the same day
> (all tiers below except the deliberately-skipped items). Deviations from the
> original recommendations:
> - B5(b) "long-lived receive connection": NOT done — superseded by the
>   schema-once gate in `MessageStore::open()` (per-process per-path DDL skip),
>   which removes ~90% of the per-open cost with zero call-site churn.
> - B6(a) "avatar out of ServerState": REJECTED per
>   `feedback_hotcold_avatar_defer` (previously tried + reverted: async blob
>   write races the sync FFI read). Replaced by CrdtStore `SaveStateSnapshot`
>   (lean clone, serialize once per drain on the actor thread).
> - B "MLS send debounce": **IMPLEMENTED THEN REVERTED same day.** Deferring
>   SEND-side ratchet persistence is unsafe: a receive ratchet that regresses
>   (app killed pre-flush) can ratchet forward again, but a regressed send
>   ratchet RE-USES generations receivers already consumed → every live
>   message fails with SecretTreeError(TooDistantInThePast) (observed on the
>   Pixel within hours). "Persist on encrypt" (MLS rule #2) is load-bearing on
>   the send path — do not retry. Receive-side 2s debounce stays.
> - "One-time friend sweep flag": REJECTED — device-keyed friend rows can
>   still appear transiently (nickname add before device-list ingest); the
>   launch sweep is the self-heal and is now cheap.
> - C5 per-chip refactors of friends_bar/server_strip/shell params: PARTIAL —
>   the fixed dampener providers (onlineIdentities/lastDmMessage/deviceLink
>   equality guards) remove most of that churn at the source.
> - Bonus beyond the audit: legacy HTTP signaling task retired entirely
>   (client-side; relay keeps endpoints for old clients) and TURN credentials
>   moved to the authed WS (`get_turn_credentials`) with Rust-owned refresh
>   (on connect + 50-min interval) — fixes the ice_config dead-chain AND the
>   unauthenticated TURN endpoint. Relay deployed 2026-07-03.
> Verified: cargo test --lib (387 incl. multi-node harness), flutter test
> (74), flutter analyze clean (baseline warnings only), FRB codegen re-run.

Three-agent audit triggered by HOLLOW_PLAN item: "we recently did like Rust threading
optimization and now I wonder if it was actually good or there is something that could be
optimized further… most importantly — in the app logic itself."

Scope: (A) the 0fa492f threading/runtime work, (B) Rust app-logic hot paths,
(C) Dart/Flutter rebuild churn + timers + startup. Every finding was verified against
source at the cited line.

---

## A. Verdict on the 0fa492f threading work: SOUND

- Runtime cap (`api/network.rs:453-472`): `worker_threads(available_parallelism().clamp(2,4))`,
  `max_blocking_threads(8)`, named `hollow-rt`. Workload is I/O-bound; cap is appropriate.
  No `block_on` is ever called from inside the runtime (all sites in `api/*` / `push_enrich.rs`),
  so no self-deadlock.
- Blocking pool budget: 2 permanent occupants (CrdtStore + CryptoStore actors) of 8; transient
  `tokio::fs`/DNS users are short. No blocking task waits on another → no exhaustion deadlock.
- Task-leak fixes complete: signaling (`signaling.rs:118-126`) and ws_client
  (`ws_client.rs:375-386`, drain at 408-424) now `break` on channel close. `stop_node` abort
  chain tears everything down. Only other spawn is a bounded 15s one-shot (`sync_handler.rs:737`).
- The "31 tokio-runtime-w threads despite the cap" anomaly = flutter_rust_bridge's own default
  uncapped runtime + library pools, NOT hollow-rt. If it ever matters, FRB's handler can be
  given a custom capped executor.

## B. Rust — confirmed issues, ordered

### Tier 1 (per-message / per-batch)
1. **[CORRECTNESS + PERF] `storage/messages.rs:1847`** — unread/mention counter references
   column `reply_to`; real column is `reply_to_mid`. Query errors on every unread refresh,
   `.unwrap_or((0,0))` swallows it → reply-mentions never counted. One-token fix.
2. **`node/sync_handler.rs:2864-2977`** (`handle_envelope_channel_sync_batch`, the MLS channel
   sync path — the hot one): no `begin_transaction()`, no pk_cache, redundant
   `channel_message_exists` pre-check (insert is already `INSERT OR IGNORE`). Its twins
   (`swarm.rs:5142` plaintext channel, `swarm.rs:5416` DM) do all three correctly — copy them.
3. **MLS whole-provider state serialized per SENT channel message** —
   `crypto_handler.rs:1615/1662`, `file_handler.rs:615` call `persist_mls_state` inline
   (serializes ALL groups → one row rewrite). Receive side already uses the `mls_dirty` 2s
   debounce (`swarm.rs:8521`, flush `swarm.rs:4408`). Route the 3 send sites through it.
4. **`node/message_ops.rs:1666-1671`** — live MLS channel receive runs
   `verify_message_signature(...)` and DISCARDS the bool. Pay the crypto, get no security.
   Enforce it (DM twin at `swarm.rs:5085` enforces) — do not just delete.
5. **`MessageStore::open()` per message/chunk** (~139 sites; hot: incoming DM `swarm.rs:5356`,
   incoming channel `message_ops.rs:1676`+`swarm.rs:5097`, outgoing `message_ops.rs:78/717`,
   reactions `message_ops.rs:1802/1836`, per file chunk `file_handler.rs:1552`+`swarm.rs:6192`,
   fetch `fetch.rs:467/588`). Each open replays ~25 CREATE TABLE + ~40 ALTER + indexes + FTS5.
   Fix: (a) one-time `init_schema()` at startup so open() = key+pragmas;
   (b) long-lived conn for receive/fetch/chunk paths — `struct DbHandle(std::sync::Mutex<Connection>)`
   is `Sync`, so `&DbHandle` crosses `.await` without breaking `Send` (the !Sync problem that
   forced per-call opens, see `share_handler.rs:118-121`). Thread through event-loop locals
   like crdt_store. NOTE: respects `feedback_sqlcipher_open_hygiene`.
6. **Full ServerState JSON serialize per CRDT op, avatar embedded** — `serialize_state_lean`
   (`sync_handler.rs:19-21`) at ~25 op sites + every remote op (`sync_handler.rs:2430`).
   `api/crdt.rs:331-336` stores the server avatar base64 inside `settings["server_avatar"]`,
   so tens of KB ride every serialize. CrdtStore coalesces the WRITE but not the serialize.
   Fix: (a) move avatar to `server_blobs` KV (`crdt_store.rs:90`) — CAREFUL: migration for
   existing states + `#[serde(default)]` discipline; (b) serialize inside the actor drain
   (send Arc<ServerState> snapshot).
7. **`mark_chunk_received` O(n²)** — `storage/messages.rs:3623-3660`: full COUNT recount per
   chunk. Increment on rows-affected; authoritative COUNT only at completion.

### Tier 2 (per-FFI-call / per-tick)
8. FFI holds global node mutex across `block_on(cmd_tx.send)` (bounded 100) — pattern at
   `api/crdt.rs:68-82` and most command senders. Stalled event loop → ALL FFI blocks behind
   the mutex. Fix: clone `cmd_tx`, drop guard, then send (one shared helper).
9. Every CRDT read FFI (`get_joined_servers` etc., `api/crdt.rs:145+`) parses full state JSON
   per call. Mostly fixed by 6a; consider denormalized summary for `get_joined_servers`.
10. `crdt/server_state.rs:659` — `banned_members` retain-scan on EVERY op; move into the
    `MemberUnbanned` arm.
11. Per-tick DB opens: 60s liveness (`swarm.rs:4418`), 30s Olm sweep (`swarm.rs:3889`) both
    open + `load_friends` even when idle. Cache friends set, invalidate on mutation.
12. Small per-message allocs: DM `from_utf8_lossy→from_str` (`swarm.rs:5065`, use `from_slice`);
    pk cache hit re-parses key per item (`crypto_handler.rs:1043`); `resolver::resolve` allocates
    on passthrough (`resolver.rs:59`, return `Cow`); fan-outs clone payload per target.

### Tier 3 (CPU on the event loop / startup)
13. **GIF/WebP conversion inline on the swarm event loop** — `file_handler.rs:124-165` via
    SendFile arm. A multi-MB GIF = seconds of full-pipeline stall (call signaling latency!).
    Fix: `spawn_blocking` + re-enter via internal `NodeCommand::FileConverted`.
14. **Vault erasure coding + shard writes inline** — `vault_ops.rs:234-305` (up to 34MB RS
    encode). Same spawn_blocking + re-entry pattern; inputs already owned.
15. Boot: unbounded `load_ops_for_server` per server (`swarm.rs:642`, no LIMIT vs MAX_OP_LOG
    1000); 6+ sequential fresh opens (`swarm.rs:570-782`); friend canonicalization sweep every
    launch (`swarm.rs:608-627`, gate behind one-time flag). Delays sync-readiness, not paint.

### Rust — verified good (do not re-chase)
CrdtStore batch-drain; Olm per-session persistence granularity; no locks across await; no
per-message task spawns; idle timer discipline (50ms share tick early-return etc.); message
send path (no regex, single encode); storage indexes healthy, no N+1; frames parse once.
Watch-item: unbounded WS inbound channel (`swarm.rs:322`) — rate limit runs after dequeue;
relay per-IP limits mitigate; consider byte-budget enqueue if ever hardening.

## C. Dart/Flutter — confirmed issues, ordered

### Tier 1 — VAD tick fan-out (jank during calls)
Speaking flags live inside monolithic `CallState`/`VoiceChannelState`; ~29 watch sites, ZERO
use `.select()`. Every speaking flip (1-4/sec/talker) rebuilds: the ENTIRE shell
(`hollow_shell.dart:1566/1673`), whole DM pane (`chat_pane.dart:837`), full VC pane w/ 7
RTCVideoView sites (`voice_channel_pane.dart:77`), both mobile call Scaffolds
(`mobile_call_video_view.dart:118`, `mobile_voice_channel_route.dart:90`), mobile channel tree
(`mobile_chats_tab.dart:1006`), +14 pills/strips.
**Root fix: evict speaking state into dedicated `callSpeakingProvider` (record) +
`vcSpeakingProvider` (Set), written at `call_provider.dart:250` / `voice_channel_provider.dart:453`;
consumers select membership. Also select-scope the shell/pane watches (they rebuild on every
mute/camera toggle too).**

### Tier 2 — 1s duration timers rebuilding video subtrees
`chat_pane.dart:2118` (_InlineCallPanel), `mobile_call_video_view.dart:64`,
`mobile_voice_channel_route.dart:64`: whole-panel `setState` per second (mobile keeps ticking
backgrounded). Extract self-ticking duration Text (pattern: `StatusCountdown`,
`system_status_banner.dart:87`).

### Tier 3 — chat pane
- Whole-map watches: `chat_pane.dart:818`, `channel_chat_pane.dart:1261`,
  `mobile_chat_route.dart:1252/1378` — any message in ANY conversation rebuilds the open pane
  + all rows. Fix: `.select((m) => m[id])` (lists immutably replaced → `==` dampens). 4 lines.
- Desktop typing whole-map watches (`chat_pane.dart:831`, `channel_chat_pane.dart:1299`) —
  lift into a TypingIndicatorBar (mobile `_TypingBar` is the model).
- Per-scroll-frame mark-seen writes (desktop): `chat_pane.dart:231-245`,
  `channel_chat_pane.dart:149-161` → FFI saveSetting per scroll tick near bottom. Edge-trigger
  like mobile (`mobile_chat_route.dart:208-223`) + no-op guard in `unread_provider.dart:218`.
- Per-row work: fresh RegExp per row (`message_bubble.dart:178`, `channel_message_bubble.dart:198`
  → static final + contains gate); `File(...).existsSync()` per reply-image row per rebuild
  (`message_bubble.dart:109`); O(n) reply-target indexWhere per row (`chat_pane.dart:1483`+3);
  mention detection per row (`channel_chat_pane.dart:1886`); `base64Decode`+new MemoryImage per
  build → thumbnail re-decode (`link_preview_card.dart:110`); NO negative avatar cache — absent
  avatar = FFI query per rebuild per row (`avatar_provider.dart:13-26`).
- **[RULE VIOLATION] no `ValueKey(messageId)` on rows in all 4 itemBuilders** — violates
  `feedback_listview_state_reuse_keys`; spoiler/hover state shifts across messages on trim.

### Tier 4 — battery / polling
- `relay_stats_provider.dart:70` — 7s HTTPS poll forever, no lifecycle gate, state re-minted
  per tick (fetchCount bump) even on identical data. Worst mobile battery offender (all 4 tabs
  stay mounted → starts at launch). Gate on lifecycle/visibility + only emit on change.
- `status_provider.dart:210/251` — 60s poll writes state unconditionally; compare before write.
- **[CORRECTNESS] `ice_config_provider.dart:55-57`** — TURN credential refresh: HTTP non-200
  returns WITHOUT scheduling retry (only success arms 50-min timer, only exceptions arm 30s
  retry). One 503 during relay restart → TURN dead until app restart → calls degrade STUN-only.
- `event_provider.dart` debugPrint interpolation per event in release — `debugPrint = (…){}`
  under kReleaseMode.

### Tier 5 — always-mounted chrome
- `video_message_bubble.dart:391/530` watch whole `fileTransferProvider` (map replaced per
  chunk event) — siblings already select (`file_attachment_widget.dart:42`).
- Broken dampeners (best leverage/line): `onlineIdentitiesProvider`
  (`device_link_provider.dart:78-89`, fresh Set per recompute → ~20 watchers per peer event);
  `lastDmMessageProvider` (`chat_provider.dart:515-522`, fresh Map → root shell rebuild per DM
  message). setEquals/mapEquals-guard them. Same shape: `device_link_provider.dart:44` refresh.
- `friends_bar.dart:46-48` (Dock daily driver) watches onlineIdentities + profiles + whole
  unread → per-chip ConsumerWidget with selects.
- `hollow_shell.dart:1443-1445` root shell watches peersProvider + lastDmMessage as params.
- `server_strip.dart:253/268`, `bottom_bar.dart:60-62`, `mobile_nav_bar.dart:22` whole-map
  watches (derived `totalUnreadProvider` pattern exists at `unread_provider.dart:439`).
- `server_provider.dart:204-228` serverMemberNamesProvider fresh Set per profile update.

### Tier 6 — startup
- Biggest: ~400+ SERIAL FFI loadSetting round-trips gate the spinner
  (`hollow_shell.dart:826-850` → `notification_provider.dart:48` + `unread_provider.dart:24`).
  Batch into one Rust FFI/DB pass or hydrate unread post-render.
- Theme/accent/background/layout reads run AFTER `fetchRelayStatus` (up to 5s) + node start
  (`hollow_shell.dart:894-926`) though they only need the DB — move before network phase.
- `fetchRelayStatus` no total timeout (`relay_status_provider.dart:9-30`, connectionTimeout
  only) — stalled body blocks node start indefinitely. Wrap in `.timeout(5s)`.
- Minor: `main()` independent awaits parallelizable; Rust `start_node` opens MessageStore twice
  (`network.rs:1172/1194`).

### Dart — verified good (do not re-chase)
VAD services fire only on change; RepaintBoundary on every RTCVideoView; markdown parse
LRU-cached; bubbles' profile watches select-scoped; shared ticker lifecycle-paused; event
dispatcher architecture (targeted notifier calls) sound; profiles load light; histories lazy.

## Recommended execution order

1. Correctness trio (small, standalone): `reply_to` → `reply_to_mid`; enforce discarded MLS
   receive signature; TURN refresh retry on non-200. (+ValueKey rule fix on chat rows.)
2. Rust hot-path batch: sync-batch transaction+pk_cache; MLS send-side debounce; FFI mutex
   drop-before-send. Harness-verify (ring 1/2).
3. Dart call-path: speaking-state eviction + duration-text extraction + shell/pane selects.
   (Directly serves the "blinking avatar" theme — same VAD churn.)
4. `MessageStore::open` split + long-lived receive connection; chunk counter de-quadratic.
5. Avatar out of ServerState + serialize-in-actor (needs migration care).
6. Event-loop CPU eviction: GIF/WebP + vault RS encode via spawn_blocking re-entry.
7. Polling/battery + startup batch/reorder.
