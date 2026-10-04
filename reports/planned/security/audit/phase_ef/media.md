# Phase E+F slice "media": calls, voice channels, meeting media, screen share, the forwarder lane, TURN

Session 34, merged phase E (STRIDE, RFC 9605 checklist, 13 classes) and phase F (WP9 code
review). Code read in the detached worktree `D:/dev/wt/s34-ef` at `aa104d48`. The libwebrtc
frame cryptor was read in the desktop build tree `D:/libwebrtc-build/src` (webrtc-sdk m144
branch at `aaeeee8`, `api/crypto/` and `libwebrtc/src/rtc_frame_cryptor_impl.*` unmodified
by our two patches, `git status` clean there) and cross-checked against the webrtc-sdk
`m144_release` head on GitHub (same `makeIv` and ratchet code). Nothing was built or run: every
verdict comes from reading code, and CPU figures are estimates.

Paths: Rust relative to `rust/hollow_core/src/`, Dart `lib/...`, relay `relay-uws/...`, the
fork `packages/flutter_webrtc/...`, libwebrtc as `libwebrtc:<path>` (= `D:/libwebrtc-build/src/<path>`).

## Scope

- Elements
  - P1 media signalling in E-02: `node/voice_handler.rs`, `node/call_book.rs`, the CallSignal
    and VoiceChannel* arms of `node/swarm.rs`, Dart `call_provider.dart`,
    `voice_channel_provider.dart`, `voice_channel_service.dart`, `voice_service.dart`.
  - P2 the SFrame layer: `lib/src/core/services/frame_cryptor_service.dart` over libwebrtc's
    `FrameCryptorTransformer` / `DefaultKeyProviderImpl` (desktop: our build; Android
    `io.github.webrtc-sdk:android:144.7559.01`; iOS/macOS `WebRTC-SDK 144.7559.09`).
  - P3 the media forwarder: standalone `forwarder/*.rs` (relay box) and the embedded peer
    forwarder `node/embedded_forwarder.rs`.
  - P4 media side of E-03: `screen_audio_capturer` (render, encode, pipe modes), ffmpeg as a
    decoder of peer media.
  - DS1 SFrame key material in RAM (Dart `_sframeKeys` cache, the KeyProvider's 16-slot ring).
- Flows: F-40 (call and VC signalling, `screen_watch`), F-41 (DTLS-SRTP + SFrame media), F-42
  (forwarder lane `fwd:{id}`), F-43 (screen-share audio, `0x03` type byte on the WebRTC data
  channel, not the relay opcode), F-44 (TURN credentials).
- Interactors: X-3 peers as call participants, TURN (coturn on the relay host).
- Specs: RFC 9605 (SFrame), every obligation that falls on the application.
- Leads: L-01 (verdict below), plus the AR-03 confirmation it asks for.

## Summary

- STRIDE cells walked: 46 (4 processes x 6, 1 store x 3, 5 flows x 3, 2 interactors x 2).
- Candidates: 8, Medium 4 (C-MEDIA-01..04), Low 4 (C-MEDIA-05..08), plus 6 Info notes.
- Requirements: 26 (R-MEDIA-01..26), 7 NOT met today (R-MEDIA-07, -13, -14, -15, -20, -23, -24).
- L-01: SAFE. Nonce uniqueness holds; no fix is required for it. The SFrame layer has other
  real problems (C-MEDIA-02, -03, -06) that the L-01 reading turned up.
- AR-03: the code matches the accepted risk and allows less than it says (mesh attribution is
  per connection, so forging needs a forwarding role).
- Release-relevant, in order: C-MEDIA-01 (a kicked or banned member stays in the voice call;
  WP 6.1 promises the opposite; the meeting twin was fixed as HOL-SEC-123), C-MEDIA-02 (one
  line of Dart removes a remote CPU and memory exhaustion), C-MEDIA-04 (HOL-SEC-040 variant:
  "Always relay calls" does not hide our address from a meeting knocker), C-MEDIA-03.

## Candidates (most severe first)

### C-MEDIA-01: A member who is kicked, banned, or loses sight of a restricted voice channel stays in the call: everyone keeps hearing and seeing it, and it keeps hearing screen-share audio

- Severity: Medium (Impact M: moderation does not reach the voice channel, share audio sent
  after the removal reaches the removed device; Exploitability M: a modified client that
  ignores its own removal. Bounded to the 60 s door keep window on 0.12 servers whose join lock
  is on the relay, since the relay then hides the device and `PeerLeft` prunes it; unbounded on
  legacy 32-hex servers, after a lock record eviction (AR-16), and for a member who only lost a
  restricted channel's label or grant, because that moves no door).
- Attacker: P-06 (kicked or banned member, or a member that lost a label/grant); P-08 (a device
  its roster removed, server-group side).
- Confidence: CONFIRMED. Every write that removes from `voice_channel_participants` was found
  by Grep and read: our own disconnect (`node/swarm.rs:3611-3614`), relay `PeerLeft` /
  `RoomMembers` (`node/swarm.rs:4179`), a received or our own leave (`node/voice_handler.rs:1268`,
  `:1920`), meetings only (`node/conference.rs:437/479/565/1096/1117`). Dart has no
  membership-driven `closePeer` (`MemberLeft` only invalidates the member list,
  `lib/src/core/providers/event_provider.dart:647-661`).
- Code: a removal of another member emits only `MemberLeft`:
  `rust/hollow_core/src/node/swarm.rs:6933` `CrdtPayload::MemberRemoved { peer_id } => {` ...
  `:6949` `let _ = event_tx.send(NetworkEvent::MemberLeft {`
  The only voice reaction to such ops leaves OUR seat, never anyone else's:
  `rust/hollow_core/src/node/voice_handler.rs:1321-1322`
  ```
  !s.is_member(local_peer_str)
      || (s.channel_uses_subgroup(cid) && !s.can_see_channel(local_peer_str, cid))
  ```
  The meeting fix states exactly why this matters, and exists for meetings only:
  `rust/hollow_core/src/node/conference.rs:803` `/// Devices in a meeting's call that hold no leaf in its group any more leave the call as`
  (continues: "if they had left the room, so Dart closes their peer: their old SFrame key stays
  in every key ring"). Receivers decrypt with the slot the frame names
  (`libwebrtc:api/crypto/frame_crypto_transformer.cc:636` `uint8_t key_index = frame_trailer[1];`)
  out of a 16-slot ring (`lib/src/core/services/frame_cryptor_service.dart:78` `keyRingSize: 16,`),
  so the removed device's frames under the old epoch keep decrypting.
  Its `screen_watch` is still admitted (Rust checks only the participant set,
  `node/voice_handler.rs:2215`), then `lib/src/core/providers/voice_channel_provider.dart:2321`
  `_watchers.add(peerId);` and per-viewer share audio goes out on the data channel without
  SFrame (`voice_channel_provider.dart:1987` `webrtc.sendScreenAudio(peerId, packet);`, WP 6.8).
- Why it breaks a claim: C-17 ("bans are enforced by every receiving client"), C-14 (a removed
  member reads nothing sent after removal: share audio is content), WP 6.1 ("the
  now-unauthorized member is dropped from the call"), matrix row media:A-MED-03's policy ("a
  seat only for a member who can see that voice channel") holds at join time only. Voice and
  video sent after the epoch rotation stay unreadable to it (rotation works), except C-MEDIA-06.
- Test: harness, the server twin of `authz_a_device_out_of_the_meeting_group_loses_its_call_for_good`:
  owner A, members B and M in one voice channel; A kicks M while M is deaf to the op (and a
  second case: A removes the label that lets M see a restricted voice channel). Assert A and B
  emit `VoiceChannelLeft` for M and refuse M's later `vc_screen_watch` and SDP. RED today.
- Fix: Rust, one helper next to `auto_leave_invisible_voice_channels`: after any op that
  `affects_subgroups`, after an MLS commit that removes leaves, and when the resolver moves,
  drop every device for which `voice_join_refusal(...)` is `Some` or `mls_authority::refused`
  holds, with the `VoiceChannelLeft` a room departure emits (Dart's `closePeer` then closes the
  connection, its cryptors and its share-audio target). Defence in depth (Dart): after each
  rotation, overwrite the previous epoch's slot with random bytes after a short grace, so an
  old-epoch sender stops decrypting even where an eviction is missed.

### C-MEDIA-02: Any call participant, or the media forwarder, can pin a CPU core of every receiver and grow its memory without bound, with frames that fail to decrypt

- Severity: Medium (Impact M: a frozen or out-of-memory client, phones worst, for as long as
  the call lasts; Exploitability H: a modified client sets a wrong key on its own sender; any
  member of an open server can sit in its voice channel; the infra forwarder only has to
  rewrite payload bytes of a share it carries).
- Attacker: P-05 (voice channel participant, meeting guest), P-04 (DM call), P-10 (forwarder).
- Confidence: CONFIRMED by reading the libwebrtc source and the option plumbing on every
  platform. The CPU cost is an estimate (33 PBKDF2 runs per frame, below), not a measurement.
- Code: the options: `lib/src/core/services/frame_cryptor_service.dart:76-77`
  ```
  ratchetWindowSize: 16,
  failureTolerance: -1, // unlimited
  ```
  On a failed decrypt the receiver tries 16 ratchets, each two key derivations, then derives
  the original key again:
  `libwebrtc:api/crypto/frame_crypto_transformer.cc:717-725`
  ```
  while (ratchet_count < key_provider_->options().ratchet_window_size) {
    ratchet_count++;
    ...
    auto new_material = key_handler->RatchetKeyMaterial(currentKeyMaterial);
    ratcheted_key_set = key_handler->DeriveKeys(
        new_material, key_provider_->options().ratchet_salt, 128);
  ```
  and every derivation is PBKDF2 with 100,000 iterations
  (`frame_crypto_transformer.cc:277-278` `if (PKCS5_PBKDF2_HMAC((const char*)raw_key.data(), raw_key.size(), salt.data(), salt.size(), 100000, EVP_sha256(),`),
  the default on desktop because our plugin never passes `keyDerivationAlgorithm`
  (`packages/flutter_webrtc/common/cpp/src/flutter_frame_cryptor.cc:324-362` parses no such key;
  `libwebrtc:libwebrtc/include/rtc_frame_cryptor.h:42` `key_derivation_algorithm(KeyDerivationAlgorithm::kPBKDF2) {}`)
  and on mobile (`webrtc_interface-1.5.1/lib/src/frame_cryptor.dart:26`
  `this.keyDerivationAlgorithm = KeyDerivationAlgorithm.kPBKDF2,`). With tolerance -1 the
  early-out never fires (`frame_crypto_transformer.h:208-210` returns false before counting,
  so `frame_crypto_transformer.cc:666` `if (last_dec_error_ == kDecryptionFailed && !key_handler->HasValidKey()) {`
  is never true). Every frame is queued with no bound (`frame_crypto_transformer.cc:435-437`
  `thread_->PostTask([frame = std::move(frame), this]() mutable { decryptFrame(std::move(frame));`).
  One failed frame therefore costs 33 PBKDF2-HMAC-SHA256 runs of 100,000 iterations, about
  3.3 million HMACs (order of a second on a desktop core, several on a phone), against 50
  audio and 30 video frames a second. A frame only has to end in `[12, k]` with slot `k`
  holding a key, which the forwarder reads off any genuine frame's trailer.
  The same derivation runs once per participant handler under the provider mutex at every
  rotation (`frame_crypto_transformer.h:241-256`), stalling all media for that time; a member
  who can force epoch changes can repeat it.
- Why: a remote unbounded allocation and CPU exhaustion of a client (in scope per the brief),
  AS-11. Honest key skew (the epoch races the heal ladder exists for) pays the same cost, which
  is worth knowing for the media stalls the memories describe.
- Test: native, not the harness. Cheapest guard: a source scan in `test/` that
  `frame_cryptor_service.dart` sets `ratchetWindowSize: 0`, plus a fork cryptor unit test that a
  frame with a wrong tag returns after one AEAD open.
- Fix: Dart, one line: `ratchetWindowSize: 0`. Hollow never ratchets (keys change through
  `rotateKey`; Grep finds no `ratchetKey`/`ratchetSharedKey` call in `lib/`), and with 0 the
  whole ratchet block is skipped (`frame_crypto_transformer.cc:716` `if (key_provider_->options().ratchet_window_size > 0) {`).
  Optional later (all clients at once, a 0.12-style clean break): make the desktop plugin pass
  `keyDerivationAlgorithm` and use `kHKDF` everywhere, which removes the rotation stall. Plugin
  change only, no libwebrtc rebuild.

### C-MEDIA-03: The relay operator's forwarder reads a screen share in clear when the sharer holds no SFrame key, and a keyless viewer shows whatever the forwarder sends

- Severity: Medium (Impact H for that share against P-01/P-10: C-21 promises the forwarder
  ciphertext only; Exploitability L-M: needs a keyless sharer, i.e. no MLS group or subgroup key
  yet (a new joiner whose Welcome is late, which a hostile relay can arrange by holding it; a
  group dropped for repair; the "MLS-less server" the code names) and a forwarder route (a
  viewer with "Always relay calls" on, a relay-routed viewer, a peer-forwarder branch)).
- Attacker: P-01 / P-10 (the operator runs the infra forwarder); P-10 for the viewer half.
- Confidence: CONFIRMED for the code path (no SFrame precondition on forwarder routing, the
  ingest leg, or the egress attach); SUSPECTED for how often a voice participant is keyless.
- Code: the keyless rule, by design, on both sides:
  `lib/src/core/providers/voice_channel_provider.dart:4465-4471`
  ```
  // No key material (MLS-less server): leave the share PC untransformed on
  // BOTH sides. A keyless sender cryptor silently DROPS every frame, and a
  // one-sided enable was the asymmetry behind issue #27.
  if (!frameCryptor.isEnabled) {
    debugPrint('[HOLLOW-VC] No SFrame key yet — share PC stays untransformed (peer=$peerId)');
    return;
  }
  ```
  The ingest leg calls it and offers anyway (`voice_channel_provider.dart:2988` `if (service.pc != null && _service?.frameCryptor != null) {`,
  then `fwd_ingest_offer` at `:3000`); `_assignViewerToForwarder` (`:2786`) checks no key;
  the viewer's egress attach goes through the same helper (`:2176`), so a keyless viewer has no
  receiver cryptor and renders plaintext. Sender and receiver also pass frames in clear while a
  cryptor exists but is disabled (`frame_cryptor_service.dart:79` `discardFrameWhenCryptorNotReady: false,`).
- Why: C-21 and secure-coding rule 6 (absent means reject). On a direct per-viewer leg the
  same keyless share is still protected end to end by DTLS-SRTP; only the forwarder, which
  terminates DTLS, gains.
- Test: Dart unit test on a routing predicate: no viewer is assigned to a forwarder, no ingest
  leg is offered and no `fwd_egress_offer` is attached while the frame cryptor holds no key.
- Fix: Dart only. Gate `_assignViewerToForwarder`, `_ensureIngestLeg`, feeder delegation and
  `_handleFwdEgressOffer` on `frameCryptor.isEnabled`, falling back to direct. Do not rely on
  `discardFrameWhenCryptorNotReady` (Info I-3: desktop libwebrtc does not copy that flag).

### C-MEDIA-04: A stranger in a room with us learns our public and LAN addresses from a Share-lane answer, even with "Always relay calls" on (HOL-SEC-040 variant)

- Severity: Medium (Impact M privacy: host candidates carry LAN addresses, server-reflexive
  ones the public address, and the setting whose job is hiding them is bypassed; Exploitability
  M: any room where a stranger is visible to us and our reply routes back: a meeting's `conf:`
  room for anyone holding the link, knockers included (meetings stay open, AR-16); a legacy
  server room for anyone with its id; a server with a public channel for anyone who knows a
  device id (heard route, `node/swarm.rs:5121-5128`); any Share room).
- Attacker: P-03.
- Confidence: CONFIRMED (Rust gate, Dart answer path, reply routing via
  `send_room_for_peer`, `node/crypto_handler.rs:2071-2076`); not run.
- Code: the Rust gate is the block list only:
  `rust/hollow_core/src/node/swarm.rs:13614-13620`
  ```
  // BLOCK GUARD: same as RtcOffer — a blocked identity can't open a
  // data channel to us, Share lane included. Siblings exempt.
  if !super::resolver::same_identity(peer_str, master_peer_str)
      && super::blocklist::is_blocked(peer_str)
  {
      return;
  }
  ```
  HOL-SEC-040 left this lane out on purpose: `node/voice_handler.rs:53-54`
  `/// us (our inbox is open to anyone) never gets one (J1). Share links keep their` /
  `/// own lane and are not gated here.` Dart answers every Share offer from a fresh STUN-only
  connection: `lib/src/core/services/webrtc_service.dart:848`
  `lane == _Lane.share ? _shareConfigFor(peerId) : iceServers;`, a config that by rule never
  follows Always relay (`lib/src/core/providers/ice_config_provider.dart:115`
  `/// "Always relay calls" is ON. NEVER add TURN or an \`iceTransportPolicy\` here.`).
- Why: class 13; the Always-relay contract ("the peer only ever sees the TURN address",
  `ice_config_provider.dart:61-64`); matrix media:A-MED-08 already noted "no AR entry names this,
  worth a policy line".
- Test: harness, next to `authz_room_presence_alone_opens_no_channel_to_us`: a stranger in a
  meeting room sends `RtcShareOffer` to a seated participant; assert no `share_offer`
  `WebRtcSignal` is emitted. RED today.
- Fix: Rust: answer a Share-lane offer only when `data_channel_peer_allowed` holds or the frame
  arrived in a share room we serve (frames are room-bound, so the room is known at dispatch).
  Dart: while Always relay is on, refuse Share-lane answers (the lane must stay off TURN, so the
  honest answer is none), and say so in the setting's copy. Or accept it as an AR with that copy.

### C-MEDIA-05: With libwebrtc logging widened for a diagnosis run, every SFrame key is written to hollow_debug.log

- Severity: Low (Impact M: the raw MLS-exported media secret and the derived AES key for every
  rotation, in the log users are asked to send to support; Exploitability L: needs
  `HOLLOW_WEBRTC_LOG=info` or `verbose`, desktop only).
- Attacker: P-09, and whoever receives a support log (C-37 names support channels).
- Confidence: CONFIRMED.
- Code: `libwebrtc:api/crypto/frame_crypto_transformer.cc:284-287`
  ```
  RTC_LOG(LS_INFO) << "raw_key "
                   << to_uint8_list(raw_key.data(), raw_key.size()) << " len "
                   << raw_key.size() << " slat << "
                   << to_uint8_list(salt.data(), salt.size()) << " len "
  ```
  (continues with `derived_key`), run on every `setSharedKey`/`rotateKey`. The Dart sink takes
  that severity from the environment and writes each line to the debug log:
  `lib/src/core/services/webrtc_native_log.dart:32`
  `final severity = Platform.environment['HOLLOW_WEBRTC_LOG'] ?? 'warning';` then
  `.logFromDart(message: '[WEBRTC-NATIVE] $line')` (`:27-28`); the stderr sink does
  the same (`packages/flutter_webrtc/common/cpp/src/flutter_webrtc_base.cc:43-45`).
- Why: C-37 ("Logs never contain ... keys").
- Test: Dart unit test that the native-log filter drops a sample `derived_key` line.
- Fix: drop native lines containing `derived_key` in both sinks (Dart listener and
  `InstallStderrLogSink`). No libwebrtc rebuild.

### C-MEDIA-06: A camera turned on in a voice channel, or sent to a peer who joins later, is encrypted under key slot 0, which can hold an older epoch's key

- Severity: Low (Impact M only together with C-MEDIA-01: a removed member still in the mesh
  that held that older epoch reads the camera; alone: a black camera for 2-4 s until the heal
  ladder re-indexes, when slot 0 is empty; Exploitability L: the voice session must have crossed
  an epoch that is a multiple of 16).
- Attacker: P-06 with C-MEDIA-01.
- Confidence: CONFIRMED by reading (every video sender path traced:
  `voice_channel_service.dart:415, 454, 1145, 1458, 1647`).
- Code: the video sender helper never sets the index, unlike its audio twin (`:580`):
  `lib/src/core/services/voice_channel_service.dart:635-641`
  ```
  Future<void> _enableSframeSenderVideo(String peerId, RTCPeerConnection pc) async {
    if (frameCryptor == null || !frameCryptor!.isEnabled) return;
    try {
      final senders = await pc.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind == 'video') {
          await frameCryptor!.enableForSender(peerId, sender, kind: 'video');
  ```
  A new cryptor starts at index 0 (`libwebrtc:libwebrtc/src/rtc_frame_cryptor_impl.cc:42`
  `key_index_(0),`) and is enabled before any index is set
  (`frame_cryptor_service.dart:140` `await cryptor.setEnabled(true);`); the sender encrypts with
  its own index (`frame_crypto_transformer.cc:498` `auto key_set = key_handler->GetKeySet(key_index_);`).
  Audio and share cryptors have the same few-millisecond window before
  `setKeyIndexForPeer`; video keeps it until the next rotation.
- Why: R-MEDIA-13; WP 6.6 ("The key index is explicitly set per peer after every cryptor creation").
- Test: Dart unit test with a fake cryptor factory: a cryptor created after `rotateKey(5, k)`
  carries index 5 before its first `setEnabled(true)`.
- Fix: in `FrameCryptorService._enableForSenderUnlocked` / `_enableForReceiverUnlocked`, call
  `setKeyIndex(currentKeyIndex)` before `setEnabled(true)`. Kills the class in one place.

### C-MEDIA-07: A sharer can turn a viewer's share audio back up, a deafened viewer included

- Severity: Low (Impact L: the sharer already chooses what plays; it overrides the viewer's
  own volume and deafen for share audio; Exploitability H for a sharer the victim watches).
- Attacker: P-05 or P-04 whose share the victim watches (`acceptsShareAudioFrom`).
- Confidence: CONFIRMED (desktop; mobile decodes in Rust and has no control frames).
- Code: remote packets reach the render exe unfiltered, `[seq][opus]` as received:
  `lib/src/core/services/screen_audio_renderer.dart:153-157`
  `void pushPacket(Uint8List packet) {` ... `final payloadLen = packet.length;`; the exe treats
  that seq as a control marker:
  `packages/flutter_webrtc/test_apps/screen_audio_test/main.cpp:1058` `if (seq == 0xFFFFFFFFu) {`
  ... `:1064` `gain_target = g;`. Deafen and volume ride the same frame
  (`lib/src/core/services/share_audio_level.dart:110` `if (_deafened) return 0.0;`,
  `:115` `static void _push() => _receiver?.setGain(_target);`), and an unchanged gain is never
  resent (`screen_audio_renderer.dart:129` `if (clamped == _gain && _active) return;`), so the
  sharer's value sticks.
- Test: Dart unit test: `pushPacket` drops a packet whose first four bytes are `FF FF FF FF`.
- Fix: drop such packets (and anything over 4004 bytes) in `pushPacket`, or move control to
  its own pipe.

### C-MEDIA-08: DM call camera video and gossip-forwarded voice-channel audio carry no SFrame layer, although WP 6.3 says they do

- Severity: Low (Impact L: DTLS-SRTP is still end to end, its fingerprints ride Olm
  (`CallSignal`) or MLS/Olm (VC), so relay and TURN still see ciphertext and C-21 holds; the
  defence in depth is missing, and a removed member still in the mesh (C-MEDIA-01) that is a
  gossip neighbour hears forwarded audio; Exploitability L).
- Confidence: CONFIRMED by reading; SUSPECTED whether gossip-forwarded tracks ever flow (no
  renegotiation follows the `addTrack`).
- Code: the DM call keys audio only:
  `lib/src/core/services/voice_service.dart:1336-1339`
  ```
  for (final sender in senders) {
    if (sender.track?.kind == 'audio') {
      await _frameCryptor!.enableForSender(peerId, sender);
      break;
  ```
  and the camera is added with no cryptor (`voice_service.dart:671`
  `await _pc!.addTrack(videoTrack, _localVideoStream!);`); `_frameCryptor` has no video call
  site in the file. Gossip forwarding re-sends a decoded track on a new sender with no cryptor:
  `lib/src/core/services/voice_channel_service.dart:2221` `neighborPc.addTrack(event.track, stream);`.
- Fix: DM: enable sender and receiver cryptors for video on camera enable and `onTrack` (same
  call key, index 0). Gossip: give each forwarded sender a cryptor (a per-sender key in
  `FrameCryptorService`), or disable forwarding until it renegotiates properly. Otherwise
  correct WP 6.3.

### Info (no candidate)

- I-1 Forwarder visibility and replay. SFrame has no receiver replay window here (RFC 9605
  9.3 makes it a MAY), so a forwarder can re-inject earlier frames of a share it carries, under
  any of the 16 slots; it also reads the clear codec header (VP8: 10 bytes on key frames,
  dimensions included; Opus TOC byte), frame sizes and timing, and viewers' LAN addresses from
  host candidates (forwarder legs have zero ICE servers by design, `voice_channel_provider.dart:2481`).
  AR-14 covers the addresses in part.
- I-2 The CallInvite friend check opens SQLCipher on the event loop
  (`node/voice_handler.rs:565` `crate::storage::MessageStore::open(db_path, db_passphrase)`),
  while its data-channel twin moved to the blocking pool (`data_channel_peer_allowed_off_loop`,
  `:69-83`). Raw-key open, so cheap, but against `feedback_sqlcipher_open_hygiene`.
- I-3 Two upstream traps any fix must not lean on: libwebrtc's options copy constructor skips
  the discard flag (`libwebrtc:api/crypto/frame_crypto_transformer.h:61-68`, used by the
  wrapper's `new webrtc::RefCountedObject<webrtc::DefaultKeyProviderImpl>(rtc_options)`,
  `libwebrtc/src/rtc_frame_cryptor_impl.h:31-32`), so on desktop
  `discardFrameWhenCryptorNotReady` is indeterminate whatever Dart passes; and disposing a
  cryptor leaves its transformer attached and disabled (`rtc_frame_cryptor_impl.cc:92`
  `RTCFrameCryptorImpl::~RTCFrameCryptorImpl() {}`, plugin `FrameCryptorDispose` only
  deregisters), so a sender whose cryptor was dropped sends frames in clear. Related bookkeeping
  bug: `_dropShareCryptors(X)` disposes BOTH directions keyed `screen:X`
  (`frame_cryptor_service.dart:296-308`), so an incoming share from X disables our live outgoing
  share cryptor to X (black share for X; plaintext only to X itself over DTLS).
- I-4 Helpers parse peer media without a sandbox: the render exe decodes peer Opus, and ffmpeg
  eagerly probes and transcodes received voice notes (`lib/src/ui/chat/audio_message_bubble.dart:143-157`)
  with ogg, opus and vorbis decoders. Both run as the user. Out of process, so a crash is
  contained; a memory bug is code execution (AT-5). Phase G: fuzz and OS sandbox. Binary search
  order (dev fallbacks, `/opt/homebrew/bin/ffmpeg`) belongs to the local slice.
- I-5 TURN credentials are one bearer token per second for everybody
  (`relay-uws/src/ws_handler.cpp:2840` `std::string username = std::to_string(expiry) + ":hollow";`,
  TTL 3600 s): coturn can neither attribute nor limit per peer, and any identity can relay
  between allocations on the box (phase G with AR-01). Without Always relay, every call and data
  channel also asks Google's and Cloudflare's STUN (`ice_config_provider.dart:43-47`,
  `webrtc_service.dart:66-71`), which learn the address and the timing of each session: a
  LINDDUN "detect" point C-24 does not name.
- I-6 libwebrtc's random seed for the IV counter is dead code
  (`frame_crypto_transformer.cc:799` `send_counts_[ssrc] = floor(CreateRandomNonZeroId() * 0xFFFF);`
  is overwritten two lines later), so every counter starts at 0. Harmless (L-01).

## Leads

### L-01 SFrame nonce uniqueness: SAFE

**What we ship.** Desktop runs our build of webrtc-sdk m144 (`third_party/libwebrtc/`, built
from `D:/libwebrtc-build/src` at `aaeeee8`; our two patches touch the desktop capturer,
content hint and audio transport, not `api/crypto/`). Android ships webrtc-sdk 144.7559.01,
iOS and macOS 144.7559.09, all built from the same `frame_crypto_transformer.cc` family (the
`m144_release` head has the identical `makeIv`). Hollow drives it in shared-key mode
(`frame_cryptor_service.dart:72-80`): one AES-128-GCM key per KeyProvider slot, derived by
PBKDF2 from the MLS exporter secret (`"sframe"`, empty context, 32 bytes) or the DM call key.

**How the IV is built.** `libwebrtc:api/crypto/frame_crypto_transformer.cc:509`
`webrtc::Buffer iv = makeIv(frame->GetSsrc(), frame->GetTimestamp());` and `:804-806`
```
buf.WriteUInt32(ssrc);
buf.WriteUInt32(timestamp);
buf.WriteUInt32(timestamp - (send_count % 0xFFFF));
```
with `send_count` per (transformer, SSRC), starting at 0 (I-6). So the IV is the triple
(SSRC, RTP timestamp, count mod 65535), carried in the frame trailer; receivers use the
trailer's IV, never recompute it.

**Who shares a key.** One key covers every sender stream of a group epoch: every participant,
every peer connection of the mesh (one RtpSender per remote peer), every kind (audio, camera,
screen, simulcast layers), every forwarder ingest leg, and, as the MLS slice noted, every
non-restricted voice channel of the same server at once (11 export sites, all
`export_secret(..., "sframe", b"", 32)`). Restricted channels and meetings have their own
groups, DM calls a fresh `Random.secure()` 32-byte key per call
(`call_provider.dart:2512-2517`), each in its own KeyProvider.

**Why no two encryptions under one key share an IV.**
- Across streams: the IV starts with the sending stream's SSRC. SSRCs are random 32-bit values
  from each PeerConnection's `UniqueRandomIdGenerator` (never repeated inside one connection).
  A collision needs two streams under the same key with equal SSRCs: for S streams the chance
  is about S^2/2^33 per epoch (400 streams, a busy server with ten camera calls: 2e-5), and an
  SSRC collision alone is not IV reuse: the two streams also need an equal RTP timestamp (each
  stream starts at a random offset, `libwebrtc:modules/rtp_rtcp/source/rtp_sender.cc:180`
  `timestamp_offset_ = random_.Rand<uint32_t>();`) at frames whose counters agree modulo 65535.
  Together, far below 1e-12 per epoch.
- Within a stream: the RTP timestamp only moves forward. Video takes it from the capture clock
  in whole milliseconds and drops any frame whose time does not increase
  (`libwebrtc:video/video_stream_encoder.cc:1643` `kMsToRtpTimestamp * static_cast<uint32_t>(incoming_frame.ntp_time_ms()));`,
  `:1650` `if (incoming_frame.ntp_time_ms() <= last_captured_timestamp_) {`), so a value
  returns only after 2^31 ms (24.9 days). Audio counts samples
  (`libwebrtc:audio/channel_send.cc:877-878` `audio_frame->timestamp_ = timestamp_;` /
  `timestamp_ += audio_frame->samples_per_channel_;`, only jumping forward on resume), so on its
  20 ms lattice a value returns after about 15.5 days of continuous sending. Several frames at
  one timestamp on one SSRC (SVC layers) differ in the counter.
- Renegotiation, ICE restart and the heal ladder's `reassert` keep the RtpSender, its SSRC and
  its timestamp; a new cryptor restarts the counter at 0 but on timestamps never used before.
  Setting a transformer reconfigures the audio stream rather than recreating it
  (`libwebrtc:media/engine/webrtc_voice_engine.cc:1140-1144`), and a recreated video stream
  keeps its start offset while its timestamps stay on the wall clock.
- A new PeerConnection (rebuild, rejoin, a mic or camera switch's new transceiver) gets a new
  random SSRC and offset.
- `rotateKey` and index reuse: the slot number (epoch mod 16) is not part of the IV; uniqueness
  is per key, and each epoch's key is fresh. Re-applying the same epoch key (heal step 1)
  re-derives the same key and leaves counters and timestamps running.
- `screen:$originator` only names a participant handler; in shared mode it holds the same key,
  and the share's own SSRCs keep its IVs apart. The forwarder re-sends the originator's
  ciphertext byte for byte (same key, IV, plaintext: a replay, not a reuse), the feeder re-emits
  packets without a key, and simulcast layer switching rewrites RTP fields, not the trailer.
- The DM key and the VC key never meet: separate KeyProviders, separate keys.

**Residual (theoretical).** If the wall clock steps back during a session and libwebrtc
recreates a video send stream on the same SSRC under the same key, timestamps from before the
step can recur, and a reuse then also needs the counter to agree modulo 65535. Negligible. Even
a reuse leaks only to someone who sees SFrame ciphertext without the key: on mesh and DM legs
that layer sits inside SRTP with end-to-end DTLS, so only the forwarder (and a removed member
still in the mesh, C-MEDIA-01) could use it.

**`failureTolerance: -1`.** A tampered or forged frame fails the GCM tag and is dropped
(`frame_crypto_transformer.cc:761-769`); -1 means the key is never marked invalid, so an
injector cannot make a receiver stop decrypting genuine frames. Its costs: it disables the
early-out, so every bad frame runs the ratchet (C-MEDIA-02), and `kDecryptionFailed` is never
reported, so the heal ladder never sees a decrypt failure, only MissingKey and InternalError
(functional). A replayed frame decrypts and plays (I-1).

**Verdict.** SAFE: no fix is needed for nonce uniqueness. Optional hardening that would meet
RFC 9605 4.1 to the letter without a libwebrtc rebuild: `sharedKey: false` and per-sender keys,
`HKDF(epoch_secret, "hollow-sframe-sender" || sender device || receiver device || kind)` for
mesh legs and `HKDF(epoch_secret, "hollow-sframe-share" || originator || stream)` for shares,
installed with `setKey(participantId, epoch % 16, key)` under distinct sender and receiver
participant ids. Dart plus a Rust derivation; every client must switch at once.

**AR-03.** The code matches the accepted risk and allows less than it describes. In the mesh a
frame is attributed to the connection it arrives on, so a participant cannot pass its media off
as another's directly. It can through a forwarding role: a delegated feeder or a peer forwarder
can inject frames under the shared key into the originator's stream (`screen:$originator`), a
gossip neighbour re-sends decoded audio it could alter, and `inbound_origin_ok` accepts an origin
naming one of our own devices (`node/voice_handler.rs:1541-1542`). All need an admitted
participant. Outsiders (relay, TURN, forwarder) cannot forge: tags fail without the key.

## Protocol checklist: RFC 9605

| Section | Obligation | Status | Evidence |
|---|---|---|---|
| 4.1 | The key management MUST ensure each media key is used by exactly one sender | Not met literally; equivalent property held | One shared key per group epoch (`frame_cryptor_service.dart:74` `sharedKey: sharedKey,`); SSRC-prefixed IV keeps senders apart (L-01). Hardening in L-01 |
| 4.3, 9.1 | Each (base_key, KID, CTR) used for at most one encryption | Met in practice | No KID/CTR: IV = SSRC, timestamp, counter (`frame_crypto_transformer.cc:804-806`); L-01 |
| 9.2 | KID assignment MUST assure non-reuse | n/a | No KIDs; the trailer's key-index byte is the epoch slot |
| 7.4, 9.3 | Senders MUST reject encrypting twice with one key and nonce | Partial | No runtime check in libwebrtc; uniqueness by construction only |
| 9.3 | Receiver anti-replay (MAY) | Not done | No window; SRTP covers on-path attackers, not the forwarder (I-1) |
| 9.4 | MUST NOT use SFrame-authenticated metadata before decrypting | Partial | The clear VP8 header is read by the depacketizer before decrypt; tampering only breaks the frame |
| 4.4.4 | A frame that fails to decrypt MUST be discarded | Met when a cryptor is enabled; not met without one | `frame_crypto_transformer.cc:761-769`; a keyless or disabled cryptor passes plaintext (C-MEDIA-03, I-3) |
| 4.4.2 | Key and salt by HKDF with SFrame labels | Deviates, security-equivalent | PBKDF2-100k with salt `hollow-sframe-salt` over a uniform 32-byte secret (`frame_crypto_transformer.cc:277-279`) |
| 5.2 | base_key = MLS-Exporter("SFrame 1.0 Base Key", "", Nk), per-sender derivation by leaf index | Deviates | Label `"sframe"` (only exporter use in the code, distinct from `epoch_authenticator`, `crypto/mls_manager.rs:1179-1185`); no per-sender split |
| 5.2 | Receivers MUST remove an old epoch when a new one with the same low E bits arrives | Met | Slot `epoch % 16` overwritten by `setSharedKey` (`voice_channel_service.dart:737`); older slots stay usable until then (C-MEDIA-01) |
| 7.3 | SHOULD change keys when clients join or leave the call | Partial, by design | Keys change with the MLS group (server, subgroup, meeting), not with the call; a removal rotates, but the removed device is not evicted (C-MEDIA-01) |
| 7.2 | No per-sender authentication | Accepted (AR-03) | See AR-03 above |
| 7.1 | Header not confidential | Accepted | Key-index byte, IV (SSRC, timestamp), clear codec bytes visible to the forwarder (I-1) |
| 7.5 | Short tags | Met | 16-byte GCM tag (`frame_crypto_transformer.cc:357` `unsigned int tag_length_bits = 128;`) |
| RFC 9420 8.5 (via 9605 5.2) | Exporter labels unique per use | Met | `"sframe"` is the only `export_secret` label in the tree |

## The 13 classes, asked of this slice

1. Authenticated but not authorised. Call signals: a friend or own device rings, later signals
   only from the device in the call (media:A-MED-01). VC signals: participant set on both lanes
   (A-MED-05..07). The gap is time: the participant set is never re-judged after a kick, ban or
   visibility loss (C-MEDIA-01).
2. Infrastructure controls membership. The relay cannot add a participant: seats come only from
   a `VoiceChannelJoin` that passes `voice_join_refusal` (server) or `conference::seated`
   (meeting). It can remove one from our view (`PeerLeft`, availability only) and it names the
   forwarder (AR-14, HOL-SEC-066). TURN URIs must name the relay host
   (`node/ws_client.rs:890`, `turn_uris_must_name_the_relay`).
3. Split view. Members on different epochs encrypt under different keys; the heal ladder
   converges them. A relay that withholds a removal commit from one member keeps that member
   encrypting under the old key, which the removed device still holds (the MLS slice's
   C-MLS-02); it reads that member's media only if still in its mesh (C-MEDIA-01).
4. Withheld or rolled-back revocation. A roster-removed device leaves the MLS group by the
   batch tick, but not the voice call (C-MEDIA-01); meetings are covered by HOL-SEC-123.
5. Identifier confusion. Cryptor keys `'$peerId:$kind'` and `'screen:$peerId:...'` cannot
   collide (peer ids hold no colon), but `screen:X` names both directions (I-3). Origins compare
   by identity (`same_identity`), so a sibling counts as the sender (AR-03 note). Participant
   sets are device-keyed, as the rule book requires.
6. Channel confusion. `Call*` counts only inside an Olm `CallSignal` (plaintext, carried and MLS
   copies refused, A-MED-01/02); VC envelopes go through the same handler from MLS (leaf-bound)
   and Olm (device-bound) with the same participant, size, origin and rate checks
   (A-MED-06/07, HOL-SEC-110); `fwd_*` only over Olm with the forwarder; share audio only on the
   data channel from a sharer we watch (`share_audio_gate_test.dart`). SFrame keys are never
   delivered by a VC message (derived locally), DM keys only by the Olm invite. Nothing found.
7. Unknown key-share / misbinding. DTLS fingerprints ride MLS (leaf-bound), Olm (device-bound)
   or a device seal (data channel), so the relay cannot sit in the DTLS handshake. Forwarder
   legs bind to the pinned forwarder's Olm identity (AR-14). Nothing found.
8. Replay. Call and VC signals ride Olm or MLS (no replay inside a session) and are live-only;
   sealed plaintext frames are judged by seal time (5 min, `node/frame_auth.rs:30`) and nonce
   (`frame_replays.first_sight`). Media: SRTP stops on-path replay; the forwarder can replay
   SFrame frames (I-1).
9. Downgrade. An invite with an empty `sframe_key` gives a DM call without SFrame (the calling
   friend's choice, matrix residual); a keyless voice channel goes untransformed, which matters
   on the forwarder lane (C-MEDIA-03); DM camera and gossip audio never had the layer
   (C-MEDIA-08).
10. Unauthenticated metadata. The SFrame trailer (IV length, key index) is outside the AAD but
    any change breaks the tag; the clear codec header is inside the AAD; RTP fields are
    rewritten by the forwarder by design and not used for decryption. The `origin` object is
    inside MLS/Olm and checked against the sender. In-band control frames on the share-audio
    pipe are not authenticated as local (C-MEDIA-07).
11. State and key lifecycle. Keys are zeroed after `setKey` in Dart, but the epoch cache
    `_sframeKeys` keeps every server's current key in Dart RAM for the provider's life, and a
    disposed cryptor's transformer stays attached (I-3). New cryptors start at slot 0
    (C-MEDIA-06). A KeyProvider lives per call or voice session.
12. Device linking. Not a media surface; one call per identity (`node/call_book.rs`) bounds
    rings (`MAX_RINGS`) and sibling presence fields (`MAX_FIELD`).
13. What a stranger can trigger. Ringing: no (friend gate before anything else,
    `node/voice_handler.rs:603`). Our IP: not through calls, voice channels or the general data
    channel (HOL-SEC-040), but yes through the Share lane, Always relay or not (C-MEDIA-04). TURN
    allocations: any identity with a full socket gets credentials (I-5, phase G). A stranger
    who joins an open server becomes a member and can then exhaust voice participants' CPU
    (C-MEDIA-02) and, in a meeting room, learn the participants' device ids (AR-16).

## STRIDE grid

### P1 Media signalling (E-02 handlers + Dart call and voice providers)

| Cell | Verdict |
|---|---|
| S | covered: media:X-1 (Olm sender proof), X-2/X-3 (seal and leaf binding), A-MED-01 (Call* only from the ringing/answering device), A-MED-07 (origin) |
| T | requirement met: Olm/MLS AEAD; SDP capped at 64 KiB (`node/voice_handler.rs:1954`, `:660`) |
| R | n/a: calls are ephemeral; call records are local only |
| I | covered: restricted-channel presence only to viewers (HOL-SEC-090); VC SDP inside MLS/Olm; data-channel SDP readable by the relay by design (C-24 note 2) |
| D | requirement met: VC rate bucket on both lanes (HOL-SEC-110), per-sender frame bucket, `MAX_RINGS`; Info I-2 (store open on the event loop) |
| E | candidate C-MEDIA-01 (seat outlives its authority); otherwise covered by A-MED-03..07 |

### P2 SFrame layer (FrameCryptorService + libwebrtc FrameCryptor/KeyProvider)

| Cell | Verdict |
|---|---|
| S | accepted AR-03 (insiders forge); outsiders cannot (GCM tag) |
| T | requirement met: GCM tag, 128-bit (`frame_crypto_transformer.cc:357`); candidate C-MEDIA-03 (frames pass in clear without a key) |
| R | n/a |
| I | L-01 SAFE (nonce uniqueness); candidates C-MEDIA-05 (keys in logs), C-MEDIA-06 (stale slot), C-MEDIA-08 (no layer on DM video, gossip audio) |
| D | candidate C-MEDIA-02 (ratchet amplification, unbounded queue, rotation stall) |
| E | n/a: holds no authority; key selection follows MLS (R-MEDIA-10, -11) |

### P3 Media forwarder (standalone and embedded)

| Cell | Verdict |
|---|---|
| S | covered: media:A-MED-09 (sealed, fresh, first-seen frames; HOL-SEC-109), A-MED-12 (relay cannot name a known person; pin, AR-14) |
| T | requirement met: cannot alter SFrame payloads (tag); can replay (Info I-1) |
| R | n/a |
| I | covered by AR-14 (addresses, who watches whom); Info I-1 (clear codec header, LAN host candidates); candidate C-MEDIA-03 (keyless share in clear) |
| D | accepted: a forwarder can drop, viewers fall back to direct; budget caps in `forwarder/mod.rs:27-34`; candidate C-MEDIA-02 (it can make viewers burn CPU) |
| E | covered: A-MED-09/10 (owner, feeder, allowlist), A-MED-11 (client-bound replies, Dart-only binding as before) |

### P4 E-03 media helpers (screen_audio_capturer, ffmpeg on peer media)

| Cell | Verdict |
|---|---|
| S | n/a for media (binary resolution is the local slice) |
| T | candidate C-MEDIA-07 (in-band control frames from the remote sharer); framing lengths checked by the exe (`main.cpp:1046` `if (payload_len < 5 \|\| payload_len > 4004) {`) |
| R | n/a |
| I | requirement met: capture scope rules (window shares capture that app only, WP 6.8) are the local slice; nothing leaves the helper but the encoded stream |
| D | requirement met: a crashed renderer loses share audio only (`screen_audio_renderer.dart` exit handler) |
| E | Info I-4 (unsandboxed parsing of peer Opus and voice notes; phase G) |

### DS1 SFrame key material in RAM

| Cell | Verdict |
|---|---|
| T | n/a: written only from MLS exporter events and the Olm invite (R-MEDIA-10, A-MED-13) |
| I | candidate C-MEDIA-05 (log); class 11 note (`_sframeKeys` keeps every current key); MLS slice C-MLS-06 covers keys recovered from the database |
| D | requirement met: a lost key heals through the ladder and the keyless watchdog (`voice_channel_provider.dart` `_sframeKeylessTick`) |

### Flows

| Flow | T | I | D |
|---|---|---|---|
| F-40 signalling | covered: Olm/MLS AEAD and seal (X-1..X-3) | covered: HOL-SEC-090; relay sees data-channel SDP by design | covered: HOL-SEC-110; relay can drop (AR-04) |
| F-41 DTLS-SRTP + SFrame | requirement met: SRTP + GCM; fingerprints in authenticated signalling | L-01 SAFE; candidates C-MEDIA-01, -06, -08; Info I-5 (third-party STUN) | candidate C-MEDIA-02; relay/TURN can drop (AR-04) |
| F-42 forwarder lane | covered: A-MED-09..12 | candidate C-MEDIA-03; AR-14; Info I-1 | accepted: fallback to direct |
| F-43 share audio on the data channel | requirement met: DTLS, peer bound by sealed signalling; play gate (HOL-SEC-058) | requirement met for outsiders (DTLS, WP 6.8 says so); candidate C-MEDIA-01 (removed member keeps it) | requirement met: sender backpressure (`webrtc_service.dart:268-280`); C-MEDIA-07 |
| F-44 TURN credentials | requirement met: authed non-guest socket only (`ws_handler.cpp:2833`), URIs pinned to the relay host (`ws_client.rs:890`) | Info I-5 (global bearer, no peer in the username: good for privacy, bad for limits) | accepted: relay withholds, Always relay fails closed (`ice_config_provider.dart:67-80`) |

### Interactors

| Interactor | S | R |
|---|---|---|
| X-3 peers as call participants | covered: device proof on every lane (X-1..X-3), call_book device binding | n/a: no non-repudiation promised for media (C-23 withdrawn) |
| TURN (coturn) | requirement met: URIs only on the relay host; peer lock relays only to allocations on that host (`relay-uws/deploy/coturn/coturn-start.sh` deny-all plus `--allowed-peer-ip`) | n/a: logs go to `/dev/null` by design |

## Requirements

| ID | Requirement | Evidence | Test |
|---|---|---|---|
| R-MEDIA-01 | A stranger, a non-friend or a blocked friend cannot make any of our devices ring | `node/voice_handler.rs:557-570`, `:603` | `authz_only_a_friend_or_our_own_device_rings_us` |
| R-MEDIA-02 | A `Call*` message counts only inside an Olm `CallSignal`; a plaintext, carried or MLS copy changes nothing | matrix A-MED-01/02 lines | `plaintext_call_signal_is_rejected` |
| R-MEDIA-03 | After a ring, only the device that rang or answered can steer the call | `node/voice_handler.rs:782-833` | `a_call_rings_every_device_and_the_first_accept_takes_it`; `call_book.rs` units |
| R-MEDIA-04 | Call ids and DM SFrame keys come from a secure random source (128 and 256 bits) | `lib/src/core/providers/call_provider.dart:2504-2517` | no test |
| R-MEDIA-05 | A VC signal counts only from a current participant of that channel, on MLS and Olm alike, at the VC rate | `node/voice_handler.rs:1950`, `:2096`, `:2215`; HOL-SEC-110 | `authz_a_vc_signal_from_outside_the_call_is_refused`, `authz_a_vc_signal_counts_only_from_a_participant_of_that_call`, `authz_a_vc_signal_flood_over_olm_is_rate_limited` |
| R-MEDIA-06 | A seat in a server voice channel only for a member who can see it; a meeting seat only for a seated device | `node/voice_handler.rs:1884-1900`, `:1839-1844` | `authz_voice_seat_only_for_a_member_who_can_see_the_channel`, `authz_voice_frames_over_mls_come_from_their_leaf` |
| R-MEDIA-07 | A device that stops qualifying for its seat (kick, ban, lost visibility, roster removal) leaves every honest participant's call by the next epoch change | NOT MET (C-MEDIA-01); meetings only: `node/conference.rs:806-836` | meetings: `authz_a_device_out_of_the_meeting_group_loses_its_call_for_good`; servers: no test |
| R-MEDIA-08 | A share's origin names its sender (or us), and only the originator assigns its viewers | `node/voice_handler.rs:1533-1544`, `:2258` | `authz_a_share_is_assigned_by_its_originator_and_reported_to_its_owner`, `vc_screen_origin_attribution_round_trip` |
| R-MEDIA-09 | A sharer streams only to viewers who asked; a receiver drops a share offer it did not ask for | `voice_channel_provider.dart:2321`, `:2038` | audio half only: `test/share_audio_gate_test.dart`; video offers: no test |
| R-MEDIA-10 | The voice key is the MLS exporter of the channel's group and changes with that group's epoch | `node/crypto_handler.rs:2699` and the 10 other `"sframe"` sites | `test_sframe_key_rotates_on_membership_change`, `restricted_voice_channel_subgroup_enforces_sframe_membership` |
| R-MEDIA-11 | A restricted voice channel uses only its subgroup's key; a server-group epoch never replaces it | `voice_channel_provider.dart:4146-4154` | Rust side as R-MEDIA-10; Dart: no test |
| R-MEDIA-12 | No (key, IV) pair repeats under one SFrame key | L-01 (`frame_crypto_transformer.cc:804-806`, monotonic RTP time) | no test (native) |
| R-MEDIA-13 | Every sender cryptor encrypts under the current epoch's slot from its first frame | NOT MET (C-MEDIA-06) | no test |
| R-MEDIA-14 | No media reaches a forwarder, and no forwarder media is rendered, without an SFrame layer | NOT MET (C-MEDIA-03) | no test |
| R-MEDIA-15 | A frame that fails to decrypt costs the receiver one AEAD open | NOT MET (C-MEDIA-02) | no test |
| R-MEDIA-16 | The forwarder acts only on sealed, fresh, first-seen frames; a stream is registered, fed and watched only by its owner, delegated feeder and allowlist | `forwarder/signaling.rs:241-258`, `forwarder/dispatch.rs:42-106` | `fwd_refuses_an_unsealed_frame_from_a_first_contact`, `fwd_refuses_its_own_frames_echoed_back`, `register_requires_origin_eq_sender`, `feeder_may_never_administer_the_stream` |
| R-MEDIA-17 | The relay can never name a known person, or us, as its forwarder, nor switch the pinned one while it is alive | matrix A-MED-12 lines | `authz_the_relay_cannot_name_a_known_person_as_its_forwarder`, `test/forwarder_pin_test.dart` |
| R-MEDIA-18 | Forwarder legs carry no ICE servers; with Always relay on, a viewer accepts only the pinned infra forwarder | `voice_channel_provider.dart:2481`, `:3283-3292` | no test for the Always-relay gate |
| R-MEDIA-19 | With Always relay on, call, voice and general data-channel connections gather relay candidates only and fail closed without TURN | `ice_config_provider.dart:67-80` | no test |
| R-MEDIA-20 | A Share-lane offer is answered only for a peer allowed a data channel or a share we serve, and never while Always relay is on | NOT MET (C-MEDIA-04) | no test |
| R-MEDIA-21 | TURN credentials go only to authenticated full sockets, and only relay-host URIs are used | `relay-uws/src/ws_handler.cpp:2833`, `node/ws_client.rs:890-897` | `test_relay_live.cpp` "no TURN credentials for a guest", `turn_uris_must_name_the_relay` |
| R-MEDIA-22 | Share audio plays only from a sharer we watch (VC) or the call peer (DM) | `acceptsShareAudioFrom` (HOL-SEC-058) | `test/share_audio_gate_test.dart` |
| R-MEDIA-23 | Bytes from a remote sharer never reach the render helper as a control frame | NOT MET (C-MEDIA-07) | no test |
| R-MEDIA-24 | No log line carries an SFrame key at any log level | NOT MET (C-MEDIA-05) | no test |
| R-MEDIA-25 | A general data channel is opened or answered only for our devices, friends and co-members | `node/voice_handler.rs:55-101` | `authz_room_presence_alone_opens_no_channel_to_us` |
| R-MEDIA-26 | A data-channel answer or ICE pairs only with our connection to the same identity and conn id | `lib/src/core/services/rtc_signal_pairing.dart:23-26` | `test/rtc_signal_pairing_test.dart` |

## What I could not check

- Runtime: nothing was built or run. The CPU cost in C-MEDIA-02 is computed from the code, not
  measured; whether gossip-forwarded tracks ever flow (C-MEDIA-08) needs a 6-person call.
- The mobile libwebrtc binaries (Android 144.7559.01, iOS/macOS 144.7559.09) were not
  source-verified file by file; the frame cryptor code is the same family and the
  `m144_release` head matches the desktop tree.
- The honest client's own reaction to its kick (does Dart leave the voice channel on
  `ServerDeleted`?) was not traced; C-MEDIA-01 assumes a modified client either way.
- str0m's `Vp8Descriptor` parser in the forwarder and the ffmpeg version shipped were not
  reviewed (phase G fuzzing).
- coturn's configuration on the live box was taken from the repo script, not the host.
