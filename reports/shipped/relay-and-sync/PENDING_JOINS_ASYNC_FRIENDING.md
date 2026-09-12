# Requests that outlive both sessions: pending joins and async friending

Design notes from the 2026-08-27 and 2026-08-28 sessions. Part 2 (async friending) is BUILT and field-verified; part 1 (pending server joins) was BUILT on 2026-08-29, rung 1, see the section at the end. Read
`project_owner_offline_join_verification` in memory first for what was measured
on the 27th and what got fixed, and `project_relay_availability_cache` for the
buffer this whole design leans on.

**Decision recorded 2026-08-28 (Vitalik):** longer relay RETENTION of data the
relay already sees, in RAM, is always a yes when it buys UX. New EXPOSURE (the
relay or a third party learning something it could not learn before) is always
a no. Every retention question below is therefore settled; every exposure
question is a hard gate. See `feedback_retention_yes_exposure_no`.

**Build order: friends first, then the server tile.** The friend version has no
ring, no coordinator and no MLS, its failure mode degrades to today, and it
ships the one new relay primitive (inbox ownership proof) that the server tile
can reuse. Details in part 2.

---

## Part 1: joining a server whose members are all offline

### The problem, precisely

A join is a REQUEST THAT NEEDS AN ANSWER, and an empty room has no answerer.

Everything else about an absent membership already degrades well. The relay
buffers messages for offline peers for three days. A join served by any single
online member works, owner or not (verified in the Rust harness and in the fleet
with three real instances). But with ZERO members online, the joiner sends its
`ServerJoinRequest` into an empty room, nothing replies, and 15 seconds later
`CheckPendingJoinTimeout` fires `ServerJoinFailed` and drops it.

That behaviour is correct as far as it goes. It fails loudly, leaves no
half-built server behind, and the identical retry succeeds the moment one member
returns (`join_fails_when_every_member_is_offline_then_succeeds_on_retry`). What
is missing is not correctness, it is that the user has to keep guessing when to
retry. For a five-person server that is a real wall.

### Shape of the fix

Two halves, and the UI half is worth building on its own even if the backend
never lands, because it turns "nothing happened" into a state the user can read.

#### The UI half: a pending server tile

The joiner's server strip grows a fourth kind of entry, alongside a normal
server, a conference and a folder.

* **Rendering.** Default letter icon, greyed out, with a clock badge. Reads as
  locked, in the way a locked item in a game does.
* **Not selectable.** Clicking it does not switch servers. It shows a short
  popover: you will be added as soon as a member of this server comes online.
  No spinner, because nothing is spinning; it may be days.
* **Context menu** (`showHollowMenu` via `ContextMenuTarget`, per
  `project_issue61_context_menus`): "Discard request" as the destructive entry,
  "Copy invite link" as the useful one. Discard clears local state; nothing
  needs to reach the relay for it, since an unconsumed request expires anyway.
* **States it has to express**, all four:
  1. pending, waiting for anyone,
  2. rejected (the ban / private / cap / NSFW / Twitch answer came back),
  3. expired (nobody came back inside the retention window),
  4. admitted but not yet synced.
* **State 4 is not a transient.** A joiner admitted by the only online member,
  who then leaves before the sync finishes, holds a real server with an empty
  channel list. Today that renders as a normal, broken-looking server. It should
  carry a "not synced yet" flair until a channel list and an op log have
  actually landed. This overlaps the OPEN BUG in
  `project_relay_availability_cache` (channel files not rendering after
  catch-up), so look at the two together.
* **The tile is also what makes the return leg work** (item 5 below): a
  persisted pending join is what tells the node to rejoin the server room at
  boot, which is the only thing that triggers the relay's replay.

#### The backend half: no new relay subsystem

**Do NOT build a pending-join registry on the relay.** The mechanism already
exists. The joiner already joins the server's WS room as part of
`handle_join_server`, and the availability cache already buffers frames per room
and replays them to whoever joins next. A join request that rides a `0x07` topic
frame sits in that ring like any other buffered traffic, and the first returning
member picks it up in their normal catch-up.

That means: no new state on the relay, no new semantics, nothing new to secure,
and the retention/TTL behaviour is the one already deployed and understood. The
relay change is limited to registering a ring for a join pseudo-topic on the
server room; compare `register_relay_catchup` in `sync_handler.rs`, which does
exactly this for channels when `relay_catchup_secs > 0` (on by default, 3 days).

Client side:

* `handle_join_server` writes the request as a topic frame instead of only
  fanning it to whoever is currently in the room.
* The 15s `CheckPendingJoinTimeout` stops meaning "failed" and starts meaning
  "parked": persist the pending join, render the tile, keep the request alive.
  `ServerJoinFailed` stays for the genuinely-rejected cases.
* The returning member's catch-up feeds the buffered request into the SAME
  `ServerJoinRequest` handler that serves a live one, so there is one accept
  path and one set of gates. It is already coordinator-gated as of the 27th.

### Six things to settle BEFORE writing code

**1. The KeyPackage, which is the hard part.** MLS KeyPackages are one-shot:
reusing one breaks forward secrecy and OpenMLS rejects a duplicate. A parked
join therefore has to

* leave a KeyPackage in the buffer,
* persist the matching private half locally, bound to that pending join,
* and be consumed exactly once by the member that admits it.

If the joiner regenerates its MLS identity, or bootstraps into some other group,
or the buffer replays the request to two returning members at once, the Welcome
is undecryptable and the join fails silently. Consume-on-use semantics are the
whole ballgame here. Budget the time for this and nothing else. Note that the
relay cannot enforce it (item 6): rings replay to everyone, so "consumed" has to
be visible IN the ring.

**2. Auto-EVALUATED, never auto-approved.** A request can sit for three days, and
the ban can happen on day two. The returning member holds the current CRDT and
must apply the current rules at the moment it serves: ban list, private flag,
member cap, NSFW consent, Twitch verification, owner-verify. Never a stored
verdict from request time. The pending tile needs the rejection path wired, not
just the success path.

**3. Retention: DECIDED, yes.** The relay can already read a `ServerJoinRequest`
today; it is plaintext JSON over WS. Holding "this identity wants into this
server" for up to three days instead of milliseconds is retention of something
the relay already sees, in RAM, never on disk. Per the rule at the top, that is
a yes. What would NOT be acceptable is the relay learning membership it does not
see today (compare how channel push fans per-member precisely so it never does,
`project_channel_push_notifications`); this design does not do that.

**4. Who the ring replays to: ANSWERED.** The boundary is "in the WS room", not
"is a member". `handle_topic_catchup` (`relay-uws/src/ws_handler.cpp:930-956`)
gates on room membership and skips only the requester's own frames, so a joiner
sitting in the room can catch up the channel rings and receives ciphertext it
cannot decrypt. Content is safe; it learns message count and timing for the
retention window. Acceptable under the rule (no content, no membership), and the
joiner can leave the room once its request is deposited and rejoin only at boot
to collect the answer, which shrinks the window further.

**5. The return leg, which the first draft did not cover at all.** The plan
above handles "joiner asks, nobody is home". It has to handle the symmetric and
COMMON case just as well: "a member admits at 9am, the joiner is now asleep".
The Welcome and the CRDT snapshot have to survive the joiner being offline.

This is nearly free. `handle_binary_direct_msg`
(`relay-uws/src/ws_handler.cpp:1265-1300`) already buffers any `0x04` whose
target is not in the room, under the target's device id, and replays it when
that device joins that room. The joiner's device id is in the request envelope.
What is needed:

* the admitting member sends the Welcome + snapshot as it does today (direct to
  the joiner's device, in the server room); the relay buffers it;
* the joiner, holding a persisted pending join, REJOINS THE SERVER ROOM AT BOOT
  so the replay fires. Without the tile persisting the pending join, nothing
  ever triggers the replay: that is the whole reason the join "failed" today.
* the Welcome was cut at epoch N; by the time it is processed the group may be
  at N+k. The joiner lands at N and heals through the existing commit catch-up
  (`project_mls_epoch_catchup`), which needs someone online. Until then the tile
  shows state 4, "admitted but not yet synced". That is fine; it is honest.

Harness test to write: joiner deposits, goes offline; member returns, admits,
goes offline; joiner returns alone and holds the server. Then a second member
returns and the joiner syncs.

**6. TTL rings cannot give you "consumed exactly once", so put the resolution in
the ring.** Rings replay to EVERY member who catches up, not to the first one.
Member X returns at 9am, admits, commits, leaves. Member Y returns at 5pm,
catches up, sees the same request, is now the coordinator, and admits AGAIN
against a KeyPackage X already consumed. Y cannot know: X's membership op rode
`0x03` (`broadcast_crdt_op_to_members`), which is invisible to the rings, and
nobody is online to sync from. Item 1's "two members at once" is the rare race;
this sequential version is the normal day.

Fix: the join pseudo-topic carries the request AND its resolution. When a
member admits or rejects, it writes the outcome (joiner device, request nonce,
admitted/rejected, the membership CRDT op itself) into the same ring. A late
member replays request then answer, in order, and skips. The request needs a
nonce so the answer can bind to it. This also gives the joiner a second way to
learn a rejection while it was offline: the answer sits in the ring the joiner
reads when it rejoins.

**7. Twitch proofs never enter the ring (decided 2026-08-29).** `twitch_proof_json`
carries `twitch_user_id` and `twitch_username`. The live unicast copy is seen by
members and the relay only; a ring copy can be pulled by any socket in the room,
which is anyone holding the invite link. Peer ids in the ring are accepted
exposure; a Twitch identity tied to a peer id is not. The parked copy is
therefore deposited without the proof, and a returning member that sees a
parked request on a Twitch-gated server with no proof answers nothing: the join
stays pending until co-presence, when the live re-request carries the proof and
runs today's gate. The fix that makes Twitch-gated servers joinable with zero
overlap is the blind-credential gate planned after the artist shop
(`HOLLOW_PLAN.md`, the "Twitch identity and gate are honest-client only"
item): an unlinkable proof of follow/sub can ride the ring copy safely.

### Smaller notes

* **Batch the backlog.** Five requests parked while everyone was away means the
  first member back does five admissions and five MLS adds. Put them through one
  commit; `add_members_batch` already does this, the batch timer already
  collects KeyPackages, so it is mostly a matter of not defeating it.
* **The admitting member is also the committer.** As of the 27th the CRDT
  accept and the MLS add run off the same `elect_server_coordinator`, so they
  agree by construction. Keep it that way when the buffered path is added.
* **Expiry needs a UI state, not silence.** A tile that vanishes after three days
  reads as a bug. Offer "request again". (The friend version avoids expiry by
  re-depositing on every connect, part 2; the same trick works here as long as
  the joiner's KeyPackage stays the same one, which item 1 requires anyway.)
* **A no-ring fallback exists once part 2 ships.** The invite link can carry the
  inviter's master id, and the joiner can drop its request into the INVITER's
  inbox mailbox (part 2's primitive). Worse availability (one member instead of
  any), zero ring semantics. Worth having as the path for servers whose owner
  turned `relay_catchup_secs` off.

### What this does NOT do

It does not make a fully-offline server joinable *instantly*. Nothing does,
short of MLS external commits with a relay-cached `GroupInfo`, which is a much
larger epic: external commits are self-serve, so every admission gate loses its
enforcement point and would need a cryptographic invite token, and the relay
would learn per-server membership and epoch. That trade was looked at on the
27th and parked; it fails the exposure rule anyway. This design is the cheap
90%: the join completes on its own, without the user having to guess when to
retry, and nobody has to trust the relay with anything it is not already
trusted with.

---

## Part 2: adding a friend who is offline, and staying offline yourself

### What already exists (more than it looks)

Read `node/social.rs:60-150` and `swarm.rs:1008-1040` before assuming anything
is missing. Today:

* the outgoing request persists as a `pending/outgoing` row in the friends
  table and is re-queued into `pending_friend_requests` at every boot;
* it drains the instant the target's DEVICE shows up in any shared room
  (PeerJoined, RoomMembers, or a ProfileUpdate that teaches us their device);
* the accept is queued in `pending_friend_accepts`, persisted, restored at boot
  (`swarm.rs:1064-1069`), and drains the same way;
* boot joins the DM room for EVERY friends row, pending included
  (`swarm.rs:2921-2965`, `load_friends(None)`), so the deterministic DM room
  exists on both sides from the moment either side has a row;
* the relay `0x04` path buffers for any target not in the room and replays on
  that device's next join of that room, three days by default.

So nothing is lost today. What is required is OVERLAP: both people online at
the same moment. And not once. Three times:

1. **Request delivery.** `FriendRequest` is a plaintext `SendDirect`, and
   `send_message_to_peer` (`crypto_handler.rs:2622`) refuses to send unless the
   peer is in a room right now. It refuses for a reason: a request to a
   stranger is addressed to a MASTER id, and no socket ever authenticates as a
   master, so the relay would buffer it under a key nobody replays.
2. **Accept delivery.** Same rule, same function.
3. **The Olm handshake.** KeyRequest/KeyBundle only runs on DM-room co-presence
   (`feedback_friend_handshake_olm_inbox_leave_race`), and
   `KEY_EXCHANGE_SKEW_SECS = 300` (`crypto_handler.rs:400`) refuses any bundle
   older than five minutes as a replay. A bundle cannot sit in a three-day
   buffer under the live rule.

**Fixing only leg 1 is worse than today.** The request appears while they are
away, they accept, and then "they never show up as a friend" for another day
while leg 2 waits for overlap, and the first DM waits on leg 3 after that. All
three legs ship together or none do.

### The fix: two changes, both small

#### Change 1: a master-keyed inbox mailbox with an ownership proof (relay)

A request to a stranger is the one message in Hollow where the sender holds no
device ids, only the master. The relay already buffers a `0x04` under ANY
target string (it never validates the target,
`relay-uws/src/ws_handler.cpp:1265`, the comment there calls it "the widest
deposit primitive on the relay"). So a frame addressed to master `M`, sent into
`inbox:{M}`, would sit in `offline_buffer[M]` today. It just never replays,
because `handle_join` replays `offline_buffer[socket's device id]`
(`ws_handler.cpp:366`), and `M` is nobody's device id.

The change: a `join` of `inbox:{M}` may carry an ownership proof, the
master-signed device-list entry that peers already verify (the same signature
from `project_signed_key_exchange_root_of_trust`, KATs on both sides). The relay
verifies it with the Ed25519 code it already uses for auth. A socket that
proves it is one of `M`'s devices gets `offline_buffer[M]` replayed on top of
its own. Without the proof this is UNSAFE: senders join `inbox:{M}` too (that is
how they deliver), and delete-on-replay would let anyone drain your requests. A
static signature is fine here because replaying it proves only what is already
true (this device belongs to `M`), and the replayer still cannot authenticate
as that device.

Two semantics decisions inside the change:

* **Inbox-owner replays are TTL-only, not delete-on-replay.** Then every
  sibling device of `M` receives the request on its own next boot, and the
  friends row is the dedup (a request already pending/accepted/declined is a
  no-op at ingest). This sidesteps needing the sibling friend-list share to
  carry "pending incoming", though that share exists and would also work.
* **Live sends stay device-targeted.** Nothing about the online path changes.
  The mailbox is only for the "no device known" case.

Exposure check: the relay learns nothing new. `inbox:{M}` is already named by
the master, `M`'s devices already join it at every boot, and the request is
already plaintext on the wire. Retention goes from milliseconds to the buffer
TTL: yes, per the rule. Third parties learn nothing: only a proven owner can
read the mailbox.

#### Change 2: ONE carried bundle rides inside the request (client)

**Refined 2026-08-28 in the build contract** (`scratchpad/async_friend_contract.md`),
which supersedes the earlier "each side carries a bundle" sketch: the handshake
needs only a SINGLE carried bundle, and `FriendAccept` stays byte-identical to
today. Why the change: `FriendAccept` is an externally-tagged UNIT variant
(serializes to the bare string `"FriendAccept"`); turning it into a struct
variant to carry a bundle would break the wire for every existing client.
`FriendRequest` is already a struct variant, so adding optional fields there IS
compatible. And Olm sessions are bidirectional once established, so one bundle
plus one pre-key message is the whole handshake.

`FriendRequest` gains two `#[serde(default)]` fields: a device-signed
`CarriedBundle` (a fresh one-time key + identity key, `to_master`, `ts`,
`sig_b64`, `device_pk_b64`) addressed to the recipient MASTER, and the sender's
`SignedDeviceList`. Both are things the live path already produces
(`generate_one_time_key`, `send_own_profile_to_peer`'s device list); this moves
them INTO the request so nothing has to be live.

The accepter, at accept time (live OR replayed from the mailbox), verifies the
bundle, then `create_outbound_session` to the requester's DEVICE (derived from
`device_pk_b64`, cross-checked against the carried device list). It sends the
UNCHANGED `FriendAccept` plus ONE pre-key establisher: an `Encrypted` message on
the new session whose plaintext is a handshake sentinel that inserts no visible
DM row. Both go into the deterministic DM room, targeted at the requester's
device, buffered by the existing device-keyed `0x04` path if the requester is
offline. The requester's node joins that DM room at boot because the pending row
exists, so the buffered `FriendAccept` + establisher replay; the establisher's
pre-key message runs the requester's `create_inbound_session` through the
existing decrypt path, giving it a bidirectional session. No second bundle, no
`FriendAccept` field change. From there DMs ride the existing three-day buffer.

**Freshness for a CARRIED bundle is a separate verification path.** The live
300s rule stays untouched (`feedback_signature_enforcement_not_logging`: the
live path enforces, never loosens). A bundle that arrived inside a friend
request is checked as: signature valid, `to_master` is our master, sender device is
in the carried master-signed list, `ts` not in the future beyond the skew, `ts`
not older than the maximum buffer retention (7d). Replay protection comes from
one-time-key single use, not from the clock. The same gates in the same order
as the live path, with one bound swapped, and it MUST be its own function so a
grep for `KEY_EXCHANGE_SKEW_SECS` still finds exactly one live rule.

**This is the same consume-once problem as the KeyPackage in part 1, and
strictly cheaper.** An Olm one-time key is cheap, vodozemac holds dozens, the
private half stays in the account until used (persist the account after
minting, as `persist_crypto_state` already does), and if a key is ever burned
(two accepts race, the account is restored from an older pickle) the failure
mode is TODAY's behaviour: the DM-room co-presence re-key heals it live. No
silent dead state, which is exactly what makes this the right thing to build
first.

One-time-key budget: one outstanding key per pending outgoing request. A user
with 50 pending requests to strangers is a spam pattern, not a user; cap
outstanding pending requests well below the account's key limit and surface it.

### Multi-device

* Whichever device of `M` reads the mailbox first shows the request; TTL-only
  replay means the others show it too on their own boot; the existing sibling
  friend-list share converges the accepted/declined state after that.
* v1 establishes the session with the ONE requesting device (the device whose
  one-time key the request carried; only it can decrypt the establisher). The
  requester's other devices converge friend state via the existing sibling
  friend-list backfill, and key with the accepter lazily on later co-presence.
  Fanning the establisher to every carried device is a later refinement, not v1
  (each other device would need its own carried bundle, which the request does
  not carry).
* Blocking already runs at ingest (`blocklist::is_blocked`, the receive handler
  is the same one), so a blocked sender's buffered request is dropped before
  any row or event. Auto-EVALUATED, never auto-approved, same as part 1 item 2.

### Re-deposit on connect, which removes the expiry state

Because the pending row persists, the sender can re-deposit the request into
the mailbox on EVERY connect, not only the first time. The relay's per-sender
fair share bounds the duplicates (a flooder evicts only itself,
`buffer_offline_msg`), and the receiver dedups on the friends row. Result: as
long as the sender comes online once inside the retention window, the request
never expires, and the outgoing-request UI needs no "expired" state at all.
Just "pending" until answered or withdrawn. Withdraw = delete the row; the
mailbox copy expires on its own and the receiver's ingest finds no live
request to attach to (carry `requested_at` so a stale copy after a withdraw is
recognisable).

### UI states

Desktop and mobile both, same release (`feedback_mobile_parity_always`).

* **Outgoing, pending:** the row already exists in the Outgoing tab. Add the
  one line that changes the user's mental model: "They'll get this the next
  time they're online, even if you're not." No spinner.
* **Incoming from the mailbox:** identical to a live request. The user should
  not be able to tell how it arrived.
* **Accepted while I was away:** the friend simply appears on the next boot,
  with the normal "X accepted your request" surface if one exists.
* **Withdraw** stays where it is.

### Harness tests to write (before any relay deploy)

MockRelay needs the mailbox: `offline_buffer` keyed by an arbitrary target, an
ownership-proof field on `join`, TTL-only replay for proven owners.

1. `friend_request_delivered_with_no_overlap`: A requests B while B is offline,
   A goes offline, B boots alone and sees the request.
2. `friend_accept_delivered_with_no_overlap`: continues 1; B accepts alone, B
   goes offline, A boots alone and holds an accepted friend AND a confirmed
   Olm session; A sends a DM offline-buffered; B boots and reads it. Zero
   moments of overlap across the whole test.
3. `mailbox_requires_ownership_proof`: a stranger joining `inbox:{B}` without
   the proof gets nothing replayed; with a forged proof gets nothing; B's own
   second device with a valid proof gets the request too.
4. `carried_bundle_freshness_is_its_own_rule`: a 3-day-old carried bundle is
   accepted; a live KeyBundle 6 minutes old is still rejected.
5. Re-deposit dedup: A reconnects five times; B sees one request.

### What this does NOT do

It does not let two people who never overlap exchange FILES; bytes never ride
the buffer (`project_relay_availability_cache`, never file bytes). It does not
change anything for people who already have a session. And it does not make
the relay an authority on who is friends with whom: the friends table on each
device is the truth, the mailbox is a helper that can be empty.

---

## Part 3: why this is the right trade, in one paragraph, for the whitepaper

A central server contributes exactly two things to friending: a mailbox that
outlives both sessions, and a prekey store. Signal runs a server for those two
things and the rest is the same cryptography Hollow already runs on the client.
Hollow's relay is already the mailbox (RAM, three days, ciphertext, replay on
join). Carrying the prekey INSIDE the request gives it the second thing without
the relay ever becoming an authority: it holds a public key it cannot use,
signed by a device it cannot impersonate, bound to a recipient it cannot
substitute. Nothing new to trust, nothing on disk, and the user's device
remains the only place the friendship actually exists. The centralized model
makes this decision silently and keeps the data forever; here it is made out
loud, with a TTL.

---

## Shipped 2026-08-28 (part 2 built), decline-sticky FIXED the same evening

The async-friend half was BUILT and committed: inbox mailbox + ownership proof
(relay, DEPLOYED to the VPS), carried Olm bundle in `FriendRequest`, accept-time
session + handshake establisher, the anti-downgrade guard (the reported "friend
flips to Incoming, DM leaves Recent Conversations" bug, FIXED, fleet-verified),
carried sender profile (name/avatar on the incoming card), the cosmetic outgoing
line. Fleet scripts added (`fleet_friend_offline.ps1`, `fleet_friend_decline.ps1`).
Design/logic memory: `project_pending_joins_async_friending`.

### The decline bugs Vitalik found on real devices, and what fixed them

Root: `FriendReject` was a unit variant sent best-effort to ONLINE devices, so
an offline requester never learned, kept its outgoing row, and re-deposited the
request on every reconnect (that is why B saw it again after every restart). The
harness had passed because it modelled one deposit and never brought A back.

What shipped (all harness-verified, 670/670; the wire is backward compatible in
both directions because `HavenMessage` is INTERNALLY tagged):

1. `FriendReject { requested_at, device_list }`, both `#[serde(default)]`. The
   reject names the request it answers and carries the decliner's master-signed
   device list.
2. Delivery rides the requester's own inbox mailbox (`send_friend_reject`: live
   fan AND join, send, leave `inbox:{requester_master}`), so every device of the
   requester learns on its own next boot. Retention only.
3. Attribution is cryptographic: verify the carried list, require the sender
   device listed and un-revoked, ingest via the same path as the request, take
   the master from the list. Present-but-bad = drop. No list = legacy resolver.
   The FLEET found this one (two fresh installs that never co-presented): the
   harness resolver is process-global, so it cannot see attribution bugs; the
   two decline tests now `resolver::forget` the decliner's device first.
4. Requester gate is monotonic (`pending/outgoing` with `requested_at == 0 ||
   >= stored`; `accepted` with `!= 0 && >= stored` for the mutual cross);
   `save_friend` advances `requested_at` by MAX for pending rows only; the
   mutual auto-accept stamps MAX(ours, theirs) before freezing. `FriendAccept`
   on a `declined` row is ignored.
5. The decliner re-sends the reject when it swallows a stale re-delivery, once
   per requester per connection, so an expired reject copy still converges.

Fleet: friend journeys mint fresh identities per run (`-Onboard -Fresh`,
`-KeepIdentities` to opt out), which also removed the fixture pollution (the
fixtures had been left identity-less). Decline journey: GREEN on the fixed build, a/b and a/c, all six gates
(requester row gone, decliner holds one declined row keyed by master).

Residual, accepted: a mutual cross where one side's accept overtakes its request
leaves that side with its own stamp; a later reject from it may be refused by
the other side. Bounded and rarer than the race itself.

## Shipped 2026-08-29: part 1, rung 1 (pending server joins)

Built under the Fable-orchestrates / Opus-codes workflow: one Rust unit, one
Dart unit, one fleet unit, each against a contract written from the code, then
verified by reading the security-bearing diff and running the suites.

### What the code facts changed about the design above

**The join is CRDT-first.** `ServerJoinRequest` never carried a KeyPackage.
The coordinator admits into the CRDT and sends the snapshot + op log; the MLS
add is a SEPARATE leg the coordinator starts on co-presence
(`MlsKeyPackageRequest` -> fresh KP -> batch -> Welcome). So item 1 above (the
"hard part") is not in this rung at all: rung 1 parks the CRDT admission and
leaves the MLS leaf to the existing co-presence heal, with a "waiting for a
member to finish setup" badge in between. A carried-KP rung 2 has a real
prerequisite first: the KP private half lives only in OpenMLS's in-RAM
`MemoryStorage` and `persist_mls_state` is not called after minting, so a
restart before any incidental persist loses it (`NoMatchingKeyPackage`).

**Zero relay changes.** Topic names are free-form, `set_topic_buffer`
registers any (room, topic), a 0x07 publish tees only into a registered ring,
`topic_catchup` skips the requester's own frames and deletes nothing.

**The "expired" tile state collapsed into re-deposit** (every 12 hours while
the app is online), the same trick part 2 uses. Three states remain: pending,
rejected (with "Request again"), and admitted-but-not-ready.

### The mechanism, in one paragraph each

Joiner: `handle_join_server` stamps a millisecond nonce (`requested_at`),
attaches its master-signed device list, persists the row FIRST, fans the live
request as before. The 15 s timeout PARKS instead of failing: the copy goes
into the server room's `~join` topic ring (`parked: true`, Twitch proof
stripped), `ServerJoinParked` reaches the UI, the node stays in the room. Boot
restores pending rows and rejoins their rooms, which is what makes the relay
replay the buffered answer. A rejected row is a tile with "Request again".

Member: attribution first, from the carried list (verify, sender device listed
and un-revoked, ingest, master FROM the list; present-but-bad is a drop). A
parked copy can never be a repeat ask, is skipped when the joiner is already a
member or when the ring already holds a resolution for that nonce, and waits
silently on a Twitch-gated server. Ban, private and cap gates now key on the
master (the old device-keyed ban check would have let a never-met banned
stranger through on the parked path). Snapshot, op log and every reject go to
the deterministic server room targeted at the joiner's device, so the relay
buffers them for an absent joiner. Every final verdict is published back into
the ring as `ServerJoinResolved` (admissions carry the `MemberAdded` op), so a
late member converges membership and never re-serves.

Refusals: `nsfw_confirm:` / `twitch_required:` are questions, never
resolutions; on the joiner they delete the row and show the existing dialog,
and `ServerJoinRejected` now carries the nonce so a stale buffered question
cannot kill the consented re-request.

### Verified

Harness (`node/test_harness.rs`): eight new scenarios plus a wire pin, the
first honesty-proved (deposit stubbed out, "A must admit B from the ring"
fails). The old `join_fails_when_every_member_is_offline_then_succeeds_on_retry`
was deleted; it asserted the behaviour this replaces. Two load-only races cost
a round each, both "queued is not landed": a node emits its event the instant
a frame is queued on the WS command channel, the mock relay lands it on its
own task, and a test that disconnects or reads the ring right after the event
loses the race under the 16-way run. Rule now in the harness: after a
node-state wait, an assertion on relay state is itself a `wait_until`.

Fleet (`scripts/fleet_pending_join.ps1`, fresh identities, eight gates): see
memory `project_pending_server_joins` for the run record.

### What the fleet found that the harness could not

Run 1 deleted the server while the parked joiner had been admitted but held no
MLS leaf yet. The joiner kept a ghost server: the tombstone rode an MLS frame
it could not read, and the plaintext twin never came. Two stacked defects in
`handle_delete_server`: the twin was sent only when the OWNER's MLS send
failed, and it computed its targets from `state.members` AFTER
`apply_op(ServerDeleted)` had cleared them, so it had been dead code on every
path since it was written. Fixed: membership captured before the apply, twin
sent unconditionally, guarded by
`server_deleted_reaches_a_parked_member_with_no_mls_leaf` (the receiver is
made deaf to room broadcasts so the test can only pass through the twin).
Eight sibling sites with the same shape are listed in `HOLLOW_PLAN.md` for a
sweep; memory `feedback_mls_first_fallback_dead_targets`.

### Exposure, settled with Vitalik

The ring is readable by any socket in the server room (anyone holding the
invite): it shows who asked to join and the outcome, as peer ids, for the TTL.
The member list never enters it. Vitalik: "if it's just peer IDs, then who
cares". The one identity link, the Twitch proof, is stripped (item 7 above).

