# Media Forwarding Plan — Resolution Capping, Originator Attribution, SFrame Packet Forwarders

**STATUS 2026-08-08: PHASE 3 IMPLEMENTED (all three stages) — field verification = the
remaining gate, then the epic closes.** (1) The Windows live-`setParameters` rejection is
ROOT-CAUSED with source-level proof and FIXED in the plugin (no DLL rebuild): the
native→Dart parameters map materialized unset optionals (`scalabilityMode` "" / `ssrc` 0 /
bitrates 0), Dart round-tripped them non-null, and the write-back turned nullopt into
Some("")/Some(0) — `CheckRtpParametersInvalidModificationAndValues` then rejects the WHOLE
call (INVALID_MODIFICATION). This also explains the pre-2026-07-19 "returned true but did
nothing" era: the missing `set_encodings` write-back DISCARDED the poisoned copies. (2)
Simulcast: forwarder ingest legs now offer TWO rid layers (`q` low-first/protected +
`f` = branch cap; VP8-constrained), str0m inverts the simulcast attrs in its answer,
the engine tags each packet's layer at ingest and each egress leg packet-SELECTS its
layer (sharer's `low_viewers` on the register; per-layer PLI; seamless VP8 switch with
seq/ts/PictureID/TL0PICIDX/KEYIDX rewrite via str0m's `Vp8Patch`; dry-layer fallback +
upgrade-home hysteresis; rid-less old-sharer streams pass through byte-identical). Old
peer forwarders are protected by a new `fwd_simulcast` watch flag — no flag, no simulcast
ingest. (3) Upload spreading: direct step-3-capable viewers past `maxDirectShareCopies`
(=1) are served through branches (peer branch w/ capacity → promote a fwd-capable direct
watcher, preferring one whose direct copy then closes, then the viewer ITSELF
(self-promotion) → an ALREADY-SERVING VPS branch only — never a fresh VPS branch for a
STUN viewer) — the "1-2 copies total" target; the 15-cap is now effectively dynamic.
Deferred from phase 3 (own session): feeder election (a peer branch feeding the VPS
forwarder's ingest — needs a new owner-delegated admission rule on the engine, security
surface). See the 2026-08-08 §7 entry for the field checklist. **DEPLOY ORDER: the VPS
`hollow-forwarder` binary must be redeployed BEFORE any client with this build shares —
the sharer assumes the infra forwarder is simulcast-capable. (DONE 2026-08-14 — new
engine live on the VPS, same identity, `.prev` kept.)** ALL remaining follow-ups are
gathered into the **§9 next-session worklist** (parallel healing, Source-quality branch
gating, ICE repair pair, chatter suppression, ghost-eviction suppression, feeder
election) — plus the condensed 3-run field pass that gates it.

Previous status (2026-08-07): STEP 3 PHASE 2 FIELD-VERIFIED COMPLETE — ALL FOUR RUNS PASSED (peer
rung + kill ladder, VPS rung, demotion, k=2 measurement + relay_private privacy gate + TURN
baseline; §7 top entry has each run's evidence). The vanished-frame defect is FIXED and
root-cause-confirmed (the removed fwd control-plane token bucket ate the last-in-burst large
frame after the client's fwd-room join chatter); every hop of the fwd control plane is now
instrumented (client send sizes / relay delivery + send-status counters in `/server-stats` /
forwarder per-frame outcome log), a 30 s idempotent fwd-room re-join belt self-heals relay
membership loss, and presence-flap tolerance is on BOTH the clients and the forwarder engine
(media legs are the only truth). Relay + forwarder deployed live. Headline number:
**egress = k×ingest on the forwarder (238/119 kbps at k=2) vs TURN's 2·B·k — and relay media
= ZERO when a peer forwarder serves.** The SFrame join-order epoch race (runs 2's 5-10 s /
formerly-permanent black screens) is **FIXED 2026-08-07** — commit cache + epoch hints +
catch-up replay, see the top §7 entry. The 2026-08-07 follow-up trio (self-ghost VC
participant, Olm decrypt-fail logging, opportunistic rebalancer) is DONE and FIELD-VERIFIED
twice (2026-08-08) — see the top §7 entry. Remaining follow-ups queued in §7 (ICE
direct-when-possible repair pair — Vitalik-approved 2026-08-08; fwd-room chatter
suppression; relay ghost-eviction PeerLeft suppression). NEXT = PHASE 3 (setParameters
root-cause → simulcast → upload spreading), which closes the epic and is the foundation
for broadcast mode / "Hollow Streaming" (§8).** Step 1 (resolution capping) shipped; step 2 (originator attribution)
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

**2026-08-15 — "SOURCE QUALITY" REMOVED (Vitalik's call). Step 1 is now purely
automatic: every viewer gets `min(share, their largest MONITOR)`, always.**

The feature could no longer keep its promise. Its original premise (§3 step 1)
was that it "lifts the cap for that ONE connection only" — true when every
viewer had a private PC and therefore a private encoder. A forwarder branch has
ONE shared encoder feeding many viewers, so "that one connection" stopped
existing, and §9.2 had to gate the request out of shared ingests. The result was
a button that worked on a direct viewer and silently did nothing on a branch
viewer, with nothing in the UI to tell them apart — worse than not having it.

Two facts made removal the right call rather than "make it work everywhere":

1. **The clamp is keyed to the viewer's largest connected MONITOR**
   (`largestDisplayResolution()` reads `platformDispatcher.displays`), NOT the
   window. So a viewer already receives every pixel their screen can show
   regardless of how small their Hollow window is. Source only ever did
   anything when the SHARE was bigger than the viewer's monitor.
2. **Desktop has no zoom on a share**, so those extra pixels were downscaled
   away on the only platform where a 4K share is likely. (Mobile has pinch-zoom,
   but a phone's display cap is small anyway.)

The field confusion that triggered this is worth recording: in the VM lab
VirtualBox resizes the GUEST DISPLAY to the window, so Win10 honestly reported
an 826-tall monitor and got 826p — which read as "the cap is following my
window and Source can't fix it". On real hardware that does not happen.

Removed end to end: the `ShareSourceQualityChip` widget + its 4 call sites, the
`source_quality` wire field on BOTH `vc_screen_watch` and `call_screen_watch`,
`sourceQualityShares`/`watchingSourceQuality` state, `setShareSourceQuality`/
`setRemoteShareSourceQuality`, the `sourceQuality` parameters on
`effectiveViewerCap`/`viewerWantsLowLayer`, and §9.2's `honorSource` flag (now
unnecessary — there is nothing to honour). `share_source_quality_chip.dart` is
renamed `share_quality_chip.dart`; the RECEIVED-resolution label chip it also
contained stays, and is now the honest way to see what you are getting.

**Wire compat is safe in both directions:** serde ignores unknown keys, so an
older client's `source_quality: true` is simply dropped by a new sharer (it then
gets the clamp — the new intended behaviour), and a new client sends no key to
an old sharer, which defaults it to false. Harness assertions were inverted to
PIN that the key no longer round-trips.

If the capability is ever wanted back, the honest form is the plan's documented
refinement — move a requesting viewer onto a direct per-viewer slot when one is
free — never re-gating a shared ingest. Note it must exclude branch HEADS: a
head with its own direct PC is exactly the cryptor collision fixed earlier today.

**2026-08-15 (run 3) — FEEDER ELECTION FIELD-VERIFIED; the branch-head SFrame
fix holds; the "quality jumping" is the f↔q dry-layer oscillator, now damped.**

- **FEEDER ELECTION WORKS, end to end, in ~1 second.** The mixed topology arose
  naturally (both VMs first probed `route=relay` → VPS branch; Win10 then
  re-probed `direct` → promoted). Host: `Feeder election: delegating <Win10> to
  feed the VPS forwarder (2 upload copies → 1)` → Win10: `Elected as FEEDER …
  (re-emitting our copy into its ingest)` → `feeding forwarder <VPS>` → `Feed
  leg into <VPS> admitted — reporting up` → host: `Feed to <VPS> is up —
  closing our own ingest there (sharer down to one upload copy)`. The
  make-before-break handover completed and the sharer went to ONE ingest.
  Revocation also fired cleanly later (`stopped feeding forwarder`).
- **Branch-head fix holds:** the Source toggle on the head no longer produces a
  direct offer, and there is no `DecryptionFailed` anywhere in the run.
- **THE "QUALITY JUMPING" — root-caused.** The engine log shows a clean
  oscillator on every egress leg of the peer branch:
  `562 serving 'f'` → `569 'f' dry — falling back to 'q'` → `580 returning to
  'f'` → `595 dry → 'q'` → `601 returning to 'f'` … i.e. **826p ↔ 413p every
  6-15 s**, exactly what Vitalik described. Driver: the sharer's encoder
  reported `limit=bandwidth`, and libwebrtc's allocator protects `encodings[0]`
  (= `q`) by design, so under BWE pressure `f` is the layer that starves.
  **This is not a regression** — the same fallback was observed and accepted on
  2026-08-14 ("the f layer starved (BWE/static-content — the allocator protects
  q by design)"). What is new is recognising that a FIXED 5 s climb-back
  (`UPGRADE_AFTER` in leg.rs) makes it a permanent oscillator on any link that
  cannot hold `f`: it flows briefly while libwebrtc probes upward, we upgrade,
  the allocator starves it again, forever.
  **Fix: `simulcast::UpgradeGate`** — adaptive hysteresis. First climb-back
  still costs only 5 s, but each upgrade that fails to STICK (dies within 30 s)
  triples the requirement, capped at 60 s; an upgrade that held longer than
  that resets it, so a genuinely recovered link gets quality back promptly.
  Pure (caller supplies `now`), 2 new unit tests.
- **A diagnostic that actively lied, now fixed.** `Encoded output: 733x412 …
  cap=1467x826 -> CAP APPLIED` — with simulcast there is one `outbound-rtp` per
  LAYER and the logger took the FIRST and returned, so it reported the `q`
  layer and cheerfully declared the cap applied while `f` was dead. It now
  reports every layer with its rid and judges the cap against the largest
  actively-encoding one. This is what hid the starvation from the first read.
- **Expectation note (not a bug): Source on a branch viewer does NOT give
  1080p, by design.** Two independent caps apply — step-1 receiver-driven
  capping means a 1467x826 window gets 826p, and §9.2 deliberately excludes
  `source_quality` from SHARED branch ingests. The plan's documented optional
  refinement (move a Source-requesting viewer to a direct slot when one is
  free) is the lever if that trade should change; it is NOT implemented.
- **Lab caveat:** the underlying BWE constraint on a host→guest path that
  should be trivially fast is suspect. The bridged-VirtualBox networking is a
  known bad actor in this lab; the oscillation damping is correct regardless,
  but the *starvation itself* may not reproduce on real machines.
- VPS forwarder REDEPLOYED with the UpgradeGate (same identity, `.prev` kept).

**2026-08-15 (run 2) — watchdog CONFIRMED WORKING; Source-on-a-branch-HEAD
found to be a black-screen bug (pre-existing, now FIXED); phantom camera gone.**

- **Liveness watchdog: armed and firing.** The new one-shot diagnostic answered
  the question the first run couldn't: this build exposes ALL four counters —
  `liveness watchdog armed on 4 counter(s): responsesReceived=… requestsReceived=…
  packetsReceived=… bytesReceived=…`. `suspect-fast` fired on the sharer
  (t=687, its dead ingest leg) and on Win10 (t=689, its dead direct leg, which
  then ran the new `_rerequestDirectShare` — "Direct share leg from … died —
  re-requesting (attempt 1, receiver-initiates)"). Both new Stage-A paths
  worked end to end.
- **But the DOWNSTREAM viewer gains little in this topology, and that is
  inherent.** Win10_222's egress leg is served by Win10's ENGINE, so it stays
  healthy until that process actually dies; the leg then goes silent and the
  3 s threshold expires at almost exactly the moment libwebrtc's own consent
  check does (kill t≈691 → ICE `Disconnected` t=694 → recovered t=695, ≈4 s vs
  ≈5 s in run 1). ICE's own timing varies 3-5 s run to run, so a 3 s threshold
  sits right on its boundary. Tightening below 3 s trades that against false
  positives on a legitimately quiet pair — do it only with more counter data,
  which the armed-log now provides.
- **THE BLACK SCREEN — root-caused, and it is NOT the kill.** Toggling Source
  quality on Win10 while it was a promoted BRANCH HEAD made the sharer send it a
  fresh DIRECT offer (`Creating offer from shared stream (profile=motion)` —
  no `simulcast f+q`, single layer, 1920x1080, VP9-preferred). One second later
  Win10 logged `Receiver screen:<host> (screen_video) state:
  FrameCryptorStateDecryptionFailed`, then the heal ladder escalated
  (676 escalate=false → 686 escalate=true) and churned MLS epochs 2→4. The
  branch was dead from that moment; the leg deaths at 687/689/694 were the
  aftermath, not the kill.
  **Mechanism:** `_branchOf(peer)` matches only a branch's `viewers` set, and a
  branch HEAD is deliberately NOT in its own — its display rides the ingest
  through its own engine. So the `route=='relay'` re-watch path
  (`current != null`) never matched a head, and the head's Source re-watch fell
  through to the direct path. That new direct PC then collided with the branch
  ingest's sender cryptor on `screen:<head>` — `enableForSender` is idempotent
  per (participant, kind), so the new PC got no cryptor of its own and sent
  frames the head could not decrypt. **This is the promotion-cryptor collision
  of 2026-08-07 arriving from the opposite direction**, and it was reachable
  before this epic's §9 work by any `route=relay` re-watch from a head — Source
  is simply the easiest way to trigger it.
  **Fix:** the relay re-watch now resolves `_fwdBranches[peerId] ?? _branchOf(peerId)`,
  so a head re-offers its OWN ingest instead of falling through. With §9.2's
  gating the recomputed cap is unchanged, so the correct end state is exactly
  "a branch viewer asking for Source stays on the f layer".
- **Phantom camera: GONE** (no `Found video track without renderer` this run) —
  the `ice_restart` flag works.
- Still unverified: `ghost_left_suppressed` (needs a genuinely half-open
  socket), feeder election (needs a peer branch + VPS branch simultaneously).

**2026-08-15 — FIRST §9 FIELD RUN (host sharer + Win10 + Win10_222 with
`HOLLOW_FORCE_RELAY_ROUTE=1`, kill+restart of Win10). Recovery PASSED; the fast
-failover watchdog did NOT fire and is FIXED; the ICE repair caused a phantom
camera tile and is FIXED. Neither defect was visible without the logs.**

- **Recovery path: PASS, unchanged from phase 2.** Kill at t=931 → the client
  presence-flap tolerance correctly held the branch on the relay's (legitimate)
  peer_left → the viewer's egress leg reported `Disconnected` at t=936 → ladder
  → `direct_failed` re-watch → VPS branch → attach + `Connected` in the SAME
  second, ICE route logged at 937. **~5 s end to end, ALL of it detection.**
- **DEFECT 1 — the liveness watchdog never fired (`suspect-fast` absent from all
  three logs).** Root cause: the freshness check compared
  `lastPacketReceivedTimestamp` against `DateTime.now().millisecondsSinceEpoch`,
  but this fork reports stats timestamps in MICROseconds
  (`statsToMap`: `stats->timestamp_us()`, flutter_peerconnection.cc). The
  subtraction went hugely negative, which always satisfied "younger than the
  threshold", so the detector returned "fresh" forever. **This is exactly the
  Step 0 the plan prescribed — "verify which members m144 populates before
  writing the rule" — and skipping it cost the whole feature a field run.**
  Fixed by removing the wall-clock comparison entirely: the detector now
  fingerprints whichever inbound counters exist
  (`responsesReceived`/`requestsReceived`/`packetsReceived`/`bytesReceived`) and
  measures elapsed time on OUR clock since that fingerprint last CHANGED —
  unit-agnostic by construction. Threshold 3 s (consent runs ~2.5 s, RTCP RR
  ~1 s), so detection should land ~3-3.5 s vs libwebrtc's ~5 s. It now also
  logs ONCE which counters it armed on, and if a build exposes none it says so
  and DISABLES itself — a watchdog that silently never fires is worse than none,
  because it looks like it works.
- **DEFECT 2 — the ICE repair invented a camera tile (the "weird bug" Vitalik
  saw).** Chain, exact and log-confirmed: Win10's repair fired at t=881 →
  `restartIce()` + `_sendRenegotiationOffer` → Win10_222's `_handleRenegOffer`
  ran its post-reneg camera safety net → `Found video track without renderer for
  <Win10> — creating` → a renderer + SFrame video receiver for a camera that was
  OFF. The safety net is right for a CAMERA reneg (onTrack can stay silent when
  a transceiver is reused) but an ICE-restart re-offer changes no m-lines, so
  everything it finds is an already-idle transceiver. Fixed with an additive
  `ice_restart` flag on `vc_reneg_offer` (3-touch + serde pin test; absent =
  false = today's behaviour): the answerer skips the camera net for it.
- **The repair itself did NOT achieve direct** (`still relayed` one second
  later) even though both sides advertised host/srflx. Legitimate — two
  NAT'd VirtualBox guests may genuinely have no direct path — and the one-attempt
  budget worked as designed. Worth re-checking on real machines before judging
  the lever's value.
- **Relay ghost suppression: NOT exercised** (`ghost_left_suppressed` still 0).
  A Task-Manager kill closes the TCP socket immediately, so the relay had
  already cleaned the peer up before the restarted client authenticated — there
  was no ghost to supersede. Confirmed by the log: Win10 rejoined at t=957 and
  NO spurious peer_left followed in the next ~11 minutes. The fix is inert until
  a genuinely half-open socket survives into the successor's auth (the original
  ~85 s field shape), not broken.
- **Source-quality gating: not exercised this run** (no `source=true` watch in
  the sharer log) — still pending.
- Deployed infrastructure was live for this run: relay + VPS forwarder both on
  the new build.

**2026-08-14 (later) — §9 WORKLIST IMPLEMENTED: 5 of 6 items complete, 1 split
out with evidence. Field verification is the remaining gate.** Implementation
plan: `tmp.md` (written from a four-agent code scan of the Dart lane, the Rust
node+engine, the relay C++, and the fork's ICE/stats surface).

- **§9.2 Source-quality gating on branches — DONE.** `_effectiveCapFor` gained
  `honorSource`; `_ingestCap` sizes a SHARED ingest by displays alone. The
  half-cap layer test moved into a pure, unit-tested
  `ScreenShareService.viewerWantsLowLayer` — which exposed a BACKFIRE the plan
  had only half-anticipated: with the cap no longer honouring Source, a
  Source-requesting viewer on a SMALL display would newly satisfy
  `vLong*2 <= fLong` and be DEMOTED to the q layer, the exact opposite of the
  request. Source now pins a branch viewer to `f`. 7 new unit tests.
- **§9.4 fwd-room chatter suppression — DONE (harness-tested).** `is_forwarder_room`
  + `ensure_olm_session_and_drain` (extracted so the full path and the minimal
  path cannot drift on the signed-key-exchange rules); both presence arms skip
  the whole cascade for `fwd:` rooms while keeping the authoritative snapshot,
  the vanished purge (the embedded engine's presence tolerance depends on it)
  and Olm session establishment. **Two burn hazards found and guarded:**
  `synced_peers` is GLOBAL, not per-room (inserting on a fwd join would make a
  LATER join of a real shared room skip discovery forever), and
  `profile_broadcast_done` is a one-shot flag that a first-ever fwd RoomMembers
  would have consumed. New harness test `fwd_room_join_skips_discovery_but_keeps_olm`
  pins both, plus the drain that delivers a queued `fwd_stream_register`. Also
  gated the post-rekey `DmSyncRequest` at its single chokepoint via a structural
  `peer_is_forwarder_only` test (covers peer forwarders too, no configured-id
  lookup).
- **§9.5 Relay ghost-eviction PeerLeft — DONE.** Root cause pinned to ONE
  emitter: the SUPERSEDE path in `handle_auth` broadcasts `peer_left` for every
  room while the successor socket is authenticating. `suppress_peer_left`
  threaded through `cleanup_peer`/`leave_room` (an explicit flag, because that
  cleanup deliberately runs BEFORE `peer_sockets` is re-pointed, so a
  "is there a newer socket?" check could never fire); the room slot is still
  ERASED (memory safety — a slot pointing at a closed socket is a dangling
  pointer), only the lie is withheld. New `/server-stats` counter
  `ghost_left_suppressed`. **Drive-by bug fixed in the same file:**
  `state.peer_rooms[peer_id] = {}` sat OUTSIDE the `!is_fetch` guard, so a
  fetch-mode auth wiped a connected full node's room set — its later close then
  found nothing to leave_room and left room slots pointing at a FREED socket
  (no peer_left, dangling pointer on every later fan-out). Both TUs
  syntax-checked on the VPS in a scratch copy; NOT yet deployed.
- **§9.3 ICE "direct whenever direct is possible" — DONE for the two lanes that
  matter, two deferred.** New `services/ice_repair.dart`: one `getStats()` pass
  yields both the settled route and whether host/srflx existed on BOTH sides
  (the candidate tables enumerate both ends, so no signaling change). Lever 1
  wired on the DM call PC and the VC mesh PCs — quiescent window only, ONE
  attempt, polite-peer initiator, hard-gated off under Always-relay, verified on
  the retry ladder. **Lever 2** re-probes the watch `route` hint 10 s after the
  audio PC settles and after a successful repair, and — the load-bearing detail
  — BYPASSES `_routeHintTo`'s sticky "already assigned ⇒ relay" short-circuit,
  without which a viewer parked on the VPS branch by the race could never report
  direct and lever 2 would be dead on arrival. Sharer side needed no code: a
  fresh `route=direct fwd_capable` watch already feeds the rebalancer. Verified
  `restartIce()` is fully wired through the fork to the shipped libwebrtc; note
  `createOffer({'iceRestart': true})` is SILENTLY DROPPED on the native path
  (only the `mandatory` sub-map is read) — never use that form.
  **Deferred: lanes C (general data channels) and D (screen-share direct PCs)** —
  both lack any non-destructive re-offer path (`_handleOffer` closes and
  replaces the PC), so each needs a new wire flag plus a reuse branch; lane D's
  value is largely already captured by branches + lever 2 + the rebalancer.
- **§9.1 Parallel healing — STAGE A DONE, STAGE B SPLIT OUT WITH A HARD
  BLOCKER.** Stage A: a 1 Hz ICE-CONSENT staleness watchdog on every
  screen-lane PC (`responsesReceived`, falling back to
  `lastPacketReceivedTimestamp` — consent checks run regardless of media, so a
  static screen share is never mistaken for a dead one), two consecutive stale
  polls required, firing the lane's existing `onDisconnected` without closing
  the PC so each role keeps its own recovery. Detection drops from ~5-7 s to
  ~2.5-3.5 s against field-proven same-second recovery. Also closed the gap the
  scan found: **direct share PCs had NO disconnect handler on EITHER end** — the
  sender now frees its slot, the receiver re-requests through a new bounded
  `_rerequestDirectShare` (deliberately NOT `_fallbackToDirect`, which would
  re-watch as `direct_failed` and wrongly push the sharer down its forwarder
  ladder). **Stage B (the shadow path) is NOT built, and the reason is
  concrete:** `FrameCryptorService._receiverCryptors` is keyed
  `(participant, kind)` and `enableForReceiver` early-returns on a hit, so a
  second concurrent receiving PC for the same originator gets NO cryptor and
  renders ciphertext — "render whichever path delivers first" is unachievable
  as specced. A shadow participant LABEL would work (key material is shared —
  `rotateKey` → `setSharedKey`), but it introduces a second SFrame identity that
  BOTH re-key sweeps must learn, which is precisely the shape of field bug #6
  (an ingest leg outside the sweeps → the whole branch black). That deserves its
  own change and its own field run, not a blind sixth change in a batch.
- **§9.6 Feeder election — DONE (needs the security review it was flagged for;
  the checklist is satisfied in code, a human sign-off is not).** Wire, all
  additive + serde-pinned: `feeder` on `fwd_stream_register`, `feed_target` on
  `vc_screen_assign`, `fwd_feed` on `vc_screen_watch`, new
  `vc_screen_feed_state`. Engine: `admit_owner_op` SPLIT so `fwd_ingest_offer`
  goes through a new `admit_ingest_offer` (owner OR the owner-delegated feeder)
  while auth/unregister stay strictly owner-only — **supply, never authority** —
  with 3 new unit tests including "feeder may never administer" and "empty
  feeder is never a wildcard". A connected INGEST leg now requests a keyframe
  immediately, so the owner→feeder handover costs one keyframe instead of a
  freeze. The feed leg needed NO new engine concept: an egress leg's SendOnly
  OFFER is exactly what an ingest leg ANSWERS, so the bridge simply relabels
  `fwd_egress_offer` → `fwd_ingest_offer` for feed targets and routes it through
  the TARGET's `fwd:` room. **The allowlist direction is the easy thing to get
  backwards and it fails closed with `not_authorized`:** a feed leg is an EGRESS
  leg on the FEEDER's engine whose "viewer" is the forwarder being fed, so the
  FED forwarder goes on the FEEDER's allowlist (`admit_attach` knows nothing
  about feeds); the reverse is NOT needed, because at the fed forwarder the head
  only OFFERS an ingest, which `admit_ingest_offer` authorises via `feeder`.
  Both registers must therefore land BEFORE the feed starts — the same
  same-socket ordering rule as promotion's register-before-assign.
  Sharer policy elects a fed branch only when a peer
  branch head advertised `fwd_feed`, keeps its OWN ingest up until
  `feed_state{up:true}` (make-before-break), and reverts on a 10 s timeout or an
  `fwd_error` — which is also exactly what an OLDER VPS binary produces, so the
  rollout degrades gracefully in both directions. **v1 privacy gate, deliberately
  conservative: election is SKIPPED whenever any `relay_private` viewer rides
  the fed branch** — their downlink would still be operator infrastructure, but
  the ciphertext would TRANSIT a member's machine and the promise covers
  transit. Flip only on an explicit decision.
- **Verified:** Rust suite green (603 passed / 0 failed before the feeder work;
  full re-run at the end), forwarder-feature tests green (20/20 across dispatch
  + wire pins), `flutter analyze lib/` shows ZERO new findings (61 before and
  after — measured against a stashed baseline), widget tests 413/413 (406 + 7
  new). Relay C++ syntax-checked on the VPS.
- **INFRASTRUCTURE DEPLOYED 2026-08-15; clients + field test are the remaining
  gate.** Relay rebuilt on the VPS and restarted — `/server-stats` now carries
  `ghost_left_suppressed`, service clean (the `stop-sigterm timed out` line at
  restart is this relay's normal shutdown, pre-existing). VPS `hollow-forwarder`
  rebuilt from this tree and swapped in, **same identity**
  (`12D3KooWHtaft…fRH` — clients pin the Olm identity key, so a re-key would
  fire SecurityAlerts everywhere), previous binary kept as
  `hollow-forwarder.prev`, previous relay binary as `hollow-relay.prev`.
  Build note: the VPS's own Rust is 1.75 and the crate is edition 2024, so the
  forwarder still has to be built on the `hollowvm` Ubuntu24 VM (Rust 1.95) and
  scp'd via Windows — 2m22s with a warm cache. Deploy order used (and to reuse):
  **relay → VPS forwarder → clients**, the middle step being load-bearing
  because the forwarder must understand `feeder` before any client ships feeder
  election. The condensed field pass is §9's F-1…F-5 checklist below.

**2026-08-14 (later) — §9 FIELD PASS COMPLETE: RUNS A (×2), B, AND C ALL PASSED — PHASE 3
IS FIELD-VERIFIED AND THE EPIC'S BUILD PHASE IS CLOSED.** The re-run of A bonus-covered
the VPS rung WITH simulcast (VPS journal: both layers rid-mapped, egress serving 'f',
clean close `20521 pkts in`, engine to 0 streams) and — via an ICE-raced `route=relay`
first watch — the opportunistic REBALANCER with simulcast (`promoting … — migrating 1/1
viewer(s) off the VPS branch`, make-before-break confirmed at the VPS: viewer-retired
egress + linger unregister + the host's fwd-room routing purge). **RUN C:** Source toggle
→ `Viewer-driven cap update -> 1920x1080` → `setParameters … accepted` → readback scale
1.31→1.0 → `Encoded output: 1920x1080 … CAP APPLIED` — live encoding change on Windows,
zero renegotiation, even landing in the mid-negotiation window that used to hard-fail.
**RUN B (the last unchecked path):** VM1 re-probed `route=direct` after a VC
leave/rejoin → direct offer (the one copy); VM2's direct watch then logged `Upload
spreading: direct viewer <VM2> → <VM1> (1 direct copy running)` → `Promoted <VM1> …
(simulcast)` → `Closing screen share service` (the copy-holder's direct PC closed) →
SFrame drop+re-enable on the ingest → LAN ingest connected in 2 s: sharer at ONE ingest,
ZERO direct copies. Twice during the session a VM's VirtualBox networking went one-way
deaf (~116 s, the known two-bridged-VMs lab artifact) — the ladder + WS reconnect
recovered both times, which doubles as unplanned resilience coverage. The dry-layer
upgrade bug from run A #1 did not recur (fix compiled in, not re-exercised — watch for
`returning to layer 'f'` without f flowing in future sessions). **The fixed forwarder
binary is REDEPLOYED to the VPS (same identity, `.prev` kept). Remaining: commit, then
the §9 worklist session.**

**2026-08-14 — RUN A (of the §9 field pass): PASS on all vantage points, one bug found
and FIXED same day.** Evidence, all four logs audited: (1) *Stage 1 live on Windows:*
`setParameters(cap 1465x826@60fps) -> accepted` + params readback on BOTH the direct PC
and the 2-encoding ingest leg (readback shows both layers: `scale=2.62 maxBr=1500000 |
scale=1.31 maxBr=6000000`) — the rejection era is over. (2) *Simulcast end-to-end:*
`Promoted … (simulcast)` → `Creating offer … simulcast f+q` → f 1465x826@1500-6000kbps +
q 732x413@500-1500kbps → `Codec preference: video/VP8 > …` → VM1's engine mapped BOTH
layers by rid (`ingest layer 'q' mapped (ssrc …)` / `'f' mapped`), `PT map … Vp8 exact`,
both egress legs `serving layer 'f'` (correct — both displays exceed q), per-layer PLIs
(`via layer ssrc`), SFrame `FrameCryptorStateOk` at every hop, zero decrypt failures.
(3) *The key routing proof:* VM2's audio path to the sharer was TURN, yet its forwarder
leg connected DIRECT (`local=srflx remote=host`) — "relay-routed" viewers ride peer
branches off-relay; **VPS journal: zero entries for the whole run.** (4) *Dry-layer
fallback fired FOR REAL:* ~25 s in, the f layer starved (BWE/static-content — the
allocator protects q by design) → both legs logged `layer 'f' dry — falling back to 'q'`
→ keyframe → `serving layer 'q'` with the picture CONTINUING (make-before-break at the
packet level — no freeze). (5) *Kill ladder:* VM1 killed → host presence tolerance held →
media-leg death +6 s → same-second `screen_offer` revert → VM2 re-rendered in ~1 s.
**THE BUG (fixed):** one second after the fallback, both legs logged `returning to layer
'f'` while f was still dead — the upgrade-home check read a stale `ideal_flowing_since`
(it only resets when an ideal-layer packet ARRIVES after a gap; a fully dry layer never
resets it), flipping desire back to a dead layer and nagging upstream PLIs. Fix: the
upgrade now also requires the ideal layer to be FRESH (seen <1 s ago). Harm was bounded
by construction (make-before-break kept q flowing) but it defeated the 5 s hysteresis.
Rust suite re-green; Windows Release rebuilt with the fix — **runs B/C must use the
rebuilt Release on all three machines; redeploy the VPS binary once the field session
settles** (same bounded bug is in the deployed engine).

**2026-08-08 — PHASE 3 IMPLEMENTED (setParameters root cause → simulcast → upload
spreading). Field verification = the remaining gate; then the epic closes.**

- **Stage 1 — the Windows live-`setParameters` rejection, ROOT-CAUSED + FIXED (plugin
  C++ only, no DLL rebuild).** The chain, proven in source: (1) the wrapper's encoding
  getters collapse unset optionals (`scalability_mode()` = `value_or("")`, `ssrc()` =
  `value_or(0)`, bitrates/framerate = `value_or(0)`); (2) `rtpParametersToMap`
  (flutter_peerconnection.cc) serialized them unconditionally, so Dart's cached
  `sender.parameters` carried `scalabilityMode: ""` / `ssrc: 0` as NON-NULL; (3)
  `toMap()` sent them back and `updateRtpParameters` wrote them onto the fresh native
  params — flipping `std::nullopt` into `Some("")`/`Some(0)`; (4) m144's
  `CheckScalabilityModeValues` finds no codec supporting mode `""` →
  `INVALID_MODIFICATION` → the WHOLE call fails (`media_engine.cc`; pre-negotiation the
  `ssrc 0 ≠ nullopt` "modified SSRC" check fires first). One bug, both historical eras
  explained: before the 2026-07-19 `set_encodings` write-back fix the poisoned copies
  were DISCARDED (setParameters returned true but was a silent no-op); the write-back
  made the poison arrive (every call false since). Fix: the native→Dart map skips
  sentinel values (unset stays null — rid added to the map while there, needed for
  simulcast readback), and the write-back path (a) NEVER writes rid/ssrc (read-only on
  a live sender — the fresh GetParameters copy already holds them), (b) skips empty
  scalabilityMode / non-positive bitrates/framerate/temporal-layers. The
  `updateResolutionCap` renegotiate-on-false fallback STAYS as the belt. Field check:
  toggle Source quality on a Windows sender → `[HOLLOW-SCREEN] setParameters(cap …) ->
  accepted` + readback + "CAP APPLIED".
- **Stage 2 — simulcast on forwarder ingest legs (packet selection, no re-encode).**
  - Sharer: ingest legs offer TWO rid layers — `q` (half per axis, ITS resolution's
    bitrate tier) FIRST (libwebrtc's rate allocator protects encodings[0] under
    congestion — the low layer is the one that must survive) + `f` (the branch cap).
    Simulcast legs are VP8-constrained (`_applyScreenCodecPreference(vp8Only:)`) —
    the engine's switch rewrite is VP8-descriptor-only and VP8 is the lane's
    field-proven codec. Per-viewer direct PCs are UNTOUCHED (step-1 capping already
    serves them; no rids there).
  - Wire: `fwd_stream_register` gains `#[serde(default, skip_serializing_if empty)]
    low_viewers` (viewers the engine should serve the q layer — computed by the sharer:
    q covers their effective cap, i.e. `viewer_long × 2 ≤ f_long`; refreshed on every
    register, applied at ATTACH time). `vc_screen_watch` gains `fwd_simulcast` —
    a peer forwarder only gets a simulcast ingest if its watch advertised the flag
    (an OLD embedded engine would fan BOTH layers' interleaved packets down one egress
    SSRC = garbage on every viewer; the VPS forwarder is assumed capable — DEPLOY IT
    FIRST). Old wire bytes pinned by new serde tests.
  - Engine (`forwarder/simulcast.rs` + leg/stream/engine): the ingest pump resolves
    each SSRC's rid ONCE (header ext, then str0m's Mid+Rid mapping — the ext stops
    arriving after RTCP establishes the SSRC) and tags every fanned packet; egress legs
    run a pure `LayerSelect` state machine — rid-less sources pass through
    BYTE-IDENTICAL to phase 1/2 (zero regression by construction); layered sources
    forward exactly one layer with seq/ts continuity offsets and VP8
    PictureID/TL0PICIDX/KEYIDX rewrite via str0m's `Vp8Patch` on switches; switches
    happen ONLY on the target layer's keyframe start (make-before-break: the old layer
    flows until then). PLI plumbing is per-layer end to end (egress asks for ITS
    layer; the stream's aggregator coalesces per rid; the ingest resolves the rid's
    SSRC, falling back to every seen source). Pump policy: dry-layer fallback (wanted
    layer dry >2.5 s while another flows — e.g. libwebrtc disabled a layer under CPU
    pressure — ride what flows) + upgrade-home hysteresis (ideal layer flowing ≥5 s).
    7 unit tests pin the state machine (passthrough byte-identity, keyframe-gated
    switch + offset continuity, continuation-packet refusal, non-VP8 layer lock,
    15-bit PictureID wrap, late-rid adoption).
  - Viewer side: ZERO changes — a branch viewer receives one ordinary stream. Old
    viewers keep working unchanged.
- **Stage 3 — upload spreading (the closing policy).** Direct step-3-capable viewers
  past `maxDirectShareCopies` (=1, soft) are served through branches:
  `_pickSpreadTargetFor` = existing peer branch w/ capacity → promote a fwd-capable
  direct watcher, PREFERRING one that already holds a direct copy (its copy closes on
  promotion — strictly fewer encodes), then the viewer ITSELF (self-promotion: its
  display rides its own engine; `_assignViewerToForwarder` keeps the head OUT of
  `branch.viewers` and skips the duplicate assign), then any other capable watcher →
  an ALREADY-SERVING VPS branch (zero marginal upload) — NEVER a fresh VPS branch for
  a STUN-capable viewer (that would trade zero relay bytes for `B + B·k` relay while
  saving nothing on the first viewer; the viewer falls through to a direct PC, capped
  by the old 15). A spread viewer's cap-change re-watch stays on its branch
  (`_reofferIngest` refreshes the register's low set + live-updates the ingest cap —
  stage 1 makes that a real live update now). relay_private honored throughout; the
  failed-forwarder memory + 2-failure ladder bound apply as everywhere. With this the
  sharer's copies = `maxDirectShareCopies` + one ingest per branch — 5 viewers ≈ 2
  encodes ≈ the §2e "10-20 Mbps instead of 50" row — and the 15-viewer cap is
  effectively dynamic.
- **Deferred from phase 3 (needs its own session): feeder election** — a peer branch
  feeding the VPS forwarder's ingest so the mixed-branch case drops from 2 sharer
  copies to 1. Sketch: the owner's register names a delegated `feeder`; the VPS admits
  the ingest OFFER from that feeder (today `admit_owner_op` binds ingest to the owner —
  the relaxation is a SECURITY surface and wants its own review); the peer engine
  grows an "egress leg toward another forwarder" (its SendOnly offer IS
  SDP-compatible with the VPS's ingest accept), signaled by the host client over the
  existing `fwd:{vps}` room. Keyframes compose by construction (VPS PLI → peer egress
  leg → peer kf_tx → sharer).
- **Verified:** Rust suite green with `--features forwarder` (26 forwarder-filtered
  incl. the new simulcast + wire tests; full suite run below), `flutter analyze` clean
  on touched files (3 pre-existing infos), widget tests 406/406, plugin C++ compiled
  via full `flutter build windows` debug.
- **Field checklist (next VM session):**
  1. *Stage 1:* Windows sender, toggle Source quality mid-share → `setParameters …
     accepted`, readback scale changes, `CAP APPLIED`, NO re-offer line.
  2. *Simulcast VPS rung:* forced-relay viewer through the VPS → VPS journal shows
     `ingest layer 'q' mapped (ssrc …)` + `ingest layer 'f' mapped (ssrc …)`, egress
     `serving layer 'f'` (or 'q' for a small/low viewer); picture ~1 s; SFrame Ok.
  3. *Low viewer:* a viewer whose display ≤ half the branch cap → register carries it
     in `low_viewers`, its egress logs `serving layer 'q'`, its received-resolution
     chip reads ~half the cap; egress kbps visibly below the f viewer's.
  4. *Layer resilience:* CPU-load the sharer (or drop the f layer) → f viewers' legs
     log `layer 'f' dry — falling back to 'q'` with picture continuing (one keyframe
     blink), then `returning to layer 'f'` when it recovers.
  5. *Spreading:* THREE direct viewers (host + 2 VMs, all direct routes) → viewer 1
     direct PC; viewer 2 (fwd-capable) `Upload spreading: … own branch
     (self-promotion)`; viewer 3 assigned to viewer 2's branch. Sharer logs exactly
     ONE direct offer + ONE ingest offer; relay media 0.
  6. *Old-client guard:* an old-build viewer (route empty) always gets a direct PC;
     an old-build peer forwarder (no `fwd_simulcast`) gets a SINGLE-layer ingest
     (`Creating offer from shared stream (profile=…)` without `simulcast f+q`).

**2026-08-07 (follow-up session) — THE PRE-PHASE-3 TRIO DONE: self-ghost VC participant
fixed, inbound Olm decrypt-fail path fully logged, opportunistic rebalancer built.**

- **Self-ghost VC participant — ROOT-CAUSED AND FIXED.** The own-join path was the ONE
  remaining master-form insertion into the device-keyed VC participant set:
  `handle_voice_channel_join` inserted + emitted `local_peer_str` (the MASTER) while Dart's
  `onLocalJoined` self-skip compared the DEVICE id (changed by the 2026-07-15 glare-election
  fix) — so every client dialed its own master as a remote participant ("Creating offer for
  peer <own master>", audio cryptors minted for it, and one "Encryption failed: No session"
  per trickled ICE candidate). Fix, in id-form-guessing-proof layers: (1) SELF is now
  DEVICE-keyed like every remote entry (insert + both own join/leave emits + every self
  membership/exclusion compare in swarm.rs/voice_handler.rs — Disconnected retain, reconnect
  re-broadcast, auto-leave, conference reply-on-join, gossip-neighbor exclusion); (2)
  `VoiceChannelJoined/Left` gained `is_self: bool` set by the RUST handler that knows —
  Dart's event_provider branches on the flag and NEVER compares ids (the whole bug class was
  Dart guessing which id form means "me"); (3) belts: `handle_voice_channel_send_signal`
  DROPS self-targeted signals loudly (either id form — kills the No-session storm class at
  the chokepoint; sibling devices have distinct device ids and are never blocked), inbound
  join/leave self-echo guards match both forms, `onPeerJoinedMyChannel` refuses to dial
  self, and the Dart set-iteration guards (`onLocalJoined`/`onModeChanged`) skip both forms.
  New harness test `vc_self_participant_is_device_keyed_no_self_dial` runs nodes with
  device≠master seeds (the existing VC tests use identical seeds and could never catch the
  mixup) and pins: own join/leave = device id + is_self, remote view device-keyed +
  !is_self, self-targeted signal dropped before Olm with no MessageSendFailed.
- **Inbound Olm decrypt-fail path — sender-tagged logging at every silent death site** (the
  evening blackhole was only diagnosable from log ABSENCE on both ends). swarm.rs live
  path: entry frames that fail UTF-8/HavenMessage parse now log with sender + size (0x05/
  0x06/0x08 payloads are always HavenMessage JSON — binary chunks ride 0x02/BinaryDirect,
  so this can't spam); base64-decode fail; PreKey-missing-identity-key; the silent
  prekey-with-existing fallthrough; the both-paths-failed PreKey drop now ALWAYS logs (the
  re-key stays cooldown-gated — a burst used to go completely dark); and the big one — a
  DECRYPTED envelope failing MessageEnvelope parse was silently MISROUTED into the
  legacy-raw-text-DM fallback (version skew's exact signature): it now logs sender + size +
  error when the payload looks like JSON. fetch.rs (push/offline) got the same treatment on
  both its lanes; the MLS post-decrypt parse-fail log gained group + sender leaf + size.
  The VPS forwarder's identity-free logs are BY DESIGN (zero-metadata doctrine) — untouched.
- **Opportunistic rebalancer (the run-4 watch-ORDER gap) — BUILT.** New sharer-side hook in
  `_handleScreenWatch`: a fresh `route=direct fwd_capable` watch arriving while the VPS
  infra branch carries viewers promotes that watcher and migrates the branch's viewers onto
  the new peer branch (`_maybeRebalanceOntoCandidate`) — sharer upload 2 copies → 1, relay
  media → 0, one blink per migrated viewer. Invariants honored: `relay_private` viewers
  never leave operator infra (they stay on the VPS branch), per-viewer failed-forwarder
  memory respected, peer cap = 3 remote legs (overflow stays), no chains (branch
  heads/branch riders are not candidates). Migration is MAKE-BEFORE-BREAK: viewers are only
  removed from the VPS branch LOCALLY (no eager `fwd_stream_auth` removal — the VPS killing
  the old egress leg before the assign lands would read as a branch failure and
  permanently fail-mark the fresh candidate); the viewer retires its own VPS leg on assign
  receipt, and the emptied branch's 30 s linger unregisters the stream. Viewer side gained
  the two missing reassignment pieces: forwarder→forwarder assigns now RELEASE the old
  forwarder's room (a lingering fwd-room membership is the stale-room routing-blackhole
  shape; own room excluded — bridge-owned) and arm the 20 s no-show watchdog (extracted
  `_armWatchNoShowTimer`, shared with the revert path) since the old leg is already retired
  when the new attach can silently die.
- **Verified:** new harness test + full Rust suite green (601/601), `flutter analyze` clean
  for the touched files, widget tests 406/406.
- **FIELD-VERIFIED 2026-08-08 (Vitalik's run, all four vantage points audited — FULL PASS).**
  Topology: host sharer + Win10 (bridged, direct fwd-capable) + Win10_222
  (`HOLLOW_FORCE_RELAY_ROUTE=1`). The logs, in order:
  1. *Rebalance:* Win10_222 watched FIRST (`route=relay fwd_capable=true`) → VPS branch
     (ingest 1152x720, `Forwarder leg local=srflx`); Win10's `route=direct` watch then hit
     `Opportunistic rebalance: promoting … — migrating 1/1 viewer(s) off the VPS branch` →
     `Promoted` → LAN ingest (`local=host remote=host`). Win10's embedded engine brought up
     ingest + 2 egress legs (own display + Win10_222) ICE-connected in ~1 s with PLI/keyframe
     flow; Win10_222's reassign logged `Left room fwd:<VPS> — purged its peer snapshot` (the
     new fwd→fwd cleanup) and re-rendered the SAME second (the observed single blink);
     SFrame receiver cryptor `FrameCryptorStateOk` at every hop — the promotion-cryptor fix
     held through a real migration, zero DecryptionFailed/MissingKey anywhere.
  2. *Make-before-break confirmed at the VPS:* its egress leg ended by ICE disconnect (the
     VIEWER retiring it), NOT an auth kill; the host's 30 s linger `fwd_stream_unregister`
     landed to the second (`stream closed: 2256 pkts`), engine settled at 0 streams / 0 kbps
     — relay media = ZERO while the peer branch served. Forwarder-side presence tolerance
     also fired en route ("presence drop for a viewer ignored — its egress leg is alive").
  3. *Kill ladder:* Win10 killed via task manager → host presence tolerance held the branch
     (2 ignored drops) → media leg died +7 s → SAME-SECOND revert: `screen_assign{''}` +
     direct offer + Win10_222's answer + `Left room fwd:<Win10>` purge; Win10_222 rendered
     the host's direct track immediately (its observed ~5 s freeze = the tolerance window).
     No `direct_failed`, no ladder engagement — the sharer-catches fast path won.
  4. *Self-ghost fix live:* ZERO "Creating offer for peer <own id>" on any machine, zero
     "No session"/Encryption-failed storms; remote dials all device-keyed. The send-belt
     visibly caught the ONE residual self-iteration — the broadcast-class state fans
     (`_broadcastAudioState/ScreenState/CameraState` compared only the master form) logged
     `DROPPED self-targeted audio_state/screen_state` on all three machines; all three fans
     now skip both id forms (fixed same day, working tree), so those lines disappear next
     build. Relay day counters: `fwd_delivered=1193, fwd_buffered=0, send_dropped=0`.
  5. *Second run (same day) — REPEATED PASS, two extra behaviors exercised.* (i) Win10's
     first watch probed `route=relay` (a genuine ICE race: its call PC paired via TURN
     despite direct being possible) → the rebalancer correctly did NOT fire and BOTH
     viewers rode the VPS branch — which incidentally re-measured the headline `1 stream,
     3 legs, ingest ~364 / egress ~729 kbps` = 2×ingest at k=2. Vitalik's leave/rejoin
     refreshed the probe (`route=direct`) → promotion + 1/1 migration + blink, as designed.
     (ii) The kill recovered via the VIEWER-initiated ladder this time: Win10_222's egress
     leg-death detection (t+6 s) beat the host's ingest-death by one log line — `Forwarder
     leg … disconnected — walking the fallback ladder` → `direct_failed` re-watch → next
     rung = VPS (correct for a relay-hint viewer; the host's revert then found an empty
     branch = no-op). The VPS re-register + egress leg came up within 1 s and the branch
     linger was cancelled 5 s before firing (the quick-re-watch design paying off). Which
     recovery wins (sharer-catches direct vs viewer-ladder rung) is a legitimate race —
     both endings render, SFrame Ok at every hop in both runs.

**APPROVED FOLLOW-UP PAIR (Vitalik, 2026-08-08) — "direct whenever direct is possible":
ICE detect-and-repair.** 100% STUN is impossible (symmetric NATs / UDP-hostile firewalls
are TURN's reason to exist), but TURN winning the NOMINATION RACE when a direct pair was
viable is repairable — libwebrtc nominates whichever pair completes its check first (TURN's
pre-warmed allocation needs no hole punch, so it often wins by one RTT) and then NEVER
migrates on its own. Two levers, app-level only (no fork ICE surgery):
1. **Quiescent ICE-restart repair, ALL WebRTC lanes** (calls, VC audio, camera, screen
   share, data channels/Share): when a PC settles on a relay pair while host/srflx
   candidates exist on BOTH sides, schedule ONE ICE restart shortly after — the re-check
   runs on a warmed network and the hole punch nearly always wins. ICE restart is
   make-before-break (media/data keep flowing on the old pair until the new one connects),
   but per Vitalik's constraint the restart must wait for a QUIESCENT window — never
   mid-transfer on a data channel, never during an active renegotiation; the reneg-glare
   rules (`_queueRenegOffer`) cover the offer mechanics. One attempt, then accept TURN.
2. **Forwarder-lane route re-probe:** the `vc_screen_watch` route hint is probed ONCE — a
   direct-capable watcher TURNed by the race stays `route=relay` forever (run-2 field
   evidence: the manual leave/rejoin was exactly this refresh done by hand). Auto re-send
   the watch with a fresh hint when the audio PC's selected route changes (or ~10 s after
   connect); the opportunistic rebalancer then promotes without user action. Rides existing
   idempotent machinery. Lever 1 makes this rarer; lever 2 catches what remains.

**2026-08-07 (later session) — SFRAME JOIN-ORDER EPOCH RACE FIXED (the runs-2 black-screen
follow-up, its own session as planned). Root mechanism, confirmed by code audit: MLS commits
ride ONE unbuffered `0x03` room broadcast (never cached client- or relay-side — the relay's
catch-up rings tee only `0x07` topic frames), and EVERY stale-group recovery trigger keyed on
`has_group`/leaf-missing — a present-but-stale group was undetectable (`swarm.rs`'s
RoomMembers arm short-circuits on `has_group`; the decrypt-fail → SyncRequest path needs an
inbound MLS ciphertext, which a voice-only channel never carries; no plaintext signal carried
an epoch anywhere). So the last VC joiner missed the join-churn commits, exported a stale
SFrame key, and sat on MissingKey until the Dart ladder's escalated re-bootstrap (~14-16 s;
on a thrashed group the re-bootstraps themselves failed → permanent).**

- **The fix is pull-based catch-up, NOT repair-by-more-commits** (an escalation remove+re-add
  bumps the epoch for everyone — exactly the churn spiral that wrecked the long-lived test
  server, epochs 39→47 in an afternoon). Three layers:
  1. **Commit cache:** `MlsManager.commit_cache` — last 8 broadcast/applied commit frames per
     group, RAM-only (fed in `broadcast_mls_commit` + the shared commit-apply path).
  2. **Detection = epoch hints:** `#[serde(default)] mls_epoch` on the plaintext first-contact
     `SyncRequest` (PeerJoined + RoomMembers + decrypt-fail + post-Welcome sites), plus a new
     plaintext `MlsEpochProbe` fired at VC join (`emit_vc_sframe_key` has_group branch — which
     previously exported a stale key BLIND) and from `voice_sframe_heal(escalate:false)` —
     turning heal step 2 from a no-op re-emit into the cure. Dart belt: receiver
     `MissingKey` fires the cheap heal immediately (5 s/peer throttle) instead of waiting
     ~6 s for ladder step 2 (`MissingKey` on a receiver = "a slot I don't hold" = the race
     signature; the key ring is additive so nothing else produces it on a live stream).
  3. **Repair = `MlsCommitCatchup` replay:** the group AUTHORITY (owner-preferred; subgroup
     coordinator for restricted channels; lowest-master fallback) answers a stale hint with
     the cached commit frames, ascending — the stale member marches to the current epoch in
     ~1 RTT with ZERO new commits; the owner's epoch never moves. Cache can't bridge →
     falls back to the existing remove+re-add (KeyPackageRequest → batch timer → Welcome).
- **Security posture:** hints can NEVER drop a group (that would be a remote group-reset
  primitive — a spoofed-high hint achieves one throttled probe, nothing else); catch-up
  ingest is member-gated, revalidated frame-by-frame through the SAME `handle_mls_commit_frame`
  path as live commits (extracted from the swarm arm, so parity is by construction), and each
  frame must be exactly `own_epoch + 1` — a gapped/garbage frame is refused before it can
  even reach the drop-group recovery. 10 s per-(group,peer) cooldowns both directions.
  Write-gates wiki updated (§5).
- **Wire compat:** all additive (`#[serde(default)]` + skip_serializing_if — old-wire bytes
  pinned by serde tests); old clients parse-drop the two new variants and simply keep
  today's behavior.
- **Verified:** 3 new multi-node harness tests (new `MockRelay::set_broadcast_deaf` lever —
  models the relay's silent backpressure drop on a healthy-looking socket, the exact field
  loss mode): heal-probe, VC-join-probe, and reconnect first-contact-hint paths each
  converge the stale node to the owner's epoch **with the owner's epoch unchanged**
  (replay, not re-add) — 3/3 in 42 s. Plus commit-cache unit tests (contiguity refusal,
  cap/dedup/clear) and 5 wire-pin serde tests. Full suite + analyze clean.
- **Field re-check for the next VM session:** fresh server, 3 participants, VM2 joins the VC
  LAST during join churn — expect picture in ~1 s (previously 5-10 s), and the host journal
  showing `MlsEpochProbe` → `Serving commit catch-up` instead of HEAL escalations.
- **SAME-DAY FIELD RE-RUNS (Vitalik, all logs audited from all four vantage points):**
  (1) *Settled-server re-run:* peer rung didn't engage (ICE race → both viewers honestly
  `route=relay` → VPS branch; killing VM1 removed a parallel viewer, so "no blink on VM2" =
  correct), kill handled cleanly, `egress = 2×ingest` at k=2 again, both presence-drop
  tolerances held, `fwd_delivered` 357→469 / `fwd_buffered=0` / `send_dropped=0`; probes
  fired at every VC join and correctly no-op'd (settled epoch 8 — the race can't occur).
  (2) *Fresh-server run with a REAL promotion (route=direct watch → `Promoted`):* kill
  ladder full pass (presence tolerance → media-leg death +6 s → `direct_failed` → VPS rung,
  picture back ≈1 s — the 5 s freeze is the ICE death window). **But BOTH viewers went black
  10-15 s at the PROMOTION itself — and the logs prove it was NOT the epoch race** (both VMs
  probed epoch 2 = the host's own epoch; the catch-up correctly had nothing to serve).
  **SECOND ROOT CAUSE of the black-screen family, now FIXED: the promotion cryptor
  collision.** The branch ingest's sender cryptor is keyed `'screen:<forwarderId>'` — the
  SAME (participant, kind) as the direct per-viewer PC to that peer. `enableForSender` is
  idempotent per that key, so `_ensureIngestLeg`'s enable NO-OP'd against the direct PC's
  cryptor, and the promotion then closed that PC + `_dropShareCryptors` — leaving the ingest
  sender UNTRANSFORMED: the branch carried plaintext, both downstream viewers (the
  forwarder's own display + the relay-routed viewer) hit `DecryptionFailed`, and nothing
  healed it until VM1's ladder ESCALATED (~14 s) — the group surgery's epoch bump re-ran the
  fix-#6 sweep, which is what re-keyed the ingest. Viewer-side heals can never reach a
  host-side missing sender. The VPS branch never collides (the infra forwarder was never a
  viewer), which is why phase-1/D6 never saw it, and the evening runs were masked by
  coincident epoch churn re-running the sweep. Fix: after the promotion's direct-PC close +
  cryptor drop, re-enable SFrame on the branch ingest (drop+re-enable rule) in
  `_assignViewerToForwarder`. Field re-verify: promotion should now show pictures in ~1 s on
  both viewers with NO heal lines; the media plane is outside harness coverage by
  construction.
- **PROMOTION CRYPTOR FIX FIELD-VERIFIED same evening** (host log 19:54: `Promoted` →
  `Sender encryption enabled for screen:<forwarder>` firing right after the direct-PC
  close; VM2 rendered through the peer branch immediately — the 10-15 s black is gone).
- **THE TARGETED-SIGNAL BLACKHOLE — ROOT-CAUSED AND FIXED (the evening's two wedges, and
  the failed revert after killing the promoted forwarder).** Nothing ever removed a room
  from `ws_room_peers` when WE left it (only Disconnected clears and PeerLeft prunes) — so
  after a viewer's `fwd:` room detach, the room's FROZEN member snapshot (still listing the
  sharer) stayed in the routing table forever, and `ws_room_for_peer`'s first-match could
  route every later targeted send into it → the relay drops sender-not-in-room directs →
  silent one-way loss until app restart. Field signature, three hits in one evening: Win10's
  9 vanished `screen_watch`es across 3 servers right after its VPS-branch detach
  ("Connecting to screen share..." forever); VM2's vanished `direct_failed` re-watch AND
  `screen_answer` one second after its `fwd:` detach at the kill (black screen instead of
  the revert — the host's direct offer sat at `Connecting` with the answer lost). Fix: the
  ws client now emits `WsEvent::LeftRoom` when the Leave frame goes out (the relay never
  echoes our own leave) and the swarm purges the room's snapshot; MockRelay mirrors it. The
  fwd rooms' join/leave churn is what made phase 2 the first heavy user of this path.
- **Remaining new bug (own session): self-ghost VC participant** — BOTH the host and Win10
  dial their OWN MASTER identity as a remote VC participant ("Creating offer for peer
  <own master>" + endless "Encryption failed: No session" storms; the host even built
  cryptors for its own master) — a master id is leaking into the VC participant set where
  only routable DEVICE ids belong. Log-storm + wasted PCs; not media-blocking.
  Also still worthwhile: sender-tagged logging on the inbound Olm decrypt-fail path (the
  receive side stayed silent throughout — the blackhole was only diagnosable from the
  absence of logs on both ends).

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

## 8. Where this lands: phase 3 closes the epic, and the tree becomes Hollow Streaming

**PHASE 3 IMPLEMENTED 2026-08-08 (see the top §7 entry) — field verification is the
remaining gate. Feeder election deferred to its own session (security-surface change
on the engine's ingest admission).**

**Phase 3 (the closing move):** STUN viewers feeding OTHER STUN viewers —
the sharer sends 1-2 copies total and the tree spreads the rest (§2e's "A feeds the room"
rows: 5 viewers at 4K ≈ 10-20 Mbps sharer upload instead of 50). Build order stands:
(1) root-cause the Windows live `setParameters` rejection in the fork; (2) simulcast
(2-3 `sendEncodings` layers, per-viewer quality by PACKET SELECTION — no re-encode
anywhere; without it one slow viewer drags its whole branch's single encode down);
(3) the sharer-side spreading policy (assign direct viewers to branches past an upload
threshold, feeder election so a peer branch can feed the VPS forwarder too) — which makes
the 15-viewer cap DYNAMIC and closes the epic. All transport machinery (branches,
promotion/demotion, the opportunistic rebalancer, the ladder, attribution, the engine)
already exists and is field-verified — phase 3 is simulcast + policy, no new transport.

**The broadcast consequence (Vitalik's framing, 2026-08-08): this IS Hollow Streaming.**
The forwarding contract deliberately keys on `(originator, stream id, kind)` and never on
"originator is in the viewer mesh" (§5.7), so the same tree serves a STREAMER whose
audience is arbitrarily large: the streamer uploads ONE copy (or one per simulcast layer),
fwd-capable viewers become branches serving 2-3 downstream legs each, branches feed
branches (phase-3 spreading), the VPS forwarder is only the reliability floor for
restricted-NAT pockets — and SFrame keeps it end-to-end encrypted THROUGH every hop, with
attribution/consent keyed on the originator. That is collectively-hosted live streaming
with no ingest server, no CDN, and no content-holding authority: the relay philosophy
(availability helper, never authority) applied to a live audience. Conference "broadcast
mode" (wiki `conferences`, deferred phase 2+) becomes a policy switch on this same tree.
The ICE direct-when-possible repair pair (§7) multiplies the tree's quality — every
race-TURNed viewer repaired to direct is one more potential branch and one less relay
dependency. Deep-dive design (viewer counts, layer ladders, join storms, moderation
surface) = its own plan session once phase 3 lands.

## 9. WORKLIST — IMPLEMENTED 2026-08-14 (see the top §7 entry for what each item
## actually became); FIELD VERIFICATION IS THE REMAINING GATE

**Status: 5 of 6 done, 1 split out.** Items 1(Stage A)/2/3/4/5 and 6 are
implemented and test-green; item 1's Stage B (shadow path) is split out with a
concrete blocker (SFrame receiver cryptors are keyed per (participant, kind), so
a concurrent shadow PC gets no cryptor — see §7). ICE repair covers the call and
VC-mesh lanes; the data-channel and screen-share lanes are deferred.

**Field pass for the next VM session (3 machines: host + VM1 bridged +
VM2 `HOLLOW_FORCE_RELAY_ROUTE=1`; rebuilt Release everywhere; deploy relay →
VPS forwarder → clients FIRST):**

- **F-1 (fast failover):** promotion topology from run 2b, then kill VM1's app.
  Expect `suspect-fast` in the viewer/sharer log within ~2-3 s (vs the old ~5-7),
  then the existing same-second recovery. Also pause a VM's network <2 s and
  confirm NO teardown (the 2-consecutive-stale guard).
- **F-2 (Source gating):** a branch viewer toggles Source → sharer logs NO
  ingest re-offer, the branch cap does not move, that viewer stays on layer `f`;
  a DIRECT viewer's Source toggle still lifts to source resolution.
- **F-3 (ICE repair):** with Always-relay OFF on both sides, force/await a TURN
  nomination → expect ONE `[HOLLOW-ICE-REPAIR]` attempt, a flip to direct, then
  lever 2's automatic re-watch and promotion with NO manual leave/rejoin. A
  forced-relay client must log NO repair attempt at all.
- **F-4 (chatter + relay, log-reading):** VPS journal shows fwd-room joins
  WITHOUT the ~45-frame discovery burst; `/server-stats` shows
  `ghost_left_suppressed` incrementing on an app kill+restart while clients log
  NO `Presence drop … ignored` lines (there is nothing left to tolerate).
- **F-5 (feeder election):** host shares; VM1 = peer head (fwd_feed), VM2
  forced-relay → VPS branch. Expect `Feeder election: delegating …` → VM1 logs
  `Elected as FEEDER` → `feed leg into … admitted` → host logs `Feed to … is up
  — closing our own ingest there` and ends with exactly ONE
  `Creating offer from shared stream`; the VPS journal shows the ingest arriving
  from VM1's identity. Kill VM1 → host resumes its own VPS ingest. Then repeat
  with VM2 under Always-relay → election must be SKIPPED entirely.

Original worklist text (for reference):

## 9-original. NEXT-SESSION WORKLIST (gathered 2026-08-14 per Vitalik — "do them all and that's it")

**Gate first: the phase-3 field pass** (full checklist = §7 top entry; condensed to three
runs, ~20-30 min): **Run A** = repeat run 2b (host shares, VM1 bridged direct
fwd-capable, VM2 `HOLLOW_FORCE_RELAY_ROUTE=1`) — regression for promotion + kill ladder,
PLUS the new lines: sharer `Creating offer from shared stream (… simulcast f+q)`, VM1
engine `ingest layer 'f' mapped` + `ingest layer 'q' mapped`, egress `serving layer 'f'`.
To see the q layer served, shrink one VM's display below half the branch cap (≤960 px
wide at a 1080p cap, e.g. 800x600) → its register lands in `low_viewers`, its leg logs
`serving layer 'q'`. **Run B** (the genuinely new behavior) = THREE direct viewers (no
force-relay env anywhere): viewer 1 → direct PC; viewer 2 → `Upload spreading: … own
branch (self-promotion)`; viewer 3 → assigned to viewer 2's branch; sharer logs exactly
ONE direct offer + ONE ingest offer, VPS journal flat zero. **Run C** (30 s) = toggle
Source quality on a Windows sender mid-share → `setParameters … accepted` + readback +
`CAP APPLIED`, NO re-offer line. All three machines need THIS build (scp flow); the VPS
forwarder already runs the new engine (deployed 2026-08-14, `.prev` kept).

Then the worklist, one session:

1. **Parallel healing / fast failover (NEW 2026-08-14).** The ~5-7 s crash freeze is
   DETECTION (ICE death), not recovery (recovery is same-second, field-proven). Shrink to
   ~1-2 s: early-suspicion signal = RTCP receiver-report / ICE-consent staleness — NEVER
   media-byte silence (a static screen share is legitimately quiet) — then MAKE-BEFORE-BREAK
   recovery: request the next rung / direct offer while the suspect leg stays up, render
   whichever path delivers a frame first, kill the loser. Attribution keys on the
   originator, so a delivery-path swap under a live tile is a pure transport change.
   Planned teardowns (demotion / migration / rebalance) are already make-before-break —
   this extends the same doctrine to crashes.
2. **Source-quality gating on branches (approved direction 2026-08-14).** Exclude the
   `source_quality` flag from BRANCH cap math (`_ingestCap` must stop honoring it via
   `_effectiveCapFor`; sizing by displays only) — one pixel-peeper must not inflate a
   shared branch/VPS ingest to 4K on everyone else's bandwidth. Source stays honored on
   direct per-viewer PCs (sharer-pays-only, consenting pair). v1: a branch viewer
   requesting Source simply stays on the f layer; moving them to a direct slot when one
   is free = optional refinement.
3. **ICE "direct whenever direct is possible" repair pair** (approved 2026-08-08, full
   spec in §7): (a) quiescent-window ICE-restart on ALL WebRTC lanes when relay was
   nominated while host/srflx existed both sides (one attempt, never mid-transfer/reneg);
   (b) forwarder-lane watch route re-probe on ICE-route change → feeds the opportunistic
   rebalancer automatically.
4. **fwd-room chatter suppression:** suppress the PeerJoined discovery cascade toward
   `fwd:` room peers (~45 junk frames per join at the forwarder; pure noise).
5. **Relay-side ghost-eviction PeerLeft suppression** (client + forwarder tolerance
   shipped; the relay-side counterpart closes the class).
6. **Feeder election** (design sketch in the 2026-08-08 §7 entry): owner-delegated
   `feeder` field on the register + engine ingest-admission relaxation (**needs its own
   security review** — the one place the owner≡ingest binding loosens) + a peer-engine
   egress leg toward another forwarder. The largest item — do last, or split out if the
   session runs long.

After the worklist: commit/release, then the **Hollow Streaming / broadcast-mode plan
session** (§8).
