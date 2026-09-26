# HOL-SEC-002: A relay operator can decrypt every device-link snapshot, master key included

```
ID:          HOL-SEC-002                 Status: Open (confirmed by code reading, exploit not yet reproduced)
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

## Exploit

1. Mallory runs a relay (or has access to one: the official VPS, a community's
   self-hosted relay, a compromised host) and logs `claim_link_code` codes, or
   notes the master id of any stream tagged `LinkSnapshot`.
2. Alice links a new phone. The populated device shows its confirm prompt,
   Alice accepts, and the snapshot streams through Mallory's relay.
3. Mallory runs `import_backup`'s decryption with the logged code (or Alice's
   public master id) and obtains Alice's master identity key, device key,
   SQLCipher contents (DMs, servers, friends) and, if selected, files and vault.
4. With the master key Mallory can sign as Alice, publish device lists adding
   her own device, and issue master-signed orders. Nothing on Alice's side
   shows it happened.

Passive: nothing is altered in transit, so no user-visible failure.

## Fix

- **Short term:** the rendezvous value sent to the relay must not be the
  passphrase, and the passphrase must not be derivable from anything the
  relay sees. A hash of the code as the room id is NOT enough: the code space
  is about 30 bits, so the relay brute-forces it offline.
- **Long term (class kill):** a PAKE (CPace or SPAKE2) keyed by the code, so
  the relay can at best make one online guess per attempt, or an ephemeral
  X25519 exchange between the two devices confirmed by a short
  authentication string compared on both screens. The mnemonic path should
  derive its key from the mnemonic secret, never from a public id.

## Variants to search

Every place a secret is derived from a value that crosses the relay in
plaintext: room names, relay JSON commands, `ws_room_for_peer` rooms, backup
and share passphrases, invite fragments, `.hollow` exports, vault shards.

## Test

To write: a harness test where the relay double records every frame and
every JSON command, then attempts to decrypt the `LinkSnapshot` stream using
only what it recorded. Must succeed before the fix and fail after.
