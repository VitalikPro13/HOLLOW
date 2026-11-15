# HOL-SEC-085: Any server member could make us forward a file to its gossip neighbours

```
ID:          HOL-SEC-085                 Status: Fixed on local main (2026-10-02), retest at
                                          release
Severity:    Medium                      (Impact M: the ciphertext of a file from another
                                          conversation or a restricted channel reached server
                                          members it was never for, without its key; disk and
                                          bandwidth spent on it; Exploitability M: any member
                                          of a server with six or more members who knows a
                                          file id)
Category:    Files / Authorization
Component:   rust/hollow_core/src/node/file_handler.rs (channel file send, WebRTC
             completion), gossip.rs, types.rs (MessageEnvelope::BroadcastMeta)
Boundary:    TB-4 (server members)
Traces to:   C-18, C-30; HOL-SEC-025 (restricted-channel files)
Attacker:    a member of a server large enough to use the gossip overlay
Found:       2026-10-02 (phase B re-check, new types row 17)
```

## Description

A `BroadcastMeta` envelope told every member of a server to relay a file id onward. It
bound nothing: any member could name any file id, and our next WebRTC transfer carrying
that id, from any conversation, was sent on to that server's gossip neighbours. The
honest use never worked, since a gossip transfer carries its broadcast id and never the
file id, so the bytes it pushed sat unmatched at every receiver. The same push also sent
a restricted channel's file to gossip neighbours who cannot see that channel.

## Fix

The gossip file relay is deleted: the envelope, the pending relays and the push. Members
of a server with six or more members pull a file from whoever holds it, which is what
already delivered every such file.

## Test

Unit `a_broadcast_meta_envelope_arms_nothing` (failed before the fix: the envelope still
parsed and armed a relay).
