# HOL-SEC-053: Every plaintext frame was attributed to the sender the relay stamped

```
ID:          HOL-SEC-053                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Critical                    (Impact H: the relay could delete any server for everyone
                                          through its owner's own device, unfriend anyone, plant
                                          friends and accept requests through the sibling lane, kick
                                          members, cancel or force joins, mark conversations read,
                                          answer a data-channel offer with its own DTLS fingerprint and
                                          hear screen-share audio; Exploitability M: needs the relay
                                          the victim uses)
Category:    Missing authentication
Component:   rust/hollow_core/src/node/frame_auth.rs (new), node/swarm.rs (inbound arms, sealing
             stage), node/fetch.rs, forwarder/signaling.rs, node/types.rs (removed variants)
Boundary:    TB-1 (client <-> relay)
Traces to:   C-25, C-01, C-12, C-15, C-16, C-21; candidates A2..A13, A15, A16, N1 (unsigned
             profile fields), S-20
Attacker:    P-01 malicious relay
Found:       2026-09-26, phase B; the server-delete path confirmed by reading 2026-09-27
```

## Description

The relay stamps `from` on every frame it forwards, and every plaintext
`HavenMessage` handler took that stamp as the sender. Nothing bound a frame to
its sender, its room or its recipient. The legacy `ServerDeleteBroadcast` arm,
fed a frame stamped with the owner's id, made the owner's own device author a
genuine owner-signed delete that every member then accepted.

## Reproduction

`authz_the_relay_cannot_send_a_frame_in_a_members_name`,
`authz_a_sealed_frame_cannot_be_moved_to_another_room_or_device`,
`authz_the_relay_cannot_echo_a_devices_own_frame_back_to_it` (node/test_harness.rs),
and the `frame_auth` unit tests.

## Fix

- Every peer payload on the relay (0x03, 0x07, 0x04, image directs, 0x09, 0x02
  stream chunks) is sealed by the sending DEVICE: an Ed25519 signature over a
  `hollow-frame1` tag, the room, the route (the room or the target device), a
  millisecond stamp, a nonce and the body's hash. One sealing stage sits in front
  of the relay connection, so nothing leaves unsealed.
- The main node, the push fetch node and the media forwarder open every frame
  against the key inlined in `from` before reading it; a frame moved to another
  room or device, delivered the wrong way, stamped with our own device or dated
  past our clock is refused. Unsealed frames are refused (breaking, decision 1).
- `ServerDeleteBroadcast`, `PeerDisconnecting`, `Ack`, `FileProbe`,
  `FileProbeResponse` and `RecoveryStatus` are gone: none had a sender, or a
  receiver, left.

## Test

Each test fails with its old rule put back and passes with the fix (scripted
mutation pass). Full suite green apart from a known load flake.
