# Phase E+F slice "olm": Olm sessions, signed key exchange, multi-device fan-out, DM rooms, the frame seal, Ed25519

Session 34, merged phase E (STRIDE, protocol checklists, the 13 classes) and phase F (WP2 crypto
code review). Read-only pass over the worktree `D:/dev/wt/s34-ef` at HEAD `aa104d48`. Nothing was
built or run; every verdict below comes from code read in that tree and in the cargo registry
(`D:/dev/cargo/registry/src/index.crates.io-1949cf8c6b5b557f/`). Paths are relative to
`rust/hollow_core/src/` unless they start with `relay-uws/` or name a registry crate.

## Scope

Elements (threat_model.md section 4):
- E-02 Rust core node, the Olm and frame-seal subsystem: `crypto/olm_manager.rs`, the KeyRequest,
  KeyBundle and Encrypted arms of `node/swarm.rs`, `node/crypto_handler.rs` (key exchange, Olm
  identity proof, carried bundles, message signatures), `node/olm_lane.rs`, `node/frame_auth.rs`,
  `node/dm_room.rs`, DM fan-out in `node/message_ops.rs`.
- E-04 push extension: `node/fetch.rs` (Android fetch node, iOS NSE through `push_enrich.rs`).
- The standalone media forwarder as an Olm responder: `forwarder/signaling.rs`.
- E-10 data store, Olm part: `olm_account` (with HOL-SEC-111 key slots), `olm_sessions`,
  `olm_read_marks`; plus the in-RAM caches (replay guard, repeat digests, retired sessions,
  `LOCAL_MASTERS`).
- Interactors X-2 (relay), X-3 (peers), X-4 (own siblings).

Flows: F-20 (KeyBundle/KeyRequest), F-21 (DM envelope), F-22 (friend request/accept), F-23 (DM sync),
F-24 (1:1 call signals), F-25 (profiles), F-26 (block list), plus two cross-cutting flows this slice
owns: the seal on every relay frame (client end of F-50/F-51) and DM room membership.

Specs: X3DH (Signal, rev 1), Double Ratchet (Signal, rev 1), Olm (matrix-org/olm `docs/olm.md`),
Sesame (Signal, rev 2), RFC 7748 section 6.1, Matrix `m.olm.v1.curve25519-aes-sha2` payload rules.
Leads L-02 and L-04. Accepted risk AR-19 (Olm half) checked against the code.

Library versions (Cargo.lock): vodozemac 0.9.0 (features: `low-level-api` only, Cargo.toml:46),
ed25519-dalek 2.2.0, x25519-dalek 2.0.1, curve25519-dalek 4.1.3, openmls_rust_crypto 0.6.0; the
relay uses libsodium `crypto_sign_verify_detached`.

## Summary

- STRIDE cells walked: 57 (3 processes x 6, 2 stores x 3, 9 flows x 3, 3 interactors x 2).
  Primary verdict per cell: covered by matrix rows or findings 13, requirement met with evidence 25,
  candidate 8 (candidates also annotate 4 covered or met cells), n/a 11.
- Candidates: 2 Medium, 2 Low, 6 Info.
  - C-OLM-01 Medium, CONFIRMED: a sync responder can make another member's signed message say a
    shorter text (signature payload field boundaries are ambiguous).
  - C-OLM-02 Medium, CONFIRMED: one friend request lets a stranger watch the target's devices come
    and go in the DM room, and a decline does not end it.
  - C-OLM-03 Low, CONFIRMED: the relay can spend any one-time key it relays and can relabel a
    device's PreKey under a device of its own (Olm unknown key-share); drop-equivalent today.
  - C-OLM-04 Low, CONFIRMED: unchecked i64 time arithmetic on sender-chosen stamps panics a
    debug-profile node or forwarder before any signature check.
  - C-OLM-05..10 Info: replay guard is RAM-only; non-canonical public key encodings verify (id
    aliases); archive signature has no domain tag; inbound Olm accepts the truncated-MAC v1 config;
    session pickles are last-writer-wins and persisted after the send is queued; vodozemac's Olm
    3DH has no contributory check (L-02 still holds).
- Requirements: 22 (R-OLM-01..22), 3 of them currently unmet (R-OLM-12, -13, -19).
- Leads: L-02 holds (every non-ephemeral key input is signed and verified before session creation on
  every path; the library itself does not reject low-order keys). L-04 holds (every Ed25519 check is
  strict; no signature bytes are used as an id, dedup key or replay key). AR-19 Olm half: the code
  matches the accepted description.

## Candidates (most severe first)

### C-OLM-01: A member answering a sync can make another member's message read as a shorter text it never sent

- Severity: Medium (Impact M: changes what another person is shown to have said, to every member
  at once over MLS, to newcomers and guests silently; Exploitability M: needs membership in a
  channel it can read and a target message whose text contains a colon).
- Attacker: P-05 (any member who can read the channel; also the member that answers a guest's
  public preview); P-04 for the DM variant (a friend rewriting our own messages in our view).
- Confidence: CONFIRMED by tracing verify, upsert and the edit path; not executed.
- Classes: 5 (signature context ambiguity), 9 (optional fields steer the check), 10 (a wire field
  read into the signed payload unchecked).

Evidence (verbatim):
- `node/crypto_handler.rs:288` `let lp = extras.lp_digest.unwrap_or("");`
- `node/crypto_handler.rs:294` `"hollow-msg2:{msg_type}:{context}:{sender}:{ts}:{mid}:{reply_to}:{file_id}:{order_us}:{lp}:{text}"`
- `node/crypto_handler.rs:336` `if extras.album().is_some_and(|a| !is_album_id_shape(a)) {` (the
  album is the only pre-text slot whose shape is checked; the comment at :273 says "Every field
  before `text` is colon-free" but nothing enforces it for `mid`, `reply_to`, `file_id`, `lp`)
- `node/crypto_handler.rs:231` `None => lp_digest.map(str::to_owned),` (no card shipped: the WIRE
  digest string goes into the signed payload as is)
- `node/sync_handler.rs:3680` `msg.lp.as_deref(), msg.lp_digest.as_deref(),`
- `node/crypto_handler.rs:1322` `let signed_ts = edited_at.unwrap_or(ts);`
- `node/sync_handler.rs:3729` `} else if let (Some(edit_ts), Some(mid)) = (msg.edited_at, &msg.mid) {`
- `storage/messages.rs:3643` `if prev_edit.is_some_and(|prev| edited_at <= prev) {` (a never-edited
  row has no lower bound)
- Same pattern: `node/swarm.rs:8004` (DmSyncBatch), `node/message_ops.rs:208` (guest preview,
  `guest_item_accepted`).

Why it breaks: the signed string joins fields with `:` and puts the free text last. A responder that
holds Alice's genuine item `{mid M, lp none, text "c1:rest"}` serves `{mid M, lp_digest "c1"
(or ":c1" when the original had no preview), no card, text "rest"}`: the payload string is byte for
byte the same, so the signature verifies as Alice's. With `edited_at` set to the original `ts`, the
item takes the edit branch and replaces the text of the row we already hold (the row is
Alice's, so `change_may_touch_row` agrees); without it, a receiver that never had the row stores the
truncated version and the genuine copy can never land (dedup by mid). Moving a colon into `mid` or
`reply_to` instead yields an extra row attributed to Alice. The attacker can drop any number of
leading colon-delimited chunks ("Do NOT click this: https://..." becomes the bare link) but cannot
add text. Channel batches are accepted unsolicited from any member who can read the channel
(`node/swarm.rs:7783`, MLS twin `node/swarm.rs:11072`), so one MLS batch reaches every member.
Breaks C-09 ("its text ... exactly what they signed") and C-17 ("nobody can ... edit ... as someone
else").

Test that would prove it: unit test in `crypto_handler.rs`: sign v2 over text `"a:b"` with no
preview, then `verify_message_signature_v2` over `lp_digest = Some(":a")`, text `"b"` must return
false (today true). Harness: member M (hostile, signs nothing new) sends B a `ChannelSyncBatch`
re-split of A's never-edited message with `edited_at = ts`; assert B's row text unchanged and no
`ChannelMessageEdited` event; a second case on a fresh device B2 asserts the genuine text lands.

Fix idea: in `verify_message_signature_v2` (and the sign side), refuse any of `mid`, `reply_to`,
`file_id`, `lp_digest` containing `:`, and require `lp_digest` to be 64 lowercase hex; the
long-term fix is a v4 payload that length-prefixes every field like `fields_digest`.

### C-OLM-02: One friend request lets a stranger watch the target's devices come and go, and a decline does not end it

- Severity: Medium (Impact M: which device ids a person has and when each is online, the exposure
  HOL-SEC-064 closed for the inbox; Exploitability H: sending a friend request needs only the
  master id).
- Attacker: P-03 (any identity that knows the target's master id and is not blocked at the time).
- Confidence: CONFIRMED by reading the client join sites and the relay's room audience; not
  executed.
- Classes: 13 (what a stranger can observe); LINDDUN linking/detecting.

Evidence (verbatim):
- `node/swarm.rs:12020` `let _ = store.save_friend(&master, "pending", "incoming", requested_at);`
  then `node/swarm.rs:12032` `let room = dm_room_code(&local_peer, &req_master);` and a `JoinRoom`
  for it: the target joins the DM room as soon as any stranger's request arrives, before the user
  sees it.
- `node/swarm.rs:3495` `.and_then(|store| store.load_friends(None).ok())` and
  `node/swarm.rs:3500` `for (friend_pid, _, _, _, _) in &friends {` (rejoined on every connect)
- `storage/messages.rs:4373` `"SELECT peer_id, status, direction, requested_at, updated_at FROM friends ORDER BY updated_at DESC".into(),`
  (no status filter: pending incoming and `declined` rows included)
- `node/social.rs:833` `let _ = store.save_friend(&master, "declined", "", original_requested_at);`
  (a decline keeps a row) and `node/social.rs:916` `// Deliberately no LeaveRoom for the DM room here.`
- `relay-uws/src/ws_handler.cpp:146` `if (inbox) return room.owners.count(peer) != 0;` and `:147`
  `return !locked || room.doors.sees(peer, now_ms);` (a DM room is neither an inbox nor a locked
  server room, so every socket in it sees the roster, `peer_joined`/`peer_left` and broadcasts)
- `node/dm_room.rs:42-58`: the requester computes the same name from its own master secret.
- Side effects on the target's `PeerJoined` cascade for the stranger's device: an auto-download
  advert carried with `NoSession::Queue` (`node/swarm.rs:3888`, `node/file_handler.rs:145-148`)
  starts an Olm key exchange with the stranger and hands it the threshold.

Why it breaks: design A (HOL-SEC-062) made DM room names secret so only the two parties can find
them, but the requester is one of the two parties. HOL-SEC-064 judged "a stranger learned the
person's online device ids and when each came and went" a Medium for the inbox; the same view now
comes from the DM room, for as long as the friend row exists, declined included. Blocking does not
help: `api/storage.rs:682-692` touches neither the row nor the room. Breaks the A28 decision (before
acceptance each side sees only a card) and the spirit of C-24's "routing metadata" being visible to
the relay only.

Test that would prove it: harness with the MockRelay (it mirrors the relay's room audience):
stranger S sends V a request; V declines; V reconnects; assert S's `ws_room_peers[dm_room]` never
lists a V device after the decline, and never while the request is merely pending.

Fix idea: join a DM room only for an accepted friendship and for our own pending outgoing request;
deliver an accept through the requester's inbox mailbox (as the reject already is) and join only at
accept time; never rejoin for `declined`/`removed` rows; leave on decline and once a removal is
delivered.

### C-OLM-03: The relay can spend any one-time key it relays and can relabel a device's PreKey as coming from a device of its own

- Severity: Low (Impact L: today it equals dropping the frame, a power the relay already has;
  Exploitability M: needs the relay, which sees every KeyBundle in the clear).
- Attacker: P-01.
- Confidence: CONFIRMED by code reading; not executed.
- Classes: 7 (unknown key-share), 13 (one-time key draining).

Evidence (verbatim):
- `node/crypto_handler.rs:683` `format!("hollow-olm-identity:{sender_device}:{identity_key}")`
  (a device can sign a binding to any Curve25519 key, including another device's; no proof of
  possession)
- `node/crypto_handler.rs:664` `if master == sender_device {` / `:665` `// Unknown device, or a
  single-device peer: nothing to cross-check.` (first-contact devices pass the device gate by design)
- `crypto/olm_manager.rs:381` `self.release_key_slots(peer_id, &message.one_time_key().to_base64());`
  and registry `vodozemac-0.9.0/src/olm/account/mod.rs:246` `.find_one_time_key(&public_otk)` (a
  PreKey from any sender may spend any one-time key in the account; HOL-SEC-111's per-requester
  slot bounds minting, it does not bind who may spend a key)

Why it matters: the relay can (a) build its own outbound session from the key Bob handed Alice and
send Bob a PreKey from its own device, or (b) take Alice's genuine PreKey to Bob, reseal the body
under its own device with a self-signed `hollow-olm-identity` binding to Alice's Curve25519 key, and
deliver it first. Bob then builds Alice's session under the relay's device id and spends the key;
Alice's real PreKey fails with a missing one-time key and the pair re-keys. The decrypted first
flight is attributed to the relay's device: every master-signed envelope then fails its signature,
and carried requests are judged as the relay identity's (no entitlement) with answers encrypted on
Alice's session, which the relay cannot read. So nothing leaks and nothing is forged today, but the
Olm plaintext binds neither sender nor recipient (X3DH section 4.8, Matrix's `sender`/`recipient`
fields), and a future carried message whose meaning depends on who receives it would inherit the
misbinding.

Test: harness with a hostile relay device: capture A's KeyBundle-derived PreKey to B, reseal as
relay device R with R's own identity proof, inject to B first; assert B builds no session for R
from a key slotted to A (fails today), and that A's own PreKey still opens.

Fix idea: in `open_prekey`, refuse a PreKey that spends a key whose slot names a different
requester (makes the HOL-SEC-111 slot a binding); refuse an Olm identity key already pinned to
another device; longer term, carry sender and recipient device ids inside every Olm plaintext and
check them.

### C-OLM-04: A stranger's crafted time stamp panics a debug-profile node or forwarder before any signature is checked

- Severity: Low (Impact H on debug-profile builds: the swarm task dies while the window lives;
  release builds wrap instead, so Exploitability L for users).
- Attacker: P-03 (anyone who can deliver a sealed frame: a stranger in a shared room, the relay
  with its own key).
- Confidence: CONFIRMED (arithmetic and profile read; `[profile.release]` at Cargo.toml sets only
  `debug = "line-tables-only"`, so overflow checks are off in release and on in dev and test).
- Class: 13, and the brief's "remote panic from one frame".

Evidence (verbatim):
- `node/frame_auth.rs:295` `now_ms - ts_ms > LIVE_SKEW_MS` (frame stamp chosen by the sealer;
  `open` refuses only stamps too far in the FUTURE, so `i64::MIN` reaches here for every live-only
  type, and for 0x02 chunks at `node/swarm.rs:4742`)
- `node/crypto_handler.rs:636` `Some(t) if (key_exchange_now() - t).abs() <= KEY_EXCHANGE_SKEW_SECS => {}`
  (runs BEFORE the signature check at :642; also reached by the forwarder's `handle_key_request`)
- `node/crypto_handler.rs:842` `if now - b.ts > MAX_CARRIED_BUNDLE_AGE_SECS {`

Why it matters: in debug builds (cargo test, `flutter run` debug, any debug-built forwarder) a single
KeyRequest `{"to": <victim>, "ts": -9223372036854775808, "sig": "x", "pk": "y"}` or any live-only
frame sealed at `i64::MIN` panics the event loop. In release the subtraction wraps: a live-only
frame stamped near `i64::MIN` is never stale and its nonce leaves the replay guard at the next prune
(`frame_auth.rs:281` stores `ts_ms + LIVE_SKEW_MS`), and `ts = now - 2^63` makes `.abs()` return
`i64::MIN`, which passes the 300 s window. Both only affect frames the sender itself signed, so
release builds gain an attacker nothing; the defect is the panic and the fragile check.

Test: unit tests feeding `is_stale(i64::MIN, now)`, `verify_key_exchange(.., Some(i64::MIN), ..)`
and a carried bundle at `i64::MIN` must return refused without panicking.

Fix idea: `now_ms.saturating_sub(ts_ms)`, `t.abs_diff(now) <= 300`, `now.saturating_sub(b.ts)`;
optionally refuse frame stamps more than a day in the past at `open`.

### C-OLM-05 (Info): The live-frame replay guard forgets everything on restart

`node/swarm.rs:621` `let mut frame_replays = super::frame_auth::ReplayGuard::default();` and
`node/frame_auth.rs:265-268` (a `HashMap` in RAM). A relay holding a live-only frame sealed less than
300 s before our process restarted can deliver it once more after the restart. In this slice the
effect is a replayed KeyRequest retiring our session with its sender and re-sending the same slot
key; the sender ignores the bundle (it holds a confirmed session) and our side switches back on its
next frame (`crypto/olm_manager.rs:437-446`), so it self-heals. Live-only types owned by other
slices (MlsKeyPackage, ServerJoinRequest live copies, RTC offers) should be checked by their owners.
Rule 8 of plan section 5 asks that freshness rules survive a restart. Attacker P-01. Fix idea:
refuse live-only frames sealed before the process started (honest senders retry), or persist the
guard's last 300 s on shutdown. Test: none.

### C-OLM-06 (Info): Rust accepts non-canonical public-key encodings, so one key verifies under many ids

`identity/native_identity.rs:142` `if pubkey_protobuf.len() < 36` and `:152`
`multihash.push(pubkey_protobuf.len() as u8);`: `peer_id_from_pubkey_protobuf` accepts trailing bytes
after the 36-byte key and derives a different (longer) id, while `verify_peer_signature` uses only
bytes 4..36. `archive/loader.rs:479` `if pk_bytes.len() >= 36 && pk_bytes[0] == 0x08 && pk_bytes[1] == 0x01 {`
hand-rolls the same derivation with a weaker header check. The relay requires exactly 36 bytes
(`relay-uws/src/crypto.cpp`, `proto_len != 36`) and the frame seal and rosters require the exact
38-byte id (`crypto/safety_number.rs:34`). Effect: a key holder can mint alias signer ids that never
appear on the transport; every path found compares the derived id with a canonical transport or
roster id, so no third-party impact was found. Fix: `!= 36` in both places and one shared helper.

### C-OLM-07 (Info): The archive signature covers a raw hash with no domain tag

`archive/exporter.rs:129` `let sig = keypair.sign(&content_hash);`, verified at
`archive/loader.rs:494`. Every other master-signed payload starts with a `hollow-*` tag; this one is a
bare 32-byte hash computed by the verifier, so no cross-protocol collision is reachable, but it
breaks rule 7 of plan section 5. Fix: sign `"hollow-archive1\0" || content_hash` (format bump).

### C-OLM-08 (Info): Inbound Olm sessions accept the truncated-MAC v1 configuration

Registry `vodozemac-0.9.0/src/olm/account/mod.rs:264` `let config = if pre_key_message.message.mac_truncated() {`
selects v1 (8-byte MAC) when the initiator sends it; Hollow always initiates v2
(`crypto/olm_manager.rs:313` `SessionConfig::version_2(),`) and never checks the inbound session's
config. Only the initiator chooses, so a third party cannot force it, and forging against 64 bits is
online-only. Class 9 hygiene: refuse a PreKey whose message is MAC-truncated (Double Ratchet
section 6.6).

### C-OLM-09 (Info): Olm session pickles are last-writer-wins and saved after the send is queued

`storage/messages.rs:1700-1702` upserts the pickle with no version; `node/crypto_handler.rs:2246`
queues the save to the CryptoStore actor and then queues the frame, both asynchronously. A process
kill after the frame left but before the write, or the iOS NSE writing a pickle that predates sends
the app had not flushed, rolls the sending chain back; the next message then reuses a message key
(same AES key and IV for a different plaintext, which the relay can compare block by block) and the
receiver fails it and re-keys. Narrow windows, class 11. Fix idea: persist the session before the
frame is handed to the sealer (await the actor), or store a monotonic send counter and refuse to
load an older pickle over a newer one.

### C-OLM-10 (Info): vodozemac's Olm 3DH and ratchet have no contributory check

Registry `vodozemac-0.9.0/src/olm/shared_secret.rs:87` and `:108` call `diffie_hellman` with no
`was_contributory()` (the same crate checks it in `sas.rs:248` and `ecies/mod.rs:262`). L-02 still
holds (see Leads), so this is defence in depth only: refuse an all-zero or low-order identity key,
one-time key or PreKey base key before `create_outbound_session` / `create_inbound_session`, as
`node/sealed_box.rs:52`, `node/ws_client.rs:437` and `node/dm_room.rs:97` already do for Hollow's
own X25519 uses; and check whether a newer vodozemac release adds the check.

## Leads

### L-02 vodozemac non-contributory DH: holds (defence in depth in C-OLM-10)

- Version: vodozemac 0.9.0 (Cargo.lock), released 2025-01-31, before the February 2026 report.
  Its Olm 3DH (`src/olm/shared_secret.rs:79-114`) and ratchet DH (`src/olm/session/root_key.rs:57`)
  do not reject all-zero or low-order public keys.
- `strict-signatures` exists (`Cargo.toml` features of the crate) and only switches
  `Ed25519PublicKey::verify` to `verify_strict` (`src/types/ed25519.rs:406`). Hollow does not enable
  it (Cargo.toml:46 enables `low-level-api` only) and never calls vodozemac's Ed25519 code (the only
  imports are `vodozemac::olm::*` and `Curve25519PublicKey`, `crypto/olm_manager.rs:7-11`), so
  enabling it would change nothing.
- Matrix's condition (every key input signed by the identity key and verified before session
  creation), path by path:
  - Live outbound: `node/swarm.rs:7426` KeyBundle arm; `hollow-keybundle:{sender}:{recipient}:{identity_key}:{one_time_key}:{ts}`
    (`node/crypto_handler.rs:506-517`) verified at `verify_key_exchange` (:615-655), device gate
    `key_exchange_device_unauthorized` (:657-675), then `create_outbound_session` at
    `node/swarm.rs:7496`. Both keys signed.
  - Carried outbound (async friending): `verify_carried_bundle` at use time
    (`node/social.rs:683`, :806-857 in crypto_handler) signs both keys under a distinct tag, then
    `create_outbound_session` at `node/social.rs:717`.
  - Live inbound PreKey: `verify_olm_identity` (`node/swarm.rs:7575`) before `open_prekey`
    (:7583); vodozemac then requires the signed key to equal the key inside the PreKey
    (`account/mod.rs:236` `if their_identity_key != pre_key_message.identity_key() {`). The
    one-time key is our own; the base key and ratchet keys are ephemeral and unsigned as in Olm and
    Matrix, and with an honest identity key a low-order base key cannot make the secret public
    (the `ECDH(IK_A, OTK_B)` term remains).
  - Push fetch and iOS NSE: `node/fetch.rs:996` then `:1000` (the NSE runs the same `run_fetch`,
    `push_enrich.rs:185`).
  - Forwarder: `forwarder/signaling.rs:470` then `:474`; it never builds an outbound session.
  - No other non-test caller of `create_outbound_session` / `open_prekey` exists (grep).
- What a low-order key still allows: only a party that signs its OWN zero key, making its own
  session readable by others, which equals leaking its own traffic.

### L-04 Ed25519 strictness: holds

Every signature check (ed25519-dalek 2.2.0 unless noted):
- `identity/native_identity.rs:188` `Ok(verifying_key.verify_strict(payload, &sig).is_ok())`
  (`verify_peer_signature`), used by `node/crypto_handler.rs:487` (support-creds field),
  `:932` (legacy device lists), `:1043` (destroy orders), `:1180` (`verify_message_signature`:
  messages, key exchange, Olm identity proofs, carried bundles, profiles, cards), `:1231` (batch
  cache), `archive/loader.rs:494`, `crdt/operations.rs:121` and `:173` (CRDT op auth, join ask),
  `api/stickers.rs:592`, `node/join_lock.rs:103`, `node/nick_claim.rs:51`, `node/ring_auth.rs:115`.
- `node/frame_auth.rs:158` `key.verify_strict(...)` (every relay frame).
- `identity/roster.rs:238` (every roster statement); `node/crypto_handler.rs:1061` (recovery-key
  signatures); `crypto/mls_manager.rs:138` (MLS leaf certificate); `node/support_creds.rs:503`,
  `:510` (shop root chain); `api/updater.rs:140` (update manifest); `rust/hollow_manifest/src/main.rs:240`.
- OpenMLS framing: `openmls_rust_crypto-0.6.0/src/provider.rs:391` uses `verify_strict`.
- vodozemac Ed25519 (`src/types/ed25519.rs:406`, non-strict without the feature): never called.
- Relay: libsodium `crypto_sign_verify_detached` (`relay-uws/src/crypto.cpp:38`, `:57`), which
  rejects a non-canonical S, small-order R and A, and a non-canonical A encoding; dalek's
  `verify_strict` does not reject a non-canonical A encoding, an unreachable divergence (no key is
  known for those points). `node/support_rsa.rs:99` is RSA, not Ed25519.

Sites where a signed blob or signature feeds an id, dedup key, replay key or hash:
- Frame replay key: `(sender, nonce)` with the nonce inside the signed bytes (`frame_auth.rs:273-282`).
- Olm repeat cache: SHA-256 of the Olm ciphertext (`crypto/olm_manager.rs:110-116`, `:187-199`),
  inside the sealed body and under Olm's MAC.
- CRDT op dedup: `(author, hlc)` (`crdt/fold.rs`, `ingest_remote`), both signed fields.
- Message dedup: `mid` (a signed field, but see C-OLM-01: its boundary is ambiguous).
- Roster base id: SHA-256 of the recovery payload (`identity/roster.rs:219-222`, relay mirror
  `relay-uws/src/roster.h:226`), not of the signature.
- Server id and meeting id: SHA-256 of `hollow-server1:` / `hollow-conf1:` with owner and nonce
  (`crdt/anchor.rs:19`, `node/conference.rs:63`), unsigned inputs.
- File id: a content commitment that the message signature then covers (`node/file_commit.rs`).
- Archive: signature over the content hash (C-OLM-07).
No site keys on signature bytes, so even a signer producing several valid signatures for one
message cannot split or merge records. The related weaknesses that do exist are payload
canonicalisation (C-OLM-01) and public-key encoding aliases (C-OLM-06).

### AR-19 (Olm half): the code matches the accepted description

- Read mark per sending device, newest seal time decrypted: `crypto/olm_manager.rs:204-222`; saved
  after the session through one queue (`node/crypto_handler.rs:2402-2407`), MAX on write
  (`storage/messages.rs` `save_olm_read_mark`, `MAX(sealed_ms, excluded.sealed_ms)`), loaded at start
  (`crypto/olm_manager.rs:141`).
- Failure at or before the mark dropped with no retire and no KeyRequest: PreKey arm
  `node/swarm.rs:7613`, normal arm `:7677`.
- Push fetch moves the mark: `node/fetch.rs` calls `persist_olm_read` after `try_decrypt_dm`
  returns a row. Nuance, not a deviation: the fetch process moves the mark (and saves the session)
  only for frames that become DM rows; other decrypted envelopes leave both unsaved, which only
  costs a re-key, the pre-mark behaviour.
- Nothing more than the AR states was found, except that a SENDER may stamp its own frames up to
  300 s ahead, pushing its own mark forward so its own failures in that window drop quietly
  (self-harm only).

## Protocol checklist

| Spec obligation | Our compliance | Evidence |
|---|---|---|
| X3DH 3.3: verify the prekey signature before use and abort on failure | Met (device-signed bundle, recipient and time bound) | `node/crypto_handler.rs:615-655`, `node/swarm.rs:7426-7470` |
| X3DH 3.3: AD binds both identity keys | Not met at the Olm layer (vodozemac Olm has no AD); identity is bound at the content layer by master signatures | C-OLM-03 |
| X3DH 3.4: the receiver deletes a used one-time key | Met, and only after the PreKey authenticates | registry `account/mod.rs:289`; slots released `crypto/olm_manager.rs:381` |
| X3DH 4.2 / 4.3: replay of the initial message | Met: one-time key single-use, repeat PreKey dropped or stale | `crypto/olm_manager.rs:970-990` test `a_replayed_prekey_is_stale_with_or_without_its_session` |
| X3DH 4.4: deniability | Deliberately not provided: every DM is master-signed (C-09) | `node/swarm.rs:7880-7900` |
| X3DH 4.5: prekeys must be signed | Met (KeyBundle, carried bundle, Olm identity proof) | `node/crypto_handler.rs:506-531`, `:682-712`, `:753-857` |
| X3DH 4.7: a malicious server can drain one-time prekeys | Partly: strangers bounded at one key per requesting device, 256 slots; the relay can spend any key it relays | `crypto/olm_manager.rs:261-273`; C-OLM-03 |
| X3DH 4.8: identity binding (unknown key-share) | Partly: no sender/recipient in the Olm plaintext | C-OLM-03 |
| X3DH 4.9: randomness | Met: vodozemac uses thread RNG; seal nonce from `getrandom` with a counter fallback | `node/frame_auth.rs:91-101` |
| Double Ratchet 3.5: discard state changes on a failed decrypt | Met (vodozemac; we try retired sessions only after) | `crypto/olm_manager.rs:427` |
| Double Ratchet MAX_SKIP (bounded skip computation) | Met by the library: gap 2000, 40 keys per chain, 5 chains | registry `session/receiver_chain.rs:29-30`, `session/mod.rs:53` |
| Double Ratchet 6.4: delete skipped keys after an interval | Not met: skipped keys live in the session pickle until evicted by count; a key for a withheld frame survives at rest | (library behaviour; low impact, noted) |
| Double Ratchet 6.6: truncated authentication tags | Outbound full MAC (v2); inbound v1 accepted | C-OLM-08 |
| Olm (`docs/olm.md`) version 1 MAC truncated to 8 bytes | We send version 2 | `crypto/olm_manager.rs:313` |
| RFC 7748 6.1: contributory behaviour is not automatic | Our own X25519 uses check it; vodozemac Olm does not | C-OLM-10, L-02 |
| Matrix m.olm payload: sender, recipient, recipient keys inside the plaintext | Not done | C-OLM-03 |
| Sesame: one session per device, a set per user | Met: sessions keyed by device id | `crypto/olm_manager.rs:14-40` |
| Sesame: the session that last received becomes active; inactive kept for decryption, bounded | Met: follow-the-peer, 4 retired per peer (RAM only) | `crypto/olm_manager.rs:344-370`, `:437-446`, `:66` |
| Sesame: encrypt to every device of the recipient and every other own device | Met, liveness-filtered (room or session) | `node/message_ops.rs:387-545` |
| Sesame: a device list the server controls must not decide recipients | Met: targets come from the held roster; relay presence only filters | `node/message_ops.rs:490-505`, `node/crypto_handler.rs:1413-1440` |
| Sesame: delete sessions of a removed device so it stops receiving | Met on `removed`; devices that stop counting without a removal are dropped from the resolver, so no fan-out reaches them (session kept, unused) | `node/swarm.rs:6676-6700`; `node/roster_book.rs:68-73` |
| Sesame: tell the user about a contact's new device | Met (`new_device` warning) | `node/roster_book.rs:633-640`, `node/security_alerts.rs:86` |
| Sesame: session selection under simultaneous initiation | Met: lower device id keeps its session; KeyRequest crossing a fresh PreKey answered on it | `crypto/olm_manager.rs:383-389`, `node/swarm.rs:7394-7405` |

## The 13 classes for this slice

1. **Authenticated but not authorised.** Key exchange binds the signature to the transport sender
   and then to its roster (`key_exchange_device_unauthorized`); carried messages count only as from
   the device whose session decrypted them (`node/swarm.rs:9182-9195`). The authz rows
   dm:A-DM-01..27 and transport:A-T00..21 cover the handlers. C-OLM-01 is the field-level variant:
   a valid signature over fields the signer never meant.
2. **Infrastructure controls device lists.** Fan-out targets are roster devices
   (`resolver::devices_for`) intersected with liveness; `room_peers_of_master` and
   `online_devices_for` admit a room peer only if the roster maps it to the master. The relay cannot
   add an Olm target: a KeyBundle must be sealed and signed by the device and the device admitted.
   Nothing found.
3. **Split view.** Olm is pairwise. C-OLM-01 lets one member give different members different
   histories; nothing detects that two members hold different text for one mid.
4. **Withheld or rolled-back revocation.** Sessions drop when a removal is learned (14 call sites of
   `enforce_device_revocations`, `node/swarm.rs:6676`); until then a removed contact device keeps
   receiving DMs. Lead L-05 belongs to the identity slice.
5. **Identifier or key-type confusion.** Every signed type checked has its own tag and names its
   subject (`hollow-keybundle`, `hollow-keyrequest`, `hollow-carried-keybundle`,
   `hollow-olm-identity`, `hollow-msg2/3`, `hollow-profile2`, `hollow-card1`, `hollow-destroy2`,
   `hollow-frame1\0`, `hollow-id1-*`, `hollow-crdt1`, `hollow-mls-leaf`, `hollow-nick1\0`,
   `hollow-ring1\0`); verification derives the signer id from the key, so a device signature never
   verifies as a master's; a bare master id is no device (G1, A-T18). The Ed25519 master key is also
   used for X25519 (DM rooms and pair keys, `node/dm_room.rs:92-107`), a reuse analysed as safe for
   these uses. Findings: C-OLM-01 (ambiguous field boundaries), C-OLM-06 (id aliases), C-OLM-07
   (untagged archive signature).
6. **Channel confusion.** KeyRequest, KeyBundle and Encrypted are Relay-lane only; a Carried message
   in the clear is dropped (`node/swarm.rs:5360`) and a Relay-lane message inside Olm is dropped
   (`:9189`); DM envelopes are refused over MLS; push fetch applies the same PreKey and DM gates.
   Nothing found.
7. **Unknown key-share.** C-OLM-03.
8. **Replay.** Seal nonce guard (RAM only, C-OLM-05); KeyRequest and KeyBundle 300 s windows; carried
   bundles 7 days plus single-use keys; Olm ratchet, 512 repeat digests and persisted read marks
   (AR-19 matches). Release builds accept absurd sender stamps by wrapping (C-OLM-04), sender-only.
9. **Downgrade and length checks.** `REQUIRE_SIGNED_KEY_EXCHANGE` is a constant true; absent
   signatures and identity proofs are refused; v1 message payloads are gone; the album is
   shape-checked. Open: inbound Olm v1 (C-OLM-08); optional `lp_digest` and `edited_at` steer the
   message check (C-OLM-01).
10. **Unauthenticated metadata.** Everything the Encrypted, KeyBundle and KeyRequest arms read is
    inside the sealed body; the DM `convo` field is the signing context, so it is checked. The seal
    does not cover the relay opcode (room, topic, public) or the topic, and no client reads either
    (`WsEvent::Message` has no topic; `fetch.rs` drops it when splitting). `SyncMessageItem.lp_digest`
    is read into the signed payload unchecked (C-OLM-01).
11. **State and key lifecycle.** One-time keys are removed only after the PreKey authenticates
    (vodozemac 0.9 `account/mod.rs:289`); slots are saved with the account; account and session are
    two writes through one queue; sends are persisted asynchronously and pickles are
    last-writer-wins across the app and the push process (C-OLM-09). Olm state never leaves the
    device in a backup or link snapshot (`storage/messages.rs:2909-2922`, test
    `snapshots_leave_device_secrets_behind_both_ways`); `olm_read_marks` is not scrubbed (metadata
    only, harmless on another device id).
12. **Device linking and cloning.** A new device mints its own Olm account; contacts get the
    `new_device` warning once the roster counts it. The link handshake is the identity slice's.
13. **What a stranger can trigger or observe.** A stranger can make us mint one one-time key per
    device id it controls (256 slots, oldest dropped, account rewritten per mint), open an Olm
    session with us (first contact by design, one stored pickle per stranger device, never deleted
    from the DB by the 7-day prune), and make us send it a KeyRequest per undecryptable frame (2 s
    throttle, only to itself). It cannot make us re-key with anyone else. With one friend request it
    can watch our presence indefinitely (C-OLM-02). The relay can spend any one-time key it relays
    (C-OLM-03). Checked and harmless: the `both_directions` bit our post-rekey DmSyncRequest carries
    is constant on 0.12 installs (`devices_for(own master)` always holds our own device,
    `node/swarm.rs:6548`), so it reveals nothing.

## STRIDE grid

Processes (S, T, R, I, D, E):

| Element | Cell | Verdict |
|---|---|---|
| P-A node Olm/seal (E-02) | S | covered: transport:A-T18 (seal against the key in `from`, own echo, bare master), dm:A-DM-01..03 (HOL-SEC-003, -053, -083); relabel by the relay: candidate C-OLM-03 |
| P-A | T | requirement met: seal over room, route, stamp, nonce and body hash, strict verify (`node/frame_auth.rs:77-88`, `:158`); Olm MAC; DM master signature before store (`node/swarm.rs:7880-7900`); field-boundary ambiguity: candidate C-OLM-01 |
| P-A | R | requirement met by design: DMs and channel posts master-signed (non-repudiable); key exchange device-signed |
| P-A | I | requirement met: Olm per device, Carried lane never in the clear (`node/swarm.rs:5360`); KeyBundles show only device ids and public keys (C-24 routing metadata); DM room presence: candidate C-OLM-02 |
| P-A | D | candidate C-OLM-04 (debug panic); requirement met: retire and KeyRequest only toward the sealing device, 5 s and 2 s throttles (`node/swarm.rs:7688-7735`); stranger session and slot growth: phase G (AR-01) |
| P-A | E | covered: dm:A-DM-01..21, transport:A-T18; carried attribution `node/swarm.rs:9182-9195` |
| P-B push fetch and NSE (E-04) | S | covered: transport:A-T00, A-T02, A-T03, A-T11; seal at `node/fetch.rs:365`, bare master at `:354` |
| P-B | T | requirement met: same seal, `verify_olm_identity` before `open_prekey` (`node/fetch.rs:996-1000`), DM signature (`:1090`) |
| P-B | R | n/a: the push process signs nothing but its relay auth |
| P-B | I | requirement met: decrypts on the device into the SQLCipher DB only; wake payload is the relay_push slice (C-26) |
| P-B | D | requirement met: no teardown or KeyRequest from fetch (`node/fetch.rs:1007-1018`); not reachable by C-OLM-04 (fetch does no stamp subtraction); pickle concurrency: C-OLM-09 |
| P-B | E | covered: transport:A-T00..A-T12, dm:N-03 |
| P-C forwarder Olm responder | S | covered: dm:N-02, HOL-SEC-109 (`forwarder/signaling.rs:239-264`) |
| P-C | T | requirement met: seal, PreKey identity proof (`forwarder/signaling.rs:470`), Olm MAC |
| P-C | R | n/a |
| P-C | I | requirement met: only its own Olm traffic; media is SFrame ciphertext (AR-14 for the pin) |
| P-C | D | candidate C-OLM-04 (debug-built forwarder: `is_stale` at `forwarder/signaling.rs:257`, key-request stamp); slots bounded at 256 (dm:N-02) |
| P-C | E | covered: dm:N-02, media:A-MED-09 |

Data stores (T, I, D):

| Element | Cell | Verdict |
|---|---|---|
| S-A Olm state at rest (`olm_account` with slots, `olm_sessions`, `olm_read_marks`) | T | requirement met: inside the SQLCipher DB, written only by our own actor; rollback window: C-OLM-09 |
| S-A | I | requirement met: never in backups or link snapshots (`storage/messages.rs:2909-2922`); read marks left in (metadata, harmless) |
| S-A | D | n/a for remote input: pickles are produced locally; a failed read-mark load only loses quiet drops (`crypto/olm_manager.rs:141-144`) |
| S-B in-RAM caches (replay guard, repeat digests, retired sessions, `LOCAL_MASTERS`, resolver) | T | requirement met: written only by our own code from verified inputs (resolver from rosters, wiki security_write_gates sections 21-23) |
| S-B | I | n/a: same process (P-09 on a running device is AR-04) |
| S-B | D | candidate C-OLM-05 (guard lost on restart); per-sender caps hold (16,384 nonces, 512 digests, 4 retired); sender count unbounded: phase G |

Flows (T, I, D):

| Flow | Cell | Verdict |
|---|---|---|
| F-20 KeyBundle/KeyRequest | T | requirement met: signature binds sender, recipient, both keys and stamp; carried tag distinct (`node/crypto_handler.rs:506-531`, `:753-765`) |
| F-20 | I | requirement met per C-24: device ids and public keys only; the relay can spend keys it reads: C-OLM-03 |
| F-20 | D | candidate C-OLM-03 (drop-equivalent), C-OLM-04 (debug panic); stranger flood bounded (dm:A-DM-01 residual); relay drop is AR-04 |
| F-21 DM envelope | T | requirement met: Olm MAC plus v2/v3 master signature on live and fetch paths (dm:A-DM-13, transport:A-T03) |
| F-21 | I | requirement met: one Olm copy per roster device that is live or holds a session (`node/message_ops.rs:480-545`) |
| F-21 | D | covered: AR-19 (Olm remainder); relay drop AR-04 |
| F-22 friend request/accept | T | covered: dm:A-DM-05, A-DM-09..12 |
| F-22 | I | candidate C-OLM-02 (DM room presence to the requester, declined included); card sealing covered by HOL-SEC-062 |
| F-22 | D | n/a in this slice (mailbox volume is phase G) |
| F-23 DM sync | T | candidate C-OLM-01 (DM batch re-split of our own messages by the friend); covered: dm:A-DM-19, A-DM-20 |
| F-23 | I | requirement met: carried only, only the requester's own conversation (dm:A-DM-19) |
| F-23 | D | n/a beyond phase G |
| F-24 1:1 call signals | T | requirement met: Olm only (`Lane::CallSignal` dropped in the clear at `node/swarm.rs:5360`; `MessageEnvelope::CallSignal` at `:9173`), judged by seal time |
| F-24 | I | requirement met: the SFrame key rides inside Olm |
| F-24 | D | requirement met: a held invite never rings (test `authz_a_call_invite_held_back_by_the_relay_never_rings`) |
| F-25 profiles | T | covered: HOL-SEC-038, HOL-SEC-062 (`hollow-profile2` over every field) |
| F-25 | I | covered: HOL-SEC-057, HOL-SEC-062 (`profile_audience`) |
| F-25 | D | n/a (light announce, other slice) |
| F-26 block list | T | n/a: local DB |
| F-26 | I | requirement met: blocking is local and silent (`api/storage.rs:678-692`); it does not stop C-OLM-02 |
| F-26 | D | n/a |
| F-SEAL every relay frame (client end) | T | requirement met: any byte change breaks it (test `any_change_to_a_sealed_frame_breaks_it`) |
| F-SEAL | I | requirement met: integrity only; room, route, stamp and nonce are routing metadata the relay already has |
| F-SEAL | D | candidate C-OLM-04, C-OLM-05 |
| F-DMR DM room membership | T | requirement met: the name is HMAC over X25519 of the two masters; a small-order key names no room (`node/dm_room.rs:87-107`) |
| F-DMR | I | candidate C-OLM-02 |
| F-DMR | D | n/a (relay availability, AR-04) |

External interactors (S, R):

| Interactor | Cell | Verdict |
|---|---|---|
| X-2 relay | S | covered: transport:A-T18, HOL-SEC-053 (cannot forge `from`), A-T21 (relay text frames carry no authority) |
| X-2 relay | R | n/a: we keep no relay statement as evidence |
| X-3 peers | S | covered: dm rows; ids are key-derived; misbinding: C-OLM-03 |
| X-3 peers | R | requirement met: master-signed content |
| X-4 own siblings | S | covered: identity rows, G1 `roster_book::heard_from` (`node/roster_book.rs:772`) |
| X-4 own siblings | R | requirement met: signed roster statements (identity slice) |

## Requirements

| ID | Requirement | Evidence | Guard test |
|---|---|---|---|
| R-OLM-01 | A relay or peer cannot make us act on a frame whose Ed25519 seal does not verify strictly against the key inlined in `from`, for this room and this route. | `node/frame_auth.rs:127-165`; `node/swarm.rs:5061`; `node/fetch.rs:365`; `forwarder/signaling.rs:245` | `authz_the_relay_cannot_send_a_frame_in_a_members_name`, `authz_a_sealed_frame_cannot_be_moved_to_another_room_or_device`, `any_change_to_a_sealed_frame_breaks_it` |
| R-OLM-02 | The relay cannot echo a device's own frame back to it. | `node/swarm.rs:5051`; `node/fetch.rs` (`from == peer_id`); `forwarder/signaling.rs:241` | `authz_the_relay_cannot_echo_a_devices_own_frame_back_to_it` |
| R-OLM-03 | A relay cannot make a live-only frame count twice or after 300 s (within one process lifetime). | `node/swarm.rs:5110-5117`; `node/frame_auth.rs:273-296` | `authz_a_live_frame_is_taken_once_and_only_while_fresh` (restart: none, C-OLM-05) |
| R-OLM-04 | A relay cannot make us build an outbound Olm session from keys the claimed device did not sign for our device within 300 s (live) or for our master within 7 days (carried). | `node/crypto_handler.rs:615-655`, `:806-857`; `node/swarm.rs:7426-7470`; `node/social.rs:683` | `substituted_olm_keys_are_rejected`, `bundle_signed_by_impostor_is_rejected`, `bundle_reflected_at_third_party_is_rejected`, `stale_bundle_is_rejected`, `verify_carried_bundle_accepts_valid_and_rejects_tampered` |
| R-OLM-05 | No one can make us build an inbound session on a Curve25519 identity key the sealing device did not sign, on the live, fetch, NSE or forwarder path. | `node/swarm.rs:7575`; `node/fetch.rs:996`; `forwarder/signaling.rs:470`; vodozemac `account/mod.rs:236` | `authz_olm_prekey_relay_cannot_open_a_session_as_another_device`, `authz_a_push_prekey_opens_only_with_its_senders_own_proof`, `fwd_opens_a_prekey_only_with_its_senders_own_proof` |
| R-OLM-06 | A revoked, removed or bare-master device cannot key-exchange or open a PreKey session with us, before or after a restart. | `node/crypto_handler.rs:657-675`; `node/resolver.rs:161-178` | `key_exchange_rejects_device_outside_signed_list`, `authz_a_removed_device_stays_refused_after_a_restart`, `bare_master_gates_stay_wired` |
| R-OLM-07 | A stranger's KeyRequests can hold at most one of our one-time keys per requesting device and 256 in all, and never push out a carried key. | `crypto/olm_manager.rs:261-285`, `:70` | `authz_one_device_holds_one_of_our_one_time_keys`, `a_key_request_flood_never_spends_a_carried_key`, `one_requester_holds_one_key_across_repeats`, `key_request_slots_survive_a_restart` |
| R-OLM-08 | Only the sealing device itself can make us retire its session or ask it to re-key; a relay replay (repeat or sealed at or before the read mark) changes nothing, across restarts. | `node/swarm.rs:7383-7420`, `:7554`, `:7613`, `:7677-7735`; `crypto/olm_manager.rs:187-222` | `authz_a_replayed_olm_frame_leaves_the_session_alone`, `olm_a_frame_replayed_after_a_restart_leaves_the_session_alone`, `olm_a_sender_back_on_an_older_copy_of_its_session_is_re_keyed`, `read_marks_survive_a_restart_and_never_move_back`, `a_push_fetched_dm_moves_the_olm_read_mark` |
| R-OLM-09 | A message the relay must not read never counts in the clear, and a carried message counts only as sent by the device whose session decrypted it. | `node/swarm.rs:5360`, `:9182-9195` | `c24_a_plaintext_copy_of_an_olm_only_message_is_dropped`, `c24_server_traffic_rides_mls_or_olm` |
| R-OLM-10 | A decrypted DM reaches the store and UI only if the sender's master signed it for us (v2/v3, size and future bounds). | `node/swarm.rs:7880-7900`; `node/fetch.rs:1090` | `a_dm_reaches_the_ui_only_after_its_signature_verifies` |
| R-OLM-11 | When we learn a device was removed, its Olm sessions are dropped and deleted, and no DM fan-out targets it. | `node/swarm.rs:6676-6700`; `node/roster_book.rs:68-73`; `node/message_ops.rs:480-545` | `device_revocation_cuts_off_and_ghost_fanout_holds` |
| R-OLM-12 | A stranger who sent us a friend request we have not accepted (pending or declined) never sees our devices in the DM room. | NOT MET: C-OLM-02 | none |
| R-OLM-13 | A third party serving history cannot make a signed message verify with different field boundaries than its author signed. | NOT MET: C-OLM-01 | none |
| R-OLM-14 | A DM room name cannot be computed from the two public master ids, and a small-order key names no room. | `node/dm_room.rs:87-107` | `the_room_is_not_computable_from_the_public_ids`, `a_small_order_key_names_no_room`, `with_no_local_key_the_room_is_nobody_elses` |
| R-OLM-15 | A 1:1 call signal counts only inside Olm and only while its frame is fresh. | `node/swarm.rs:5360`, `:9173`; `node/types.rs:4234` | `plaintext_call_signal_is_rejected`, `authz_a_call_invite_held_back_by_the_relay_never_rings` |
| R-OLM-16 | Simultaneous key exchange settles on one session per device pair. | `crypto/olm_manager.rs:383-389`; `node/swarm.rs:7394-7405`, `:7470-7490` | `olm_glare_with_a_repeated_key_request_settles_on_one_session`, `olm_key_request_crossing_a_prekey_is_answered_on_the_same_session` |
| R-OLM-17 | The ratchet follows the wire: a direct send never overtakes carried frames queued earlier for the same device. | `node/olm_lane.rs:165-175` | `node_code_encrypts_olm_only_in_turn`, `olm_a_direct_burst_behind_a_waiting_carry_keeps_the_session` |
| R-OLM-18 | No Olm account or session state leaves the device in a backup or link snapshot. | `storage/messages.rs:2909-2922` | `snapshots_leave_device_secrets_behind_both_ways` |
| R-OLM-19 | No sender-chosen time stamp can panic a node or forwarder in any build profile. | NOT MET: C-OLM-04 | none |
| R-OLM-20 | Every Ed25519 verification is strict (dalek `verify_strict`, libsodium on the relay). | L-04 list above | none (no source scan guards it) |
| R-OLM-21 | A forwarder answers only sealed, fresh, once-seen key requests and opens a PreKey only with its sender's own proof. | `forwarder/signaling.rs:239-264`, `:382-440`, `:470` | `fwd_takes_a_key_request_once_and_only_while_fresh`, `fwd_refuses_an_unsealed_frame_from_a_first_contact`, `fwd_opens_a_prekey_only_with_its_senders_own_proof` |
| R-OLM-22 | A peer cannot make the master key alone speak as a device (a bare master id is heard only for roster notices). | `node/roster_book.rs:772`; `node/swarm.rs:5081`; `node/fetch.rs:354` | `authz_the_master_key_alone_never_speaks_as_the_bare_master_id`, `bare_master_gates_stay_wired` |
