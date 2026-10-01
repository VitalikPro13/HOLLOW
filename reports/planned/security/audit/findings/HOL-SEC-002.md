# HOL-SEC-002: A relay operator can decrypt every device-link snapshot, master key included

```
ID:          HOL-SEC-002                 Status: Fixed on local main (2026-10-01), retest at release
Severity:    High, possibly Critical      (Impact H: total identity compromise; Exploitability M: needs the relay position, then passive)
Category:    Cryptography / Authentication
Component:   rust/hollow_core/src/node/link_handler.rs (handle_claim_link_code, handle_resolve_link_code,
             handle_accept_link_push), node/swarm.rs (AcceptLinkPush passphrase choice, mnemonic auto-request),
             node/ws_client.rs (claim_link_code / resolve_link_code JSON), relay-uws ws_handler.cpp (code map)
Boundary:    TB-1 (client <-> relay)
Traces to:   C-05, C-06, C-23; threat model flow F-12
Attacker:    P-01 hostile or compromised relay (official operator, any self-hosted operator, anyone with the relay host)
Found:       2026-09-26, while drawing the device-linking flow of the data-flow diagram
```

## Description

Device linking sends the populated device's full `export_backup` snapshot
(the `.hollow` zip, `identity.key` included) to the new device through the
relay, encrypted with Argon2id + AES-256-GCM under a passphrase. The
passphrase is a value the relay already holds:

- **Code path.** The passphrase is the 6-character link code
  (`export_backup_bytes(link_code, ..)`). The same code is sent to the relay in
  plaintext as `{"type":"claim_link_code","code":..}` and
  `{"type":"resolve_link_code","code":..}`, and again as the room name
  `link:{CODE}` in both devices' `JoinRoom`.
- **Mnemonic path.** With no code, both sides use the master peer id as the
  passphrase (`set_my_link_code(local_peer_str)`, and the `_ =>
  local_peer_str` arm in `AcceptLinkPush`). The master peer id is public: every
  friend, server member and the relay know it.

The whitepaper (section 3.4) says "the relay carries ciphertext only". The
relay does carry ciphertext, but it holds the key to it.

## Reproduction

`link_the_relay_cannot_open_the_snapshot` records every frame and command the mock
relay sees during a real link and tries to open the snapshot with each value it saw.
On the old code the link code itself was the passphrase, so the first try opened it.
Candidate I8 (two relay oracles that let a link code be guessed past the throttle) is
folded in here: a guessed rendezvous part opens nothing, and the secret part can only
be tried online, once per code.

## Fix (design ID-1, section 6)

The code has two parts: six rendezvous characters the relay sees (claim, resolve, the
`link:{rv}` room) and four secret characters it never sees. The two devices run SPAKE2
(RustCrypto `spake2`, Ed25519 group) keyed by the secret and bound to the rendezvous;
the presenter proves the key with an HMAC confirm before the joiner seals anything.
HKDF-SHA256 (salt = the rendezvous) gives one AES-256-GCM key per direction; the AAD
names the rendezvous and the direction. The joiner's hello and the presenter's offer
ride that channel; the snapshot travels under a fresh random 32-byte key carried in
the offer, never under anything the relay holds. The code answers ONE handshake: a
second device in the room is ignored and a hello that does not open burns it. The
mnemonic path (the public master id as the passphrase) is deleted; nothing reached it.
Code: `node/link_pake.rs` (new), `node/link_handler.rs` (rewritten),
`api/network.rs` `claim_link_code(rendezvous, secret)` / `resolve_link_code`.

## Test

`link_the_relay_cannot_open_the_snapshot` (no relay-visible candidate, nor the whole
code, opens the blob; the label is unreadable; the stash holds the presenter's vouch
for the device the joiner minted), `authz_a_relay_that_answers_the_code_gets_one_guess`
(relay as presenter: a wrong confirm and the joiner seals nothing; relay as joiner:
outside the room ignored, a second handshake ignored, a bad hello burns the code and
the real joiner gets `not_found`), `authz_link_frames_from_a_stranger_are_refused`,
`every_layer_binds_on_its_own` (link_pake: identities, salt, AAD and direction each
bind alone), `a_pending_link_installs_the_device_key_it_was_made_for`. Mutation pass:
9/9 link rules killed.

## Residual

A relay that plays one side gets one online guess at 20 bits per link attempt, and each
guess costs the person a new code. The rendezvous part tells the relay that a link is
happening and between which two connections.
