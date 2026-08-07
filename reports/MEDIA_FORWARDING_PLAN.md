# Media Forwarding Plan — Resolution Capping, Originator Attribution, SFrame Packet Forwarders

**STATUS 2026-08-07: STEP 3 PHASE 2 FIELD-VERIFIED COMPLETE — ALL FOUR RUNS PASSED** (peer
rung + kill ladder, VPS rung, demotion, k=2 measurement + relay_private privacy gate + TURN
baseline; §7 top entry has each run's evidence). The vanished-frame defect is FIXED and
root-cause-confirmed (the removed fwd control-plane token bucket ate the last-in-burst large
frame after the client's fwd-room join chatter); every hop of the fwd control plane is now
instrumented (client send sizes / relay delivery + send-status counters in `/server-stats` /
forwarder per-frame outcome log), a 30 s idempotent fwd-room re-join belt self-heals relay
membership loss, and presence-flap tolerance is on BOTH the clients and the forwarder engine
(media legs are the only truth). Relay + forwarder deployed live. Headline number:
**egress = k×ingest on the forwarder (238/119 kbps at k=2) vs TURN's 2·B·k — and relay media
= ZERO when a peer forwarder serves.** Remaining before phase 3: commit the working tree;
follow-ups queued in §7 (SFrame join-order epoch race = own fix session; opportunistic
rebalancer; fwd-room chatter suppression; relay ghost-eviction PeerLeft suppression).** Step 1 (resolution capping) shipped; step 2 (originator attribution)
shipped; step 3 phase 1 (the VPS infra forwarder) COMPLETE + FIELD-VERIFIED — see §6 for the
deliverable table and §7 for the D6 evidence and the five bugs the field found. Phase 2 embeds the
SAME forwarder engine in desktop app builds: fwd-capable watchers on a direct route serve the
TURN-only viewers (2–3 downstream legs each), the sharer's ladder becomes peer forwarder → VPS
forwarder → direct+TURN, and the relay carries ZERO media in the common case. Policy as decided:
ON by default + Settings toggle ("Peer media forwarding", Call Privacy section), desktop only,
never mobile. §7's phase-2 entry has the implementation map + the field-verification procedure.
Both D6 follow-ups are closed (forwarder-aware ICE route label; ingest+egress kbps in the
aggregate counter line so the `B + B·k` saving is quotable from the journal at k>1).
Then phase 3 = simulcast (prerequisite: root-cause the Windows live `setParameters` rejection),
then the 15-viewer cap goes dynamic.
Design refs: `~/.claude/plans/pure-doodling-cupcake.md` (D1–D6) and
`~/.claude/plans/hey-please-read-the-sequential-penguin.md` (the D3–D6 implementation plan).
Supersedes the old HOLLOW_PLAN.md line-2080 framing ("extend the voice gossip tree to CAMERAS and SCREEN SHARE").

---

## 1. The problem this solves

The nightmare scenario: one participant screen-shares in 4K, a large voice channel watches, and either
(a) the sharer's upload melts, (b) everyone's CPU melts, or (c) the relay's 1 Gbps port melts. These are
**three separate bottlenecks** that get conflated into "P2P can't do this":

1. **Sender upload.** 1080p30 screen content with our ScreenContentProfile libwebrtc build runs ~2.5–4 Mbps
   (far less when mostly static; 4K ≈ 4× that). Today the sharer opens one PC **per viewer** — hard cap
   **15 outgoing / 10 incoming** (`maxScreenShareOutgoing/Incoming`, raised from 5/3 in Phase 6.75;
   older docs saying "5" are stale) — so N viewers = N full copies = N separate encoders. A 20 Mbps home
   upload direct-serves only ~5 viewers at 1080p, i.e. the cap already EXCEEDS what a typical home link
   can carry — beyond that the bandwidth estimator degrades every stream. Step 1 stretches this
   (smaller per-viewer streams); step 3 is what actually breaks the ceiling.
2. **Viewer download.** One stream per viewer; never the bottleneck.
3. **Relay/VPS bandwidth.** Screen share rides the **call ICE config, which includes TURN** — so every
   restricted-NAT viewer costs the relay `stream_in + stream_out` **today**. (Not to be confused with
   Hollow Share, the file-transfer lane, which is STUN-only by design and never touches TURN — see
   memory `feedback_share_vs_screen_share_lanes`.)

Baseline verified 2026-07-13: only AUDIO gossip-forwards today (VC mesh→gossip at 6+ participants,
`voice_handler.rs` thresholds 6 up / 4 down, ≤12 neighbors); `voice_channel_service.dart` onTrack skips
video; screen share is a separate per-viewer PC service, capped at 15 outgoing / 10 incoming viewers,
no forwarding; track dedup keys on the immediate sender.

## 2. The core design insights

### 2a. Don't extend the audio gossip tree to video — it forwards TRACKS

The voice tree re-attaches a received remote track to the next PC, which means **decode → re-encode at
every hop**. For 32 kbps Opus that's nearly free. For video it's CPU death plus generational quality loss
per hop — it would produce exactly the "bad quality, high CPU" outcome we're trying to avoid. Video
forwarding must be **packet-level**: forward the RTP packets untouched.

### 2b. SFrame is what makes packet-level forwarding possible (and safe)

The outer WebRTC encryption (DTLS-SRTP) is hop-by-hop and terminates at each connection. The inner SFrame
layer (AES-128-GCM, already shipped for all voice/video/share media) is bound to the **originator**: frames
are encrypted once by the sharer under the sharer's sender key, and only holders of the group's keys can
decrypt — no matter how many hops a packet takes. A forwarder reads only RTP headers (stream id, sequence)
to route; it can never read payloads and can't tamper (auth tag breaks). This is the relay philosophy
applied to live media: **availability helper, never authority.**

### 2c. A forwarding peer and an "SFU" are the same component

Do not design "gossip tree" and "SFU" as two systems to balance. Design ONE **forwarder role** — a node
that receives SFrame-encrypted RTP for a stream and fans packets to downstream viewers — and let anything
play it:

- a **viewer-peer** with spare upload (collective hosting applied to live media),
- a **volunteer's always-on box** (same philosophy as the line-2092 storage pool),
- an **infra peer on the VPS** (what people would call an SFU — but it's just a well-connected member of
  the forwarding mesh we happen to operate: no new server authority, blind to content, and if it dies the
  tree rebalances to direct paths).

One codebase, one signaling contract, one healing mechanism.

### 2d. Why the forwarder beats TURN

TURN is a **blind per-connection pipe**: it has no concept of "stream", so it cannot share bytes between
two viewers of the same share. A forwarder understands "these packets are stream X" and fans one ingest to
many egresses.

For a stream of bitrate B and k relay-dependent viewers:

| | Relay bandwidth | Sharer upload for those viewers |
|---|---|---|
| TURN (today) | `2·B·k` (in+out per viewer) | `B·k` (one copy each) |
| Forwarder | `B + B·k` (ONE ingest, k egresses) | `B` (one copy total) — or **0**, see below |

At B = 10 Mbps (4K): 2 TURN'd viewers cost 40 Mbps today vs 30 with the forwarder; 10 viewers cost
200 vs 110. And the **ingest doesn't have to come from the sharer** — any peer already receiving the
stream can feed the forwarder, so a viewer with fiber can carry the relay ingest while a weak-upload
sharer spends nothing on the restricted-NAT audience.

When everyone in the room can STUN, the relay carries **zero media bytes** — the forwarder role simply
never wakes up. It is a fallback assist, never the default path; the 1 Gbps port (~250 concurrent 4 Mbps
egresses, theoretical) is a ceiling we approach only in pathological all-symmetric-NAT rooms, and by then
T4 relay sharding is the answer anyway.

### 2e. Worked example (the scenario from the session)

Sharer S streams 4K ≈ 10 Mbps to viewers A, B, C (STUN-reachable) and D, E (restricted NAT).

| | S upload | Relay bandwidth |
|---|---|---|
| Today (5 per-viewer PCs, D/E via TURN) | 50 Mbps (5 copies, 5 encoders) | 40 Mbps (2 TURN pipes) |
| Tree + forwarder | ~20 Mbps (1 copy → A, 1 → forwarder) | 30 Mbps (1 in, 2 out) |
| Tree + forwarder, A feeds the relay | **10 Mbps** (1 copy → A; A→B,C + A→forwarder) | 30 Mbps |

Peer hops are packet copies (no decode/re-encode): ~20–50 ms each, imperceptible for a screen share.
Stack step 1's resolution capping on top and the common all-1080p room turns that 10 Mbps into ~3–4.

## 3. The three steps

### Step 1 — Receiver-driven resolution capping (COMPLETE — shipped + field-verified 2026-08-05)

The dream-idea: nobody should receive 4K they can't display.

- The viewer's existing opt-in watch signal (`vc_screen_watch` / `call_screen_watch`, issue #38) gains the
  viewer's **display resolution** (physical pixels, largest connected display, orientation-normalized).
- The sharer applies a per-viewer `scaleResolutionDownBy` on **that viewer's own encoder**. Per-viewer PCs
  mean per-viewer encoders, so there is no shared cap to renegotiate when a 4K viewer joins — their new PC
  simply gets its own encoding params (`addTransceiver` init `sendEncodings`; post-connection changes via
  `setParameters`, both proven by the 2026-07-20 360p-cap fix).
- **"Source quality"** = an explicit per-viewer request, **OFF by default**, that lifts the cap for that
  one connection only — one pixel-peeper (zooming to read small text) doesn't drag the room to 4K.
- Backward compat: absent resolution field (old client) = no downscale, today's behavior preserved.
- Wins in the common case (4K sharer, 1080p room): ~4× less bandwidth AND ~4× less encode CPU per viewer
  (today 5 watchers = 5 separate 4K encodes; capping makes them 1080p encodes).
- Later refinement (not v1): report actual rendered tile size instead of monitor size.
- DONE (same day): the viewer's quality chip now shows the RECEIVED resolution live (`ShareQualityChip`
  listens to the incoming renderer: "824p60" clamped → flips to "1080p60" when Source is toggled; falls
  back to the sharer's source label before frames arrive; our own outgoing share keeps its source label).
  Desktop only — mobile never displayed share labels.

### Step 2 — Multi-hop originator attribution (prerequisite for any tree; buildable/testable before forwarding exists)

Today everything about an incoming track is keyed on the peer whose PC delivered it. The moment A forwards
S's share, three things break without attribution: the UI shows "A is sharing"; dedup treats two delivery
paths of S's stream as two streams; and — the SFrame part — the receiving cryptor gets registered under A,
whose key did NOT encrypt the frames, so decryption fails.

The fix is a small signaling contract: a forwarded stream carries `(originator, source kind, stream id)`;
receivers key **attribution, dedup, watch-gate consent, and SFrame cryptor registration on the
ORIGINATOR**, while transport (which PC, which packets, glare, conn_id) stays keyed on the immediate
neighbor. This is the master-vs-device split Hollow already lives by, applied to media: *who it's from*
vs. *who delivered it*.

### Step 3 — The forwarder role (PHASE 1 COMPLETE + FIELD-VERIFIED 2026-08-06; phase 2 next)

Built on **str0m in RTP mode, NO libwebrtc fork patch** (the original "needs RTP-layer access in our
fork" framing was superseded by the D2 spike — see §5.2).

- Packet-level relay of SFrame ciphertext RTP; forwarders never decrypt, never re-encode. ✅ SHIPPED
- **Infra peer on the VPS FIRST** (phase 1, done): the reliability floor and the restricted-NAT
  answer, replacing TURN for shares at `B + B·k` instead of `2·B·k`, and later the backbone of
  conference **broadcast mode**. Note this inverted the original ordering below — the infra peer
  landed before viewer-peer forwarders because it needs no client-side upload policy, no tree
  scoring, and can be restarted/instrumented freely during bring-up.
- Viewer-peer forwarders = **PHASE 2 — IMPLEMENTED 2026-08-06, field verification pending** (see
  §7): same engine embedded in desktop app builds (their own display = downstream viewer #0 over a
  local leg); fanout of 3 remote legs per forwarder; ON by default + Settings toggle, desktop
  only, never mobile. This is the step that takes the relay's media cost to ZERO in the common
  case.
- **Simulcast** (two-three `sendEncodings` layers, e.g. 1080p + 360p): forwarders adapt per-viewer quality
  by **packet selection** — a weak viewer gets the small layer, no re-encode anywhere.
- Tree building: automatable scoring by upload headroom / route class (PeerScore.is_direct already exists
  from T3), NAT reachability, and stability; rebalance on churn.
- Healing: the share lane's existing **receiver-initiates, sender-catches** reconnection pattern is the
  heal mechanism — a viewer who loses its feed re-requests, the tree reassigns.
- Raise/remove the 15-viewer outgoing cap once forwarding shares the load.

## 4. Constraints to honor (from existing iron rules)

- Encoding caps ride `addTransceiver` init `sendEncodings`; pre-negotiation `setParameters` is DROPPED at
  O/A (`project_webrtc_engine_screenshare_research`). **Post-connection `setParameters` on the Windows
  share sender is ALSO rejected** (field-verified 2026-08-05 in the VM test: every call logs
  `REJECTED by libwebrtc` and the readback scale never changes — the cap has only ever applied via init
  encodings; the historic "second layer" re-apply was cosmetic). Any dynamic cap change must therefore be
  prepared to renegotiate: `updateResolutionCap` returns bool, callers fall back to a fresh offer with the
  new cap in init `sendEncodings` (~1-2s stream restart). A real fix means digging into
  `RtpSenderSetParameters` in the fork / the libwebrtc wrapper's `set_parameters` (candidate causes: the
  Dart→native round-trip writing back read-only fields like ssrc/rid → INVALID_MODIFICATION; the wrapper
  swallowing the RTCError string). Worth fixing before step 3 — simulcast layer switching wants live
  setParameters too.
- Screen shares are OPT-IN (#38): nothing streams without `screen_watch{want:true}`; receivers drop
  unsolicited offers. Step 1 extends this signal; step 3 must preserve the consent semantics through
  forwarders (consent refers to the ORIGINATOR's share).
- SFrame cryptors are idempotent per (peer, kind); `setKeyIndexForPeer` after every enable
  (`project_sframe_heal_ladder`). Step 2 re-keys registration on the originator.
- New/changed signal fields: `#[serde(default)]`, old clients must keep working (absent = old behavior).
- VC participants key on the ROUTABLE WS sender, never the MLS leaf; per-person UI collapses
  device→master. Attribution metadata must respect both rules.
- Lane split: Hollow Share (files) = STUN-only `_Lane.share`; screen/camera/voice media = call config
  WITH TURN. Never add TURN to `shareIceConfigProvider`.
- Relay: never lower `maxPayloadLength`; per-IP accounting via `ip_limit_key()`; media forwarding through
  an infra peer needs its own bandwidth-accounting decision (the 10 GB/day per-IP cap would be consumed
  by media — policy TBD in the step-3 plan session).

## 5. Open questions — ALL RESOLVED (2026-08-05/06 plan session; details in the approved plan)

1. **VPS forwarder = separate headless Rust process** (own systemd unit next to relay-uws), never
   inside the C++ relay. It is NOT a full node: a minimal WS-auth + Olm signaling loop + the
   forwarder engine (spawn_node drags CRDT/MLS/storage it must never hold).
2. **NO libwebrtc fork patch at all.** The forwarder is a transport-only Rust module built on
   **str0m** (RTP mode) inside hollow_core behind a `forwarder` cargo feature — the same crate
   later embeds in the app for phase-2 peer forwarders (their own display = downstream viewer #0
   over a localhost leg). The 2026-07-19 "engine swap = NO" verdict doesn't apply: that was about
   the client media engine; a blind forwarder needs exactly and only what str0m provides.
   **Spike-proven — see §7.**
3. **Tree v1 = static policy, no optimizer**: restricted-NAT viewers → forwarder, STUN viewers →
   direct; sharer = tree root/coordinator; ingest always from the sharer in phase 1 (feeder
   election = phase 2, since re-emitting IS the forwarder role); rebalance only on
   join/leave/failure via the existing receiver-initiates heal. Viewer self-reports a route hint
   on `screen_watch`.
4. **Simulcast = phase 3** (the auto-quality mechanism once the tree removes per-viewer
   encoders); prerequisite = root-causing the Windows live-setParameters rejection in the fork.
   Until then: ingest leg encoded at max(effectiveViewerCap) over assigned forwarder viewers
   (step-1 machinery reused); a forwarder viewer's Source request re-offers the ingest.
5. **Forwarder gets its own bandwidth budget** (global + per-stream fair-share: degrade to the
   small layer first, refuse NEW ingests/attaches with explicit FwdError codes, never starve
   existing legs; zero metadata logging). Verified: the relay's 10 GB/day per-IP cap meters only
   relay-WS binary frames — no call media today (screen-share audio's "0x03" is a WebRTC
   data-channel type byte, not the relay opcode; TURN/coturn bytes are also unmetered).
6. **Cameras deferred** — the contract carries `kind` from day one, so enabling later is policy.
7. **Conference broadcast deferred** — contract keys on `(originator, stream id, kind)`, never
   on "originator is in the viewer mesh", which is all broadcast mode will need.

Additional scoping locked: **phase 1 is VC-only; DM calls keep TURN** (k=1 ⇒ the forwarder saves
zero bytes — the win exists only at k>1 viewers sharing one ingest). Forwarder control plane =
its own `fwd_*` envelope namespace over a dedicated `fwd:{forwarder_peer_id}` relay room
(Olm-encrypted; a forwarder can never satisfy the `is_vc_participant`/CRDT/MLS gates and must
never hold group keys). Discovery = relay `get_media_forwarder` text command mirroring
`get_turn_credentials`. **Phase-2 peer forwarding defaults ON with a Settings toggle** (desktop
only, never mobile/metered, 2–3 downstream legs) — Vitalik decision 2026-08-06.

## 6. Build order (deliverables D1–D6 from the approved plan)

| D | Deliverable | Status |
|---|---|---|
| D1 | Step 2 originator attribution (wire + spoof guard + Dart re-key + SFrame heal fix + tests) | **DONE** (see §7) |
| D2 | str0m ↔ libwebrtc interop spike | **PASSED** (see §7) |
| D3 | Forwarder module in hollow_core + headless `hollow-forwarder` bin + systemd deploy | **DONE** (see §7) |
| D4 | Relay `get_media_forwarder` discovery + client plumbing | **DONE** (see §7) |
| D5 | Client integration: route hint, `vc_screen_assign`, attach flow, fallback ladder | **DONE** (see §7) |
| D6 | Field verification (forced-relay VM viewer through the VPS forwarder) + this report updated | **PASSED** (see §7) |

Then phase 2 (peer forwarders, same crate embedded in-app) → phase 3 → dynamic removal of the
15-viewer cap.

**Phase 3 (the closing move, Vitalik's framing 2026-08-06): full upload spreading.** Today peer
forwarders serve only the relay-routed viewers (relay → 0); the sharer still uploads one copy
per STUN viewer. Phase 3 extends the same branches to DIRECT viewers — the sharer sends 1-2
copies total and STUN peers pull from each other (the §2e "A feeds the room" rows: 5 viewers at
4K ≈ 10-20 Mbps sharer upload instead of 50) — plus feeder election (a peer branch can feed the
VPS forwarder too). Prerequisites, in order: (1) simulcast (packet-selection per-viewer quality
— without it one slow viewer drags its whole branch's single encode down), which itself needs
the Windows live-`setParameters` rejection root-caused in the fork; (2) then the sharer-side
policy: assign direct viewers to branches past an upload threshold. That is what makes the
15-viewer cap DYNAMIC and closes the epic. All the machinery (branches, promotion, ladder,
attribution, engine) already exists — phase 3 is simulcast + policy, no new transport.

## 7. Status log

**2026-08-07 — PREP SESSION for runs 2-4: the vanished-frame defect attacked on every hop;
fwd control-plane rate limit REMOVED; relay + forwarder redeployed (fresh socket).**

- **Evidence loss discovered first:** journald on the VPS only retained ~9 h — the idle
  forwarder's per-minute `0 stream(s)` aggregate line flooded the journal and rotated the whole
  evening field session out of retention (zero interesting lines survive). The aggregate line
  now logs ONLY while active (plus one trailing idle line at the transition). Lesson: idle
  heartbeat logs are evidence-eaters on a journald box.
- **Token bucket REMOVED (both roles).** The per-peer 20/5 bucket in `forwarder/signaling.rs` +
  `node/embedded_forwarder.rs` was the ONLY spot in the entire fwd pipeline that ate a frame
  with zero trace — unlogged by design ("replying would defeat the limiter") and sitting BEFORE
  Olm decrypt, i.e. exactly where a "silently vanished" frame would die invisibly. Per the
  relay doctrine (rate limits that silently drop = the broken-core class, `feedback_relay_rules`)
  it is gone, not tuned: garbage still fails the cheap HavenMessage/Olm parse, the expensive
  KeyRequest re-bundle keeps its 5 s per-peer cooldown, and every admission refusal is an
  explicit FwdError. Honest note: the bucket is count-based, not size-based, so it is a
  *suspect*, not a confirmed culprit — but it can no longer confound the next run.
- **Every hop of the fwd control plane now observable:** (1) client send side already logged
  sizes (added in the field session); (2) relay `send_to_peer` now captures the uWS send status
  it previously IGNORED — uWS silently returns DROPPED past maxBackpressure — into
  `/server-stats` counters `send_dropped` / `send_backpressure`, plus `fwd_delivered` /
  `fwd_buffered` counting 0x04/0x08 directs to the configured forwarder id that were delivered
  live vs diverted into the offline buffer (the buffered path = the membership-blackhole shape:
  a frame buffered for a peer whose long-lived socket never re-joins is a frame that vanishes);
  (3) the forwarder logs EVERY inbound 0x06 with size + outcome (KeyRequest / fwd_* → engine /
  non-fwd / unparseable / decrypt-failed — sizes and envelope types only, zero identities). The
  previously-silent HavenMessage-parse and base64-decode failures now log too. One run pinpoints
  the drop hop.
- **30 s fwd-room re-join belt (VPS signaling loop):** the relay's `handle_join` is idempotent
  (redundant joins suppress the peer_joined broadcast) and replays buffered messages on every
  join — so a periodic re-join both restores any relay-side membership loss AND recovers frames
  that fell into the offline buffer, within 30 s.
- **Presence-flap tolerance on the FORWARDER (engine `handle_peer_gone`):** the client-side
  iron rule ("the MEDIA LEG is the only truth that may kill a branch") was LATENT on the
  forwarder — a spurious PeerLeft/members-diff tore down live streams/legs. Now: presence loss
  tears down only what carries NO connected media; live streams get `owner_gone` and the sweep
  tick reaps them once their legs dry up; an admitted owner op (re-register / ingest offer)
  clears the mark. Same engine ⇒ the embedded peer forwarder inherits the tolerance.
- **Deployed:** relay rebuilt + restarted live (new `/server-stats` fields verified); forwarder
  rebuilt on the Linux VM (uncommitted phase-2 tree — the VPS had been running the phase-1
  binary all along) and swapped in, service restarted = the planned fresh-socket probe. Same
  identity (`forwarder.key` persisted). Previous binary kept as `hollow-forwarder.prev`.
- **Field checkpoints for the next runs:** run 2's kill-VM1 rung must show the VPS journal
  logging `inbound … fwd_stream_register → engine` then `… fwd_ingest_offer → engine` (>10 KB)
  — if the offer line is missing, read `/server-stats`: `fwd_buffered` > 0 = relay membership
  blackhole (the 30 s belt should self-heal it); `send_dropped` > 0 = uWS backpressure. Also
  verify fix #6 (branch-ingest SFrame re-key) on an epoch change mid-share, and run 1's
  presence-flap tolerance now has a forwarder-side twin to watch.
- **SAME-DAY RETEST RESULT (08:19 UTC): vanished-frame defect FIXED and root-cause CONFIRMED;
  VPS rung PASSED end-to-end; peer rung not exercised (host config).** All previously-vanishing
  frame classes delivered and journal-confirmed with matching sizes (ingest offer 10.7 KB,
  egress answers 5.9/6.6 KB); `fwd_delivered=105, fwd_buffered=0, send_dropped=0`; both legs
  ICE-connected ≈1 s; egress = k×ingest throughout. **Root-cause confirmation:** the journal
  captured the exact kill shape — a viewer's fwd-room join fires the client's full discovery
  cascade AT the forwarder (~45 `non-fwd HavenMessage — ignored` frames within ONE second,
  profile/sync chatter), and the viewer's 6.6 KB egress answer arrives immediately AFTER that
  burst. Under the removed 20-burst/5-per-sec token bucket, the chatter drained the sender's
  bucket and the big control frame — always the LAST frame of the burst — was the one silently
  eaten. The "size correlation" was an ORDER correlation. Presence tolerance + auth-remove
  teardown both behaved on the real VM1 kill (VM2 unaffected). **Why the peer rung didn't
  engage: the HOST had "Always relay calls" ON** — its call PCs offer only relay candidates, so
  BOTH VMs' audio pairs to the sharer went TURN and both honestly probed `route=relay` → both
  were assigned to the VPS branch (VM1 was never a direct-route watcher, so no promotion; the
  kill therefore couldn't blink VM2 — they were parallel viewers). Host log fingerprint:
  `[HOLLOW-VC] ICE route … local=relay` on the host side of every call pair while general-lane
  PCs to the same machines are LAN/P2P direct. Fix for the re-run: Always-relay OFF on the
  HOST (it belongs on the VMs only in run 4). Follow-up polish (non-blocking): suppress the
  client's PeerJoined discovery cascade toward `fwd:` room peers — the forwarder ignores it
  all; it's join-burst bandwidth + journal noise.
  CORRECTION from run 2b (below): Vitalik reports Always-relay was OFF everywhere — the
  all-TURN call pairs of the first attempt were an ICE race (TURN candidates won lab-wide),
  not policy; the identical config produced direct pairs minutes later. Route probes honestly
  report whatever ICE picked, so an occasional VPS-instead-of-peer assignment is expected lab
  behavior, and the ladder handles it — no code change.
- **RUN 2b (08:32 UTC) — PEER RUNG + KILL LADDER: FULL PASS.** VM1 probed `route=direct` this
  time → on VM2's forced-relay watch the host logged `Promoted <VM1> to peer forwarder`,
  register-before-assign held, ONE ingest leg on the LAN (`Forwarder leg — local=host
  remote=host`), the direct PC to VM1 closed (one upload copy), VM1's engine attached its own
  display + VM2 within ONE second (register → both attaches → ingest + 2 egress ICE-connected →
  VP8 PT exact), VPS journal FLAT ZERO throughout — relay media = 0. THE KILL: VM1's app died →
  presence dropped first and the client tolerance held the branch (`Presence drop for forwarder
  … ignored — its ingest leg is alive`), 6 s later the MEDIA LEG died → `Ingest leg …
  disconnected — reverting its viewers` → VM2 got a direct offer and rendered in <1 s (the
  sharer-catches fast path; the VPS rung correctly never engaged since the sharer was alive).
  PLI coalescing verified under load (viewer PLI storm → 1/s upstream). **Fix #6
  field-verified:** two MLS epoch bumps (5, 6) landed mid-share with the branch ingest inside
  the re-key sweep (`enabled on 3 PCs` incl. the ingest leg) — viewers behind the branch
  decrypted after the bumps, the exact scenario that used to go permanently black.
- **The 5-10 s establishment black screen (both VMs) = NOT the forwarder lane: it is the
  join-order SFrame/MLS epoch race, now precisely characterized on a CLEAN server.** Signature
  (VM2, mirrored on VM1): legs connect instantly and ciphertext flows, but the receiver
  cryptor reports DecryptionFailed → MissingKey — the viewer's MLS group sat at epoch 4 while
  the VC-join commits marched the group to 5-6 and the sharer rotated its sender key
  immediately; the viewer missed those commits (join-race), so no epoch key. The voice-lane
  heal ladder converged it: HEAL escalate=false at +8 s → escalate=true at +16 s →
  re-bootstrap from the coordinator → key index 6 → FrameCryptorStateOk → picture. On the
  thrashed server the re-bootstraps themselves failed, which is why it looked permanent there.
  This is open item #2's bug with a clean repro signature: LAST JOINER MISSES THE JOIN-CHURN
  COMMITS AND SITS ON A STALE EPOCH UNTIL THE ESCALATED RE-BOOTSTRAP. Fix directions for its
  own session: make the sharer hold sender-key rotation until the group's members ack the
  epoch key (or keep a previous-index grace), and/or fast-path the WrongEpoch → SyncRequest
  recovery for freshly-joined members. Not a phase-2 blocker: once keys converge the lane is
  stable, and a share started into a SETTLED VC (like run 1) gets pictures in ~1 s.
- **RUN 3 (08:49-08:51 UTC, after one void attempt where the ICE race sent everyone to the
  VPS again) — DEMOTION: PASS.** Promotion on VM2's watch (`route=direct` VM1 → `Promoted`,
  host leg = `Forwarder leg`), VM2 left the VC → ~30 s linger → `fwd_stream_unregister` to the
  peer forwarder + revert assign → 2 s later VM1's display back on `STUN (direct P2P)`. The
  void attempt bonus-verified the viewer ladder (`direct_failed` → direct recovery ~1 s) and
  the VPS branch's 30 s ingest linger firing to the second. **Runs 1, 2, 3 all PASSED — run 4
  (k=2 measurement + relay_private + TURN baseline) is the last gate before commit.**
- **RUN 4 (12:25-12:27 UTC) — k=2 MEASUREMENT + PRIVACY GATE + TURN BASELINE: PASS. PHASE-2
  FIELD VERIFICATION COMPLETE (all four runs).** Both VMs under Always-relay: watches carried
  `fwd_capable=false relay_private=true` (a forced-relay user neither serves nor rides a peer),
  both assigned to the VPS branch, peer rung never considered. Steady-state journal aggregate:
  **`1 stream, 3 legs, ingest ~119 kbps, egress ~238 kbps` — egress = exactly 2×ingest at k=2**
  (the public `B + B·k` vs TURN `2·B·k` number: 3B vs 4B). Mid-stream
  `systemctl restart hollow-forwarder`: presence tolerance held the branch on the WS drop, the
  fresh forwarder refused with `unknown_stream` → sharer reverted its viewers → both VMs on
  direct+TURN in ~6-9 s (`ICE route: TURN (relayed)` — correct under their Always-relay). NIC
  observation: ~1.8 Mbps total (forwarder) vs ~4.2 Mbps (TURN) for the same 2 viewers
  (content-dependent; the journal ratio is the rigorous number). Full-day control-plane
  counters: `fwd_delivered=357, fwd_buffered=0, send_dropped=0`.
- **Follow-up (named by Vitalik from the field, deliberate v1 gap): watch-ORDER sensitivity —
  no opportunistic rebalance.** If the relay-routed viewer watches BEFORE any direct
  fwd-capable watcher exists, it lands on the VPS rung and STAYS there (v1 = static policy,
  rebalance only on join/leave/failure): the sharer then carries 2 uploads (direct copy + VPS
  ingest) where a promotion would carry 1 with relay at zero. Near-simultaneous watches are a
  topology coin flip on processing order. The fix is an opportunistic rebalancer — "fresh
  direct fwd_capable watcher appeared while a VPS branch serves viewers ⇒ promote + migrate
  that branch's viewers" — costing one blink per migrated viewer; slots naturally into the
  phase-3 tree-scoring work (or a small v1.5 if the 2-upload case bites earlier).

**2026-08-06 (evening) — PHASE 2 FIELD SESSION: RUN 1 PASSED IN FULL; runs 2-4 blocked by an
SFrame/MLS key-staleness issue in the thrashed test server (NOT a forwarder bug); 7 field bugs
found and FIXED (uncommitted, on the working tree). Continue next session.**

- **RUN 1 (peer-forwarder path) PASSED with all four vantage points agreeing:** host sharer saw
  `route=relay` → promoted the direct watcher (VM1) → ONE ingest leg at the branch cap; VM1's
  embedded engine registered the stream (expectation gate), attached its own display via the
  self-assignment short-circuit (`ICE route: Forwarder leg (blind relay hop)` — follow-up #1
  label live), VP8 PT-mapped `exact`, served the forced-relay viewer (VM2) over the LAN;
  **aggregate line: 1 stream, 3 legs, ingest ~976 kbps, egress ~1953 kbps — egress = 2×ingest
  for k=2, on a member's desktop**; VM2 rendered ATTRIBUTED TO THE SHARER; the VPS forwarder
  journal stayed at `0 streams / 0 kbps` the whole time — **relay media = ZERO.** Also verified
  live on the real relay: `fwd_capable`/`relay_private` wire round-trip, and the ladder
  descending peer → VPS → direct on failures.
- **Seven field bugs found by the kill/churn tests, ALL FIXED in the working tree:**
  1. *Deliverer-death strands the watch:* `_cleanupPeerScreenShare` closed a delivered stream
     silently (no ladder) — and the sharer's revert direct-offer is `_audioConnectedPeers`-gated,
     so when the host↔viewer audio PC happened to be down, NOTHING re-initiated ("Connecting to
     screen share..." forever). Fix: deliverer death while the originator still shares walks
     `_fallbackToDirect` (receiver-initiates doctrine; the re-watch rides the relay so it heals
     even with the direct audio PC broken).
  2. *Revert-assign with no follow-up offer strands the tile:* `screen_assign{forwarder:""}`
     now re-arms the 20 s watch timer.
  3. *Relay ghost-socket eviction = spurious PeerLeft:* after an app kill+restart, the relay
     evicts the ghost ~85 s later and broadcasts PeerLeft for its rooms even though the SAME
     peer's live socket is present — both sharer and viewers tore down a WORKING branch on it.
     Fix: presence-flap tolerance — a branch with a live ingest leg and a delivered stream that
     is still rendering are kept; the MEDIA LEG is the only truth that may kill a branch (its
     own ICE death fires the existing recovery paths). Relay-side suppression = follow-up.
  4. *Self-attach races the register:* promotion sent the self-assign FIRST; the promoted
     forwarder's attach is a LOCAL short-circuit and beat the relay-carried register →
     `unknown_stream` → its own display laddered away instantly. Fix: register + ingest offer are
     sent BEFORE any assign (same-socket ordering makes the engine provably know the stream
     first), plus a one-shot 700 ms self-attach retry on `unknown_stream` as the belt.
  5. *Sharer re-laddered its own forwarder's display onto the VPS:* a branch HEAD's
     `direct_failed` now DEMOTES the branch (viewers revert and re-ladder; the head falls
     through to the direct path) — and `_pickForwarderFor` hard-refuses branch heads (no chains
     in v1).
  6. *Branch ingest legs sat OUTSIDE both SFrame re-key sweeps* (the epoch-rotation sweep and
     `_sframeHealReapply`): an ingest sender that misses a rotation keeps encrypting under the
     old key index → every viewer behind that forwarder decodes nothing (MissingKey→
     DecryptionFailed → endless PLI storm) while heals bump epochs and dig deeper. LATENT IN
     PHASE 1 TOO (the VPS `_ingestService` had the same blind spot — D6 simply never rotated an
     epoch mid-share). Fix: both sweeps now include `_fwdBranches[].ingest`.
  7. *(From the same session, non-forwarder)* the join-flow toast crashed on `Overlay.of` after
     dialog pop (`create_server_dialog.dart`) — fixed per the toast iron rule.
- **OPEN BLOCKER (why runs 2-4 stopped): recurring SFrame failure in the VOICE lane of the
  long-lived test server, join-order dependent** — VM2 joining the VC LAST reliably failed
  SFrame (audio cryptors failing before any share), while VM2 joining FIRST worked; and the
  final promotion attempt still went black on both viewers even with fix #6 on the sharer. The
  server's MLS group is thrashed: epoch 39 → 47 in one afternoon of heal-escalation
  re-bootstraps; key events fire constantly with `enabled on 0 PCs`. The failure looks like a
  pre-existing epoch/key-distribution ordering bug (`feedback_mls_patterns` territory) amplified
  by the churned group — NOT a forwarder-lane bug (the forwarder moves ciphertext it never
  decrypts; run 1 proved the lane end-to-end when keys were sane).
- **NEXT SESSION:** (1) reproduce on a FRESH server + fresh VC (clean MLS group) — run 1 should
  pass in ~1 s again, then runs 2 (kill VM1 → VPS rung, checkpoint-verified before the kill),
  3 (demotion), 4 (k=2 measurement + relay_private check, procedure above); (2) investigate the
  join-order SFrame failure as its own bug (repro: host+VM1 in VC, VM2 joins last → audio
  cryptor failures; VM2 first → fine); (3) verify fix #6 engages (host log should show the
  branch-ingest re-enable on epoch change mid-share); (4) relay follow-up: suppress
  ghost-eviction PeerLeft when the peer has another live socket in the room.
- **LATE-NIGHT ADDENDUM — FRESH SERVER = RUNS 1 AND 2 BOTH PASSED.** On a newly created server
  (clean MLS group) the whole flow worked immediately: run 1 re-passed with pictures on both
  VMs, and at +45 s the relay's ghost eviction fired for the promoted forwarder — **the
  presence-flap tolerance held the branch** (`Presence drop … ignored — its ingest leg is
  alive`), the exact event that killed the earlier session. Run 2 (VM1 killed): VM2 re-watched
  `direct_failed` within seconds → VPS rung → VPS rung ALSO failed (vanished-frame defect
  below) → second `direct_failed` → **direct+TURN, picture restored in ~10-15 s — the share
  survived TWO failed helpers.** This confirms the runs-2-4 blocker was the thrashed old
  server's MLS state, not the forwarder lane.
- **REMAINING DEFECT, precisely characterized — large Olm frames to the VPS forwarder vanish:**
  three occurrences today, always the same shape: small frames (register 443 B) arrive, large
  ones (ingest offer ~10.5 KB, egress answers ~6 KB) silently don't; peer↔peer fwd frames of the
  same sizes always flow. The VPS forwarder's WS socket has been up since morning without a
  reconnect. Prime suspect: relay-side backpressure drop on that long-lived socket (uWS
  `maxBackpressure` — check its configured value and the drop path in send_to_peer); first
  probe next session = restart `hollow-forwarder.service` (fresh socket) and re-run the VPS
  rung; if it heals, instrument the relay's backpressure counters. Silent drops on the fwd
  control plane also argue for a client-side attach/offer RETRY tier later.
- **VM lab notes that cost hours:** TWO VirtualBox VMs bridged over Wi-Fi = broken (second
  guest's inbound goes silent ~90 s after connect; one-way-deaf WS + dead data channels);
  bridged+NAT mix works and NAT is actually the more production-faithful viewer topology. A
  VM restored from a foreign lab image had an Am79C970A NIC (no Win10 driver — zero adapters)
  and stale static IP config. `HOLLOW_FORCE_RELAY_ROUTE=1` (route-hint-only env knob, added
  this session) is REQUIRED to exercise the peer path in the lab now that Always-relay
  deliberately routes to the VPS rung (`relay_private`).

**2026-08-05/06 — step 2 + spike session (everything below in one day):**

- **Step 2 (D1) IMPLEMENTED.** `StreamOrigin {peer, kind, stream}` boxed on
  `vc_screen_offer/answer/ice` (`#[serde(default)]` + skip_serializing_if ⇒ byte-identical wire
  when absent; serde tests pin the old wire shape). Spoof guard in voice_handler
  (`inbound_origin_ok`, resolver-based so master-vs-device forms collapse): origin must name the
  authenticated sender (offer dir) or ourselves (answer/ICE echo) or the WHOLE signal drops.
  Olm inline screen arms consolidated into the shared voice_handler handlers. Dart re-key:
  attribution/consent/badges/SFrame participant (`'screen:$originator'`) on the ORIGINATOR,
  transport routing on the deliverer; `_incomingShareOrigins` deliverer index;
  `_shareSessionId` + device-id origin minted per share session. SFrame heal-ladder fix rode
  along (share cryptors were unreachable by heal step 1). Verified: new harness test
  `vc_screen_origin_attribution_round_trip` (round-trips both directions, old-wire compat,
  spoof drop), full suite 579/579, widget tests 406/406, no new clippy/analyzer findings.
- **D2 spike PASSED (live field test, Windows host sharer → VirtualBox-NAT Win10 VM viewer).**
  All 5 criteria: (1) production-path share (real ScreenShareService encoder config + SFrame
  FrameCryptor, dev key) rendered through the blind hop — spike keyless, payloads ciphertext
  end-to-end; (2) PLI: mid-stream viewer attach → picture in ~2–3 s, requests aggregated +
  rate-limited upstream; (3) 5% deliberate egress UDP loss (post-RTX-cache) visually clean —
  NACK/RTX recovery from the forwarder's packet cache works; (4) BWE alive over the ingest leg:
  ~150 kbps idle desktop → 2–3.2 Mbps under motion, holds under loss; (5) PT spaces negotiate
  independently per leg and codec-level translation maps them (VP8 96→96 here).
  Spike artifacts (`rust/spike_str0m`, `lib/src/core/services/spike_forward_dev.dart`, one
  env-gated `main.dart` hook) are THROWAWAY — delete when D3 lands.
- **str0m/Windows lessons for D3** (memory `project_media_forwarding_epic` has the full list):
  tolerate `WSAECONNRESET` on UDP recv/send (bounced ICE checks kill the leg right after "ICE
  Connected" otherwise); `Event::MediaAdded` fires only for REMOTE media — keep the `Mid` from
  `add_media()`; str0m auto-creates StreamTx for SDP-negotiated media; PT translation by
  (codec, clock-rate) between the legs' `codec_config().params()`.

**2026-08-06 — D3+D4+D5 session (phase 1 implementation complete; D6 = the remaining gate):**

- **D3 DONE.** `rust/hollow_core/src/forwarder/` behind the `forwarder` cargo feature
  (`mod` config+boot, `signaling` = fetch.rs-shaped manual WS loop + Olm key-exchange RESPONDER,
  `dispatch` = pure admission + per-peer token bucket, `engine` = stream/leg orchestration +
  10 s budget/sweep tick, `stream` = per-stream fanout/PLI/counters, `budget` = pure caps) +
  `src/bin/hollow_forwarder.rs`. Crate gained `crate-type "rlib"` + first `[features]` section
  (str0m 0.21 + toml optional; verified inert for app builds: default `cargo check` clean, FRB
  codegen untouched — the module lives OUTSIDE `api`). Deployed on the OVH VPS as
  `hollow-forwarder.service` (`/home/ubuntu/forwarder`, TOML config, UDP 40000-40199 opened in
  ufw, NO license key — the public relay is open). **Deviations from the approved plan, all
  evidence-backed:** (1) NO hand-rolled packet-cache ring — str0m's own RTX cache via
  `write_rtp(...).nackable(true)` serves egress NACKs (spike criterion 3 proved it post-cache);
  (2) NO `FwdIce` in v1 — both legs ride COMPLETE SDPs (forwarder = fixed public host candidate;
  the spike proved a NAT'd libwebrtc client reaches one without trickle); tag reserved;
  (3) engine keeps the spike's per-leg task + per-leg UDP socket + broadcast fanout (kernel
  demuxes; no bespoke demux layer), ports = a coturn-style RANGE, one per leg;
  (4) forwarder identity = ONE keypair, master==device (`forwarder.key`); rotation = NEW identity
  + relay flag update, never a re-key (clients pin the Olm identity key).
  Lockfile note: adding str0m surfaced the known anyhow-1.0.75→backtrace→cc→getrandom-0.4 cycle;
  fixed by bumping the anyhow pin to 1.0.104 (drops the backtrace edge).
- **D4 DONE.** Relay `get_media_forwarder` (ws_handler.cpp, mirrors get_turn_credentials: guest
  gate, `--forwarder-peer-id` startup config, `peer_sockets.count()` liveness) — deployed live.
  Client: `WsCommand::GetMediaForwarder` fired on every `WsEvent::Connected` beside the TURN
  request (no timer — static id) → `NetworkEvent::MediaForwarderInfo` → Dart
  `forwarderInfoProvider` (plain Notifier cache, ice-config rules).
- **D5 DONE.** `vc_screen_watch` gained `#[serde(default)] route` ("" old client / "direct" /
  "relay" / "direct_failed"); viewer derives it from ONE immediate stats pass on the audio PC
  (`pcFor()` + `probeIceRouteOnce`; forced-relay setting short-circuits to "relay"). New
  `vc_screen_assign` variant (full touch list incl. rate-limiter + `is_vc_participant` +
  `inbound_origin_ok` spoof guard). Sharer: relay-routed new-client viewers go through the
  forwarder (idempotent full-allowlist `fwd_stream_register`, SINGLE ingest leg at
  max(effectiveViewerCap), no `_outgoingScreenShares` slot — the 15-cap starts lifting), 30 s
  ingest linger after the last forwarder viewer, `FwdError`/ingest-death reverts the audience to
  direct offers. Viewer: `screen_assign` → fwd room join + `FwdAttach`; `fwd_egress_offer` rides
  the extracted `_attachIncomingShare` helper (originator-keyed maps + SFrame
  `'screen:$originator'`, forwarder = deliverer — D1 made this a pure key choice, zero UI edits);
  COMPLETE-SDP answers via `gatheredLocalSdp()`. **Forwarder legs are EXEMPT from "Always relay
  calls"** (STUN-only `_forwarderLegIceConfig` — the forwarder IS the relay replacement; forced
  TURN would blackhole the leg). Fallback ladder: fwd_error / 20 s watch timeout / egress-leg
  disconnect ⇒ detach + re-watch with `route:"direct_failed"` (once per session) ⇒ today's
  direct+TURN path. Spike artifacts deleted (`rust/spike_str0m`, `spike_forward_dev.dart`,
  main.dart hook); `_gatheredLocalSdp` ported into ScreenShareService first.
- **D6 FIELD VERIFICATION PASSED 2026-08-06** (Windows host sharer → VirtualBox-NAT Win10 VM
  viewer with "Always relay calls" ON, real VPS forwarder). Final run: stream registered → both
  legs ICE-connected inside 1 s → `PLI sent upstream (via ssrc)` → picture on the viewer in
  **~1 second**, ~1.2 Mbps egress. Proven: video traverses the blind hop; the viewer renders it
  ATTRIBUTED TO THE SHARER with SFrame decrypting under the ORIGINATOR's key on a forwarder that
  never held it; the sharer logs exactly ONE `Creating offer from shared stream` (one encode, one
  copy, NO per-viewer PC — the 15-cap is untouched). The fallback ladder proved itself twice
  unplanned: a forwarder-refused ingest and a mid-stream forwarder restart both reverted the
  audience to direct+TURN and rendered normally (which also served as the step-2 regression check).
  **Two follow-ups, neither blocking:** (1) the viewer's `[HOLLOW-SCREEN] ICE route` line labelled
  the forwarder leg `TURN (relayed)` — that log predates this lane and cannot distinguish a
  forwarder leg from a TURN'd direct leg, so it reads misleadingly on a client with "Always relay
  calls" ON; make the label forwarder-aware. (2) Measure the actual relay saving with k>1 viewers:
  at k=1 forwarder and TURN cost the relay the same `2·B`, so the `B + B·k` vs `2·B·k` win only
  shows from the second viewer on (that is the number worth quoting publicly).
- **Five bugs the field found that no test could** (all ours, each one hop further down the
  pipeline — worth remembering as the shape of this class of work):
  1. **str0m ICE destination.** Sockets bind `0.0.0.0` but advertise the public IP; `Receive`'s
     `destination` must be the ADVERTISED address or str0m silently discards every inbound STUN
     check. Both legs sat unconnected. (The spike dodged it by binding the LAN IP directly.)
  2. **STUN servers on forwarder legs (client).** libwebrtc's UDP port withholds its candidates
     while waiting on configured STUN servers; on a host whose DNS answers IPv6-first with no
     routable IPv6 (the test VM: ULA address, IPv6-only default gateway) the allocator produced
     ZERO candidates and never activated ICE. Forwarder legs need NO ice servers — the forwarder
     is public and learns the peer's mapping as peer-reflexive. Empty list = what the spike used.
  3. **`fwd_stream_register` dropped on send (client).** Routed via `send_encrypted_message`'s
     `ws_room_for_peer` lookup, which found no shared room because the fwd-room join hadn't
     landed yet → frame discarded → the forwarder refused the ingest with `unknown_stream`. The
     fwd lane has a DETERMINISTIC room; route through it explicitly (the DM one-way-loss rule).
  4. **PT translation ignored codec format params.** VP9 appears twice in a PT space (profile 0
     and 2), H264 seven times; matching on (codec, clock_rate) alone can relabel a stream so the
     receiver accepts packets and decodes nothing — black screen with healthy byte counters.
     Match the full `CodecSpec`, fall back to codec+rate with a loud log.
  5. **Keyframe request never reached the sharer.** `stream_rx_by_mid` did not resolve (the
     working path is the SSRC seen on the wire), and the 1 s PLI aggregator DROPPED requests
     inside its window instead of coalescing them. A joining viewer waited for a spontaneous
     keyframe: **2m50s** of black screen, measured. Now: SSRC fallback, coalesce-never-drop, and
     the forwarder requests a keyframe itself the moment an egress leg connects.
  Every one of these was invisible to unit/harness tests by construction (media plane) and was
  found by adding one decisive log line at a time — first inbound datagram per leg, candidate
  counts on both sides of the SDP exchange, and the PT-mapping decision.
- **Tests:** Rust suite 589/589 default features + 14/14 forwarder-feature unit tests (serde:
  fwd tags pinned + defaults + no-target, screen_assign +
  route; harness: `forwarder_room_and_signal_round_trip` — fwd room join without RoomCleared,
  no-session queue→KeyRequest→drain, client-bound ignore arm, ForwarderSignal emission —
  and `vc_screen_assign_and_route_round_trip` incl. spoof drop; forwarder unit tests for
  budget/admission/token-bucket/PT-map run under `--features forwarder`); widget tests 406/406;
  `flutter analyze` clean; relay rebuilt + restarted live.

**2026-08-06 (same day, later session) — STEP 3 PHASE 2 IMPLEMENTED (viewer-peer forwarders);
field verification = the remaining gate:**

- **Build plumbing.** The `forwarder` cargo feature now reaches app builds via a new
  `rust/hollow_core/cargokit.yaml` (`extra_flags: --features forwarder` for debug/profile/release —
  vendored cargokit has no per-platform switch), kept mobile-inert by TARGET-SCOPING the str0m/toml
  optional deps to `cfg(not(any(android, ios)))` and gating the module + all bridge code on
  `all(feature, not(android/ios))`: verified `cargo tree --target aarch64-linux-android` resolves
  NO str0m while desktop does. str0m's crypto backend is aws-lc (NOT OpenSSL) — desktop release
  builders need cmake (+ NASM on Windows MSVC); already proven on the dev box and the Linux VM.
- **Engine embed-ability (forwarder module).** New auto-advertise mode: empty `public_ip` =
  embedded — each leg advertises the default-route LAN IP as host candidate PLUS its NAT mapping
  discovered per-socket via a new minimal STUN client (`forwarder/stun.rs`, RFC 5389 binding +
  XOR-MAPPED-ADDRESS, IPv4-only by design — the D6 bug-#2 lesson), advertised as a SECOND host
  candidate (the same "public host candidate" shape the VPS uses behind 1:1 NAT). CLIENT legs keep
  the zero-ICE-config iron rule on BOTH lanes — the forwarder side carrying the reflexive
  candidate is what makes the pair connect. STUN discovery runs inside the leg task (engine loop
  never blocks); `Receive::destination` stays the primary advertised address. Ephemeral UDP ports
  (`udp_port_min = 0`); embedded caps = 2 streams / 4 legs per stream (3 remote + own display) /
  no bps budget (the leg count IS the budget). `spawn_embedded_engine()` = engine::run only — no
  second identity/DB/Olm (those are VPS-only boot steps).
- **Node bridge (`node/embedded_forwarder.rs`).** The client-bound fwd_* ignore arm now feeds an
  embedded engine when enabled: expectation gate (a `fwd_stream_register` is admitted ONLY for an
  `(originator, kind)` this client advertised `fwd_capable` for on a live watch — a peer forwarder
  only ever forwards a stream its user explicitly watches), per-peer token bucket (20/5, the VPS
  numbers), then the engine's own spoof/owner/allowlist/caps admission unchanged. Engine replies
  ride `NodeCommand::EmbeddedForwarderOut` back into the swarm loop where the OlmManager lives,
  Olm-encrypt through OUR OWN `fwd:{device_id}` room (deterministic-room rule both directions;
  send path = `send_fwd_envelope_via_room`, extracted from the phase-1 client sender).
  SELF-addressed signals short-circuit: `ForwarderSendSignal` to our own device id injects
  straight into the engine, and engine→self replies emit `NetworkEvent::ForwarderSignal`
  `from_peer == us` — the forwarder's own display is just another attach, no Olm, no relay.
  Presence: PeerLeft/RoomMembers diffs on our fwd room drive `EngineCmd::PeerGone`; reconnect
  rejoins the room; TURN credential URIs double as the STUN source. STUN derivation prefers a
  `stun:` URI, falls back to the TURN host on :3478.
- **Wire.** `vc_screen_watch` gains `#[serde(default)] fwd_capable: bool` (absent = old client =
  false = never a candidate). NO new envelope variants — the whole phase rides the phase-1 fwd_*
  contract ("a forwarding peer and an SFU are the same component", §2c, now literal).
  New FFI: `set_peer_forwarding_enabled`, `set_forwarder_expectation` (+ codegen).
- **Sharer-side selection (voice_channel_provider.dart).** Phase-1's single-forwarder state
  generalized to per-forwarder BRANCHES (`_FwdBranch`: viewers, one ingest leg, linger timer).
  Relay-routed viewer ladder: existing peer branch with capacity (< 3 remote legs) → promote a
  fresh candidate (fwd_capable watcher on a 'direct' route) → VPS infra forwarder → direct+TURN.
  PROMOTION self-assigns the forwarder (`vc_screen_assign{forwarder: itself}` sent to it — its
  display switches to its embedded engine's egress leg) and closes our direct PC to it: ONE
  upload copy serves the forwarder + its downstream viewers. Its own display rides the register
  allowlist + the branch's ingest cap (max over branch audience). `direct_failed` re-watches now
  DESCEND the ladder: the failed branch is remembered per viewer (never re-assigned), two failed
  rungs ⇒ direct; the viewer's own fallback counter caps at two as well (both sides bound the
  ladder). Branch death (ingest disconnect / FwdError / forwarder stops watching / peer vanishes)
  reverts that branch's viewers to direct offers and DEMOTES an idle peer forwarder back to its
  own direct feed.
- **Viewer side.** `vc_screen_assign` trust widened per the phase-2 model: the assignment is
  authenticated as coming from the stream's ORIGINATOR (Rust `inbound_origin_ok`) and honored
  only for a watched share, so the sharer may name ANY forwarder for its own stream — VPS, a
  viewer-peer, or US (self-assignment → local attach through the FFI short-circuit; our own fwd
  room membership belongs to the bridge, never joined/left from the assignment path). The
  per-assignment fwd_* source gate is unchanged. Watch payloads advertise `fwd_capable` (desktop
  + toggle) and arm/withdraw the engine expectation on watch start/stop/leave.
- **Settings.** `peerForwardingProvider` (persisted `peer_media_forwarding`, default ON — absent
  key = enabled; loaded at bootstrap beside Always-relay, pushed into the node post-start and on
  toggle). "Peer media forwarding" toggle beside "Always relay calls" (desktop Settings > Security
  > Call Privacy); disabling mid-serve tears the engine down and downstream viewers heal.
- **Always-relay privacy gate (added same day — the phase-1 "forwarder legs are exempt from
  forced TURN" rationale only holds for OPERATOR infrastructure).** A forced-relay user's media
  must never touch another MEMBER's machine, in either role: (1) `_canForwardShares()` is false
  under Always-relay — they never serve; (2) new `#[serde(default)] relay_private: bool` on
  `vc_screen_watch` — the sharer skips the peer rungs and routes them VPS-forwarder-or-direct
  only (advisory, like `route`); (3) viewer-side HARD refusal in `_handleScreenAssign` — a peer
  forwarder assignment while Always-relay is on walks the ladder instead (catches buggy/malicious
  sharers at the cost of one attempt). The VPS forwarder remains fine for them: same operator
  trust domain as TURN, which is exactly what D6 field-verified.
- **D6 follow-ups CLOSED:** (1) forwarder legs (`ScreenShareService(forwarderLeg: true)`) log
  `ICE route: Forwarder leg (blind relay hop) — pair local=… remote=…` instead of the misleading
  TURN/STUN taxonomy; (2) the engine's per-minute aggregate line now carries ingest AND egress
  kbps — at k viewers egress ≈ k × ingest, which IS the `B + B·k` vs `2·B·k` number to quote; the
  relay-side counterpart comes from `/server-stats` NIC deltas with the VM procedure below.
- **Field verification procedure (pending; topology = host sharer + TWO bridged-network VMs —
  NAT-mode VirtualBox guests can't reach each other, and the peer leg VM2→VM1 needs the LAN).
  NOTE: Always-relay no longer exercises the peer path (the privacy gate routes it to the VPS
  rung BY DESIGN) — the restricted-NAT viewer is simulated with the `HOLLOW_FORCE_RELAY_ROUTE=1`
  env var instead (route-hint-only lab knob, inert in production):**
  1. *Peer-forwarder path:* host shares; VM1 (bridged, defaults — fwd toggle ON, no
     Always-relay) watches → direct; VM2 (bridged, `HOLLOW_FORCE_RELAY_ROUTE=1`, Always-relay
     OFF) watches → expect: sharer logs "Promoted <VM1> to peer forwarder" + ONE ingest offer for
     the branch, VM1's `[HOLLOW-SCREEN] ICE route` reads `Forwarder leg (blind relay hop)` (its
     display now rides its own engine), VM2 renders ATTRIBUTED TO THE SHARER, VPS forwarder
     journal shows NO new stream — relay media = 0.
  2. *Ladder:* kill VM1's app mid-stream → VM2's feed dies → re-watch `direct_failed` → sharer
     assigns the VPS forwarder (journal shows the stream register + legs) → picture back.
     Restart `hollow-forwarder.service` mid-stream too → VM2 falls to direct+TURN, per phase 1's
     proven ladder.
  3. *Demotion:* VM2 stops watching → 30 s linger → VM1 demoted (sharer log + VM1 gets a direct
     offer back, ICE route line goes back to the normal taxonomy).
  4. *k>1 saving (follow-up #2 measurement) + privacy-gate check:* BOTH VMs with "Always relay
     calls" ON (env var unset) → both must land on the VPS forwarder (never VM1, even though
     VM1 is fwd-capable — that IS the relay_private verification): journal aggregate line reads
     1 stream, 3 legs, egress ≈ 2 × ingest (`B + 2B` total). TURN baseline: stop
     `hollow-forwarder.service`, re-watch (ladder → direct+TURN), read `/server-stats` NIC deltas
     ≈ `4B`. Quote that pair publicly.
