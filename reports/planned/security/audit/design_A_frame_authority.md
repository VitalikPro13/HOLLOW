# Design A: every frame names its sender

Session 10 (2026-09-27, xhigh). Closes candidate class A (A2..A18; A1 was HOL-SEC-003)
with J8 and J9, plus the items handed to it by sessions 7 to 9: I4, I5, I6, A17, J5, J7,
the unsigned profile fields of N1, a signed content hash for files (the variant left by
HOL-SEC-022/023), signed epoch probes (S-20), meeting host pinning and the lobby frames
(S-26, S-29..S-32). Evidence: `design_A_inventory/` (five files, one per area, read
against this session's tree; every claim carries file:line and a quote).

## The problem in one paragraph

The relay stamps `from` on every frame it forwards, and every plaintext `HavenMessage`
handler took that stamp as the sender. Against the relay our threat model assumes
(P-01, fully malicious) every plaintext frame could be sent in anyone's name, moved to
another room or device, held back or replayed. The worst case, confirmed by reading: a
`ServerDeleteBroadcast` stamped with the owner's id made the owner's own device author a
genuine, owner-signed delete that every member then accepted, so the relay alone could
delete any server for everyone. The same stamp let the relay unfriend anyone, plant
friends through the sibling lane, mark conversations read forever, cancel or re-admit
joins, kick members, answer our data-channel offers with its own DTLS fingerprint and
listen to screen-share audio. That breaks claim C-25. Separately, much control traffic
rides in plaintext and tells the relay what claim C-24 says it never learns.

## Decisions

Before this session (Vitalik, 2026-09-26, `candidate_findings.md` decision 1): every
state-changing plaintext message is secured, as a breaking change. Where a session
exists the message moves into Olm or MLS; what must stay plaintext is device-signed.

Taken in session 10 (Vitalik, 2026-09-27), plan section 8 items 13-16: EVERYTHING in
this design lands in 0.12, done properly and with no compatibility shims; old clients
update ("cleaner is better"). A-D1 = option (a), all of C-24 including the structural
leaks; A-D2 = yes; A-D3 = pin the host; A-D4 and A-D5 are fixed too. Session 11 builds
section 5 in full, then ID-1 follows.

## Principles

1. The relay's `from` decides nothing. Every peer payload is sealed by its sending
   device; the receiver checks the seal against the key inlined in `from` before
   anything reads the frame. One check at the transport covers every message type,
   present and future.
2. A seal proves which device sent a frame, never what it may do: handlers keep judging
   authority on the now authenticated sender.
3. A frame is bound to where it was sent: its room, and either the whole room or one
   device. The relay cannot move it.
4. Replay is judged per message type, in one exhaustive list the compiler forces every
   new variant into. A live-only frame must be fresh and is taken once. A frame the
   relay legitimately delivers late carries its own replay defence, and the seal's
   timestamp gives every handler a send time the sender cannot omit.
5. What the relay may read is what claim C-24 allows (open, see the end).

## 1. Sealed frames (BUILT: `node/frame_auth.rs`)

- **Format.** `"\0HF1" | ts_ms (i64 BE) | nonce (16) | route_len (u8) | route | sig (64)
  | body`. The body is the unchanged `HavenMessage` JSON (or stream-chunk bytes). A NUL
  never starts JSON, so an unsealed frame is recognised without parsing.
- **Signature.** Ed25519 by the DEVICE key over `"hollow-frame1\0" | u32 len | room |
  u32 len | route | ts_ms | nonce | SHA-256(body)`. Route `*` = fanned out to a room or
  topic, else the target device id (or a master id for the inbox mailbox).
- **Cross-protocol.** Starts with `hollow-` like every Hollow signature; the NUL after
  the tag cannot occur in the text-formatted tags, and MLS `SignContent` starts below
  0x40 (design D).
- **Sending.** One sealing stage in front of the relay connection at the top of the
  event loop (`spawn_sealer`): 0x03, 0x07, 0x04, image directs, non-empty 0x09 and 0x02
  stream chunks. The harness's mock relay sits behind the same stage, so every harness
  test runs sealed.
- **Receiving.** Every 0x05/0x06/0x08 payload and every 0x02 chunk must open: sealed,
  `from` an Ed25519 peer id, signature valid for the room it arrived in, route `*` for a
  broadcast delivery and our device (or master) for a direct one, not stamped over 300 s
  ahead, and never stamped with our own device (the relay never hands a device its own
  frames; an echo would pass every "is this us" gate). The relay replays offline DMs and
  buffered channel frames as 0x06 and rings as 0x08, so every legitimate delivery
  matches its route.
- **Endpoints.** Main node (swarm), push fetch node (`fetch.rs`: opens, drops the legacy
  relay-JSON "direct" path that carried no seal), media forwarder
  (`forwarder/signaling.rs`: answers each client in the format it used, refuses unsealed
  frames from a client that ever sealed, so it can deploy before 0.12). The web public
  viewer must seal and open (anonlisten-sites, ships on release day).
- **Clock.** Relay auth holds every client within 60 s of the relay, so honest peers
  differ by two minutes at most; 300 s is the key-exchange window.
- **Breaking.** 0.12 refuses unsealed frames and 0.11 cannot parse sealed ones. No relay
  change is needed; the relay stores and replays payloads opaquely.

## 2. Replay classes (BUILT: `HavenMessage::live_only`, `MessageEnvelope::live_only`)

- Exhaustive matches next to the enums. **Live-only** frames older than 300 s are
  dropped, and a nonce already seen from that sender inside the window is dropped
  (`ReplayGuard`, per sender, capped, pruned on the 30 s tick). Stream chunks are
  live-only but skip the nonce guard (a fast transfer would outgrow it; a repeated chunk
  only fails the file's own integrity check).
- **Durable** (may arrive late from buffers, mailboxes, rings): Olm `Encrypted`, CRDT
  op broadcasts and sync answers, MLS messages, Welcomes, commits and catch-ups, parked
  join requests and their resolutions and rejections, kick notices, friend request,
  accept, reject, removal, destroy notices, public-channel content and share manifests.
  Each has its own defence (below and in the handlers).
- **Carried signals.** Call signals, voice and forwarder signalling, typing and sync
  requests carried inside Olm or MLS are judged by the frame's seal time: a ratchet stops
  a replay, never a relay that holds a frame back. (A held call invite used to ring a
  day late.)
- **Olm repeats.** A genuine Olm frame delivered twice used to fail its spent message key
  and tear the session down (A14). `OlmManager` remembers the digests of the last 512
  ciphertexts each session decrypted and drops a repeat before any teardown path.
- **Removed** (no sender left, or no receiver): `ServerDeleteBroadcast` (the Critical
  above; deletion is the owner-signed CRDT op), `PeerDisconnecting`, `Ack`, `FileProbe`,
  `FileProbeResponse`, `RecoveryStatus`.

## 3. Handler authority on the authenticated sender (BUILT)

| Row | Fix |
|---|---|
| FriendRemove | a removal sealed before the friendship's own stamp belongs to an earlier friendship |
| FriendAccept | on a pending request, an accept sealed before our request was made is stale, whatever it names |
| MemberKickBroadcast (+MLS twin) | a kick sealed before our current membership began (the membership record) is ignored |
| ServerJoinRequest | live copies are live-only; a copy sealed before the joiner last left never re-admits (no clock slack: a voluntary leave is the joiner's own clock) |
| ServerJoinRejected | must name the pending ask exactly (the `0` wildcard is gone) |
| ServerJoinResolved | may not name an ask after its own seal (a far-future stamp froze a joiner) |
| MlsKeyPackage | live-only (a replayed package forced leaf churn) |
| SyncRequest | the op log goes only to a member; a tombstone serves anyone only its deletion op |
| SiblingServerAnnounce | a server we hold gets only the UI refresh (a pending join let any member's snapshot replace our state); a new one is pinned to the owner the announcing device holds |
| ProfileRequest / ProfileRequestFor | a full profile only to our own devices, friends, co-members and people we asked to be friends; a relayed profile only about someone the asker shares a server with |
| Share audio (Dart) | plays only from the call's peer or a sharer we asked to watch (any open data channel could play into it) |
| Fetch node kill ack | a junk or refused order is acked by its own stamp; a bare ack (clears everything parked) only after a wipe |

## 4. Tests (each failed with its old rule put back; scripted mutation pass)

Unit: `frame_auth` (7: open for sender/room/route, forged sender, moved room/device/
delivery, every-byte tamper, unsealed/future/truncated, replay guard, every command
sealed for its delivery), `fetch::a_junk_kill_deposit_is_acked_alone`.

Harness (relay powers only, plus `inject_raw*` for frames no key could produce):
`authz_the_relay_cannot_send_a_frame_in_a_members_name`,
`authz_a_sealed_frame_cannot_be_moved_to_another_room_or_device`,
`authz_the_relay_cannot_echo_a_devices_own_frame_back_to_it`,
`authz_a_removal_older_than_the_friendship_is_ignored`,
`authz_a_live_frame_is_taken_once_and_only_while_fresh`,
`authz_a_call_invite_held_back_by_the_relay_never_rings`,
`authz_a_replayed_olm_frame_leaves_the_session_alone`,
`authz_only_a_member_is_served_the_op_log`,
`authz_a_full_profile_goes_only_to_someone_we_know`,
`authz_a_join_request_from_before_a_leave_never_readmits`,
`authz_a_kick_from_before_a_rejoin_is_ignored`.

Mutation pass: 15 rules, each put back, each test FAILED; two tests were rewritten when
the first pass showed they did not guard their rule (the echo test observed nothing;
the op-log gate has two layers, mutated together). Harness notes: the mock relay knows
every `seed_bytes` identity's key, so an injection is sealed as its claimed sender (a
hostile peer signs as itself) and existing tests keep proving their deeper gates; the
HOL-SEC-003 test re-seals its captured `KeyRequest` because the replay guard now refuses
the capture. `flush_frames` (a typing frame as an ordering barrier) replaced three fixed
sleeps.

## 5. Decided, to build in session 11

### A-D1. What the relay may read (C-24)

Today the relay reads, in plaintext: every CRDT op (server names, channel names incl.
restricted ones, roles, bans, member lists), full op logs, profiles and signed device
lists (announced to every room peer, strangers included), our friend list and DM contact
list with per-day counts (sibling sync), read positions, emote sets, the per-post
notification hint (channel, mention names, reply author; J9), channel sync watermarks
(J8), typing, voice presence and share states, join requests (device list, Twitch proof,
KeyPackage) in the `~join` ring, conference knocks, file ids and share manifests. DM room
names are a hash of the two masters, so anyone who knows both ids finds the room.

DECIDED (a): all of it in 0.12. The sibling lane moves into Olm; op broadcasts, sync
requests and answers, hints, typing and voice state into MLS with the Olm copy for
leafless devices; profiles to friends over Olm and to co-members over MLS; and the
structural ones are designed and built too: DM room names from a secret only the two
parties hold, the `~join` ring out of plaintext, file ids no longer readable by the
relay, and the presence announces of A-D5.

PARTLY BUILT (session 12, phases 1 and 2 of six): `HavenMessage::lane()` is one
exhaustive list of what may ride a plaintext frame; everything else rides
`MessageEnvelope::Carried { msg, at_ms }` inside one device's Olm session, and a
plaintext copy is dropped before any handler. `node/olm_lane.rs::carry()` sends from
anywhere; the sealing stage hands the carry to the event loop and waits for its
frames, so wire order stays program order (a plaintext frame overtaking the carried
state it depends on kept subgroups from forming). A queued carry is judged by `at_ms`,
and nothing is re-sent after it went out (a stale announce re-onboarded a left
server). Moved: the own-device lane and destroy fan-out; CRDT op twins, sync and
channel sync requests, the kick notice, typing (DM from friends only), status (friends
and co-members only), the J9 hint (MLS `ChannelHint`, the subgroup for a restricted
channel, Olm copy to leaf-less devices) and the voice twins. Five dead MLS twins
removed. Tests: the `c24_*` wiretap tests and authz tests that now send through a
node's own session (`carry_as`), since a plaintext injection of a carried type passes
vacuously. Left: C the join lane, D profiles (A28 decided: before acceptance only name
and avatar), E DM room names from the masters' DH, F file and share traffic. The claim
was reworded the same day: routing metadata is the relay's, data never is.

BUILT (session 13, phases E and F):
- E. A DM room is `hex(HMAC-SHA256(X25519(our master, their master), "hollow-dm-room1"
  | lo | hi))[..16]` (`node/dm_room.rs`), so only the two identities can name it; the
  X25519 keys are the Ed25519 master keys converted, which every device of both holds.
  A small-order key names no room. The process keeps its own master keys by id, so the
  harness's nodes share one process; they are registered before the event loop starts,
  and in the push fetch and the iOS extension. `DmSyncRequest` (watermark, gap digest)
  is carried; on presence it goes only over a session that already exists, because a
  new session asks on its own (`request_dm_resync_after_rekey`). Old rooms are simply
  abandoned (clean break).
- F. `FileRequest`, `FileUnavailable`, `PublicFileHeader` (the guest's key now rides
  Olm too), `EmoteRequest`, `EmoteAssets` and `AutoDownloadPref` are carried. Share
  control could not ride Olm: the swarm room is named by the root hash, so a relay
  joins it as an ordinary peer and would get the manifest through its own session.
  It rides `ShareSealed` instead, AES-256-GCM under a key HMAC-derived from the link
  key with the root hash as associated data (`share_handler::seal_control`), opened
  only in that share's room and only as control for that share; a new `Lane::Share`
  keeps the inner types off every other lane.
- Tests: `c24_a_dm_room_is_named_by_the_two_master_keys`,
  `c24_file_and_asset_traffic_rides_olm`, `c24_share_control_opens_only_with_the_link_key`,
  a wiretap on the guest pull test, unit tests in `dm_room` and `share_handler`; tests
  that injected these types in plaintext now send through a node's own session. Eleven
  rules were put back one at a time and each failed its test.
- Still readable, as routing: the 0x02 stream header's transfer id (the committed file
  id, which nothing else the relay reads carries), the share room's root hash and the
  data-channel SDP (`Rtc*`, `RtcShare*`).
- Found, not fixed (predates this work): when two devices key each other at the same
  moment, each rebuilds its session from the other's PreKey ("undecryptable with
  existing session"), the sessions cross, and the next ordinary Olm message fails to
  decrypt and forces a re-key. HEAD shows the same crossings; with more traffic carried,
  a message sent in that window is lost more often (harness flakes under full load:
  `destroy_friend_announce_flips_verified_and_banner` before the presence change above,
  `peer_fallback_recovers_own_sends_correct_direction` about once in nine runs, and
  possibly the two call tests session 12 noted, not checked). Glare should settle on one
  session.

### A-D2. File content commitment (H8 remainder)

No file carries a signed content hash: the message signature covers the file id only.
Any member holding a channel file's key can substitute its bytes, an asked holder can
answer with any bytes, and a guest's public-file download (key in a plaintext header)
can be substituted by the responder. Fix: the author signs size and SHA-256 of the
plaintext inside the message signature (a v4 payload, breaking), and every completion
path (stream decrypt, inline, push, guest pull, share bridge, vault relink) checks the
bytes before `mark_file_complete`; the file name and extension ride the signature too.
DECIDED: yes, in 0.12.

BUILT (session 11, HOL-SEC-060), as self-certifying file ids rather than a v4 payload:
the id is SHA-256 over author master, message id, size, plaintext SHA-256, name, ext
and a thumbnail's vault video (`node/file_commit.rs`). The existing signature binds the
id, so it covers the commitment with no new payload version; the id also names its
author, which closes the first-header race the v4 payload would have left (a member
could sign a v4 message of its own with the same id). Headers, sync and public cards
are checked against the id before a row is written, an unasked header only from the
author's devices, and every completion path hashes the bytes first (a wiring test
counts them). Pre-0.12 files keep random ids and the old gates: AR-13 (accepted).

### A-D3. Conferences (S-26, S-29..S-32)

The knock's access hash is a replayable bearer broadcast in plaintext; while a knock is
pending any bound leaf's Welcome is accepted, so an identity of the relay's own can be
the meeting's committer and SFrame source; lobby, ended, kicked and denied frames are
taken from anyone (Dart trusts a spoofable lobby host). Fix: self-certifying conference
ids (the host's master hashes into the id, as design E did for servers), Welcomes and
lobby frames only from the host the id names, and a knock proof bound to the knocker
(HMAC over its device and time under a key from the code) instead of the bearer hash.
DECIDED: pin the host.

BUILT (session 11, HOL-SEC-061): meeting id = 40 hex of SHA-256("hollow-conf1:{host
master}:{nonce}"); host frames carry {master, nonce, the host device's MLS leaf
certificate} and count only when the id hashes from them and the certificate binds the
sealing device; the Welcome carries the nonce and counts only from that master's leaf;
Dart keeps the first proven host. The knock proof is an HMAC over (meeting id, knocking
device) keyed by Argon2id(code, meeting id); no time is needed because the knock is a
live-only sealed frame. Found while testing: refusing a rogue Welcome spends the
knocker's KeyPackage, so a refused or unreadable meeting Welcome re-knocks at once.
Pre-0.12 rooms are refused (Vitalik: no migration).

### A-D4. The relay (relay-side, deploys before 0.12)

- A17: auth signs only `hollow-ws-auth:{device}:{ts}`; a captured frame replays to
  another relay, and as an unsigned `fetch:true` socket it sits invisibly beside the live
  device, takes its room slots, drains its buffer and acks away its kill orders. Fix: a
  relay challenge nonce and the relay domain in the signed string, with `fetch`, `guest`
  and the license key signed.
- I4: rooms need only a name; inbox and DM rosters are presence and friendship oracles,
  and a silent `fetch` stranger gets rosters and broadcasts. Fix: no rosters or presence
  for non-owners of an inbox, fetch sockets never listed, DM room names from a secret
  (with A-D1).
- I5/I6 + new: any room member opens, extends (retroactively, to 7 days) or clears rings
  and reads `~join`; one frame just under 1 MB flushes a ring; one socket can fill the
  65,536 ring registrations. Fix: ring control only from the owner (a signed opt-in, the
  40-hex id proves the owner), per-room and per-peer registration caps, byte-fair
  eviction.
- A18: any reply containing `license_key` stops the node and wipes the stored key. Fix:
  exact error code, never wipe the key on a relay's word, one stored key per relay.
- TURN URIs are not checked against the relay domain; J5 forwarder id and J7 nickname
  master are relay- or claimer-chosen (and the client friends the nickname's master with
  no confirmation). Fix: TURN hosts must be the relay's domain, the forwarder pinned per
  relay, nickname claims master-signed and a confirmation showing whom a request goes to.

### A-D5. Smaller items

- Recovery pool: its authority is the invite token, but the token is in the room name
  the relay sees. Fix: the room named by a hash of the token, frames carrying proof of
  it. (A membership gate was tried and reverted: the pool is for ex-members of a dead
  server, whose member list a tombstone empties.)
- Light profile announces go to every room peer, strangers included, and a friend
  request's sender gets our profile back before we accept (product decision).
- DM typing has no friend check (a stranger in a shared room can show a typing dot);
  sibling-lane stamps (read markers, emote tombstones) are unbounded (our own devices
  only now); public-channel unreaction and link-card replays (B11 variants).
- Channel-file stream completion is keyed by id only (a holder's bytes complete
  another's header); binding it to the header's sender breaks gossip delivery, so A-D2
  is the fix.

## Residuals

- A frame's seal authenticates the device; which device may do what stays the handlers'
  job, and design ID-1 decides what a stolen device can do.
- A relay may still drop, delay (inside 300 s for live frames), reorder, and fake
  presence to trigger our sends (C-25 allows it).
