# Multi-Relay Client: one client, many relays, no federation

**Status:** PLANNED. Design agreed 2026-09-12 (Vitalik + Fable session). Nothing built.
**Owner:** Vitalik (architect).
**Companion memory:** `project_federation_decision` (why an operator pool is rejected and this is the answer instead), `project_self_hosting_overhaul_2026_09` (the invite relay hint and switch dialog this builds on), `project_scaling_plan` (the own-swarm mesh this must not contradict).
**Plan checklist:** HOLLOW_PLAN.md, Infrastructure Master Plan (to be added when this starts; see section 14 for the bullet that must be rewritten first).

---

## 0. TL;DR

Today a Hollow client sits on exactly one relay. Change the relay and you leave everyone on the old one behind. A friend on the official relay and a private server on a friend's self-hosted box cannot coexist in one client; the user restarts into one or the other. That is the single biggest friction self-hosting creates, and it is the thing people mean when they ask whether Hollow "has federation".

The fix is not federation. Federation is a protocol between operators, and every version of it widens the metadata surface (see `project_federation_decision`). The fix is a client that holds one WebSocket per relay it cares about, with every server and every friendship bound to the relay it lives on. Interop happens inside the client. No relay ever talks to another relay. No relay learns anything it does not learn today.

Decision summary:

- A relay becomes a first-class object in the client: an **active relay set**, persisted, synced to siblings.
- The node holds **one ws_client per active relay**, added and removed at runtime, no process restart.
- **A server is bound to one relay** (the one its owner created it on; the invite already carries it).
- **A friendship is bound to one relay** (the one the request was answered on).
- **Identity rooms** (inbox, sibling convergence) are joined on **every** active relay.
- One **router** in Rust resolves relay from room code, so the 149 existing send sites do not change.
- The invite "switch relay and restart" dialog becomes "add this relay", in place.
- Push, TURN, license keys and the kill list become per relay.
- The own-swarm mesh (scaling within `relay.anonlisten.com`) is unaffected: the official domain is ONE entry in the relay set, and what happens behind that DNS name is invisible to this design.

---

## 1. The problem, precisely

The relay domain is a process-global read once at node start (`api/network.rs` `RELAY_DOMAIN`, consumed by `spawn_node` and `start_fetch_node`). `swarm.rs` creates one ws_client, one command channel, one event channel. All connection state is keyed by room only: `ws_room_peers`, `synced_peers`, `relay_catchup_done`, topic subscriptions, keepalive, joined rooms. `WsEvent::Disconnected` clears ten state sets globally. Neither the `friends` table nor the `servers` table nor `ServerState` records a relay. The invite relay hint (`hollow_link_utils.dart`, `?relay=`) exists only in Dart and is consumed once, to decide whether to park the invite and restart the process (`relay_switch_dialog.dart`, `pending_invite_after_switch`).

Consequences today:

1. Joining a server on another relay means leaving every friend and server on the current one until you switch back.
2. A friend on relay A and a friend on relay B cannot both be online for you at once.
3. Multi-device siblings that happen to sit on different relays never converge.
4. Push wakes can only fetch from whichever relay was selected when the app last ran.
5. A duress kill deposit reaches only the current relay.

---

## 2. Non-goals

- **No relay-to-relay protocol of any kind.** No gossip, no forwarding, no shared registry, no directory. This is the line that keeps the metadata surface where it is.
- **No automatic relay discovery.** A relay enters the active set only because the user added it (Settings) or accepted an invite that named it. Never from a list the network hands out.
- **No "best relay" selection or load balancing across trust domains.** That belongs to the own-swarm mesh behind one domain.
- **No cross-relay servers.** A server lives on one relay. Migration between relays is a later, owner-driven CRDT operation (section 13).
- **No change to the relay binary for the core feature.** Every relay in the set is an unmodified relay. Section 9 lists one optional relay-side addition for push and it is backward compatible.

---

## 3. Model

### 3.1 Vocabulary

- **Relay**: a domain (`relay.anonlisten.com`, `myrelay.duckdns.org`). Identity of a relay is its domain string, normalised by `normalizeRelayHost`.
- **Active relay set**: the relays this identity currently holds a socket to. Persisted per identity, synced to siblings. The official relay is always present and cannot be removed (it can be disabled, section 3.4).
- **Binding**: the relay a server or a friendship lives on. Persisted locally. Servers: one relay per server id. Friends: one relay per master id.
- **Identity rooms**: `inbox:{master}` (stranger friend requests, sibling handshakes) and the DM rooms of friends. The inbox is joined on every active relay; a friend's DM room only on that friend's bound relay.

### 3.2 Which relay does a thing go to

| Traffic | Relay |
|---|---|
| Server room broadcasts, topic frames, CRDT ops, MLS, channel files, VC signaling | the server's bound relay |
| DM to a friend (Olm, files, calls, read markers) | the friend's bound relay |
| Stranger friend request by nickname | the relay the nickname was resolved on (the UI picks; the default relay is preselected) |
| Stranger friend request by invite link | the relay the link names |
| Inbox room join + proof | every active relay |
| Sibling convergence (device list, settings, read state) | every active relay (siblings converge through inbox + DM rooms; the identity's own self-DM room is joined everywhere) |
| Push token registration + prefs | every active relay |
| Kill deposit (DestroyIdentity) | every active relay |
| TURN credentials, media forwarder | per relay, requested on each socket's Connected |
| Nickname claim, link code claim | one relay chosen by the user (the default relay preselected); the claim reply tells the user which relay the code is valid on |
| Conferences (`conf:{id}`) | the relay in the conference link (host's choice at creation, the default relay preselected) |
| Forwarder rooms (`fwd:{id}`) | the relay the forwarder is configured for (unchanged; a forwarder is a single-relay process) |
| Reports (`ReportUser`) | the relay the reported peer was seen on (the server's or friendship's bound relay) |

### 3.3 Friend on two relays

Both of you may be active on two shared relays. The bound relay wins for all targeted traffic. The other is a fallback only when the bound relay is down for us AND the friend is observed present on the fallback (RoomMembers of the DM room on that relay). Presence for the friends list = union across relays, with the relay shown on hover when more than one is active.

Re-binding a friendship to another relay is a user action on the friend row ("Reach through..."), never automatic. Rationale: automatic rebinding would move the DM room to whichever relay both happen to share, which lets an operator observe a relationship it did not need to see.

### 3.4 Disabling versus removing

- **Disable**: keep the relay in the set but hold no socket. Servers and friends bound to it show as unreachable ("relay off"). Used for "I do not want to talk to the official relay right now".
- **Remove**: only allowed when nothing is bound to it, or after the user confirms what becomes unreachable. Bindings are never silently deleted; a removed relay's servers stay in the list greyed out until the user leaves them or the relay comes back.

---

## 4. Data model

### 4.1 Local tables (SQLCipher, `storage/messages.rs`)

```
relays (
  domain        TEXT PRIMARY KEY,
  enabled       INTEGER NOT NULL DEFAULT 1,
  added_at      INTEGER NOT NULL,
  label         TEXT NOT NULL DEFAULT '',        -- user nickname for the relay, UI only
  license_key   TEXT NOT NULL DEFAULT '',        -- per relay; empty = none required
  is_default    INTEGER NOT NULL DEFAULT 0       -- exactly one row; preselected wherever a relay is chosen
)
server_relays (server_id TEXT PRIMARY KEY, domain TEXT NOT NULL)
friend_relays (peer_id   TEXT PRIMARY KEY, domain TEXT NOT NULL)   -- MASTER id
```

Kept as side tables rather than columns on `servers`/`friends` so the existing readers do not change and the migration is one INSERT ... SELECT per table.

Every new field on a persisted Rust struct carries `#[serde(default)]` (CLAUDE.md rule). The tables above are plain SQL, but the settings snapshot that rides sibling sync (section 4.3) is a struct and gets the attribute.

### 4.2 Migration on first launch after upgrade

1. `relays` seeded with the current `relay_domain` setting (enabled) plus every entry of `relay_domain_list` (enabled = false for the non-current ones, since today they were never connected).
2. `server_relays` = every server id to the current domain.
3. `friend_relays` = every friend row to the current domain.
4. The old scalar `relay_domain` setting stays written (the official relay if enabled, else the first enabled one) so a downgrade still boots on a sensible relay.

### 4.3 Sibling sync

The active relay set (domains + enabled flags, never license keys) rides the existing sibling settings sync as a new `#[serde(default)]` field. Bindings do NOT ride sibling sync: a sibling learns a server's relay from the server's own join path (section 6.3) and a friend's relay from the friend-list sync that already carries the friend row (add the domain to that payload, `#[serde(default)]`, absent = the relay the sync arrived on).

License keys stay per device (they are per device today).

### 4.4 Invites

`serverInviteLink`, `conferenceLink`, `roomInviteLink` already stamp `&relay=`. They must stamp the **server's bound relay**, not `relayDomainProvider` (today's "my current relay"). Nine build sites listed in section 7.4.

---

## 5. Rust: node changes

### 5.1 One ws_client per relay

`spawn_node` takes the initial relay set instead of one domain. For each enabled relay it spawns `spawn_ws_client` with its own command receiver and event sender. Events are tagged: `WsEvent` gains a `relay: RelayId` on every variant that today has none (`Connected`, `Disconnected`, `RoomMembers`, `PeerJoined`, `PeerLeft`, `LeftRoom`, `Message`, `DirectMessage`, `BinaryDirect`, `TurnCredentials`, `MediaForwarderInfo`, `KillSignal`, nickname and link-code replies). `RelayId` is a small integer index into the node's relay table, mapped back to the domain for Dart.

New `NodeCommand`s: `AddRelay { domain, license_key }`, `RemoveRelay { domain }`, `SetRelayEnabled { domain, enabled }`. Adding spawns a client and joins the identity rooms; removing leaves rooms, drops the client, and clears that relay's slice of state (section 5.3).

`set_relay_url` stays as a compatibility shim for one release (it sets the official entry), then goes.

### 5.2 The router

`WsRouter` replaces the bare `UnboundedSender<WsCommand>` that 156 handler signatures take. Same `send(WsCommand)` shape, so call sites stay put. Resolution:

- Commands carrying `room_code`: look up room to relay. Server rooms via `server_relays`. DM rooms: the router keeps a `dm_room -> relay` map built from `friend_relays` at start and on every friend change. `inbox:` rooms and the self-DM room fan to every enabled relay. `conf:`/`fwd:` rooms go to the relay recorded when the room was joined (the join call carries it explicitly).
- Roomless commands take an explicit relay: `GetTurnCredentials`, `GetMediaForwarder`, `ClaimNickname`, `ReleaseNickname`, `ResolveNickname`, `ClaimLinkCode`, `ReleaseLinkCode`, `ResolveLinkCode`, `RegisterPushToken`, `SetPushPrefs`, `UnregisterPushToken`, `SetOfflineBuffer`, `KillDeposit`, `KillAck`, `CheckPeers`, `ReportUser`. New signatures `send_on(relay, cmd)` and `send_all(cmd)`.
- A room with no binding (a server we are joining for the first time) goes to the relay named by the join request. The join path is the one place a binding is CREATED (section 6.2).
- Unknown room and no hint: log and drop, never "first relay". A silent default relay would recreate the one-way-loss bug class from `feedback_dm_friend_establishment_bugs_2026_07`.

`JoinRoom` for a server room on a relay that is disabled returns an error event so the UI can show "relay off" instead of a spinner.

### 5.3 Per-relay state

The room-keyed maps stay room-keyed. Room codes do not collide across relays except for the identity rooms that are deliberately joined everywhere, and for those the router needs peer to relay attribution. So:

- `ws_room_peers: HashMap<room, HashSet<peer>>` stays, plus a new `peer_relays: HashMap<peer, HashSet<RelayId>>` fed by `RoomMembers`/`PeerJoined`/`PeerLeft` (relay-tagged). Targeted sends to a peer in an identity room pick the relay from `peer_relays` intersected with enabled, preferring the friend binding.
- `synced_peers`, `relay_catchup_done`, `key_request_in_flight`, `key_bundle_sent_to`, `mls_bootstrap_requested`, `mls_welcome_grace`, `mls_epoch_hint_cooldown`, `peer_auto_dl`, `reject_resent`, `requested_file_receipts`: each entry records the relay it was established on (wrap the key or the value, whichever is cheaper per set; most are `HashSet<peer>` and become `HashSet<(RelayId, peer)>`).
- `WsEvent::Disconnected { relay }` clears only that relay's entries. `ws_room_peers` drops rooms bound to that relay plus that relay's contribution to identity rooms (from `peer_relays`).
- `RoomMembers` diffing (`feedback_ws_presence_stale_rooms`) runs per relay; a vanished peer on relay A is not a `PeerDisconnected` if it is still present on relay B for the same room (only possible for identity rooms).
- Topic subscriptions live inside each ws_client already (`WsClientState`), so they are naturally per relay. The desktop microtask-deferred subscribe (`feedback_channel_topic_subscriptions`) resolves the server's relay before calling.

### 5.4 Once-per-connection gates

`relay_catchup_done` and the inbox proof are per connection today and are cleared on Disconnected. With relay tagging they become per (relay, room, channel). The precondition rule stays: stamp only once `ws_room_peers` holds the room on THAT relay (`feedback_once_per_connection_gate_precondition`).

### 5.5 Globals that must stop being global

- `LICENSE_KEY` becomes per relay, from the `relays` table, passed into each ws_client at spawn. `set_license_key(domain, key)` FFI.
- `REALTIME_ACTIVE` stays process-global (it is about the app being foregrounded, not about a relay).
- Proxy tunnel (`proxy_tunnel.rs`) stays one SOCKS listener shared by every socket; the REALITY config is for the official relay's Xray. A self-hosted relay reached through the tunnel simply exits the tunnel to its own host. Per-relay proxy toggles are out of scope.
- TURN: `WsEvent::TurnCredentials { relay, ... }` becomes `NetworkEvent::TurnCredentials { relay_domain, ... }`. The 50-minute refresh timer runs per socket.
- `pending_nickname_resolve` keyed by relay.

### 5.6 The forwarder and conferences

The media forwarder is a separate process on one relay; `fwd:{id}` rooms are joined on the relay the forwarder announced itself on (the server's bound relay). No change to `forwarder/`.

Conferences are virtual servers on `conf:{id}`; the conference link names the relay, and the host's dashboard offers the relay choice at creation (default official). Binding recorded in `server_relays` like any server.

---

## 6. Rust: bindings lifecycle

### 6.1 Server creation

`create_server` takes the relay (a dropdown of enabled relays with the default relay preselected; a client with a single enabled relay never asks). Writes `server_relays` before the first `JoinRoom`.

### 6.2 Server join via invite

The invite's relay hint is passed from Dart into Rust (`join_server(id, relay)`); Rust writes the binding, adds the relay to the set if absent (after the Dart dialog, section 7.2), then runs the existing join path on that relay. `pending_server_joins` gains a `relay` column (`#[serde(default)]` on the struct, absent = official) so a parked join resumes on the right relay after restart.

### 6.3 Sibling learns a server

Server re-announce on sibling reconnect (`feedback_server_lifecycle_sibling_sync`) carries the relay domain (`#[serde(default)]`, absent = the relay the announce arrived on). The sibling writes the binding and joins there. If the sibling does not have that relay in its set, it is added disabled and the UI shows "1 server on a relay you have not enabled".

### 6.4 Friend request accepted

`FriendAccept` is sent into `dm_room_code` on the relay the request arrived on. Both sides write `friend_relays` = that relay. The accept payload carries the domain too (`#[serde(default)]`), so a sibling that receives the friend row through the friend-list sync gets the binding with it.

### 6.5 Friend removal, server leave, server delete

Remove the binding row in the same transaction as the existing tombstone writes. A relay whose last binding disappears stays in the set (the user removes relays, not the code).

### 6.6 Kill deposit

`destroy.rs` deposits on every enabled relay and waits for the first `KillAck`; the rest are best effort. A revoked device that comes back on ANY of its relays gets the signal.

---

## 7. Dart

### 7.1 Providers

- `relayDomainProvider` (single string) becomes `activeRelaysProvider` (`List<RelayEntry{domain, enabled, label, official}>`), loaded in `_bootstrap` as a sync Notifier, never AsyncNotifier-in-build.
- `savedRelayListProvider` is absorbed into it (the list already exists; the change is that entries can be enabled together).
- `relayStatusProvider` becomes keyed by domain (`relayStatusProvider(domain)`), one `/relay-status` fetch per active relay.
- `relayStatsProvider` becomes keyed by domain; the home stats card shows one row per enabled relay.
- `overallConnectionProvider` stays ONE value for the chrome (`feedback_genuine_connection_status`): Online if any enabled relay is connected, Connecting if any is connecting and none connected, Offline if all are down. A new `relayConnectionsProvider` gives the per-relay detail for hover and Settings.
- `IceConfigNotifier` holds a map domain to TURN triple. `iceConfigProvider(callRelay)` picks the set for the call's room relay. Always-relay-calls stays a `ref.listen`, still fails closed, still never touches forwarder legs.

### 7.2 The add-relay flow (replaces the switch dialog)

`ensureRelayForInvite` and `ensureRelayForInviteId` stop exiting the process. New behaviour at all eight call sites (`deep_link_service.dart`, `hollow_link_card.dart` x3, `browse_public_dialog.dart`, `create_server_dialog.dart`, `guest_server_sidebar.dart`, `mobile_chats_tab.dart`, `conference_dashboard.dart`):

- Relay already enabled: proceed.
- Relay in the set but disabled: dialog "This server is on `x`, which is turned off. Turn it on?" (ghost Cancel, filled Turn on).
- Relay unknown: dialog "This invite is on another relay, `x`. Add it alongside your current relays?" with the same relay-status probe the switch dialog runs today (TLS, version, TURN present). Filled Add, ghost Cancel. No restart. If `/relay-status` says the relay requires a license key, the dialog asks for it inline.
- `pending_invite_after_switch` is deleted along with `exitForRelaySwitch()` once the shim period ends.

### 7.3 Settings

`network_section.dart` and the mobile twin: the radio becomes a toggle per row. Rows show domain, label, official badge, connection dot (`StatusDot` with `filled:` shape), counts ("3 servers, 12 friends"), and a license key field when the relay requires one. Remove is disabled while bindings exist, with the count as the reason. The copy "Friends and servers on a different relay won't be reachable" goes away.

`welcome_dialog.dart` first-run keeps one relay field; it seeds the set.

### 7.4 Invite builders

Nine sites read `relayDomainProvider` to stamp the link: `room_provider.dart`, `pending_join_ui.dart`, `channel_sidebar.dart` x2, `server_context_menus.dart`, `conference_dashboard.dart` x2, `mobile_server_settings_route.dart`, `mobile_chats_tab.dart`, `mobile_conferences_route.dart`. Each becomes `serverRelayProvider(serverId)`.

### 7.5 Badges

Only when more than one relay is enabled: a small relay chip on server rows (server strip hover, server settings header) and a hover line on friend rows ("via myrelay.duckdns.org"). Nothing on chat rows, nothing on voice or call surfaces (zero layout cost rule). Purpose labels on every icon-only control.

### 7.6 Custom-relay banners

`channel_chat_pane.dart`, `chat_pane.dart`, `mobile_chat_route.dart`, `mobile_settings_tab.dart` show a "custom relay" banner keyed on `!= kDefaultRelayDomain`. They key on the ROOM's relay instead. `status_provider.dart` gates the news feed on the official relay being enabled, not on it being the only one.

---

## 8. Push

The sharpest break, because the wake runs in a fresh process with one domain.

- Token registers on every enabled relay (`send_all`). Prefs likewise.
- FCM payload stays `{wake, sender}` plus `relay` (the domain that buffered the message). Relay-side change: include `relay` in the push payload. Old relays omit it; the fetch node then tries every enabled relay in order, official first.
- `start_fetch_node(relay_domain, ...)` takes the relay per call. Android: the FCM isolate reads `relay` from the payload. iOS: the NSE entry point already takes `relay_domain` per call; the app group hints cache gains the relay next to the sender.
- Debounce and budget stay per relay (they are relay RAM).

---

## 9. Relay-side changes (optional, backward compatible)

1. Push payload `relay` field (section 8).

Nothing else. No new frames, no membership sharing, no cross-relay anything. `/relay-status` already advertises `license_required`, `turn`, `forwarder`, `version`, which is everything the add-relay dialog needs.

---

## 10. Privacy and security review

**What a relay learns, before and after.** Exactly the same per relay: peer ids in its rooms, room membership, topic subscriptions, IPs, online timing, push tokens of peers registered with it, nickname bindings it holds, kill entries deposited with it. A relay never learns the OTHER relays in a client's set. The inbox room is joined everywhere, so each relay learns "this identity is here", which it already learns from the auth handshake.

**New exposure introduced:** none across operators. Within one client: the sibling settings sync now carries the relay list, encrypted like every other sibling field.

**Things that must hold:**

- Signed key exchange, signed CRDT ops, signed messages: unchanged. A relay was never trusted for content and still is not.
- `inbound_origin_ok`, `admit_remote_op`, `channel_readable_by`, the write gates in wiki `security_write_gates`: all keyed on identities and server state, none on the relay. No gate weakens. Add a wiki row for the new `server_relays`/`friend_relays` writes (local, user- or join-driven, never remote-writable).
- A malicious relay can still drop or delay. With bindings it can now also see that a server or friendship is bound to it, which it could already infer from traffic.
- The duress path improves: a kill deposit reaches every relay, not one.
- A relay must not be able to REBIND a server or friend. Bindings are written only from local user action, the invite the user accepted, or authenticated sibling/friend sync. Never from a relay message.

**Availability:** one relay down = its servers and friends unreachable, everything else fine. Today one relay down = everything down.

---

## 11. Harness

The harness already passes a `MockRelay` into every spawn helper; the blocker is `spawn_node_mock` returning one channel pair. Change it to return one pair per relay in the node's initial set, then `relay_a.register(node, ...)` / `relay_b.register(node, ...)` works unchanged. Presence oracles (`online_identities_from`, `is_online`, `member_panel`) already take the relay.

Tests to write first, before any node code:

1. `two_relays_server_on_b_friend_on_a_both_reachable`: A and B each host a server; a node bound to both chats in both.
2. `relay_b_disconnect_keeps_relay_a_sync_gates`: drop B; A's `synced_peers`, MLS bootstrap flags and `relay_catchup_done` survive; B's are cleared.
3. `friend_bound_relay_wins_over_shared_fallback`: friend present on both; DM rides the bound one; bound down, fallback used; bound back, bound used again.
4. `sibling_learns_server_relay_from_reannounce`: sibling with only relay A learns a server on B, gets B added disabled, joins after enabling.
5. `invite_join_creates_binding_and_resumes_after_restart`: parked join on relay B survives a restart with its relay.
6. `kill_deposit_reaches_every_relay`: revoked device on B only gets the signal.
7. `inbox_join_on_every_relay_stranger_request_arrives_on_b`.
8. `add_relay_at_runtime_joins_identity_rooms` and `remove_relay_refused_while_bound`.

Fleet (`scripts/fleet.ps1` + `fleet_relay_switch.ps1` as the base): a Windows instance and a Linux instance, official relay plus the VM Docker relay, both active in ONE client; join a server on the VM relay from an invite while a DM with a friend on the official relay stays live; kill the VM relay and confirm the DM is untouched and the server shows "relay off".

---

## 12. Phasing

**Phase 0: harness.** Multi-pair `spawn_node_mock`, relay-tagged `WsEvent`, tests 1 and 2 red.

**Phase 1: node core.** Relay table + bindings + migration. N ws_clients, `WsRouter`, per-relay state, selective Disconnected, runtime add/remove/enable. Bindings lifecycle (section 6). Tests 1 to 8 green. `set_relay_url` shim keeps the current app booting unchanged (a single-relay set = today's behaviour, so this phase can ship dark).

**Phase 2: Dart.** `activeRelaysProvider`, Settings toggles, the add-relay flow at eight sites, per-server invite stamping at nine sites, per-relay TURN, connection aggregate, badges, banners. Fleet scenario green on Windows and Linux; iOS Simulator run of the add-relay dialog and Settings (`project_ios_simulator_probe`).

**Phase 3: push, kill list, license.** Relay payload field on the relay (deploy), fetch node per relay, iOS hints cache, kill deposit fan-out, per-relay license keys. Live push test on Android and iOS with a DM on the VM relay.

**Phase 4: polish and docs.** `SELF_HOSTING.md` section "Your relay next to the official one", the website self-hosting page, changelog (through the `sepia` skill), whitepaper 12.11 update, HOLLOW_PLAN checklist, wiki `security_write_gates` rows, `FEATURE_MATRIX.md` rows for the new Settings and dialogs.

**Later: server migration (section 13).**

---

## 13. Later: moving a server to another relay

An owner-authored CRDT op `ServerRelayChanged { domain, hlc }` (signed like every op; `op_allowed` = owner only). Members that ingest it rewrite their binding and rejoin. The old relay keeps the room until every member has left. The topic rings on the old relay are not carried over (they are availability, never truth). Not in this epic; listed so the binding table is designed with a single-writer op in mind.

---

## 14. Reconciling HOLLOW_PLAN.md

The Infrastructure Master Plan scaling section says under "Client-side relay selection + failover": "No relay pinning required. Because the inter-relay mesh handles forwarding, a user can be on any relay and still reach any room. The client doesn't need to know which relay other users are on." That is true INSIDE one trust domain and must be reworded so the two designs read together:

> **Two different things called "multiple relays".** (1) The own-swarm mesh: several of OUR boxes behind `relay.anonlisten.com`, forwarding between each other, invisible to the client, which still sees ONE relay entry. No pinning needed there. (2) The multi-relay client: one client holding sockets to SEVERAL trust domains (the official domain plus self-hosted relays), each server and friendship pinned to the relay it lives on, no relay-to-relay traffic at all. Pinning is how you cross trust domains; the mesh is how one trust domain scales. See `reports/planned/relay-and-sync/MULTI_RELAY_CLIENT_PLAN.md`.

Also update the bullet at "Add configurable relay URL in app settings (self-hosted relay = isolated network, no cross-contamination with official)": isolation stops being the model once this ships; a self-hosted relay is one of several the client holds.

---

## 15. Decisions (Vitalik, 2026-09-12)

1. **Default relay.** The relay set carries ONE "default" toggle (a radio across the rows in Settings, the official relay at first). The default is preselected everywhere a relay must be chosen: creating a server, hosting a conference, claiming a nickname, claiming a link code. Every one of those places still offers a dropdown of the enabled relays. The `relays` table gains `is_default INTEGER NOT NULL DEFAULT 0`, exactly one row set, synced to siblings with the rest of the set.
2. **Nickname claims.** One relay per claim, the user picks, the default toggle preselects. Never claim on every relay at once.
3. **Friend rebinding.** As proposed: a "Reach through..." item on the friend context menu, visible only when both sides share more than one enabled relay.
4. **Disabling the official relay.** Allowed. When it is off, no connection to it is ever opened: no socket, no `/relay-status`, no `/server-stats`, no news feed, no Shop, no push token registration there. Nothing in the app may assume the official relay is reachable.
5. **Guests on a foreign relay.** Same behaviour as guests on the official relay today (`project_relay_ip_limits`): a guest socket to that relay for the browse, nothing added to the set; joining for real adds the relay through the section 7.2 dialog.

---

## 16. Sizing

| Item | Count | Touched by this plan |
|---|---|---|
| ws command send sites | 149 | 0 (router keeps the API) |
| Handler signatures carrying the sender | 156 | 0 (type alias swap) |
| `ws_room_peers` references | ~870 | a handful (Disconnected, RoomMembers, targeted sends in identity rooms) |
| State sets wiped on Disconnected | 10 | 10 (relay-tagged) |
| Dart sites that stop restarting | 8 | 8 |
| Invite build sites | 9 | 9 |
| WsCommand variants needing an explicit relay | 16 | 16 |
| Harness spawn helpers | 5 | 1 (`spawn_node_mock`) |

Comparable to the multi-device epic in reach, smaller in crypto risk (no key material moves; the MLS and Olm code changes only in the bookkeeping of which relay a gate was stamped on).
