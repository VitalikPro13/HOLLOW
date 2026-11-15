# HOL-SEC-119: A channel delete or a refused reaction reached the screen unchecked

```
ID:          HOL-SEC-119                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Info                        (Impact L: a row or a reaction shown hidden or added
                                          until the next reload, nothing stored;
                                          Exploitability L: needs a store that fails to open,
                                          or a replayed reaction)
Category:    Integrity / UI events
Component:   rust/hollow_core/src/node/message_ops.rs (handle_envelope_delete_message,
             handle_envelope_add_reaction), node/swarm.rs (the Olm DM reaction arm)
Boundary:    TB-3 (server members)
Traces to:   phase B re-check channel A-CH04 (suspicion S12, never carried), A-CH05
Attacker:    any sender of a channel delete or reaction
Found:       2026-09-26 (S12), confirmed 2026-10-03 (matrix rebuild)
```

## Description

The live channel delete ran every check inside the store open, but sent
`ChannelMessageDeleted` outside it: when the store failed to open, a delete from anyone
for any message id reached the app unchecked. The live reaction add sent its event
whether or not the store took the reaction, so an add the store refused (a replay older
than its reactor's own removal, the per-reactor cap) still showed.

## Fix

The delete event is sent only after the row, the signature and the hide all passed; a
store that does not open ends the handler. A reaction add is shown only when the store
took it, as a removal already was, on the channel and the Olm DM paths.

## Residual risk

None known.

## Test

`authz_a_channel_change_reaches_dart_only_once_stored` (node/message_ops.rs tests: a
delete with an unopenable store and a replayed reaction show nothing); mutation 2/2
killed (`tmp_s32_lead_mutate.py`).
