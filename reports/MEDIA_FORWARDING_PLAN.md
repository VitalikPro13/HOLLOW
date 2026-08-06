# Media Forwarding Plan — Resolution Capping, Originator Attribution, SFrame Packet Forwarders

**STATUS 2026-08-06: STEP 3 PHASE 1 IS COMPLETE AND FIELD-VERIFIED.** Step 1 (resolution capping)
shipped; step 2 (originator attribution) shipped; step 3 phase 1 (the infra forwarder — D3 module +
bin + VPS deploy, D4 relay discovery, D5 client integration, D6 field verification) all DONE — see
§6 for the deliverable table and §7 for the status log incl. the D6 evidence and the five bugs the
field found. A live screen share now traverses the VPS forwarder end to end: one encode on the
sharer, blind packet relay, SFrame decrypting under the ORIGINATOR's key on a hop that never holds
it, picture in ~1 s.
**NEXT SESSION = PHASE 2: viewer-peer forwarders** (same crate embedded in the app; STUN-reachable
peers with spare upload serve the TURN-only peers, so the relay carries ZERO media in the common
case). Policy already decided: ON by default + Settings toggle, desktop only, never mobile/metered,
2–3 downstream legs. Then phase 3 = simulcast (prerequisite: root-cause the Windows live
`setParameters` rejection), then the 15-viewer cap goes dynamic.
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
- Viewer-peer forwarders = **PHASE 2, next session**: same crate embedded in the app (their own
  display = downstream viewer #0 over a localhost leg); fanout of 2–3 per forwarder covers dozens
  of viewers at one extra hop; ON by default + Settings toggle, desktop only, never mobile/metered.
  This is the step that takes the relay's media cost to ZERO in the common case.
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

Then phase 2 (peer forwarders, same crate embedded in-app) → phase 3 (simulcast) → dynamic
removal of the 15-viewer cap.

## 7. Status log

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
