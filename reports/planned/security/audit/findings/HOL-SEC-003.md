# HOL-SEC-003: A relay operator can open an Olm session in any device's name and read that device's DMs, history included

```
ID:          HOL-SEC-003                 Status: Fixed on local main (2026-09-26), retest at release
Severity:    Critical                    (Impact H: DM history, new DMs, file keys and call keys readable, unsigned envelopes forgeable;
                                          Exploitability H: from the relay position it is unilateral, repeatable and silent on first contact)
Category:    Authentication (identity misbinding, class 7 of the plan's section 2.2)
Component:   rust/hollow_core/src/node/swarm.rs :: handle_incoming_request, HavenMessage::Encrypted PreKey branch (~6697-6875)
             rust/hollow_core/src/node/fetch.rs :: olm_decrypt_payload / create_inbound_prekey_session (~769-825)
             rust/hollow_core/src/forwarder/signaling.rs (~399, ~427), rust/hollow_core/src/push_enrich.rs (~355)
             rust/hollow_core/src/crypto/olm_manager.rs :: create_inbound_session (106)
Boundary:    TB-1 (client <-> relay), TB-2 (peer <-> peer)
Traces to:   C-08, C-10, C-21, C-30; threat model F-20 (KeyBundle / KeyRequest), AT-3 "MITM the key exchange"; authz row A-DM-03
Attacker:    P-01 hostile relay (the official operator, any self-hosted operator, anyone who compromises a relay host)
Found:       2026-09-26, phase B, walking the KeyBundle row: "what authenticates each Curve25519 key that ends up in a session?"
```

## Description

The 0.8.2 fix (`REQUIRE_SIGNED_KEY_EXCHANGE`) signs the RESPONDER's Olm keys:
`KeyBundle` carries a device signature over
`hollow-keybundle:{sender_device}:{recipient_device}:{identity_key}:{one_time_key}:{ts}`,
so the side that builds the OUTBOUND session knows whose keys it is using.

The other side is not covered. The initiator's first message is a PreKey frame,
`HavenMessage::Encrypted { message_type: 0, body, identity_key }`, and the
receiver builds its INBOUND session on the frame's `identity_key`
(`olm.create_inbound_session(&peer_str, their_identity, &ciphertext)`, swarm.rs
6729 and 6799). Nothing binds that Curve25519 key to `peer_str`: it is not
signed, not in the device list, and not compared with anything. `peer_str` is
the sender id the relay stamps. The Olm identity key pin
(`security_alerts::note_olm_identity_key`) only raises an alert when a
previously pinned key changes, and pins silently on first contact.

vodozemac needs one of the receiver's unused one-time keys. The relay has them:
every `KeyBundle` crosses it in plaintext, and a signed `KeyRequest` replayed
inside its 300 s window makes the receiver tear down its session, mint a fresh
one-time key and send it out in a new bundle, which the real requester ignores
because it still holds a session. On an existing session the receiver's
"undecryptable with existing session" branch removes the real session before
building the relay's (swarm.rs 6728).

Once the relay holds the session, everything the receiver authorises by
"it arrived over this device's Olm session" is the relay's to use:

- whatever the receiver encrypts to that device: new DMs, `FileHeader`s with
  their AES keys, call signals with SFrame keys;
- plaintext requests the receiver answers over that session:
  `DmSyncRequest` (swarm.rs 10650) serves the conversation's history, and
  `DmSiblingSyncRequest` (10716) serves EVERY conversation when the relay
  impersonates one of the user's own devices;
- every envelope that carries no signature of its own: `CallSignal` (a call
  that rings as the contact, with a media key the relay chose), `Typing`,
  `FileHeader`, `SessionAck`, and the rest.

Master-signed content (DM text, edits, deletes) still cannot be forged.

## Reproduction

`authz_olm_prekey_relay_cannot_open_a_session_as_another_device`
(node/test_harness.rs), using only relay powers. Before the fix the receiver
accepted a session in its contact's name, rang a forged call, and the relay read
both new DMs and the earlier history. An existing pinned key raised one alert; a
first contact raises none.

## Fix

- **Short term:** every PreKey frame carries the sender DEVICE's signature over
  its Olm identity key, `hollow-olm-identity:{sender_device}:{identity_key}`
  (new fields on `HavenMessage::Encrypted`, sent only on type 0). Every consumer
  (swarm, fetch, forwarder signalling, the iOS extension) verifies it against
  the relay-stamped sender with `verify_message_signature` (the key must derive
  to `peer_str`) and applies `key_exchange_device_unauthorized` BEFORE touching
  any session: an absent or wrong proof drops the frame and leaves the existing
  session alone. Absent means reject, like the signed key exchange.
- **Long term (class kill):** one `authenticate_inbound_olm_key(sender, key,
  proof)` choke point that every inbound session creation must pass, so an
  unauthenticated `create_inbound_session` cannot be written; a CI guard that
  `create_inbound_session` is called only there. Separately, plaintext requests
  whose answer is served over a session (`DmSyncRequest`,
  `DmSiblingSyncRequest`, channel sync requests) deserve their own
  authentication: they should ride the Olm session themselves or be signed, so
  the answer never depends on the relay's word about who asked.

## Variants to search

- Every place a Curve25519 or Ed25519 key arrives in a frame and is used to
  build a session or verify later traffic without a signature by the claimed
  owner: carried bundles (signed, fine), forwarder signalling, the NSE fork.
- Every plaintext request answered over a session or to the requesting device:
  `DmSyncRequest`, `DmSiblingSyncRequest`, `SiblingStateSyncRequest`,
  `FriendListRequest`, `ChannelSyncRequest`, `ProfileRequest`, `FileRequest`,
  `LinkSnapshotRequest`. Authority there is the relay-stamped `from`.
- Every "decrypt failed, tear down and rebuild" branch: a frame that is not yet
  authenticated must never destroy authenticated state.

## Fix as built (2026-09-26)

`HavenMessage::Encrypted` gained `identity_sig` / `identity_pk`. Every frame is
built by `crypto_handler::encrypted_frame`, which attaches the proof that
`bind_olm_identity` signs once per node (swarm event loop, standalone
forwarder). `verify_olm_identity` runs before any session is created or torn
down in swarm.rs, fetch.rs and the forwarder. Absent means refused: a client
without the fix can no longer open NEW sessions with one that has it; running
sessions are unaffected (the same trade-off the signed key exchange shipped with).

Left open, tracked separately: `key_exchange_device_unauthorized` lets a
revoked device through because it resolves to itself (candidate F5); a garbage
NORMAL frame with a spoofed `from` still tears a session down (candidate A14);
`hollow_push_decrypt` is an exported, unused fork decrypt that still trusts the
frame's key (candidate O4, delete it).

## Test

`authz_olm_prekey_relay_cannot_open_a_session_as_another_device`: failed before
the fix on all three counts (call rang, new DM read, history read); passes after,
with the relay attaching a proof signed correctly by its own device key. The
Olm, friend, call and forwarder tests on the same path (57) pass, and the full
suite was 893/894 with the only failure the sleep-budget ratchet, since fixed.
