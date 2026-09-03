# Hollow Security Audit — September 2026

**Date:** 2026-09-03
**Target:** Hollow, at commit `e0be717` (branch `main`)
**Scope:** the full application — Rust core (`rust/hollow_core`), the relay
(`relay-uws`), the Flutter client (`lib`), and the shop backend
(`anonlisten-sites/shop`) that issues the credentials the client pins.
**Method:** internal white-box review, self-directed. Eight parallel domain
reviewers against Hollow's own documented invariants, a dependency scan
(`cargo audit` cross-checked for reachability), and dynamic proof-of-concept
tests driving the real code paths. This was NOT a third-party audit.

---

## 1. Executive summary

Hollow's cryptographic primitives are sound and its history of fixed disclosures
holds up. The message-signing pipeline, the Olm key exchange, MLS group
membership, the SFrame media scope for group voice, content-addressed assets, and
the shop credential chain were all examined adversarially and found solid.

However, this review found **four Critical issues**, each of which breaks a
core promise of the product, and each independently exploitable. Three of the
four were reproduced with running proof-of-concept tests. In plain terms:

1. **A server member can take over any server they are in.** CRDT operations
   carry a self-declared author string and are not signed, so a member can forge
   an operation as the owner and promote themselves, ban the owner, or delete the
   server. Proven.
2. **The relay can decrypt any 1:1 call.** The call's SFrame media key is sent to
   the other party in a plaintext frame the relay reads, never encrypted. Proven.
3. **A peer can write an arbitrary file to the victim's disk.** The inline-image
   receive path joins an unsanitized, attacker-controlled filename onto a
   directory and writes to it. This is the exact class the itsfolf disclosure
   closed for Hollow Share, reappearing in a second, unpatched path. Proven, with
   a benign `echo hello` payload landing outside the intended folder.
4. **The relay can silently misdirect a victim's direct messages to an
   attacker.** A signed device list is bound to whatever device delivers it, so
   an attacker can graft their own device into a stranger's identity and receive
   that person's DMs in plaintext. Confirmed by code analysis end to end.

There are also **four High**, **eight Medium**, and several Low and
informational findings, plus one substantive dependency issue in the MLS crypto
backend on ARM builds.

**Release-readiness verdict:** the store back end is well hardened and is close
to ready, but the app itself should not go to a wider release until at least the
four Criticals and the two client-side Highs are fixed. None of the four require
a sophisticated attacker; three need only a relay operator or an ordinary member,
and the difficulty ratings are all Low. The good news is that every Critical has
a clear, contained fix, and the two most dangerous ones (the call key and the
file write) are small changes.

### Findings at a glance

| ID | Title | Severity | Difficulty | Proven |
|---|---|---|---|---|
| CRDT-1 | Unsigned CRDT ops → server takeover via forged author | Critical | Low | PoC |
| TRANSPORT-1 | 1:1 call SFrame key sent plaintext to the relay | Critical | Low | PoC |
| FILE-1 | Inline-image filename path traversal → arbitrary file write | Critical | Low | PoC |
| CRYPTO-1 | Device-list poisoning → DM misdirection + permission impersonation | Critical | Low | code-confirmed |
| FILE-2 / DART-1 | Voice-flag/filename bypasses download gate + auto-runs ffmpeg | High | Low | code-confirmed |
| CRDT-2 | Unbounded HLC timestamp locks a server field forever | High | Low | PoC |
| RELAY-1 | Unbounded offline-buffer keys stall the relay event loop | High | Low | code-confirmed |
| RELAY-5 | `resolve_link_code` has no brute-force protection | High | High | code-confirmed |
| SHOP-1 | Relay can suppress a user's support marks before the pin engages | Medium | Low | reported |
| SHOP-2 | Crafted `.hollowpack` decodes an oversized image → OOM | Medium | Low | reported |
| FILE-3 | Vault shards carry no per-shard integrity → reconstruction DoS | Medium | Medium | reported |
| BACK-1 | Redeem endpoint has no per-code lock → double-mint race | Medium | Medium | reported |
| RELAY-2 | Dead `GET /bootstrap` leaks peer_id + IP with no auth | Medium | Low | code-confirmed |
| RELAY-3 | `check_peers` liveness oracle still live, guest-reachable | Medium | Low | code-confirmed |
| RELAY-4 | `/register` `/unregister` buffer the body with no size cap | Medium | Low | code-confirmed |
| RELAY-6 | Revoked device replays a stale list to read the master inbox | Medium | Medium | reported |
| DART-2 | Zero-tap ffmpeg probe on any auto-downloaded media | Low | Low | code-confirmed |
| TRANSPORT-2 | Call signaling uses first-match room → silent call loss | Low | Medium | reported |
| RELAY-7 | Offline-buffer deposit forces repeated push wake-ups | Low | Low | code-confirmed |
| BACK-2 | CSP allows `style-src 'unsafe-inline'` (no sink) | Low | — | reported |
| DEP-1 | libcrux constant-time/SHA3 bugs in the MLS backend on ARM | Medium | High | scan + trace |

Informational: TRANSPORT-3 (unwired gossip TTL), BACK-3 (per-process rate
limiters), CRYPTO-min (identity key not zeroized), a relay license-key error
oracle, and dependency notes DEP-2..DEP-5.

---

## 2. Scope and methodology

### 2.1 What was reviewed

Eight domains, one reviewer each, all read-only, against Hollow's documented
security invariants (`CLAUDE.md`, `WHITEPAPER.md §23`, and the wiki
`security_write_gates.md`):

1. Cryptographic core, key exchange, multi-device identity.
2. Message signing, CRDT sync, the remote-write gates.
3. File transfer, Hollow Share, Vault, the asset rail.
4. The relay (uWebSockets C++) — every opcode and handler.
5. Shop client side — `.hollowpack`, support credentials, Twitch credentials.
6. Transport, voice and call signaling, SFrame scope, the media forwarder.
7. The Flutter client — where remote content becomes local action.
8. The shop backend — the credential issuer and Creem webhook receiver.

### 2.2 Threat model

The load-bearing assumption, taken from Hollow's own whitepaper: **the relay
operator is untrusted.** The relay tells you which authenticated peer sent a
frame; it never tells you who authored the content inside it. The reviewers took
each of these adversaries in turn: a malicious relay or network attacker, a
curious or malicious server member, a guest in a public channel, an unfriended
stranger, a malicious friend, a malicious content author, and (mostly out of
scope) a local attacker with the device.

### 2.3 Rating scales

**Severity** by impact: Critical (E2EE break, remote code execution,
zero-interaction compromise, or full identity impersonation), High (forgery a
recipient accepts, auth bypass, cross-tenant access, deanonymization, persistent
DoS of a victim), Medium (limited forgery or censorship, metadata leak,
single-shot DoS), Low (hardening), Informational.

**Difficulty** by attacker cost, following Trail of Bits: Low (any peer or the
relay, scriptable), Medium (needs a role, a race, or a crafted artifact), High
(needs a privileged position, key material, or improbable timing).

### 2.4 Tooling and evidence

- **Static:** eight domain reviewers; every Critical was then re-verified by the
  author reading the cited code directly.
- **Dynamic:** proof-of-concept tests added to the crate that drive the real
  vulnerable functions with attacker input (Appendix A). Payloads were benign:
  the file-write proof drops `echo hello` into a self-deleting temp directory and
  only proves the path escapes; nothing was executed and no live service was
  touched.
- **Runtime baseline:** the existing adversarial suite (124 gate and rejection
  tests) passes in 27 seconds — the defenses that ARE in place hold at runtime.
- **Dependencies:** `cargo audit` over 583 crates, each advisory traced to its
  real reachability (Section 5).

---

## 3. Critical findings

### CRDT-1 — Unsigned CRDT operations allow server takeover

**Component:** `rust/hollow_core/src/crdt/operations.rs:11-16` (the `CrdtOp`
type), `crdt/server_state.rs:1214-1339` (`op_allowed`) and `:490-538`
(`apply_op`), `node/swarm.rs:6111-6132` (the `CrdtOpBroadcast` handler).
**Actor:** a server member. **Severity:** Critical. **Difficulty:** Low.
**Status:** reproduced (Appendix A, `poc_crdt1_*`).

`CrdtOp` has four fields — `server_id`, `hlc`, `author`, `payload` — and **no
signature.** The `author` is a plain string. When a `CrdtOpBroadcast` arrives,
the handler logs but does not reject an `author` that differs from the sender
("the op may be legitimately relayed"), then gates only on `op_allowed(op)`,
which checks whether the *claimed* author holds the required role. Nothing binds
the operation to the claimed author's key.

So any member who can put a frame into the server room can forge an operation.
Two variants, both proven:

- **Author spoof:** set `author` to the owner's peer_id (visible in any member
  list) and carry a `RoleChanged` promoting yourself. `op_allowed` asks "can the
  owner change this role" — yes — and applies it.
- **ServerCreated re-mint:** `op_allowed` returns `true` unconditionally for
  `ServerCreated` (server_state.rs:1338; a unit test at :1717 even asserts a
  "stranger" is allowed), and `apply_op` inserts the named `owner_peer_id` as
  Owner. Send `ServerCreated { owner_peer_id: me }` for an existing server and you
  are its owner.

From there: promote to Admin or Owner, ban the real owner, rename, change any
setting, or tombstone the server with `ServerDeleted`. The dedicated MLS handlers
for kick and server-delete DO bind the authenticated sender, but the generic
`CrdtOp` path that carries roles, members, channels and settings does not, and
it is the path the plaintext `CrdtOpBroadcast` fallback (present for MLS-epoch
resilience) uses, which the relay and any member can write to.

**Recommendation:** sign every CRDT op over `(server_id, hlc, author, payload)`
with the author's key, and verify that signature against `op.author` before
`op_allowed`, at every apply site (live, sync batch, and the plaintext
broadcast). Relaying stays fine because the signature travels with the op. Make
`op_allowed` reject `ServerCreated` for a server that already exists, and make
`apply_op` merge rather than overwrite `roles`/`members`/`name` on
`ServerCreated`.

### TRANSPORT-1 — The 1:1 call media key is sent to the relay in plaintext

**Component:** `rust/hollow_core/src/node/voice_handler.rs:140-224`
(`handle_call_send_signal`, `build_call_invite`, `build_call_accept`),
`crypto_handler.rs:2828-2846` (`send_message_to_peer`).
**Actor:** the relay operator or any network observer. **Severity:** Critical.
**Difficulty:** Low. **Status:** reproduced (Appendix A, `poc_transport1_*`).

When a 1:1 call starts, the client generates a fresh SFrame key and puts it,
verbatim, into a `CallInvite` message. That message is serialized to JSON and
sent through `send_message_to_peer` → `WsCommand::SendDirect`, with **no Olm
encryption anywhere on the path.** `CallAccept` echoes the same key back the same
way. The SFrame key is the AES-128-GCM key that protects the call's audio and
video. The proof-of-concept shows the exact frame the relay receives:

```
{"type":"call_invite","call_id":"call-1","video":true,"sframe_key":"00112233445566778899aabbccddeeff"}
```

The relay is explicitly untrusted. Any relay operator, or anyone who can read
relay traffic, recovers the call key. If the call is or can be forced to be
TURN-relayed (symmetric NAT, or the "always relay calls" setting), the same party
can also capture the ciphertext and decrypt the media live. The 1:1 call SDP and
ICE also ride this plaintext path, so the relay additionally sees the peers' ICE
candidates, i.e. their IP addresses.

This is specific to 1:1 calls. Group voice channels and conferences are
unaffected — they derive the SFrame secret from the MLS group's `export_secret`
and never put a key on the wire. The same file even Olm-encrypts the voice-
channel SDP/ICE lane through `send_encrypted_message` (voice_handler.rs:846), so
the fix pattern already exists in place.

**Recommendation:** never transmit `sframe_key` in a plaintext message. Either
derive the call's SFrame secret from an authenticated key agreement (as the
group path does) or Olm-encrypt the whole `Call*` family through the existing
`send_encrypted_message` pipe. Add a test asserting the serialized outbound
`CallInvite` never contains the raw key bytes.

### FILE-1 — Inline-image filename path traversal → arbitrary file write → RCE

**Component:** `rust/hollow_core/src/node/swarm.rs:8573` and
`node/fetch.rs:1156`, both `files_dir().join(format!("{fid}.{ext}"))` with raw
wire fields; `node/types.rs` `FileHeaderPayload` (`fid`/`ext` are plain strings).
**Actor:** a peer with an Olm session (a friend, or a stranger after one accept).
**Severity:** Critical. **Difficulty:** Low. **Status:** reproduced (Appendix A,
`poc_file1_*`).

The "offline inline image" feature delivers a small image to an offline DM peer
with the bytes riding inside the Olm-encrypted `FileHeader`. On receipt, the code
writes those bytes to `files_dir().join(format!("{fid}.{ext}"))`, where `fid` and
`ext` are attacker-controlled wire strings, **with no sanitizer.** An absolute
`fid` makes `Path::join` discard the base entirely; a relative `..\..\..` walks
out. The sanitizers that every other file path uses
(`file_transfer::final_file_path`, `share_handler::safe_file_name`) are simply
not applied here, in either of the two copies of this code.

The proof-of-concept, with a benign payload, wrote `echo hello` to a path
**outside** the intended `...\hollow\files` directory. Replace the target with
the Windows Startup folder (two `..` up from Hollow's data dir, always present,
no victim-specific knowledge needed) and the extension with `exe`, and this is
remote code execution. On default settings the write happens with zero
interaction: the default DM auto-download threshold is 169 MB and inline images
are tiny, so they pass the gate. If a user turned auto-download off, the voice-
flag bypass in FILE-2 forces the write anyway.

This is the same vulnerability class as the itsfolf Hollow Share disclosure
(GHSA path-traversal → RCE), in a second code path the original fix never
covered.

**Recommendation:** route both sites through `file_transfer::final_file_path`,
and additionally validate that `fid` matches the expected 64-hex-character shape
before any path use. Add the regression test that Hollow Share already has
(`unique_final_path_stays_inside_dir`) for both sites.

### CRYPTO-1 — Device-list poisoning misdirects DMs and impersonates permissions

**Component:** `rust/hollow_core/src/node/crypto_handler.rs:1355-1391`
(`ingest_device_list`), `swarm.rs:13481` (the ProfileUpdate handler ingests the
list before its profile-signature check), `crypto_handler.rs:666-679`
(`key_exchange_device_unauthorized`), `message_ops.rs:527-565`
(`collect_target_devices`), `crdt/server_state.rs:984` (roles resolve through the
same resolver). **Actor:** a stranger. **Severity:** Critical. **Difficulty:**
Low. **Status:** confirmed by code analysis end to end; not yet reproduced in the
harness.

A signed device list proves only that its master signed *the list*. It does not
prove that the device delivering it belongs to that master. But `ingest_device_list`
treats delivery as proof: for any validly master-signed list, it maps the
delivering device to that master and folds it into the persisted device set,
"even if it is not listed in `list.devices`" (the code's own comment). The
justification, "arrived in the master's room", is false — the delivering peer
chooses which room to send from and can carry any public signed list.

The attack: a victim hands out their signed device list on any room join
(including their inbox room, which accepts strangers). An attacker replays that
list inside a `ProfileUpdate` into a room they share with a target. The target's
`ingest_device_list` runs before any profile-signature check and maps the
attacker's device into the victim's identity, persisting it into
`devices_for(victim_master)`. Now:

- **DM disclosure.** `collect_target_devices` reads `devices_for(master)`, so the
  target's next DM to the victim is fanned to the attacker's device. The Olm
  authorization gate `key_exchange_device_unauthorized` reads the same poisoned
  `devices_for` set, so the session is authorized. The attacker decrypts the DM.
- **Permission impersonation.** Server role checks resolve `op.author` through
  the same process-global resolver, so on the poisoned peer, the attacker's own
  ops are locally accepted as the victim's.

Message-content signatures cannot be forged this way (they bind the master's
key), so this is disclosure and local-policy impersonation, not content forgery.
The only mitigation, a new-device alert, is a dismissible notice that fires after
the poisoning and never on first contact.

**Recommendation:** never register `sender → master` (or fold the sender into the
persisted list) unless the sender appears inside the master-signed `devices`
array — the same rule `key_exchange_device_unauthorized` already enforces for key
exchange. Move the profile-signature verification ahead of the device-list ingest
so the wrapping `ProfileUpdate` must itself be signed by the delivering peer's own
master.

---

## 4. High, Medium, and Low findings

### High

**FILE-2 / DART-1 — Voice flag bypasses the download gate and auto-runs ffmpeg.**
`file_handler.rs:94-115` exempts a file from the auto-download gate when
`voice || is_voice_message_name(name)`; both are sender-controlled, and `ext` is
a separate field, so a peer sends `name: "voice_1.ogg", ext: "exe"` and the file
is pulled to a receiver who set auto-download to off. On the Dart side
(`settings_provider.dart:743`, `audio_message_bubble.dart:70-103`), a file named
like a voice note is auto-pulled and then `AudioMessageBubble.initState` runs the
bundled ffmpeg on the attacker's bytes with no play tap — a memory-unsafe decoder
fed hostile input with zero interaction. This chains directly with FILE-1. *Fix:*
cap the exemption to a small conversational-audio size and verify the MIME/ext
actually names audio; never let it override an explicit off setting. Severity
High, difficulty Low.

**CRDT-2 — An unbounded HLC timestamp locks a field forever.** `AdminLwwReg::merge`
compares the op's `hlc.physical_ms`, which is attacker-controlled; the 5-minute
drift cap in `Hlc::witness()` bounds only local clock generation, not the compared
value. The proof-of-concept set `physical_ms` to `u64::MAX`, renamed a server to
"PWNED", and the real owner could not rename it back. Interestingly the drift
check logged a rejection during local generation, which confirms it never touches
the merge comparison. *Fix:* clamp `physical_ms` against wall-clock plus the skew
window at merge time, and reject ops from the future. Severity High, difficulty
Low. Reproduced (Appendix A).

**RELAY-1 — Offline-buffer key flood stalls the relay.** `state.offline_buffer`
has no cap on the number of distinct target keys (unlike `topic_buffers`, capped
at 65,536), and the target is an unvalidated client string. Once the 512 MB byte
budget is hit, `evict_over_budget` does an O(n) scan of every key on every insert,
on the single event-loop thread. A single connection with a disposable identity
can flood minimal `0x04` frames to unique fabricated targets and starve message
processing for every user. *Fix:* cap the distinct-key count, validate the target
shape, and replace the linear eviction with an ordered index. Severity High,
difficulty Low.

**RELAY-5 — `resolve_link_code` has no brute-force protection.** Device linking
reuses a 6-character code that, per the design, is the passphrase for the
transferred identity backup. `resolve_link_code` requires only authentication
(not even non-guest) and has no per-connection attempt cap; the only defense is a
5-minute TTL over a 36^6 keyspace. Exhausting that window against one live link is
not clearly practical on one relay core today, which is why this is difficulty
High, but there is zero defense-in-depth on a code that gates full identity
transfer. *Fix:* add a small per-connection attempt cap with backoff. Severity
High.

### Medium

**SHOP-1 — Relay can suppress a user's support marks before the pin engages.**
`gated_support_creds` refuses an unsigned or empty `support_creds` only once a
signed copy has been seen and pinned for this receiver, and an empty string is
treated as an unconditional "clear" with no signature check
(`social.rs:1358-1407`, `support_creds.rs:701-716`). A relay that rewrites the
field to `""` from the victim's first announce ensures the pin never activates,
so it can indefinitely hide a specific user's support and Twitch-owner marks from
any viewer with whom they share no MLS group (DM friends, guests). It cannot mint
marks, only suppress. *Fix:* commit `support_creds` inside the mandatory profile
signature, or establish the pin at first contact alongside the device list.

**SHOP-2 — Crafted `.hollowpack` decodes an oversized image.** `blob_shape`
(`hollowpack.rs:725-748`) fully decodes each pack image via
`image::load_from_memory` before the role dimension ceiling is checked. A tiny,
highly compressible WebP declaring a 16384×16384 canvas decodes to about 1 GB of
pixels; with up to 8 files per pack this is a realistic OOM, especially on mobile,
just from opening a pack. *Fix:* read the WebP header dimensions and reject over a
generous outer ceiling before decoding.

**FILE-3 — Vault shards carry no per-shard integrity.** `ShardMetadata` has only a
whole-content id; a malicious or corrupt shard holder's bytes are accepted at
store time and surface only as an opaque AES-GCM failure at full reconstruction,
with no re-fetch from a different holder. AES-GCM prevents a bad reconstruction
from being accepted, so this is availability, not integrity: a persistent, un-
self-healing per-content denial of service, easiest in full-replication mode on
small servers. *Fix:* add a per-shard hash, verify on fetch, retry from another
holder on mismatch.

**BACK-1 — Redeem endpoint double-mint race.** `redeem.js` has no per-code lock
between its `isKeyBurned` check and `burnKey`, across a span that includes a
Creem `validateKey`, a blind-sign subprocess (up to 30 seconds) and `activateKey`.
Two concurrent requests with different blinded messages can both pass the check
and both get a valid blind signature; the only thing preventing a double-mint is
Creem's activate endpoint being atomic. The sibling module `twitch_keys.js`
already has the `inFlight` lock this one is missing. *Fix:* add the same per-code
in-process lock.

**RELAY-2 — Dead `GET /bootstrap/:room_code` leaks peer_id and IP.**
`handle_bootstrap` (`http_handlers.cpp:194-223`) returns every registered peer's
id and raw addresses for any room code, with no auth — the deanonymization class
that was deliberately closed for the WS `discover_peers`/`check_peers` commands,
missed on this older HTTP surface. Current clients no longer populate that table
(retired 2026-07), so live impact is limited to stale clients and any future
regression, but the endpoint is still compiled and served. *Fix:* delete
`/register`, `/unregister`, and `/bootstrap`, matching the `/turn-credentials`
precedent.

**RELAY-3 — `check_peers` liveness oracle is only half removed.** The
room-membership sub-probe was neutered, but the online/offline liveness query for
arbitrary peer_ids remains, unthrottled and reachable by guests
(`ws_handler.cpp:1759-1786`). The "check_peers removed" note overstates the fix.
An attacker who knows a peer_id can poll a forced last-seen timeline. *Fix:*
gate it behind non-guest auth and/or a shared-room requirement, and correct the
internal note so future reviewers do not treat it as closed.

**RELAY-4 — `/register` and `/unregister` buffer the body with no size cap.**
`res->onData` accumulates the whole request body before any validation, unlike
every other bounded path in the relay. Slow large uploads are a pre-auth memory
DoS. *Fix:* add a small body cap, or delete these dead routes per RELAY-2.

**RELAY-6 — Revoked device replays a stale list to read the master inbox.**
`verify_signed_device_list` deliberately enforces no freshness or version, and
the relay holds no revocation state, so a revoked device (whose key is unchanged)
can authenticate and present its last pre-revocation signed list to keep reading
`inbox:{master}` — every future friend request to that master — indefinitely,
with no log the master would see. It is a passive read leak, not active
impersonation (clients validate a responder against the current list). *Fix:*
have the client sign a timestamp into the device-list payload and have the relay
reject a proof older than a day or two.

### Low and informational

- **DART-2 (Low).** The zero-tap ffmpeg probe fires for any auto-downloaded
  audio or video, not only the forged-voice case — defense-in-depth around a
  memory-unsafe decoder.
- **TRANSPORT-2 (Low).** 1:1 call signaling routes via a first-match room lookup
  rather than the deterministic DM room, so a stale presence view can silently
  drop a call invite. Route it through `send_message_to_peer_in_room`.
- **RELAY-7 (Low).** An offline-buffer deposit to a known peer_id forces a push
  wake-up every 10 seconds — a documented, deliberate tradeoff; noted for
  completeness. A per-sender cooldown would fix it without dropping reconnection
  bursts.
- **BACK-2 (Low).** The shop CSP allows `style-src 'unsafe-inline'` with no
  injection sink to exploit it.
- **TRANSPORT-3 (Info).** The gossip WebRTC-broadcast relay does not clamp TTL,
  but the path appears unwired (no client caller). Add the clamp before it is ever
  wired.
- **CRYPTO-min (Info).** `NativeKeypair` derives `Clone` and does not zeroize its
  secret bytes on drop — relevant only to a local memory-dump attacker.
- **Relay license-key oracle (Info).** Auth error responses distinguish
  invalid/in-use/required license keys, a minor enumeration oracle for the
  paywall, not for E2EE.
- **BACK-3 (Info).** The shop's in-memory rate limiters are per process, a
  documented tradeoff.

---

## 5. Dependencies and supply chain

`cargo audit` reported 8 advisories over 583 crates. Reachability was traced with
`cargo tree`; most are transitive and several are not in the shipped build graph.

**DEP-1 (Medium) — libcrux in the MLS crypto backend on ARM.**
`libcrux-secrets 0.0.5` (RUSTSEC-2026-0212, incorrect constant-time swap/select on
aarch64) and `libcrux-sha3 0.0.8` (RUSTSEC-2026-0207/0208, wrong SHAKE output and
an AVX2 panic) reach the app through `hpke-rs` → `openmls_rust_crypto`. They are
in the build graph for the ARM targets (macOS on Apple Silicon, iOS, Android), so
a constant-time correctness bug sits under MLS on real shipping platforms.
Fixes exist (libcrux-secrets ≥ 0.0.6, libcrux-sha3 ≥ 0.0.10). The already-planned
`openmls 0.8.1 → 0.9.0` upgrade is the natural carrier, but it must be verified to
actually lift libcrux to the fixed versions; if it does not, add a direct version
bump.

**Not reachable — dismissed.** `libcrux-chacha20poly1305 0.0.7` and
`libcrux-aesgcm 0.0.7` advisories are not in the build graph for any shipped
target (checked for Windows, macOS/iOS/Android ARM); lockfile-only.

**Lower-priority, tracked.**
- `openmls 0.8.1` (DEP-2, Low): the 0.9.0 upgrade carries upstream MLS message-
  parsing fixes (out-of-tree commit sender, a deserialize panic, a
  GroupContextExtensions bypass), all reachable from any group member. Already
  planned.
- `rsa 0.10.0-rc.18` (DEP-3, Low): reached via `blind-rsa-signatures` in the
  credential path. The Marvin timing attack targets private-key operations; the
  client only verifies (public key), and the live issuer is the Node backend, so
  client impact is nil. Worth noting that a release-candidate crate sits in a
  security-critical path.
- `tract`/`memmap2` (DEP-4, Low): reached via the DeepFilterNet noise-suppression
  model loader; the model is bundled and trusted, so these are local-only, not
  network-reachable.
- `lru 0.7.8` unsoundness via vault erasure coding: triggers only on a panic in
  `pop()`. Low.
- Verify the bundled SQLite is ≥ 3.50.4 for the FTS5 CVE-2025-7709; and the usual
  unmaintained build-time crates (`instant`, `paste`, `proc-macro-error2`).

`cargo audit` is not currently installed in the toolchain or CI. Adding it to CI
(with a reviewed ignore list for the accepted local-only items) would keep this
list current automatically.

---

## 6. What was checked and found sound

A credible audit reports its negative space. The following were reviewed
adversarially and found solid, with no finding:

- **The message-signing pipeline.** v2 signatures bind text, reply target,
  attachment id, link-preview digest, ordering stamp and message id; backfill and
  sync reject both absent and forged signatures; edits, deletes, and reactions are
  verified per item; the `hidden_at` deletion proof is reject-absent; dedup is by
  message id. The code matches `security_write_gates.md` everywhere traced.
- **Olm key exchange.** Bundles and requests are device-signed, bound to
  recipient and freshness, and the device must appear in the master-signed list;
  the carried-bundle path is domain-separated against reflection; verification
  rejects rather than logs.
- **MLS and the relay auth binding.** The relay recomputes `peer_id` from the
  public key before the signature check (the 0.8.2 fix, present and correctly
  ordered); no command is reachable before auth; every forwarded frame's sender is
  the authenticated identity, never a client field.
- **Relay membership gates** on every live send and broadcast opcode
  (0x02/0x03/0x07/0x09 and the text commands), with a full opcode table produced;
  integer and length parsing is bounded throughout; the IPv4-mapped-IPv6 unmap in
  `ip_limit_key` is correct.
- **The shop credential chain.** Every credential binds a specific master, the
  full chain is verified before it is trusted or spent, follow credentials never
  ride a profile, the Twitch join gate resolves the joiner's master from the
  connection rather than a request field, the 90-day window uses the verifier's own
  clock, and a transplanted credential fails at the blind-signature check. The
  backend re-derives every Twitch fact server-side, verifies the Creem webhook HMAC
  with a body cap and PII scrubbing, uses constant-time token comparisons, and
  isolates tenants at the database layer.
- **`.hollowpack` and asset rail.** Import recomputes the hash and never re-encodes
  or joins an attacker path; the asset rail recomputes SHA-256, rejects non-WebP,
  size-caps per kind, and drops unsolicited hashes. The Hollow Share traversal fix
  and `parse_id` allowlist are intact (FILE-1 is a separate, unpatched path).
- **The forwarder and voice origin guards.** Client legs carry zero ICE servers;
  `inbound_origin_ok` drops spoofed screen origins; the forwarder treats the
  originator as the trust root and the feeder as supply only; conferences admit
  strictly through the MLS add.
- **The Dart client surfaces** other than FILE-2: link previews never fetch to
  render, deep links confirm before dangerous actions, the updater is hash-pinned,
  the Twitch token never leaves Rust, push payloads are routing-only, and there is
  no WebView or HTML rendering anywhere.

---

## 7. Remediation priorities

**Before any wider release (Critical + client Highs):**

1. Sign CRDT operations and verify against `op.author` before `op_allowed`; fix
   `ServerCreated` (CRDT-1). Also clamp the HLC merge timestamp (CRDT-2).
2. Stop sending the call SFrame key in the clear; encrypt the `Call*` family
   (TRANSPORT-1).
3. Sanitize the inline-image filename at both write sites (FILE-1), and cap the
   voice-note exemption so it cannot bypass the gate or feed ffmpeg unbidden
   (FILE-2 / DART-1).
4. Require the delivering peer to be inside the signed device list before binding
   it to a master (CRYPTO-1).

Each of these has a running or code-confirmed proof and a contained fix. Because
they touch signing and wire formats, add the inverted regression test alongside
each (Appendix A shows the vulnerable behavior; the fix should make the secure
assertion pass).

**Soon after (relay Highs and the crypto dependency):**

5. Cap the offline-buffer key count and fix the eviction scan (RELAY-1); add
   brute-force protection to `resolve_link_code` (RELAY-5); delete the dead HTTP
   endpoints (RELAY-2, RELAY-4).
6. Carry the `openmls 0.9` upgrade and verify it lifts libcrux to the fixed
   versions (DEP-1, DEP-2).

**Follow-ups:** the Mediums and Lows above, and adding `cargo audit` to CI.

**Store go-live:** the backend is well hardened; BACK-1 (the redeem lock) is the
one item worth closing first. The live Creem key, wiping the sample catalog, and
flipping to production remain a manual step for the owner.

---

## Appendix A — Proof-of-concept tests

These tests were added to the crate, run, and then removed (they prove the
vulnerability, so they pass while the bug exists; a regression test would assert
the secure behavior instead). The full source is preserved in the audit
scratchpad (`audit_poc.rs`). All five passed:

```
poc_crdt1_forged_server_created_grants_ownership .... ok   (member → Owner)
poc_crdt1b_author_spoof_promotes_attacker .......... ok   (author spoof → Admin)
poc_crdt2_unbounded_hlc_locks_a_field .............. ok   (u64::MAX → name locked)
poc_file1_inline_fileheader_writes_outside_files_dir ok   (echo hello outside files/)
poc_transport1_call_sframe_key_is_plaintext_on_the_wire ok (key in the frame)
```

Representative output:

```
[PoC TRANSPORT-1] relay-visible CallInvite frame contains the SFrame key verbatim:
  {"type":"call_invite","call_id":"call-1","video":true,"sframe_key":"00112233445566778899aabbccddeeff"}
[PoC FILE-1] a peer-controlled fid wrote `echo hello` to
  C:\Users\...\Temp\.tmpXXXX\pwned.txt, outside C:\Users\...\hollow\files
```

Each proof exercises the real vulnerable function with attacker input; the
file-write proof used a benign payload and a self-deleting temp directory and did
not execute anything.

## Appendix B — Method notes

Eight domain reviewers ran in parallel against the documented invariants; every
Critical was re-verified by reading the cited code directly before it was written
up. The runtime baseline (124 existing gate and rejection tests) passed
throughout. Reviewers reported false positives honestly and confirmed several
previously fixed classes were still closed; those are in Section 6. No live
service, real relay, or host system was touched during the review.

---

## Appendix C. Remediation record (started 2026-09-03)

This appendix is the working record of the fix pass that followed the audit.
It also absorbs the deferred items from the 2026-09-02 scanner triage (the
former `tmp2.md`), so this file is the single list to close.

### C.1 Corrections found while mapping the fixes

The mapping pass read every ingest site before any code was written and found
that three findings were under-called:

- **CRDT-1 is wider than described.** The sync-batch path
  (`crdt::sync::merge_ops`, used by `SyncResponse` on the plaintext, Olm and
  MLS paths) applies every payload except `ServerDeleted` with no `op_allowed`
  call at all, and the Olm-fallback single-op path (`swarm.rs` near line 9170)
  has no gate whatsoever. The wiki's claim that `op_allowed` ran at every
  ingest was false. The fix is therefore one admission function (signature,
  future-clock clamp, permission) that every remote ingest site calls, not a
  signature added to the two paths the audit named.
- **CRYPTO-1 has a third unguarded path.** Besides the two `ProfileUpdate`
  handlers, the `FriendRequest` handler ingests the carried device list first,
  inside the stranger-reachable inbox mailbox. `ServerJoinRequest` and
  `FriendReject` already implement the correct membership check; the fix
  makes the rule live inside `ingest_device_list` itself.
- **TRANSPORT-1 is also an integrity break.** A relay that can read the
  call key can inject a `CallAccept` carrying its own key. Encrypting the
  family is not enough on its own; the plaintext `Call*` arms are removed so
  a plaintext call signal is rejected outright.

### C.2 New finding recorded during remediation

**CRDT-3 (Medium), the join-time state snapshot is trusted wholesale.**
`ServerStateSnapshot` is accepted from any peer while our own join is pending,
and its embedded registers are adopted without validation. Signed ops close
the live forgery, but a malicious admitting member can still hand a joiner a
poisoned view of that one server. Blast radius is the joiner's local view;
other members validate the joiner's later ops against their own state. This
pass clamps future clocks inside the snapshot. The full fix is a signed genesis
model, where a joiner rebuilds from the owner-signed `ServerCreated` forward
and treats the snapshot as a cache; that is a follow-up design, blocked on
older servers whose op logs are skeletal.

### C.3 Decisions that differ from the audit's recommendations

| Finding | Audit recommended | Decision and reason |
|---|---|---|
| RELAY-6 | Sign a timestamp into the device list; relay rejects proofs older than a day or two | The relay keeps a per-master high-water mark of the highest signed list `version` it has verified and refuses lower ones. Same protection, no wire-format change, no new cross-language test vector, and a revoked device is cut off the moment the master's live device reconnects rather than after a grace window. |
| SHOP-1 | Commit `support_creds` inside the profile signature, or pin at first contact | The field's own master signature becomes mandatory. Unsigned or badly signed values are refused and the stored value preserved, pinned or not. The trust-on-first-use pin is retired. Same outcome, less machinery. |
| CRDT-1 migration | Not discussed | Clean break. Unsigned ops are rejected everywhere, including old history served during a join. With one active user a permissive phase buys nothing, and a permissive phase on a public repo is a published hole. |
| FILE-2 | Cap the exemption and verify the type; never override an explicit off | A genuine voice note (flag set, voice-note name, `ogg` extension, at most 8 MiB) still overrides the global threshold, because that is the documented product rule. It no longer overrides a per-conversation "never". Dart mirrors the predicate and checks the container's magic bytes before any decoder runs. |
| BACK-2 | (Low, no sink) | Accepted. Twelve components bind CSS custom properties through `style=` attributes, which a nonce cannot cover. `img-src 'self' data:` leaves no exfiltration channel. Recorded in the shop README. |
| License-key oracle | (Info) | Accepted. The client shows three distinct messages on purpose, and the keys gate a paywall, not encryption. |
| TRANSPORT-3 | Clamp before wiring | Clamped now at both the relay function and the FFI door, even though the Dart producer is still a stub. |

### C.4 Carried over from the 2026-09-02 scanner triage

These were judged real on 2026-09-02 and deferred to a dedicated pass. They are
part of this fix pass.

| ID | Item | Severity | Notes |
|---|---|---|---|
| DEP-2 | openmls 0.8.1 to 0.9.0 with companions on the 0.6 line | Medium | Upstream fixes reachable from any group member: a commit from a sender outside the tree (#2186), an out-of-bounds panic in `DeserializeBytes` (GHSA-rrmv-c79f-cf5r), extensions rejecting trailing bytes, a bare GroupContextExtensions proposal bypassing the proposal machinery (#2125). Semver-major. The MLS persistence layer reaches into the memory-storage crate's internal map and dumps it in a hand-rolled format, so the upgrade is verified against a fixture captured from the current code before the bump. |
| DEP-1 | libcrux constant-time and SHA3 fixes on ARM | Medium | Carried by DEP-2: `openmls_rust_crypto 0.6` pins `hpke-rs 0.7`, which pins `libcrux-sha3 0.0.10` and `libcrux-secrets 0.0.6` exactly. The lift is proven with `cargo tree` after the bump. |
| DEP-6 | rusqlite 0.34 to 0.40.2 for the bundled SQLCipher amalgamation | Medium | The bundled SQLite is 3.45.3, not the 3.46.1 the June report assumed. CVE-2025-7709 (FTS5, reachable through message search over peer content) is fixed at 3.50.3. The SQLCipher amalgamation lags plain SQLite: rusqlite 0.37 still ships 3.46.1, 0.38 is the first safe version (3.50.4), 0.40.2 ships 3.51.3. rusqlite 0.38 removed the default `u64`/`usize` conversions. Android OpenSSL stays on the env-var scheme. |
| DEP-7 | weezl and moxcms (GIF LZW and ICC parsing) | Low | Denial of service, not code execution, on peer-sent images. Both are pinned by `image 0.25.10`, the newest 0.25 release, so there is nothing to bump yet. Re-check `cargo info image` for 0.25.11 or 0.26; when it lands, bump in `hollow_core`, re-seed `hollow_art`'s lock for the encoder crates, and run the encoder tests. |
| CI-1 | GitHub Actions hardening | Low | Pin the ten third-party actions to commit SHAs, `persist-credentials: false` on the four checkout steps, a read-only workflow-level `permissions` block in `ci.yml`, `contents: write` scoped to the release job in `build-ffmpeg.yml`, and a `dependabot.yml` for the `github-actions` ecosystem. |
| CI-2 | `cargo audit` in CI | Low | A CI job with a reviewed ignore list for the accepted local-only advisories. |

Also still tracked outside this file: the Aikido export keeps seven rows
un-ignored on purpose (the six Actions items and openmls above, plus weezl and
moxcms). The per-issue table lives outside the repo at
`C:\Users\Jabun\Documents\Coding\Aikido_hollow_issues\TRIAGE_2026-09-02.md`.

### C.5 Follow-ups deliberately left open

- **Hollow Share signaling (`RtcOffer`, `RtcAnswer`, `RtcIceCandidate` and the
  share variants) still rides plaintext.** The relay sees SDP and ICE for a
  data channel whose payload is AES-encrypted with keys that ride Olm, so the
  exposure is metadata and a DTLS fingerprint the relay could in principle
  rewrite to sit on ciphertext. Low. It uses the same mechanism as the call
  fix and is a separate unit so the share reconnection dance is not destabilised
  in the same release.
- **CRDT-3** as above.
- **Vault multi-holder retry** if the shard-request path cannot address an
  alternate holder cheaply (the unit reports what a retry needs).
- **Call ring-all.** Calls still target one deterministically chosen device of
  the callee. Unchanged by this pass.

### C.5a New finding surfaced during verification

**FRIEND-1 (Low, correctness, pre-existing) — friend re-add can re-form the
friendship on one side without fresh consent.** The harness test
`readd_while_online_requires_fresh_consent` fails intermittently, about one run
in six in isolation: after A removes B and re-adds while both are online, A can
end up listing B as an accepted friend off a stale accept that B never sent for
the new request, while B correctly holds only a pending incoming request. This
is not caused by this pass. The same assertion failed on 2026-08-28 before any
of this work, and this pass does not touch the auto-accept drain
(`pending_friend_accepts`); the only change to the friend-request handler is the
CRYPTO-1 device-list guard, and the test fails on A's state after the request
has already reached B. It is a friend-state-machine timing race, out of scope
here, and left for a dedicated pass because touching that code to chase a flake
would destabilise the friend paths this release already changed. Peer sync keeps
it from being a lost message; the visible effect is a one-sided friend row.

### C.5b Fixed under this pass beyond the audit list

**PROFILE-1 (Medium, denial of service) — a peer's profile image was stored and
later decoded with no dimension bound.** Found while mapping FILE paths: the
profile-update handler stored an incoming avatar or banner blob and decoded it
later with the same full-decode call the pack bug used, so the SHOP-2
decompression bomb reached a second, wider path (any format, not only WebP, and
zero interaction). Closed by routing every image decode in the crate through one
bounded decoder and validating an incoming profile image's header and byte size
before it is stored.

### C.6 Status

"Fixed" means the regression test exists, was shown failing against the old
behaviour with an honesty proof, and is green with the full suite. Verification
as of 2026-09-03: the Rust suite passed three full runs (789 then two clean at
793, zero failed), `cargo audit` is clean on the new tree, `cargo check`,
`cargo clippy` and `flutter analyze` are clean on the changed files, the relay
built and its three test programs passed on the Linux build VM, and the shop
suite is 652 passing. Every security-bearing diff was read line by line.

The fleet was then run on two fresh identities against the real relay. The
server journey passed end to end: create, invite, join, member attribution,
channel messages both ways with one row each, owner delete, and the delete
tombstone reaching the other member. Every server operation now travels as a
signed CRDT op through the new admission gate, so this is CRDT-1 proven between
two installs that never met. The friend journey established the friendship with
its signed device list, converged on both sides, and delivered the first DM;
that exercises the CRYPTO-1 device-list binding across fresh installs in both
ingest directions. The reverse DM was not confirmed because a sidebar row's
centre was covered and the probe's click could not open the conversation, a
probe interaction limit on this build, not a protocol fault. Neither instance
logged a runtime error.

Not committed and not deployed. This is client-side security on a public repo,
so it goes to a `security/<version>-audit` branch and is held until release day
per the embargo rule. The relay deploy is binary-only and could go earlier, but
it waits for the owner's go because it touches the live host.

| ID | Status |
|---|---|
| CRDT-1, CRDT-2, CRDT-3 clamp | fixed, harness-verified |
| TRANSPORT-1, TRANSPORT-2 | fixed, harness-verified |
| CRYPTO-1 | fixed, harness-verified, fleet-confirmed across fresh installs |
| SHOP-1 | fixed, harness-verified |
| FILE-1, FILE-2, FILE-3, SHOP-2, CRYPTO-min, TRANSPORT-3 | fixed, harness-verified |
| PROFILE-1 (new, see C.5b) | fixed, harness-verified |
| DART-1, DART-2 | fixed, analyze + widget tests green |
| RELAY-1 to RELAY-7 | fixed, built and tested on the VM; deploy pending owner go |
| BACK-1 (BACK-2 accepted) | fixed, shop suite green; deploy is the owner's manual step |
| DEP-1, DEP-2, DEP-6, CI-1, CI-2 | done, patch applied, lock regenerated, audit clean |
| FRIEND-1 (new, see C.5a) | pre-existing flake, out of scope, left for a dedicated pass |
