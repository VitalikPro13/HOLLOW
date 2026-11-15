# HOL-SEC-071: A legacy server's catch-up rings went to whoever signed for them first

```
ID:          HOL-SEC-071                 Status: Fixed on local main (2026-09-29); relay DEPLOYED
Severity:    Low                         (Impact L: a pre-0.12 server's relay catch-up and parked
                                          joins stopped, or its ciphertext kept a week, and the
                                          owner's own settings refused; nothing readable, peer sync
                                          unaffected; Exploitability M: needs the server id and to
                                          sign before the owner or a mod, or after every ring of
                                          the room was dropped)
Category:    Missing authorization
Component:   relay-uws/src/ring_auth.h :: topic_prefix, in_own_topics, ring_namespace;
             ws_handler.cpp :: handle_set_topic_buffer, apply_ring_control, create_topic_buffer;
             rust/hollow_core/src/node/ring_auth.rs :: ring_topic, topic; every topic send,
             subscribe, catch-up and registration site; test_harness.rs (MockRelay)
Boundary:    TB-1 (client <-> relay)
Traces to:   C-25; HOL-SEC-065 residual
Attacker:    P-06 anyone with a legacy server's id
Found:       2026-09-29 (A-D4 residual, session 17)
```

## Description

A 32-hex server id names no owner, and anyone may file a join lock under one in their
own name. The relay kept one set of rings per room, so the first owner whose lock
signed a ring control owned them: a stranger signing first (or after every ring of the
room had been dropped, which HOL-SEC-070's churn could force) could stop them or stretch
their retention, and the real owner's controls were refused without a word.

## Reproduction

`authz_a_legacy_servers_rings_follow_its_owner_not_the_first_signer`
(node/test_harness.rs): a stranger files its own lock and signs for rings BEFORE the
owner returns; the owner's registration still makes its rings, the stranger can neither
name the owner's topics nor stop them.

## Fix

A legacy server's ring topics carry the owner: `{owner}.{channel}`, and `{owner}.~join`
(`ring_auth::ring_topic` in Rust, `topic_prefix` in C++). The relay counts a signed
control only when every channel lies in the topics of the owner it is signed for
(`in_own_topics`, part of `authorized`), a signed stop reaches only that owner's topics,
and the per-server cap counts per owner (`ring_namespace`). Members name the owner their
state anchors (`anchor_owner`, the invite's `owner=` for a joiner) in every send,
subscription, catch-up and registration, so a lock filed in someone else's name reaches
only rings no member uses. The first-signer binding and its snapshot field are gone
(codec v6 still reads v5). A self-certifying id names its one owner, so its topics stay
plain channel ids.

## Test

The harness test above, `a_legacy_servers_topics_carry_its_owner`,
`a_legacy_control_reaches_only_its_owners_topics` (node/ring_auth.rs); C++
`test_ring_auth` (the legacy namespace and `ring_namespace` checks). Mutation pass: the
client registering plain topics (fails the harness test at the owner's registration),
and the prefix check dropped (fails at "never one in the owner's topics").

## Residual

A joiner of a legacy server whose invite carries no `owner=` uses plain topics, so its
parked join is not seen by members (AR-10 territory: such links cannot pin the owner
either).
