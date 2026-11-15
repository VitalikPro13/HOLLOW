# Brief for the authorisation-matrix enumeration (Hollow security audit, phase B)

You are gathering EVIDENCE for an authorisation matrix. You are not deciding
policy and you are not fixing anything. Another reviewer will re-read every
file:line you cite, so precision beats volume.

Repo root: C:\Users\Jabun\Documents\Coding\HOLLOW
Rust core: rust/hollow_core/src (node/, crdt/, crypto/, identity/, forwarder/, vault/, storage/)
Relay (C++): relay-uws/src

## Hard rules

1. READ-ONLY. Do not edit, create or delete any file in the repo. Do not run
   cargo, flutter, git write commands, or any build/test: the tree is shared
   with a session that is running tests. Reading, grep, and writing YOUR
   OUTPUT FILE in the scratchpad are the only writes allowed.
2. Every claim of a check or a state change carries `path:line` that you
   actually read, plus a short VERBATIM quote of the line (or the key part of
   it). Never infer a check from a comment, a doc, a function name or the wiki
   `tools/hollow-memory/wiki/security_write_gates.md`; that wiki is the claim
   under test, not evidence. Read the code.
3. If you cannot find something, write `NOT FOUND` (and where you looked).
   Never guess a line number.
4. Follow calls: if a handler calls `foo()` which does the check, open `foo()`
   and cite the line inside it that decides.

## Attacker model (what "authorised" must survive)

- P-01 hostile relay: reads every relay-visible byte and JSON, drops, delays,
  reorders, replays, and injects frames with ANY `from`/sender value, lies about
  room membership and presence. It cannot forge Ed25519 signatures or break
  Olm/MLS/AES without a key it was handed.
- Every peer attacker runs a modified client with VALID keys for its OWN
  identity (master + devices) and signs its own messages correctly. The
  question is never "is it signed" but "is the signer allowed to say THIS
  about THIS object".
- Principals to keep distinct: relay-stamped sender DEVICE id (`peer_str`,
  `from`), the MASTER that device resolves to (`resolver::resolve`), the key
  that signed a payload, a CRDT `op.author`, an MLS leaf credential, and the
  object the message NAMES (a device, master, server, channel, member, role,
  message id, file id, order target...).

## Output

Write your full result to the output file named in your task (in the
scratchpad directory). Then reply with (a) the output file path, (b) the list
of SUSPICIONS only, one line each with file:line. Keep the reply short.

For EACH inbound message type in your scope, one section:

```
### A-?? <Enum>::<Variant>  (short description of what it changes)
- Dispatch sites (every transport that can deliver it): plaintext HavenMessage
  arm / Olm MessageEnvelope arm / MLS MessageEnvelope arm / fetch.rs (push
  background node) / relay topic 0x07 ring / sync backfill / gossip re-flood /
  WebRTC data channel. One bullet per site with path:line.
- Handler: fn name, path:line
- Target object: what the message NAMES and by which field(s)
- State changes: every write in order, path:line + quote: store writes
  (MessageStore::*), CRDT/ServerState, resolver writes, RAM maps that change
  later behaviour, Olm/MLS session or group changes, events emitted to Dart that
  make Dart act (wipe, navigate, ring, delete), outbound sends made on the
  sender's behalf.
- Checks before the FIRST state change, in order, path:line + quote, and WHICH
  principal each one checks (sender device / resolved master / signer key /
  op.author / leaf credential / nothing).
- Who can sign: exact signed payload (quote the format string) and which key,
  or "unsigned (authority = transport sender)".
- Binding: the line that ties the signer's/sender's authority to the TARGET
  object named in the message. Quote it. If there is none, write
  `NONE FOUND` in capitals.
- Transport parity: are the checks identical at every dispatch site? List
  every difference with path:line.
- Freshness / replay: what stops an old valid copy (version, ts window, dedup
  id, one-time key, in-memory stamp...). Does it survive a restart? Or
  `NONE FOUND`.
- Absent fields: each security-relevant `Option`/`#[serde(default)]` field and
  what happens when it is absent or empty (reject / accept as legacy /
  preserve).
- Blast radius: irreversible? local only or propagates to others?
- Tests: names of existing tests exercising a REJECTION on this path (grep
  node/test_harness.rs and #[test] fns). "none found" is a valid answer.
- SUSPICION (0..n): anything that looks like authenticated-but-not-authorised,
  a gate missing on one transport, absent-means-accept, a relay-controlled or
  sender-controlled field trusted for authority, a check on the wrong
  principal (device vs master, deliverer vs author), a state change BEFORE its
  check, or a remote-triggerable panic. Give the concrete exploit shape in two
  or three lines (Alice = victim, Mallory = attacker, which principal Mallory
  is: relay, stranger, friend, member, admin, revoked sibling...). Mark your
  confidence: CONFIRMED-BY-READING (you followed every line) or PLAUSIBLE.
```

Useful anchors (verify, lines may drift by a few):
- `node/swarm.rs`: WsEvent arms ~3874-4600 (RoomMembers 3874, BinaryDirect
  4385, KillSignal 4419, Message/DirectMessage 4560);
  `apply_remote_crdt_op` 6119; `handle_incoming_request` 6436..14168.
  Inside it: KeyRequest 6507, KeyBundle 6570, Encrypted (Olm decrypt) 6682 and
  its MessageEnvelope match ~6969..9400; HavenMessage arms from 9448 (SyncRequest)
  onward; MlsChannelMessage 10884 and its MessageEnvelope match ~10980..11540;
  MlsKeyPackage 11679, MlsWelcome 11858, MlsCommit 11982, MlsEpochProbe 12000,
  MlsCommitCatchup 12016, MlsKeyPackageRequest 12071, FriendRequest 12111 ...
  VoiceChannel* ~14034..14151.
- `node/sync_handler.rs`: `handle_envelope_*` (MLS-delivered twins).
- `node/fetch.rs`: the push background node's own ingest (HavenMessage ~470,
  Encrypted ~717, kill frame 227).
- `node/crypto_handler.rs`: verify_* helpers, device lists
  (`ingest_device_list`, `device_list_binds_sender`, `speaks_for`),
  `verify_key_exchange`, `channel_readable_by`.
- `crdt/server_state.rs`: `admit_remote_op`, `op_allowed`, `apply_op`.
- `node/resolver.rs`: the device->master map (every WRITE to it is
  security-relevant).
- `node/types.rs`: HavenMessage (1374..2930), MessageEnvelope (2931..),
  SignedDeviceList (68), DestroyIdentity (95).
- `relay-uws/src/ws_handler.cpp`: relay command and binary opcode handlers.
