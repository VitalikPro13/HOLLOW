# Harness Coverage Map — what the multi-node harness can/can't verify

**Purpose:** the authoritative line between *Claude's job* (green harness → you real-test → push) and
*Vitalik's job* (manual / Tier-2). Derived from the real `NodeCommand` + `NetworkEvent` surface in
`rust/hollow_core/src/node/types.rs` (every command = a thing the app can drive). Updated 2026-06-19.

## The three rings (the dividing line is "pure in-process Rust state" vs "depends on something outside")

- **Ring 1 — distributed-logic core.** Pure Rust state machines over the mock relay. **Harness can own
  this almost completely.** This is where ~every multi-device bug lived (the ones that ate debugging
  time because they're invisible until you cross-reference devices' internal state).
- **Ring 2 — transport-dependent.** WebRTC media, file/shard P2P, vault, recovery pool, the real relay.
  **Harness can drive the CONTROL/SIGNALING plane, NOT the media/data plane.** Partial by nature.
- **Ring 3 — platform & presentation.** Flutter UI, FFI bridge, native push/keychain/app-lock/installer,
  per-OS quirks, the real relay C++. **Harness covers ~none.** Tier-2 (run app + logs + screenshots) +
  Vitalik manual.

Coverage tags below: ✅ full (driveable + inspectable in-process) · ◐ partial (control/signaling only,
media/data plane stubbed) · ✗ out of harness scope.

---

## RING 1 — Claude owns this (target: ✅ across the board)

| Feature area | Commands (examples) | Cover | Notes |
|---|---|---|---|
| DM messaging | `SendMessage`, `EditDmMessage`, `DeleteDmMessage`, `AddDmReaction` | ✅ | direction/`is_mine`, sig, dedup, edits/deletes/reactions all DB-inspectable |
| DM sync / backfill | (reconnect flow) `DmSyncRequest` both-directions | ✅ | **PoC test green.** sibling + peer-fallback + inversion guard |
| Friends | `SendFriendRequest`, `Accept/Reject`, `RemoveFriend`, by-nickname | ✅ | friends table + sibling friend-sync; nickname resolution is a relay RAM map → mock it |
| Profiles | `UpdateProfile`, `ProfileUpdated` | ✅ | profile rows; avatar/banner blobs are bytes in DB |
| Typing | `SendTypingIndicator`, `TypingStarted` | ✅ | event-level; device→master collapse assertable |
| Presence / online | (relay room membership) | ✅ | **inspector built** — `online_identities`/`is_online` read from authoritative relay |
| Servers (CRDT) | `CreateServer`, `Rename`, `DeleteServer`, `UpdateServerSetting` | ✅ | CRDT state in DB; **member_panel inspector built** |
| Channels | `CreateChannel`, `Remove/Rename`, layout, `SetChannelPublic` | ✅ | channel CRUD + public-channel branch |
| Server join/sync | `JoinServer`, snapshot-on-join, op-log persistence | ✅ | the CRDT-sync-persistence class of bug; snapshot vs op-log replay |
| Roles / perms / bans | `ChangeRole`, `ChangeRolePermissions`, `Ban/Unban`, `KickMember` | ✅ | role chokepoint (`get_role`) already collapses device→master |
| Labels / nicknames | `CreateLabel`, `AssignLabel`, `SetNickname`, `SetTwitchUsername` | ✅ | CRDT cosmetic layer |
| Pins | `PinMessage`, `UnpinMessage` | ✅ | CRDT |
| Channel messaging | `SendChannelMessage`, edit/delete/react, `RequestChannelSync` | ◐→✅ | **rung 2 of build** — needs live-MLS inspector (`DebugSnapshot`) for cross-device decrypt assert |
| MLS group lifecycle | (join/leave drives MLS add/remove), `MlsEpochChanged` | ◐→✅ | **rung 2** — device-leaf membership + epoch via `DebugSnapshot`; the device-vs-master invariant |
| Public channels (guest) | `RequestPublicChannels`, `RequestPublicChannelSync`, `LeaveGuestRoom` | ✅ | plaintext path, guest sync |
| Device linking | `RequestLinkSnapshot`, `AcceptLinkPush`, link-code | ◐ | **rung 3** — snapshot transfer reuses backup pipeline; the .hollow blob streams as a `LinkSnapshot` (data-plane-ish but in-process buffer works) |
| Device revocation | `RevokeDevice`, `SelfRevoked`, ghost fan-out | ✅ | **rung 3** — tombstone propagation, Olm/MLS cutoff, ghost (room-presence) fan-out all state-level |
| Invisible / presence | `SetInvisible` | ✅ | |
| Olm key exchange | (implicit) `KeyExchange*`, glare | ✅ | **glare fixed this session**; session status needs `DebugSnapshot` (Olm lives in event loop) |

---

## RING 2 — Claude owns the CONTROL plane, Vitalik owns the MEDIA/DATA plane

| Feature area | Commands | Cover | What's covered vs not |
|---|---|---|---|
| 1:1 calls (voice/video) | `CallSendSignal`, `CallSignal` | ◐ | **CAN:** assert call-signal types are whitelisted + routed to the right peer/identity, offer/answer/ICE-candidate envelopes reach the target, glare/renegotiation ROUTING. **CANNOT:** actual audio/video, SFrame, real ICE/DTLS, codec negotiation, the "iOS cold-VideoToolbox first call" class — those need real libwebrtc + media tracks. |
| Voice channels | `VoiceChannelJoin/Leave/SendSignal`, gossip mode | ◐ | same split: participant-set state + signal routing ✅; the SFU/gossip media mixing ✗ |
| File transfer (DM) | `RequestFile`, `WebRtcSendFile`, FileHeader | ◐ | **CAN:** file-request handshake, FileHeader envelope, the header-vs-bytes race LOGIC, offline-image inline path, sig promotion. **CANNOT:** the actual WebRTC data-channel byte transfer (no data channels in-process). Mock can deliver a `BinaryDirect` to simulate arrival. |
| Vault (erasure shards) | `VaultDownloadFile`, `StoreShardOnPeer`, `RequestShardFromPeer` | ◐ | **CAN:** shard assignment logic, k/m selection, store/request envelopes, reconstruction math (pure). **CANNOT:** the cross-peer WebRTC shard stream. |
| Recovery pool | `RecoveryPool*` events, assignment | ◐ | **CAN:** pool membership, inventory exchange, assignment algorithm, reconstruction trigger logic. **CANNOT:** actual shard streaming between peers. |
| Hollow Share (P2P) | `ShareManifestRequest`, `ShareChunkRequest`, seeding | ◐ | **CAN:** manifest/have/chunk-request envelope routing, bitmap logic. **CANNOT:** real chunk transfer over data channels. |
| SQLCipher DB | (all persistence) | ◐ | **CAN:** real SQLCipher runs in-harness — schema, CRDT/message/crypto persistence, dedup, migrations are EXERCISED. **CANNOT:** platform-specific failure modes (iOS WAL/App-Group `0xdead10cc`, DPAPI). |

**The honest rung-2 value:** I can catch *signaling/control/state* bugs (wrong target, dropped offer,
unwhitelisted signal type, bad shard assignment, header race, persistence corruption) — the stuff that's
invisible without cross-referencing two peers. I can NOT catch *media/data-plane* bugs (no audio, black
camera, ICE failure, real byte-transfer stalls) — those you see/hear immediately and test manually.

---

## RING 3 — Vitalik owns this (harness ✗, by nature)

| Area | Why out of scope |
|---|---|
| Flutter UI (widgets, providers, layout, animations, design system, mobile/desktop shells) | harness asserts the Rust state *behind* the UI is correct, never that a widget renders/wires it. A provider reading the right value into the wrong widget is invisible. → Tier-2: run app + logs + `flutter drive` screenshots |
| FFI bridge (`flutter_rust_bridge` codegen, Dart↔Rust marshalling) | harness runs pure Rust, never crosses the bridge |
| Real relay (uWS C++) | harness uses a *mock*; mock fidelity is an assumption (we found+fixed a gap this session). Real backpressure/topic-routing/TLS/license/offline-caps → live-smoke only |
| Push notifications (FCM/APNS, NSE, App Group, collapse-id) | OS push services + native extensions |
| Identity-at-rest (keychain/DPAPI/Argon2 launch gate), app lock (PIN/biometric) | OS-native secure storage + local_auth |
| Screen capture/share, window mgmt, annotation | native Graphics Capture / ScreenCaptureKit / window_manager |
| Installer, code signing, auto-updater | platform packaging |
| WebRTC media plane (audio/video/screen pixels, SFrame, ICE/TURN/DTLS) | real libwebrtc + network; see ring 2 |

---

## The build ladder (where we are)

1. ✅ **Inspectors (rung 1 foundation)** — UI-layer + raw-layer state readers. DONE 2026-06-19.
2. **Servers + channels + MLS (rung 1 completion + first ring-2 touch)** — create/join/channel-send,
   cross-device decrypt, `DebugSnapshot` command for live MLS/Olm in-memory state. ← NEXT
3. **Device lifecycle (rung 1)** — link sibling, revoke, ghost cutoff.
4. **Ring-2 control plane** — call/VC signal routing, file-request handshake, shard assignment,
   recovery-pool logic — each driven + asserted at the envelope/state level, media/data plane stubbed.

When the harness is green, the claim is precisely: **"the distributed-logic core + the control/signaling
plane behave correctly across N devices."** Not "the whole app works." Voice audio, pixels, push, and the
real relay stay Vitalik's manual pass — by design, because those fail visibly and immediately.
