# Networking — WebSocket, Gossip, Signaling, Link Preview, Twitch

Covers seven Rust modules in `rust/hollow_core/src/node/` that handle relay communication, binary streaming, peer discovery, gossip overlays, link previews, and Twitch OAuth.

---

## ws_client.rs — WebSocket Relay Client

Files: `rust/hollow_core/src/node/ws_client.rs` (the socket loop, `Client`),
`node/relay_session.rs` (the session rules as plain state with no socket and no clock: counting,
acks, the outbound queue, liveness, backoff, the v3 auth bytes; every rule unit-tested by handing
it instants), `node/ws_client_wire_tests.rs` (the client against an in-process relay speaking the
section 9 wire: zombie windows, failed resumes, make before break, suspend, drain, door proofs) and
`node/resume_e2e.rs` (ignored test: the real client against the real relay through the zombie
proxy, run by `scripts/resume_e2e.sh`). Spec: `reports/planned/relay-and-sync/RESUMABLE_SESSIONS_PLAN.md`
section 9 (the wire) and section 11 (as built). Relay half: `relay_uws_server.md`, "Resumable
sessions".

### Purpose

One WSS connection per relay carries every room: text (CRDT ops, key exchange, sync) and binary
(file and shard streaming, room broadcasts). Against a relay that offers it, a **session outlives
the socket**: both sides count the stream frames they handled and ack them, a dropped socket resumes
on a new one without a single rejoin, and a heartbeat with a deadline finds a dead path in seconds.
The relay URL is built from the `relay_domain` passed through `spawn_node()` (Dart
`relayDomainProvider`).

### Entry points

- `ws_client.rs:spawn_ws_client(relay_url, peer_id, keypair_proto, pub_key_b64, license_key, fetch, cmd_rx, event_tx)`:
  spawns `Client::run` and registers its control channel in `CONTROLS` (one per running full
  client, so one per relay). The task ends when the node drops its command sender (`shutdown()`).
- `ws_client.rs:connect_and_auth()`: a signed-in socket for the push fetch node (`fetch.rs`) and
  the media forwarder (`forwarder/signaling.rs`). Always today's v2 frame, never a session,
  whatever the relay offers; any answer other than a plain `auth_ok` is refused.
- FFI (`api/network.rs`): `relay_nudge(reason)` -> `ws_client::nudge`,
  `relay_set_background(bool)` -> `set_background`, `relay_suspend()` -> `suspend()` (returns once
  every client closed, at most `SUSPEND_MAX` 5 s). `set_realtime_active(bool)` marks a live call.
- `spawn_with()` (cfg(test)): its own `Timing` and control channel, outside the FFI's reach.

### WsCommand Enum (swarm -> WS client)

Room state: `JoinRoom`, `JoinInbox { room_code, roster }` (our own `inbox:{master}` room, showing
our roster; design ID-1R), `SetDoor { room_code, door }` (the newest door of a server room; never
written itself, joins of that room prove it), `LeaveRoom`, `Subscribe { room_code, topics }`,
`SetOfflineBuffer`. Data: `SendToRoom` (0x03), `SendPublic` (0x0A), `SendDirect` (0x04),
`SendDirectImage` (0x08), `SendBinaryDirect` (0x02), `SendToRoomTopic` (0x07), `SendChannelDirect`
(0x09), `Carry` (writes nothing here: the sealing stage hands it to the node's Olm lane). Control:
`CheckPeers`, `DiscoverPeers`, `GetTurnCredentials`, `GetMediaForwarder`, `Claim/Release/ResolveNickname`,
`Claim/Release/ResolveLinkCode`, `RegisterPushToken`, `UnregisterPushToken`, `SetPushPrefs`,
`SetTopicBuffer`, `TopicCatchup`, `KillDeposit`, `KillAck`, `LockGet`, `LockPut`, `ReportUser`.

`CheckPeers { peers, rooms }` feeds the 60 s peer liveness timer (3 s under `cfg(test)`; friends
only). Reachability is `peer_is_reachable` (device-aware) and the query names
`resolver::devices_for(master)`, the master only for an identity with no known devices, because the
relay only ever sees DEVICE ids.

### WsEvent Enum (WS client -> swarm)

- `Connected`: a fresh session: the first connect, after `SessionLost`, or every connect to a relay
  without sessions. Rooms are joined from here.
- `Suspended`: the socket is gone but the relay holds the session. Nothing is lost and sends keep
  queueing; `Resumed` or `SessionLost` follows.
- `Resumed { gap }`: the session is back on a new socket with no rejoin. `gap`: frames fell out of
  the relay's ring while away, so the node runs its catch-ups.
- `SessionLost` (was `Disconnected`): the relay refused or forgot the session, or there never was
  one. The node purges and rebuilds from the next `Connected`.
- `Connecting { reconnecting }`: a connect attempt starts (not for a make-before-break race).
- `PeerJoined`, `PeerLeft`, `RoomMembers { room, peers }`, `DoorStatus { room, proved }` (sent right
  before the `RoomMembers` it came with; false only in a door-locked room that hides us),
  `LeftRoom { room }` (local, see Room budget), `TopicCatchupDone`.
- `Message` (0x05, and 0x08 topic frames), `DirectMessage` (0x06), `BinaryDirect` (0x02).
- `LicenseError { reason }`, `RoomBudgetUpdate { joined, limit }`, `RoomCapHit { room }`,
  `PeerStatus`, `DiscoveredPeers`, `TurnCredentials`, `MediaForwarderInfo`, the nickname and link
  code events, `KillSignal { blob, signal }`, `LockChain`.

**Orders** (`relay_session::on_drop`, `on_established`, `on_resume_refused`; pinned by
`events_follow_the_order_of_section_9_8` and the wire tests):
- A drop with a session: `Suspended`, then `Resumed { gap }`, or `SessionLost` + `Connected`.
- A drop without one (a relay without sessions): `SessionLost`, then `Connected`. Each failed
  connect attempt while no session is held emits `SessionLost` again.
- A make-before-break win (a race or a move): `Suspended`, then `Resumed`.
- `Resumed` reaches the node before any frame the relay replays.
- While a sid is held, a failed connect emits nothing: the client never declares the session lost
  on its own, because the relay's grace started at the relay's own detection. Dart shows Offline
  after 120 s of Reconnecting (`connection_status_provider.dart`, `outageOffline`).
- A `resumed` whose `h` is above what we wrote or below our last ack is not about our session:
  `SessionLost`, that socket is dropped, and a fresh connect follows at once (`Connected`).

### Handshake: `ws_client.rs:open_socket()`

`open_socket` = `challenge()` (steps 1 and 2) then `sign_in()` (steps 3 to 5); a move runs the two
apart (see "Move to a better network").

1. `dial_websocket()` opens the TCP stream itself, so socket options go on before TLS:
   `TCP_USER_TIMEOUT` 20 s on Linux and Android (`limit_unacked_send_time`, socket2), so the kernel
   stops hiding a dead path behind 15 to 30 minutes of retransmits. Then TLS and the upgrade
   (`client_async_tls_with_config`). TCP + TLS + upgrade together are bounded by
   `Timing::handshake` (10 s).
2. `{"type":"auth_hello"}` -> `auth_challenge { nonce, door_key, session }`. A relay older than
   0.12 answers `auth_failed` ("needs updating"). Each auth reply within `Timing::auth_reply` (5 s).
3. `relay_session::Ask::choose(offered && want_session, fetch, held)`: **v3 only when the challenge
   carries exactly `"session":1`** (`AuthReply::offers_sessions`) and the socket is a full one; v2
   otherwise, and always for fetch and forwarder sockets. v3 = the v2 frame plus `"v":3`, `session`
   (`"new"` or the held sid) and `in_h` (our receive count; 0 for `"new"`), signed as
   `relay_session::auth_v3_message`
   (`hollow-ws-auth3\n{domain}\n{nonce}\n{peer}\n{ts}\n{mode}\n{license_digest}\n{session}\n{in_h}`,
   pinned with the relay's `auth_frame.h` through `relay-uws/test/session_vectors.json`). v2 signs
   `auth_v2_message` (pinned against `test_auth_frame.cpp`). The domain is
   `relay_auth_domain(url)`: the dialled host, lowercase, no port.
4. `relay_session::judge(ask, held, reply)`: `auth_failed` is an error (only the relay's exact codes
   `invalid_license_key`, `license_key_in_use`, `license_key_required` are `LicenseRefusal`s);
   `resumed { h, gap, reprove }` only if we asked to resume; `auth_ok { sid?, resume_failed? }` =
   `Established::Fresh { sid (if sid-shaped), lost: held || resume_failed }`; a second challenge is
   an error. The `hb_secs` and `grace_secs` the relay advertises are ignored: the client keeps its
   own `Timing` (section 9.9 numbers).
5. License: `license_key_in_use` emits `LicenseError` once per outage (`license_busy_notified`,
   reset on success) and the client keeps retrying, because the holder is usually our own ghost
   socket or a sibling; the other two codes stop the client (`stopped`).

### The outbound queue: `relay_session::Outbound<WsCommand>` (replaced `pending_commands`)

- **Unwritten** entries: `Entry::Command` (from the node), `Entry::Replay` (the client's own
  fresh-session replay), `Entry::Frame` (a lost session's written frame, sent again as it was). A
  command becomes a frame only when written (`Client::render`), so a join's door proof is made for
  the session current at write time.
- **Written, unacked**: every counted frame on a session socket gets its number and is recorded
  BEFORE the write (`Outbound::record`), then kept byte for byte until the relay's `ack` or
  `hb_ack` covers it (`Outbound::ack`; an `h` above what we wrote or below our last ack changes
  nothing). A frame that may have reached the relay is resent on resume, never written again as new.
- **Flow control**: at 4096 written-unacked frames or 8 MiB the pump waits for an ack
  (`can_write`); a frame bigger than that still goes once nothing is waiting.
- **Unwritten bounds**: 20,000 entries or 32 MiB. Past them `prune` drops first a sealed live-only
  frame its receiver would refuse anyway (`HavenMessage::live_only` and `frame_auth::is_stale`, read
  from our own seal by `sealed_class`), then the oldest ordinary entry, and **room state (join,
  leave, subscribe, opt-in) last**. The class is computed only on overflow.
- **CRITICAL: the node's channel is the backpressure.** While a socket is live, `takes_commands()`
  reads `cmd_rx` only while the unwritten queue is under HALF of either bound
  (`Outbound::has_room`), so a burst such as a file stream over 32 MiB waits in the node's channel
  instead of being pruned. With no socket the client takes everything and the bounds apply.
- **Pump**: at most `PUMP_BATCH` (64) entries per loop turn, so reads and acks interleave with a long
  flush; paused while a make-before-break race is open. A failed write on a session socket loses
  nothing (the frame was recorded; the resume resends it). On a session-less socket the failed
  entry goes back in front (`unpop`) and nothing behind it moves (the flush-tail bug of plan 1.6).
- **Session lost** (`Outbound::lose_session`): the written-unacked frames move ahead of the unwritten
  queue as `Entry::Frame`, byte-identical, except room-state frames (the replay rebuilds those);
  numbering restarts at 0.

### Inbound count and acks: `relay_session::Inbound`

The counting rules are shared with the relay (`relay_frame_counts`, `client_frame_counts`; vectors
in `session_vectors.json`): every binary frame counts one, every JSON type outside the uncounted set
counts one, text that does not parse counts one, `{"type":"gap","n":N}` counts N. Uncounted relay to
client: `auth_challenge`, `auth_ok`, `auth_failed`, `resumed`, `hb_ack`, `ack`, `reconnect`,
`members`, `peer_joined`, `peer_left`, `kill_signal`. Uncounted client to relay: `auth_hello`,
`auth`, `hb`, `ack`, `inactive`, `active`, `end`. Counting happens only on a session socket. The
client acks `{"type":"ack","h":N}` at once after 16 counted frames, or 2 s after the first unacked
one (`ack_due_at`); every `hb` carries `h` too.

### Resume

`Established::Resumed { h, gap, reprove }` -> `Outbound::resume(h)` drops what `h` covers and
returns the rest. `Resumed { gap }` goes to the node, then those frames are written again in order,
byte-identical (`write_control`), then the unwritten queue. Nothing is rejoined and nothing
resubscribed. On `reprove: true` (the relay came back from a snapshot without door standing) the
session's door context becomes this socket's challenge and `reprove_doors()` queues, at the front,
a join of every joined room we hold a door for, proving it anew.

**Door proofs** (`proof_door()`): with a session, every proof is made for `session_door`, the
challenge of the socket that minted the session (the relay keeps that nonce as the session's door
nonce across resumes), until a reprove. Without a session, the socket's own challenge.

### Fresh session

`Established::Fresh { sid, lost }`: if `lost`, `lose_session()` (unacked frames carried over); then
`SessionLost` (if lost) and `Connected`; the inbound count resets; `replay_rooms()` puts at the
FRONT of the queue a join of every room in `Rooms::joined` (own `inbox:` rooms first, as
`JoinInbox` with their stored roster, the rest sorted), then every stored subscription, then the
offline-delivery opt-in, and emits `RoomBudgetUpdate`. So after a `resume_failed` the wire order is
the replay, the dead session's unacked frames, then the unwritten queue. A fresh session opened while
backgrounded writes `inactive` at once (see "The app's flag").

**Join echo rule** (`render_join`, `replayed_joins`): the swarm's `Connected` work joins the same
rooms again. The first join of a room that renders byte-identical to the replay's join within
`Timing::replay_echo` (5 s) is dropped, once per room. Every other join is written, identical or
not: a re-join is how the node asks the relay for a fresh `members` (the PeerLeft self-heal). The
record clears on a leave, a lost session, a session-less socket's drop and a room-cap rollback.
Pinned by `only_the_nodes_echo_of_the_replay_is_dropped`.

**`Rooms`** (client memory that outlives sockets and sessions): `joined`, `inbox_rosters`, `doors`
(from `SetDoor`; a changed door of a joined room queues a re-join that proves it), `subscriptions`
(the latest topic set per room), `offline_optin`, `last_join_attempt`. `enqueue()` updates it at
once, before the command reaches the wire, so a fresh session joins what the node asked for even if
the command is still queued.

### Liveness

- Heartbeat every 15 s in the foreground, 60 s in the background, but 15 s in the background too
  while a call is live (`Timing::heartbeat_for`, `Client::beat_every`; a call's signalling needs a
  dead path found in seconds). `set_realtime_active` tells every client (`Control::Realtime`): a
  call starting brings the next beat forward, one ending slows the beat after the next one.
  `{"type":"hb","h":N}` on a session socket, a WebSocket ping on a relay without sessions (which
  answers pings with pongs, so it gets the fast liveness too). The client answers the relay's pings.
- **Dead rule** (`Liveness::dead_at`): nothing at all heard for 10 s after a heartbeat went out ->
  drop (`Why::Dead`) and reconnect at once. Any inbound frame answers a heartbeat, so a busy
  download is never judged dead.
- Sleep: every heartbeat tick compares the wall-clock delta with the monotonic one
  (`Clocks::slept`); more than 5 s apart means the machine slept, which is an internal `wake` nudge.
- The relay's side: `idleTimeout` 45.

### Nudge, background, suspend

- `nudge(reason)` (reasons `foreground`, `focus`, `network`, `wake`, `call`, `push`, anything else
  `other`: `relay_session::app_reason`) sends `Control::Nudge { external: true }` to every client.
  `Client::nudge` resets the backoff. Every open attempt (`Purpose::Connect`, `Race`, `Move`) absorbs
  further nudges, so a burst costs one probe or one connect. With a socket: an app `network` nudge
  may MOVE the session (below); otherwise nothing if a frame arrived in the last 2 s
  (`wants_probe`) or a probe is out; else a heartbeat with a 1 s deadline (`probe_sent`), and on a
  miss a NEW socket opens and resumes while the old one is still judged (**make before break**,
  `Purpose::Race`). The first to answer wins: any frame on the old socket drops the race; the new
  socket winning drops the old one quietly (no close frame) and emits `Suspended` then `Resumed`; a
  failed race is ignored (the dead rule decides the old socket). With no socket: connect now (a
  drain wait is cancelled); an attempt older than 2 s is started over, a younger one is left alone.
- **A suspend ends only when the app comes back** (`relay_session::ends_suspend`): an app nudge
  `foreground`, `focus`, `call` (an incoming call or a call kept alive in the background) or `push`
  (a push woke the live process: the ring holds what woke it; the app suspends again 10 s later),
  or `set_background(false)`. App `network` and `wake` nudges, unknown reasons and the client's own
  `wake` (the sleep detector) do nothing while suspended or while a suspend is waiting to close: a
  phone socket closed on purpose stays closed.
- `set_background(bg)`: kept process-wide (`BACKGROUND`, so a new client starts in it); switches the
  heartbeat interval; tells the relay the flag if it does not hold it yet (`sync_flag`); `false` is
  also the phone's ONE foreground nudge (it ends a suspend and probes; the app does not nudge
  `foreground` as well).
- `suspend()`: the client first takes what the node already queued, then (`begin_suspend`,
  `check_suspend`) waits until the queue is written and the relay acked it all (asking with one
  `hb`), at most `Timing::suspend_wait` (2 s); acks what it received; closes 1000 `suspend` and
  waits up to 2 s for the relay's close reply (`goodbye`). The session goes into grace and the
  client stays closed (`suspended`). A race or move in flight is dropped first, and a probe that
  misses while the suspend waits is not raced (a socket raced past the suspend would reopen what
  the app closed). With no socket open it is suspended at once.

### The app's flag (`relay_session::Flag`, `sync_flag`)

`inactive` / `active` are uncounted and never resent, so the client tracks what the relay holds (the
relay keeps it across grace, resume and its snapshot). A fresh session starts active. A flag write is
known to have arrived only once the relay answered (`hb_ack`) a heartbeat written AFTER it on the
same socket; a socket a race or move may take the session from (`doubt`) proves nothing. After every
open (fresh session, resume, move win) and on every `set_background`, the app's flag is written
unless the relay is known to hold it (or it is already in flight on this socket); with no socket open
it waits for the next open. Why so careful: every `active` makes the relay send one `members` per
room, as every resume already does, so a resume where nothing changed writes no flag at all. The
usual phone return (inactive held, back while suspended) writes `active` after `resumed`: one extra
burst, the price of clearing the flag (a relay that skipped that burst when nothing was withheld
would make it free). A fresh session writes the flag before its join replay goes out (`sync_flag`
writes, `replay_rooms` only queues): the relay hides a device only once it holds `inactive`, so a
replayed join ahead of it would announce a backgrounded phone in every room
(`a_fresh_session_writes_inactive_before_its_join_replay`).

### Move to a better network (plan 3.7, `route_moved`, `Purpose::Move`)

On an app `network` nudge with a session socket and no attempt open, the client asks the `Route` seam
(`route_source`: a UDP `connect` to the live socket's relay address sends no packet and names the
local address the routing table would use; the debug `relay_connect` override is the address
dialled, so it counts as the relay's) whether it differs from the live socket's local address
(`Socket::path`, read from the TCP stream at dial time).
- **Different**: two stages (`Step`). First the new socket is dialled and takes the relay's
  challenge (`challenge()`) while the old one carries on as usual, both ways: a captive portal or a
  slow path costs the old socket nothing. Then (`sign_in_move`, `Attempt::signing`) the new socket
  signs in to resume (`sign_in()`) while the old one stays open but untouched: not read
  (`read_next` held), not written (no queue, heartbeat, ack or flag), not judged
  (`Liveness::pause`, no dead rule or probe deadline). The resume signs the count of what the old
  socket delivered; whatever the relay still wrote into it stays unacked in its ring and comes back
  once in the replay. The relay moves the session and closes the old socket 1000 `moved`; the client
  drops it quietly and emits `Suspended` then `Resumed`, like a race win. A move that fails while
  dialling changes nothing; one that fails signing in leaves the old socket as it was: read again,
  judged from one heartbeat, told the flag the app set meanwhile, no event.
- **Same** (a VPN or virtual adapter event, `NotifyIpInterfaceChange` noise): today's probe and
  nothing else. A failed lookup also only probes.
- **No move on a relay without sessions**: a new socket there is a fresh login that supersedes the
  old one and drops whatever is in flight on it, so a network change is only probed.
- Known cost: an IPv6 temporary-address rotation followed by a network event moves once (harmless,
  one socket).

### Reconnect timing: `schedule()`, `relay_session::Backoff`

- After a dead socket, a failed write or a drain close: at once, backoff reset.
- After a close or a failed connect: the drain time when one is set, else full jitter, uniform in
  `[0, min(cap, 0.5 s * 2^attempt)]` (`Backoff::next_within`, a `getrandom` roll). The cap
  (`relay_session::backoff_cap`) is 5 s (`Timing::resume_backoff_cap`) while we hold a session and
  are inside the relay's grace counted from our own `Suspended` (`suspended_at`, 120 s,
  `Timing::grace`), so a path that comes back by itself (router or ISP flap, a zombie that thaws:
  no OS event, no nudge) is resumed within seconds; otherwise 30 s. **A refusal brings the 30 s cap
  back at once** (`refused`: a 1008 close, in the handshake (`rate_limit`, `ip_limit`, `bad_auth`)
  or on a live socket, an `auth_failed`, a license refusal; `ConnectError::Refused`): each refused
  socket spends the relay's 10-new-a-minute budget of the address, an unreachable path costs
  nothing. Cleared when a socket is up. While `realtime_active()` (a call, voice channel or
  conference is live) a steady 1 s (`Timing::realtime_retry`) and no climb, so an ICE restart offer
  can reach the relay inside the call's hold-open window. The attempt count resets on every
  success and every nudge.
- Never while suspended.
- Handshake errors never carry relay text verbatim: a frame that does not parse is named by its
  `type` only (`reply_kind`), relay codes pass only when short and plain (`log_word`, at most 24
  letters, so no sid), and close reasons are logged the same way.

### Drain hint

`{"type":"reconnect","after_ms":N}` -> `drain_at = now + min(N, 30 s)` (`drain_wait`). The relay
closes the socket in the same tick, and the reconnect waits for `drain_at`. If the socket is still
open at `drain_at`, the client closes it 1000 `drain` (waiting up to 2 s for the reply) and resumes
at once.

### Shutdown

The node drops its command sender -> `shutdown()`: on a session socket `{"type":"end"}`, then close
1000 `end` (the 2 s goodbye bound), so the relay hands the ring to `offline_buffer` now instead of
after the grace; then the task returns. Without the exit the socket would ping and reconnect forever,
one leaked task per node restart.

### Fleet dial override (debug builds only)

`dial_override()`: a `relay_connect` file in the data dir holding one `ip:port` (it must parse as a
`SocketAddr`) is dialled instead of the relay's address; TLS and the auth domain stay the relay's.
The fleet uses it to route one app through a proxy it can cut. `cfg(debug_assertions)` only: a
release build always dials the relay. Test `the_fleet_dial_override_takes_only_one_address`.

**CRITICAL: every sink write goes through `bounded_send(write, msg)`** (30 s `WRITE_TIMEOUT` around
`SinkExt::send`; the goodbye frames use `bounded_send_within` with 2 s). An unbounded send on a
wedged TCP connection (a zero-window zombie peer) pends forever with no error, and while that await
is pending `select!` polls no other arm, so the liveness rule itself can never run. A timeout is an
error and takes the normal drop path. Never add a raw `write.send(...)` here. Memory
`feedback_ws_zombie_liveness_timeout`.

### Wire Protocol (JSON for control, binary for data)

**ClientMsg** (serde-tagged JSON): `AuthHello`; `Auth { v, peer_id, public_key, timestamp, nonce,
domain, signature, license_key?, fetch?, session?, in_h? }`; `Join { room, inbox_roster?,
door_proof? }`; `Leave { room }`. Every other command is built by `command_frame()` as a JSON value
or a binary frame; the session frames come from `relay_session` (`hb_frame`, `ack_frame`,
`INACTIVE`, `ACTIVE`, `END`).

**ServerMsg** (serde-tagged JSON): `PeerJoined`, `PeerLeft`, `Members { room, peers, proved? }`
(emits `DoorStatus` first; `proved` absent = an open room = true), `TopicCatchupDone`, `PeerStatus`,
`DiscoveredPeers`, `TurnCredentials` (URIs naming any host but the relay's are dropped,
`turn_uris_on_relay`), `MediaForwarder`, `Error` ("Too many rooms" rolls back the last join),
the nickname and link code answers, `KillSignal`, `KillDeposited`, `LockChain`, `HbAck { h }` and
`Ack { h }` (both ack the outbound queue), `Reconnect { after_ms }` (the drain hint).

### Binary Frame Protocol

All data frames are type-prefixed; a NUL byte (`0x00`) ends each room, peer and topic field.
Layouts pinned by `commands_keep_their_wire_layout`.

**Outbound (client to relay):**
| Type byte | Format | Purpose |
|-----------|--------|---------|
| `0x02` | `[0x02][room][0x00][target][0x00][data]` | Binary direct (file and shard streaming) |
| `0x03` | `[0x03][room][0x00][data]` | Room broadcast |
| `0x04` | `[0x04][room][0x00][target][0x00][data]` | Direct message |
| `0x07` | `[0x07][room][0x00][topic][0x00][data]` | Topic broadcast (channel rings) |
| `0x08` | `[0x08][room][0x00][target][0x00][data]` | Direct carrying an inlined image (image cap offline) |
| `0x09` | `[0x09][room][0x00][target][0x00][channel][0x00][flags][data]` | Channel copy for an offline member; flags bit0 = mention |
| `0x0A` | `[0x0A][room][0x00][data]` | Public broadcast (reaches sockets a locked room hides) |

**Inbound (relay to client):**
| Type byte | Format | Emits |
|-----------|--------|-------|
| `0x02` | `[0x02][room][0x00][from][0x00][payload]` | `WsEvent::BinaryDirect` |
| `0x05` | `[0x05][room][0x00][from][0x00][payload]` | `WsEvent::Message` |
| `0x06` | `[0x06][room][0x00][from][0x00][payload]` | `WsEvent::DirectMessage` |
| `0x08` | `[0x08][room][0x00][topic][0x00][from][0x00][payload]` | `WsEvent::Message` |

Parsing: `parse_binary_relay_frame()` (room, from, payload) and `dispatch_binary()`.

### Room Budget Tracking

`enqueue()` emits `RoomBudgetUpdate { joined, limit: 2000 }` (`ROOM_BUDGET_LIMIT`) on every
`JoinRoom`, `JoinInbox` and `LeaveRoom`, and the fresh-session replay emits one too. A join records
`last_join_attempt` when it is rendered; an `Error` containing "Too many rooms" removes that room
from `joined` and emits `RoomBudgetUpdate` and `RoomCapHit`.

`WsEvent::LeftRoom { room }` is emitted when the Leave frame is rendered: the relay never echoes our
own leave, and the swarm must purge `ws_room_peers[room]` on it. A self-left room's frozen member
snapshot otherwise lives forever and `ws_room_for_peer` can route targeted sends into it, which the
relay drops (sender not in room): a silent per-node signal blackhole until restart (field-hit twice
during media-forwarding phase 2's `fwd:` room churn; memory `feedback_ws_presence_stale_rooms`).


---

## ws_stream_transfer.rs — Binary Stream Reassembly

File: `rust/hollow_core/src/node/ws_stream_transfer.rs`

### Purpose

Chunked binary streaming of files, vault shards, and Share chunks over WebSocket `SendBinaryDirect` frames. Replaces the old libp2p Yamux/QUIC streaming. Since WS runs over TCP, chunks arrive in order and reassembly is straightforward.

### Constants

- `WS_CHUNK_SIZE` = 256 KB — max payload per WS binary frame
- `TYPE_FILE` = `0x00` — file transfer
- `TYPE_SHARD` = `0x01` — vault shard transfer
- `TYPE_SHARE_CHUNK` = `0x02` — Hollow Share encrypted chunk
- `TYPE_CONTINUATION` = `0xFF` — continuation chunk (not the first)

### StreamKind Enum

- `File` — P2P file transfer (DM or channel file)
- `Shard { shard_index: u16 }` — vault shard with 2-byte index
- `ShareChunk { chunk_index: u32 }` — Share encrypted chunk with 4-byte index

### Wire Format

**First chunk:**
```
[type:1][id:64][total_size:8][extra...][data...]
```
- `type` — `0x00` (File), `0x01` (Shard), `0x02` (ShareChunk)
- `id` — 64-byte zero-padded ASCII identifier (file_id hex for files, content_id for shards)
- `total_size` — 8-byte LE u64, total transfer size in bytes
- `extra` — 0 bytes for File, 2 bytes LE u16 shard_index for Shard, 4 bytes LE u32 chunk_index for ShareChunk
- `data` — first chunk of actual file data (up to `WS_CHUNK_SIZE - header_len`)

Header sizes: File = 73 bytes (1+64+8), Shard = 75 bytes (1+64+8+2), ShareChunk = 77 bytes (1+64+8+4).

**Continuation chunks:**
```
[0xFF:1][id:64][data...]
```
- Just the continuation marker, the 64-byte padded ID, and raw data bytes
- Continuation data capacity: `WS_CHUNK_SIZE - 65` bytes per chunk

### Sending: ws_stream_transfer.rs:ws_stream_send()

Parameters: `ws_cmd_tx`, `room_code`, `target_peer`, `kind`, `id`, `source_path`, `total_size`, `start_offset`.

1. Open source file with `BufReader` (streams from disk, never loads full file into memory)
2. If `start_offset > 0`, seek past already-sent bytes (for transfer resumption)
3. Build first chunk: type byte + `pad_id(id)` + total_size LE + kind-specific extra + first data read
4. Send via `WsCommand::SendBinaryDirect`
5. Loop: read continuation chunks from disk, each prefixed `[0xFF][id:64]`
6. `tokio::task::yield_now().await` between continuation chunks for cooperative backpressure
7. Logs total chunk count on completion

### Sending from memory: ws_stream_transfer.rs:ws_stream_send_bytes()

Parameters: `ws_cmd_tx`, `room_code`, `target_peer`, `kind`, `id`, `data: &[u8]`.

Same wire format and chunking logic as `ws_stream_send()`, but reads from a `std::io::Cursor` instead of a file on disk. Used by `stream_to_peer_bytes()` to eliminate the write-then-read disk round-trip for vault shard streaming. No seek/resume support (shards are always sent in full).

### Receiving: ws_stream_transfer.rs:ws_stream_receive()

Parameters: `pending: &mut HashMap<String, WsTransferState>`, `data: &[u8]`.

Returns `Some(StreamRequest)` when transfer completes, `None` when more chunks needed.

**First chunk path (type 0x00/0x01/0x02):**
1. Parse type, ID (64 bytes, stripped of trailing zeros via `parse_id()`), total_size, kind-specific extra
2. If transfer ID already exists in `pending` (resumed transfer), append payload to existing temp file and return
3. Create temp file at `~/.hollow/files/.ws_recv_{id}.tmp`
4. Write initial payload data
5. If `StreamKind::File`, register in global `stream_progress()` map for UI progress tracking
6. If `bytes_received >= total_size`, single-chunk transfer — call `complete_transfer()` immediately
7. Otherwise insert `WsTransferState` into `pending` map

**Continuation chunk path (type 0xFF):**
1. Parse ID from bytes 1..65
2. Look up `WsTransferState` in `pending` map
3. Write payload to temp file
4. Update `bytes_received` and atomic progress counter
5. If `bytes_received >= total_size`, call `complete_transfer()`

### WsTransferState

Per-transfer receiver state stored in `pending` HashMap keyed by transfer ID:
- `kind: StreamKind`
- `id: String`
- `total_size: u64`
- `bytes_received: u64`
- `temp_file: std::fs::File` — open file handle for writing
- `temp_path: PathBuf` — temp file location
- `progress: Option<Arc<AtomicU64>>` — for File kind only, shared with UI progress tracking

### StreamRequest (completion result)

Returned when all bytes received:
- `kind: StreamKind`
- `id: String` — hex identifier
- `size: u64` — total bytes
- `temp_path: PathBuf` — where the reassembled data lives

### StreamProgress (global progress tracking)

`ws_stream_transfer.rs:stream_progress()` — returns `&'static Mutex<HashMap<String, StreamProgress>>` singleton.

`StreamProgress` struct: `bytes_received: Arc<AtomicU64>`, `total_bytes: u64`. Only registered for `StreamKind::File` transfers. Polled by the swarm event loop to emit `FileProgress` events to the Dart UI. Cleaned up in `complete_transfer()`.

### ID Encoding

- `ws_stream_transfer.rs:pad_id()` — pads string to exactly 64 bytes (zero-filled)
- `ws_stream_transfer.rs:parse_id()` — strips trailing zeros from 64-byte buffer

---

## HTTP Signaling — RETIRED (2026-07)

`node/signaling.rs` (HTTP register/heartbeat/bootstrap against the relay) was **deleted** in July 2026. Peer discovery is fully WS-native:

- **Join-time**: joining a WS room returns the authoritative `Members` snapshot and live `PeerJoined`/`PeerLeft` events.
- **Periodic**: the swarm's 30s re-bootstrap timer sends `WsCommand::DiscoverPeers { room_code }` for the active DM room + every server room; the relay answers `discovered_peers` from its live room map (one map lookup, no fresh TLS handshake — the HTTP poll's handshake could stall under WS bursts and produced the perennial "[HOLLOW-SIGNALING] Bootstrap failed, non-fatal" noise).

The relay KEEPS its `/register`, `/unregister`, `/bootstrap/:room_code` HTTP endpoints for pre-2026-07 clients only; current clients never call them. The retired register heartbeat had registered an EMPTY address list anyway (a libp2p multiaddr leftover), so the HTTP path carried no unique information.

### TURN credentials over WS (same change set)

TURN credentials also moved off HTTP: `WsCommand::GetTurnCredentials` → relay `get_turn_credentials` (guest sockets get an error; the credentials sit behind relay auth instead of an open farmable endpoint) → `ServerMsg::TurnCredentials { username, password, ttl, uris }` → `WsEvent::TurnCredentials` → `NetworkEvent::TurnCredentials` → Dart `iceConfigProvider.setTurnCredentials()`. Rust owns the refresh cadence: a request on every `WsEvent::Connected` plus a 50-minute `turn_refresh_timer` (credentials last 1h). This replaced the Dart HTTP fetch whose retry chain dead-ended on a single non-200 (calls silently degraded to STUN-only until app restart). The relay keeps HTTP `/turn-credentials` for old clients.

### Daily byte-budget status over WS (2026-07-05)

The relay byte-budget query that used the same shape (`request_relay_bandwidth()` → `get_bandwidth` → `BandwidthStatus`) was REMOVED 2026-08-28 with the budget itself.

**Close reasons are read** (previously discarded via `Message::Close(_)`): ws_client logs the relay's Close frame reason (`bad_license`, auth timeout, superseded ...). The `bandwidth_limit` reason and its `BandwidthLimited` event are gone with the budget (2026-08-28).

---

## gossip.rs — Gossip Overlay

File: `rust/hollow_core/src/node/gossip.rs`

### Purpose

Per-server gossip overlay that manages which peers to maintain WebRTC data channels with. For small servers (<6 members), every peer connects to every other peer (full mesh). For larger servers, the gossip overlay selects 6-12 "gossip neighbors" based on composite scoring, and messages are relayed through the overlay graph instead of direct full-mesh connections. This keeps WebRTC connection count manageable.

### Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `MIN_GOSSIP_NEIGHBORS` | 6 | Minimum neighbors per server overlay |
| `MAX_GOSSIP_NEIGHBORS` | 12 | Maximum neighbors per server overlay |
| `MAX_TOTAL_WEBRTC` | 50 | Global cap across ALL server overlays |
| `ROTATION_INTERVAL_SECS` | 300 (5 min) | How often neighbor rotation runs |
| `BROADCAST_DEDUP_TTL_SECS` | 60 | Dedup cache entry lifetime |
| `GOSSIP_ACTIVATION_THRESHOLD` | 6 | Server size at which gossip activates |
| `DEFAULT_BROADCAST_TTL` | 4 | Max relay hops for broadcasts |
| `VOICE_GOSSIP_THRESHOLD_UP` | 6 | Voice switches to gossip at this count |
| `VOICE_GOSSIP_THRESHOLD_DOWN` | 4 | Voice switches back to mesh at this count |
| `BROADCAST_FALLBACK_TIMEOUT_SECS` | 30 | Timeout before direct file request fallback |

### PeerScore — Composite Peer Scoring

`gossip.rs:PeerScore` — scoring data per peer per server overlay.

**Fields:**
- `uptime_ratio: f64` — 0.0-1.0, fraction of tracked time the peer was connected
- `avg_latency_ms: f64` — exponential moving average RTT (default 100ms)
- `bandwidth_score: f64` — EMA of bytes/sec throughput from file transfers
- `shard_overlap: u32` — number of vault shards this peer holds that we recently accessed
- `is_direct: Option<bool>` — ICE route class (Tier 3 reachability, 2026-07-06): `Some(true)` = host/srflx/LAN, `Some(false)` = TURN-relayed, `None` = unmeasured. Reported by Dart `_logIceRoute` via `webrtc_route_report()` FFI once per connection.
- `connected_since: Option<Instant>` — None if currently disconnected
- `total_connected_secs: f64` — accumulated connection time
- `total_tracked_secs: f64` — total observation time
- `last_updated: Instant`

**Composite score formula** — `gossip.rs:PeerScore::composite()`:
```
score = (shard_overlap * 0.10)           // each overlap adds 0.10
      + latency_score * 0.30             // 1.0 - (avg_latency_ms / 500).min(1.0)
      + uptime_ratio * 0.20
      + bandwidth_normalized * 0.10      // (bandwidth_score / 10_000_000).min(1.0)
      + reach_score                      // direct 0.15 / unmeasured 0.075 / TURN 0.0
```
Weights: shard overlap is per-shard additive, latency 30%, uptime 20%, bandwidth 10%, reachability 15%. The direct-vs-TURN spread (0.15) clears the rotation's 10% improvement margin, so the 300s rotation drifts the mesh toward directly-reachable peers.

**Update methods:**
- `PeerScore::refresh_uptime()` — recalculates `uptime_ratio` from accumulated connected/tracked seconds
- `PeerScore::mark_connected()` — calls `refresh_uptime()`, sets `connected_since`
- `PeerScore::mark_disconnected()` — calls `refresh_uptime()`, clears `connected_since`
- `PeerScore::update_latency(rtt_ms)` — EMA with alpha=0.3: `new = 0.3 * rtt + 0.7 * old`
- `PeerScore::update_bandwidth(bytes, duration_secs)` — EMA with alpha=0.3 on throughput (bytes/sec)

### GossipOverlay — Per-Server State

`gossip.rs:GossipOverlay` — one instance per server.

**Fields:**
- `server_id: String`
- `neighbors: HashSet<String>` — current gossip neighbors (WebRTC data channel targets)
- `known_peers: HashSet<String>` — all online peers in this server (superset of neighbors)
- `peer_scores: HashMap<String, PeerScore>`
- `seen_broadcasts: HashMap<String, Instant>` — broadcast dedup cache
- `pending_relays: HashMap<String, PendingRelay>` — waiting for file data after BroadcastMeta arrived via MLS
- `last_rotation: Instant`

### Neighbor Selection

**Initial selection** — `gossip.rs:GossipOverlay::select_initial_neighbors()`:
1. Compute budget: `MAX_TOTAL_WEBRTC - global_count` (hard cap — global WebRTC limit takes priority)
2. If budget is 0, return empty (no new connections allowed)
3. Target: `min(budget, MAX_GOSSIP_NEIGHBORS)`, then `max(target, min(MIN_GOSSIP_NEIGHBORS, budget))`, capped by `known_peers.len()`
4. Sort all known peers by composite score descending
5. Take top N as neighbors
6. Returns the selected peer IDs (caller must establish WebRTC connections)

**Auto-add below minimum** — `gossip.rs:GossipOverlay::add_known_peer()`:
- Inserts peer into `known_peers` and ensures a `PeerScore` entry exists
- If `neighbors.len() < MIN_GOSSIP_NEIGHBORS`, adds the peer as a neighbor immediately
- Returns `Some(peer_id)` if the peer was added as a neighbor, `None` otherwise

**Peer removal** — `gossip.rs:GossipOverlay::remove_known_peer()`:
- Removes from `known_peers`
- If the peer was a neighbor, picks the best-scoring non-neighbor as replacement
- Returns `(was_neighbor: bool, replacement: Option<String>)`

### Neighbor Rotation

`gossip.rs:GossipOverlay::rotate_with_budget(global_webrtc_count)` — called periodically (every 5 minutes via `gossip_relay.rs`). Receives the current global WebRTC peer count from the swarm.

1. Refreshes uptime for all scored peers
2. **Fill below minimum**: picks best non-neighbor until `neighbors.len() >= min(MIN_GOSSIP_NEIGHBORS, current + budget)` — respects global WebRTC cap
3. **Trim above maximum**: repeatedly drops worst neighbor until `neighbors.len() <= MAX_GOSSIP_NEIGHBORS`
4. **Swap (when in range [MIN, MAX])**: finds worst neighbor and best non-neighbor. Swaps only if best candidate scores >10% higher than worst neighbor (`best_score > worst_score * 1.1`)
5. At most 1 swap per rotation for stability
6. Returns `(to_connect: Vec<String>, to_disconnect: Vec<String>)`

**Priority peer protection** — `gossip.rs:GossipOverlay::pick_worst_neighbor()`:
- Filters out peers with `shard_overlap >= 3` — they are never candidates for removal
- Among remaining, picks the one with lowest composite score

### Broadcast Dedup

- `gossip.rs:GossipOverlay::should_relay_broadcast(broadcast_id)` — returns `true` (first time) or `false` (duplicate). Inserts into `seen_broadcasts` on first call.
- `gossip.rs:GossipOverlay::mark_broadcast_seen(broadcast_id)` — marks as seen without relay decision (used by originator)
- `gossip.rs:GossipOverlay::evict_stale_broadcasts()` — removes entries older than `BROADCAST_DEDUP_TTL_SECS` (60s). Also evicts `pending_relays` older than `BROADCAST_FALLBACK_TIMEOUT_SECS` (30s).

### Small-Message CRDT-Op Flood (Tier 2 large-server scaling, 2026-07-06)

CRDT ops flood the WebRTC mesh instead of paying the relay's O(N) egress
(`reports/shipped/relay-and-sync/LARGE_SERVER_SCALING_2026.md` §7). Wire frame: data-channel type byte
`0x04` carrying `gossip.rs:GossipCrdtOp { broadcast_id, server_id, ttl, op_json }`
(max `MAX_GOSSIP_OP_BYTES` = 15 KB; bigger ops fall back to the relay).

- **Origin:** `sync_handler.rs:broadcast_crdt_op_to_members()` tries
  `gossip_relay.rs:flood_crdt_op()` first — targets =
  `GossipOverlay::connected_relay_targets()` (neighbors whose data channel is
  LIVE per `PeerScore.connected_since`), emitted as ONE
  `NetworkEvent::GossipRelayOp { targets, payload }` (Dart fans the frame out).
  Returns 0 → caller falls back to the per-identity relay `SendDirect` loop.
  Uses `event_tx.try_send` so it stays callable from sync helpers.
- **Receive:** Dart hands `0x04` frames to `webrtc_gossip_op_received()` FFI →
  `NodeCommand::WebRtcGossipOpReceived` → `gossip_relay.rs:accept_gossip_op()`
  (size cap + broadcast-id dedup) → re-enters `handle_incoming_request` as a
  synthetic `HavenMessage::CrdtOpBroadcast`, so the op runs the exact same
  author-permission matrix, op_log dedup, persistence, and UI events as a
  relay op.
- **Propagation is bounded by op-newness:** the forward step (inside the
  `CrdtOpBroadcast` arm) only fires when the op grew the local op_log, so each
  node re-floods a given op at most once (fresh broadcast_id per hop; `ttl` is
  a reserved wire field). That arm is also mesh-first now — the historical
  per-member `SendDirect` re-forward was O(N²) network-wide.
- The MLS twin (`send_mls_broadcast`, single SendToRoom) is unchanged; nodes
  without WebRTC (the whole test harness) always take the relay fallback.

### Pending Relay System

For gossip file relay: when a `BroadcastMeta` arrives via MLS (metadata about a file being broadcast), the overlay registers a pending relay. When the actual file data arrives via WebRTC data channel, the overlay consumes the pending relay and forwards the file to gossip neighbors.

- `gossip.rs:GossipOverlay::add_pending_relay(file_id, broadcast_id, ttl, origin, channel_id, sender_peer_id)` — registers a pending relay
- `gossip.rs:GossipOverlay::take_pending_relay(file_id)` — consumes and returns the relay info (returns None if not found or already consumed)
- `gossip.rs:GossipOverlay::get_timed_out_relays()` — returns file_ids of relays older than 30s (file never arrived via gossip, need direct fallback)

`PendingRelay` struct: `broadcast_id`, `file_id`, `ttl`, `origin`, `channel_id`, `sender_peer_id`, `created: Instant`.

### Relay Target Selection

- `gossip.rs:GossipOverlay::get_relay_targets(exclude_peer)` — returns all neighbors except the excluded peer (the sender). Used when forwarding a broadcast.
- `gossip.rs:GossipOverlay::get_voice_gossip_neighbors(voice_participants, local_peer_id)` — returns neighbors that are also in the voice channel participant set (intersection). Excludes local peer.

### Voice Channel Gossip Thresholds

Hysteresis pattern to prevent thrashing:
- At `VOICE_GOSSIP_THRESHOLD_UP` (6) participants, voice switches from full mesh to gossip relay
- At `VOICE_GOSSIP_THRESHOLD_DOWN` (4) participants, voice switches back to full mesh
- This 2-participant hysteresis band prevents rapid switching when participants hover around the threshold

### Broadcast ID Generation

`gossip.rs:generate_broadcast_id()` — 16 random bytes via `getrandom::fill()`, hex-encoded to 32 characters.

---

## gossip_relay.rs — Gossip Relay Branching

File: `rust/hollow_core/src/node/gossip_relay.rs`

### Purpose

Timer-driven gossip operations that run from the swarm event loop. Handles broadcast relay, neighbor rotation, dedup eviction, and peer exchange. These are the "do something periodically" functions that operate on the `GossipOverlay` state.

### Functions

#### gossip_relay.rs:handle_webrtc_broadcast_received()

Called when a WebRTC data channel delivers a gossip broadcast from a neighbor.

Parameters: `gossip_overlays`, `event_tx`, `webrtc_peers`, `broadcast_id`, `ttl`, `origin_peer_id`, `sender_peer_id`, `temp_path`, `total_size`, `kind`, `shard_index`.

Flow:
1. Iterate all server overlays looking for one that hasn't seen this `broadcast_id`
2. Call `overlay.should_relay_broadcast(broadcast_id)` — returns true on first match
3. If `ttl > 0`, get relay targets (excluding sender) from the matched overlay
4. For each target that has an active WebRTC connection (`webrtc_peers.contains(target)`), emit `NetworkEvent::GossipRelayFile` with `ttl - 1`
5. Break after first matching overlay (broadcast belongs to one server)
6. If no overlay accepted (already seen everywhere), log and skip

#### gossip_relay.rs:handle_gossip_rotation()

Timer tick handler for neighbor rotation. Called periodically from the swarm event loop.

Flow:
1. Iterate all server overlays
2. Skip overlays where `known_peers.len() < GOSSIP_ACTIVATION_THRESHOLD` (6) — small servers don't need gossip
3. Call `overlay.rotate_with_budget(global_webrtc_count)` to get `(to_connect, to_disconnect)` lists
4. Emit `NetworkEvent::GossipConnect { peer_id }` for each peer to connect
5. Emit `NetworkEvent::GossipDisconnect { peer_id }` for each peer to disconnect

#### gossip_relay.rs:handle_gossip_eviction()

Timer tick handler for broadcast dedup eviction and relay timeout fallback.

Flow:
1. Iterate all server overlays
2. Get timed-out pending relays (file didn't arrive via gossip within 30s)
3. For each timed-out relay, fall back to direct file request:
   - Check if origin peer is reachable via `crypto_handler::peer_is_reachable()`
   - If reachable, send `HavenMessage::FileProbe { file_id }` to origin via `crypto_handler::send_message_to_peer()`
4. Call `overlay.evict_stale_broadcasts()` to clean up dedup cache and expired pending relays

#### gossip_relay.rs:handle_gossip_exchange()

Timer tick handler for peer exchange protocol. Sends neighbor lists only to gossip neighbors (not the whole room).

Flow:
1. Iterate all server overlays
2. Skip overlays with empty neighbor sets
3. Build `HavenMessage::PeerExchange { server_id, peers }` with the overlay's neighbor list
4. Send via `send_message_to_peer()` (`SendDirect`) to each gossip neighbor individually
5. Adaptive interval: `gossip_exchange_interval_secs(max_members)` returns 120s/<100, 180s/100-499, 240s/500+

### Integration with Swarm Event Loop

These four functions are called from `swarm.rs` match arms on timer ticks:
- `handle_gossip_rotation()` — every `ROTATION_INTERVAL_SECS` (300s / 5 min)
- `handle_gossip_eviction()` — periodically (tied to broadcast cleanup interval)
- `handle_gossip_exchange()` — periodically (tied to peer exchange interval)
- `handle_webrtc_broadcast_received()` — on each `WebRtcBroadcastReceived` event

---

## link_preview.rs — URL Link Preview Fetching

File: `rust/hollow_core/src/node/link_preview.rs`

### Purpose

Fetches OpenGraph metadata from URLs typed in the compose box and builds a `LinkPreviewRef` struct embedded in the outgoing message envelope. **Privacy-critical: sender-side only.** Receivers render the embedded preview and NEVER make HTTP requests to the previewed URL. This prevents Hollow from becoming an IP-harvesting amplifier.

### Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `MAX_HTML_BYTES` | 2 MB | HTML response body cap. YouTube ships ~1.2 MB inline, so 1 MB would cut off OG tags. |
| `MAX_IMAGE_BYTES` | 4 MB | OG image response body cap. Typical OG images are <500 KB. |
| `FETCH_TIMEOUT_SECS` | 3 | Total timeout for HTML + image fetches combined |
| `MAX_TITLE_CHARS` | 200 | Unicode character cap for title |
| `MAX_DESC_CHARS` | 400 | Unicode character cap for description |
| `THUMB_MAX_DIM` | 400 px | Max dimension for a compact-card WebP thumbnail |
| `THUMB_MAX_DIM_LARGE` | 800 px | Max dimension when the card will be large |
| `MIN_LARGE_THUMB_W` | 320 px | Below this, never use the large card (stretched logos) |
| `HERO_MIN_W` / `HERO_MIN_ASPECT` / `HERO_MAX_ASPECT` | 600 px / 1.3 / 3.0 | An undeclared but unmistakable share hero |
| `USER_AGENT` | `"Mozilla/5.0 (compatible; HollowBot/1.0; +https://anonlisten.com/bot)"` | Crawler-shaped on purpose — the fx*/vx* embed proxies serve OG tags only to bot UAs, and x.com serves them to us because of this. The `+url` must resolve (page lives at `!website/src/routes/bot/`). |

### Client reuse

`http_client()` caches ONE `reqwest::Client` in a `OnceLock<Mutex<Option<Client>>>` so keystroke-triggered fetches share its pool and TLS config. (Until 2026-09-30 it was keyed on the anti-censorship tunnel's SOCKS address; the tunnel is removed.)

### Public API

`link_preview.rs:fetch_link_preview(url)` -> `Result<LinkPreviewRef, String>`

Flow:
1. Parse URL via `reqwest::Url::parse()`. Reject non-http/https schemes.
2. Extract display domain from parsed URL
3. Get the shared client via `http_client()`
4. **Social adapter first** (see below). Any failure logs and falls through to the OpenGraph path — a dead adapter degrades to the old behavior, never to an error.
5. Fetch HTML via `fetch_bounded()` with 2 MB cap
6. Parse OG metadata via `parse_og_metadata()` — now also reads `og:type`, `twitter:card`, `og:video[:url|:secure_url]`, `og:image:width`
7. If `og:image` or `twitter:image` found: resolve relative → fetch (4 MB cap) → `convert_to_webp_preview()` at `THUMB_MAX_DIM_LARGE` when the page looks large-card-worthy, else `THUMB_MAX_DIM` → base64
8. Decide the layout with `wants_large_card()` (below) and fill `RichCard`
9. Return `LinkPreviewRef { …, rich: Option<Box<RichCard>> }`
10. Errors are returned as `Err(String)` — caller silently drops the preview without blocking the message send

### Card layout — declaration-driven, NOT a host allowlist

`declares_large_card()` / `declares_video()` / `wants_large_card()`.

The page says which layout it wants and the code reads it: `twitter:card` = `summary_large_image` or `player`, or `og:type` starting `video`/`music`. Measured live 2026-08-02 — semgrep.dev, github.com and instagram.com all send `summary_large_image`; youtube.com sends `player` + `video.other`; wikipedia sends neither.

Plus one undeclared fallback: an image ≥ `HERO_MIN_W` wide with aspect in `HERO_MIN_ASPECT..=HERO_MAX_ASPECT` (the classic 1200x630). Wikipedia's SQUARE 1200x1200 article logo fails on aspect, which is the point. Veto: no image, or decoded width < `MIN_LARGE_THUMB_W`.

Video affordance follows the same declarations. A declared `og:video` that is a real `.mp4`/`.webm` becomes `video_url` and plays inline; otherwise `video_url` is the PAGE url and the card opens it.

**A `MEDIA_PAGE_HOSTS` allowlist was written and deleted — do not reintroduce it.** See `feedback_declared_standards_over_allowlists`.

### Social adapters (`mod social`)

Key-free public APIs, called DIRECTLY from the client — there is no Hollow-run proxy. FxEmbed reads the post server-side, so X never sees the user's IP for the metadata either way.

- **X family** (`x.com`, `twitter.com`, `fixupx.com`, `fxtwitter.com`, `vxtwitter.com`, `twittpr.com`) → `GET https://api.fxtwitter.com/2/status/{id}`. **The v2 endpoint nests the post under `status`; the older `/status/{id}` uses `tweet`. `parse_fxembed()` accepts EITHER** — reading only `tweet` made every X link silently fall back to OpenGraph on first ship. Prefers a video (with its poster) over a still photo.
- **TikTok** (`tiktok.com`, `vxtiktok.com`, `tnktok.com`) → `GET https://www.tiktok.com/oembed?url=…`. Title, author, thumbnail; no media URL exists, so no inline video.
- Host matching is SUFFIX on the parsed host (`host == s || host.ends_with(".{s}")`), never substring — `x.com.evil.tld` matches nothing.
- Adapter results always get `kind: "large"`.
- `EMBED_PROXY_BASE` (`set_embed_proxy_url` FFI) optionally routes the whole adapter step at a configured service. **Empty = direct, and that is the default.**

### HTML Fetching

`link_preview.rs:fetch_bounded(client, url, max_bytes)`:
1. `client.get(url).send().await`
2. If `Content-Length` header exceeds `max_bytes`, bail early
3. Read full body via `resp.bytes().await`
4. If body length exceeds `max_bytes`, bail
5. Return bytes

### OG Tag Parsing

`link_preview.rs:parse_og_metadata(html)` -> `ParsedMeta`:

Uses the `scraper` crate to parse HTML and select `<meta>` tags.

**Fallback chain:**
- **title**: `og:title` -> `<title>` tag text -> `""`
- **description**: `og:description` -> `<meta name="description">` -> `""`
- **site_name**: `og:site_name` -> `""`
- **image**: `og:image` -> `twitter:image` / `twitter:image:src` -> `None`

Iterates all `<meta>` elements, reads `property` or `name` attribute (lowercased), matches against known OG/Twitter keys.

### Text Truncation

`link_preview.rs:truncate_chars(s, max_chars)` — truncates by Unicode code point count (not byte count). Preserves multi-byte characters (emoji, CJK, etc.) correctly.

### LinkPreviewRef Output Struct

Defined elsewhere (likely `types.rs`), populated by `fetch_link_preview()`:
- `url: String` — original URL
- `title: String` — truncated to 200 chars
- `description: String` — truncated to 400 chars
- `domain: String` — display domain from URL host
- `site_name: String` — from `og:site_name`
- `thumb_webp_b64: Option<String>` — base64 WebP thumbnail
- `thumb_w: Option<u32>` — thumbnail width
- `thumb_h: Option<u32>` — thumbnail height

---

## twitch.rs — Twitch OAuth

File: `rust/hollow_core/src/node/twitch.rs`

### Purpose

Twitch integration for server join gating. Server owners can require that joiners follow or subscribe to a Twitch channel. Uses the OAuth 2.0 Device Code Grant flow (no redirect URI needed, works on all platforms). The joiner proves their Twitch status locally and attaches a `TwitchProof` to their join request; the server validates the proof without making any network calls.

### Constants

- `TWITCH_CLIENT_ID` = `"z3piofwp5qr458qfn0ncn6a501ua05"` — Hollow's registered Twitch application
- `DEVICE_CODE_URL` = `"https://id.twitch.tv/oauth2/device"`
- `TOKEN_URL` = `"https://id.twitch.tv/oauth2/token"`
- `VALIDATE_URL` = `"https://id.twitch.tv/oauth2/validate"`
- `HELIX_BASE` = `"https://api.twitch.tv/helix"`

### Data Types

**TwitchDeviceCodeResponse**: `device_code`, `user_code`, `verification_uri`, `expires_in`, `interval` — returned when starting the device flow. The `user_code` and `verification_uri` are shown to the user in the UI.

**TwitchTokenResponse**: `access_token`, `refresh_token`, `expires_in`, `token_type` — OAuth tokens after successful authorization.

**TwitchValidateResponse**: `client_id`, `login`, `user_id`, `expires_in` — from token validation endpoint. Provides the Twitch user ID and login name.

**TwitchProof**: `twitch_user_id`, `twitch_username`, `followed_at: Option<String>`, `is_subscribed`, `sub_tier: Option<String>`, `timestamp: i64` — attached to server join requests. Generated by the joiner, validated by the server.

**TwitchServerSettings**: `channel_id`, `channel_name`, `min_follow_days`, `require_sub`, `owner_verify` — parsed from `ServerState` CRDT settings.

### TwitchServerSettings::from_server_state()

`twitch.rs:TwitchServerSettings::from_server_state(state)` -> `Option<Self>`

Reads from the CRDT `ServerState.settings` map:
- `twitch_verification_enabled` — must be `"true"` or returns None
- `twitch_channel_id` — must be non-empty or returns None
- `twitch_channel_name` — display name
- `twitch_min_follow_days` — parsed as u32, defaults to 0
- `twitch_require_sub` — `"true"` or false
- `twitch_owner_verify` — `"true"` or false

### Device Code Grant Flow

**Step 1: Start** — `twitch.rs:start_device_flow()` -> `Result<TwitchDeviceCodeResponse, String>`
- POST to `https://id.twitch.tv/oauth2/device` with `client_id` and `scopes: "user:read:follows user:read:subscriptions"`
- Returns device code, user code, verification URI

**Step 2: Poll** — `twitch.rs:poll_for_token(device_code, interval_secs)` -> `Result<TwitchTokenResponse, String>`
- Minimum poll interval: 5 seconds
- POST to token URL with `client_id`, `device_code`, `grant_type: "urn:ietf:params:oauth:grant-type:device_code"`
- On success: parse and return `TwitchTokenResponse`
- On `authorization_pending`: continue polling
- On `slow_down`: increase interval by 5 seconds and continue
- Any other error: return Err

### Token Management

**Refresh** — `twitch.rs:refresh_access_token(refresh_token)` -> `Result<TwitchTokenResponse, String>`
- POST to token URL with `grant_type: "refresh_token"` and the refresh token
- Returns new `TwitchTokenResponse` with fresh access/refresh tokens

**Validate** — `twitch.rs:validate_token(access_token)` -> `Result<TwitchValidateResponse, String>`
- GET to `https://id.twitch.tv/oauth2/validate` with `Authorization: OAuth {token}` header
- Returns user info including `user_id` and `login` name

### Helix API Checks

**Follow check** — `twitch.rs:check_follow(access_token, user_id, broadcaster_id)` -> `Result<Option<String>, String>`
- GET `{HELIX_BASE}/channels/followed?user_id={}&broadcaster_id={}`
- Headers: `Client-Id` and `Authorization: Bearer`
- Returns `Some(followed_at_iso8601)` if following, `None` if not
- Response parsed from `{ data: [{ followed_at }] }`

**Subscription check** — `twitch.rs:check_subscription(access_token, user_id, broadcaster_id)` -> `Result<(bool, Option<String>), String>`
- GET `{HELIX_BASE}/subscriptions/user?broadcaster_id={}&user_id={}`
- 404 = not subscribed (returns `(false, None)`)
- Success: returns `(true, Some(tier))` where tier is e.g. "1000", "2000", "3000"
- Response parsed from `{ data: [{ tier }] }`

### Proof Generation (Joiner-Side)

`twitch.rs:generate_proof(access_token, twitch_user_id, twitch_username, broadcaster_id)` -> `Result<TwitchProof, String>`

1. Call `check_follow()` to get `followed_at`
2. Call `check_subscription()` to get `(is_subscribed, sub_tier)`
3. Timestamp with current Unix epoch seconds
4. Return `TwitchProof` struct

### Proof Validation (Server-Side, Synchronous)

`twitch.rs:validate_proof(proof, settings)` -> `Result<(), String>`

**No network calls** — purely synchronous validation of the proof data.

Checks:
1. `twitch_user_id` must not be empty
2. **Freshness**: proof `timestamp` must be within 5 minutes into the past or 1 minute into the future (`age_secs > 300 || age_secs < -60`)
3. **Follow required**: `followed_at` must be `Some`. If `min_follow_days > 0`, the follow age must meet the threshold.
4. **Subscription required** (if `settings.require_sub`): `is_subscribed` must be true

Error messages include the channel name for user-friendly display.

### ISO 8601 Date Parsing

`twitch.rs:parse_follow_age_days(followed_at)` — calculates days since follow.

`twitch.rs:parse_iso8601_to_epoch(s)` — minimal manual parser for `"YYYY-MM-DDTHH:MM:SSZ"` format. Avoids `chrono` dependency.
- Strips trailing `Z`
- Splits on `T` for date/time
- Splits date on `-` for year/month/day
- Splits time on `:` for hour/min/sec
- Manually accumulates days from 1970 accounting for leap years via `is_leap()`
- Returns Unix epoch seconds

`twitch.rs:is_leap(year)` — standard leap year check: `(year % 4 == 0 && year % 100 != 0) || year % 400 == 0`

---

## Cross-Module Integration Map

### Message Flow: Text Message Through Relay

1. Swarm sends `WsCommand::SendToRoom` or `WsCommand::SendDirect` to `ws_client.rs`
2. `ws_client.rs:Client::enqueue()` queues it; `command_frame()` renders the binary frame (`0x03` for room, `0x04` for direct) when the pump writes it
3. Relay broadcasts/routes the frame
4. Recipient's `ws_client.rs` receives binary frame type `0x05` (room) or `0x06` (direct)
5. Emits `WsEvent::Message` or `WsEvent::DirectMessage` to swarm

### Message Flow: File/Shard Streaming

1. Sender calls `ws_stream_transfer.rs:ws_stream_send()` with source path
2. First chunk + continuations sent via `WsCommand::SendBinaryDirect` (type `0x02`)
3. Recipient's `ws_client.rs` receives binary frame type `0x02`, emits `WsEvent::BinaryDirect`
4. Swarm calls `ws_stream_transfer.rs:ws_stream_receive()` with the data
5. Returns `Some(StreamRequest)` when all chunks received

### Message Flow: Gossip Broadcast (Large Servers)

1. Originator sends file metadata via MLS (through relay) and file data to gossip neighbors via WebRTC
2. Neighbor receives both: MLS metadata registered via `gossip.rs:add_pending_relay()`, file data via WebRTC
3. When file arrives, `gossip.rs:take_pending_relay()` consumes the pending entry
4. `gossip_relay.rs:handle_webrtc_broadcast_received()` checks dedup and relays to other neighbors with `ttl - 1`
5. If file doesn't arrive within 30s, `gossip_relay.rs:handle_gossip_eviction()` falls back to direct `FileProbe` request

### Peer Discovery Flow

1. Joining a WS room returns the authoritative `Members` snapshot; live `PeerJoined`/`PeerLeft` events follow
2. The swarm's 30s re-bootstrap timer sends `WsCommand::DiscoverPeers` for the active DM room + all server rooms
3. The relay answers `discovered_peers` from its live room map; the swarm emits `PeerDiscovered` for peers not already tracked
4. All sources feed the swarm's peer tracking (`ws_room_peers`, `synced_peers`)
5. (HTTP signaling register/bootstrap RETIRED 2026-07 — see the HTTP Signaling section)

### Gossip Overlay Lifecycle

1. Server joined with >6 peers -> `GossipOverlay::new()` + `select_initial_neighbors()`
2. `GossipConnect` events trigger WebRTC data channel establishment
3. Every 5 min: `handle_gossip_rotation()` swaps neighbors based on scores
4. Every tick: `handle_gossip_eviction()` cleans dedup cache, falls back on timed-out relays
5. Periodically: `handle_gossip_exchange()` broadcasts neighbor lists for topology awareness
6. Peer goes offline: `remove_known_peer()` finds replacement neighbor

## Topic re-subscribe on reconnect (2026-07-03)

Relay channel-topic subscriptions belong to the socket, and to its session where the relay keeps one: a resume keeps them on the relay, so nothing is resubscribed. `Rooms::subscriptions` (ws_client.rs) keeps the latest `WsCommand::Subscribe` topic set per room (cleared on LeaveRoom), and every FRESH session's replay (`replay_rooms`) re-joins the rooms THEN re-sends every subscription, ahead of anything queued. Without this, a silent reconnect kept room traffic (typing/presence) flowing while topic-routed channel messages went nowhere until a channel re-open.
