# HOL-SEC-039: A replayed edit reverted text, and a replayed reaction came back

```
ID:          HOL-SEC-039                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Low                         (Impact L: a message shows text its author already replaced; a
                                          reaction its author removed is back; Exploitability M: the relay holds
                                          every plaintext copy, and a stale sync responder serves old ones)
Category:    Replay (missing ordering)
Component:   rust/hollow_core/src/storage/messages.rs :: edit_message_in, add_reaction, remove_reaction
Boundary:    TB-1 (relay), TB-2 (peer <-> peer)
Traces to:   C-09; candidates B10, B11 (evidence channel:S10, S11)
Attacker:    P-01 relay, P-05 server member
Found:       2026-09-26, phase B channel pass; confirmed by reading 2026-09-27
```

## Description

Each edit is signed with its own time, but the store applied any edit whose text
differed, so an older signed edit put back replaced text. A reaction removal was
recorded only as evidence, never read on the way in, so a replayed add, or an add
the relay delivered after its removal, brought the reaction back.

## Reproduction

`authz_an_older_edit_never_reverts_a_newer_one`,
`authz_a_removed_reaction_stays_removed` (storage/messages.rs tests).

## Fix

- An edit applies only when it is newer than the row's last edit.
- A reaction removal is always recorded (even when the add has not arrived), and
  an add signed no later than a recorded removal of the same reaction by the same
  person is refused. A later re-add counts.

## Test

Both tests fail with the old rule put back and pass with the fix. Full suite green.
