# Media Forwarding Plan — Resolution Capping, Originator Attribution, SFrame Packet Forwarders

**Design session 2026-08-05 (Vitalik + Claude); steps 2–3 planned + started same day — see §7 for
live status. Step 1 COMPLETE (shipped + field-verified). Step 2 IMPLEMENTED (harness-green). The
str0m forwarder spike PASSED all 5 acceptance criteria in a live host→VM field test — GO for the
forwarder build. Approved implementation plan (D1–D6): `~/.claude/plans/pure-doodling-cupcake.md`.**
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

### Step 3 — The forwarder role (the epic; needs RTP-layer access in our libwebrtc fork)

- Packet-level relay of SFrame ciphertext RTP; forwarders never decrypt, never re-encode.
- Viewer-peer forwarders first: fanout of 2–3 per forwarder covers dozens of viewers at one extra hop.
- Infra peer on the VPS as the reliability floor and the restricted-NAT answer (replaces TURN for shares
  at `B + B·k` instead of `2·B·k`), and later the backbone of conference **broadcast mode**.
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
| D3 | Forwarder module in hollow_core + headless `hollow-forwarder` bin + systemd deploy | next session |
| D4 | Relay `get_media_forwarder` discovery + client plumbing | with D3 |
| D5 | Client integration: route hint, `vc_screen_assign`, attach flow, fallback ladder | after D3+D4 |
| D6 | Field verification (forced-relay VM viewer through the VPS forwarder) + this report updated | release gate |

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
