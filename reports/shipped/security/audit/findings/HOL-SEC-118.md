# HOL-SEC-118: Olm channel changes for a server we no longer hold were applied

```
ID:          HOL-SEC-118                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact L: reactions and author edits on rows of a
                                          server we left; Exploitability M: any device holding
                                          an Olm session with us)
Category:    Authorisation / Channel content
Component:   rust/hollow_core/src/node/message_ops.rs (olm_change_for_unknown_server),
             node/swarm.rs (the five Olm change arms)
Boundary:    TB-2 (contacts), TB-3 (server members)
Traces to:   phase B matrix channel A-CH05 (session 32)
Attacker:    any device holding an Olm session with us
Found:       2026-10-03 (matrix rebuild)
```

## Description

Leaving a server deletes its state and ops but keeps its channel rows as history. The
Olm arms for channel edits, link cards, deletions and reactions passed the state they
found for the server (none) to handlers that judge a missing state as "nothing to
judge", so any device holding an Olm session with us could attach its own signed
reactions to that server's old rows, and an old author could still rewrite its posts
there. The Olm post arm already refused a server we do not hold.

## Fix

Every Olm channel change arm first asks `olm_change_for_unknown_server`: a change that
names a server we hold no state for is refused before any handler, the same rule as
posts. The public arms keep their guest path (guests write to the in-memory guest store,
HOL-SEC-095).

## Residual risk

None known on this path. MLS changes need a group of that server, which a leave tears
down.

## Test

`authz_olm_channel_changes_need_a_server_we_hold` (node/message_ops.rs tests: the rule,
and every Olm change arm asks it); mutation 3/3 killed (`tmp_s32_lead_mutate.py`).
