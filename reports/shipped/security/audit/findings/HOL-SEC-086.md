# HOL-SEC-086: A push wake from anyone moved the live Android node into a room with them

```
ID:          HOL-SEC-086                 Status: Fixed on local main (2026-10-02), retest at
                                          release
Severity:    Low                         (Impact L: the sender learned we were online and
                                          got a key exchange from us; Exploitability M: any
                                          stranger who can trigger a push to us, or the relay)
Category:    Push / Privacy
Component:   rust/hollow_core/src/api/network.rs (nudge_live_dm_fetch),
             node/fetch.rs (run_fetch, dm_wake_room)
Boundary:    TB-1 (relay), TB-2 (contacts and strangers)
Traces to:   C-13, C-24, C-26; HOL-SEC-035 (the channel-wake twin)
Attacker:    a stranger, or the relay forging a wake
Found:       2026-10-02 (phase B re-check, transport A-T12)
```

## Description

On Android a DM push wake asks the running node to join the DM room of the wake's
sender, so the relay replays what it buffered. The sender named in the wake was never
checked: a wake naming a stranger made the node join a pairwise room with that stranger
as a full socket, which showed us online there and started a key exchange with it. The
fetch node, used when no node runs, joined the same room. HOL-SEC-035 closed the channel
half of this; the DM half was never raised.

## Fix

One gate, `fetch::dm_wake_room`, for both paths: a DM wake joins a room only with our own
identity or an accepted friend we have not blocked. Any other wake joins nothing.

## Test

Unit `a_dm_wake_from_a_stranger_joins_nothing` (failed before the fix: the fetch node
connected for a stranger's wake); `a_dm_wake_names_only_ourselves_or_a_friend`, which also
checks that the live node's nudge asks the gate.
