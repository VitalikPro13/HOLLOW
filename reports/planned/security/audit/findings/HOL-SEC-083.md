# HOL-SEC-083: The master key alone could act as the bare master id

```
ID:          HOL-SEC-083                 Status: Fixed on local main (2026-10-02), retest at
                                          release
Severity:    High                        (Impact H: the identity's DM history, friends,
                                          servers with their join keys, and writes as one of
                                          its devices; contacts filed its DMs and profile under
                                          the owner; Exploitability M: needs the master key,
                                          which every backup and every removed device holds)
Category:    Identity / Authorization
Component:   rust/hollow_core/src/node/resolver.rs, roster_book.rs, swarm.rs (frame
             ingress, room presence), fetch.rs, crypto_handler.rs
             (key_exchange_device_unauthorized), mls_authority.rs (via disowns)
Boundary:    TB-3 (own identity and its devices), TB-2 (contacts)
Traces to:   C-01, C-03, C-08, C-09; HOL-SEC-077 (design ID-1)
Attacker:    a holder of the master key whose device the roster does not count (a
             restored backup nobody approved, a removed device)
Found:       2026-10-02 (phase B re-check, G1)
```

## Description

Design ID-1 says the master key alone admits no device. The relay lets a client log in
as the id of any key it holds, so a master-key holder could log in as the master id
itself. Every "is this one of our devices" check then accepted it: the resolver mapped
a master id to itself, so it compared equal to our own identity; key exchange read an id
that resolves to itself as first contact; the MLS leaf check never judged a leaf whose
device id is the master id; a carried roster attributed its sender by resolving it. Our
own devices served it the sibling lanes (DM history, friends, servers with their join
keys, emotes, read markers) and took its writes, and contacts opened sessions with it,
filed its DMs and profile under the owner and fanned the owner's DMs out to it.

## Fix

A master id is a device only when the roster we hold for it counts it (a pre-multi-device
install, whose device id is its master id). The resolver keeps the set of masters whose
roster it holds and no longer maps a master id to itself on its own;
`resolver::is_bare_master` names the rest. Frames from such an id are dropped at every
door (relay frames, stream chunks, the push fetch node) except the roster notice, whose
statements verify alone; room presence never lists it; key exchange refuses it; its MLS
leaf is disowned; a carried roster attributes only a linked member.

## Test

Harness `authz_the_master_key_alone_never_speaks_as_the_bare_master_id` (failed before
the fix: the owner's device served its friend list and DM history); units
`authz_a_master_id_is_a_device_only_while_its_roster_counts_it`,
`room_presence_follows_whether_a_master_id_is_a_device`, `bare_master_gates_stay_wired`,
`a_master_id_is_bare_only_under_a_roster_that_leaves_it_out`; mutation pass 24/24.
