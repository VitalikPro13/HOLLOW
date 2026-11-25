# HOL-SEC-207: A member could re-admit someone who left, on a spare ask from before their second leave

```
ID:          HOL-SEC-207                 Status: Fixed in 0.14.1
Severity:    Low                         (Impact L: a former member is listed as a member
                                          again against their will, so members' fan-out
                                          reaches their devices until someone removes them;
                                          Exploitability L: needs a malicious member, a
                                          joiner whose clock ran ahead of the wall and a
                                          spare re-ask of an earlier rejoin)
Category:    Authorization / Write gate bypass
Component:   rust/hollow_core/src/crdt/server_state.rs (admission_allowed),
             rust/hollow_core/src/crdt/operations.rs (JoinAsk)
Boundary:    TB-2 (other members of a server)
Traces to:   CLAUDE.md "MemberAdded carries the joiner's OWN master-signed JoinAsk ...
             each ask admits once"; wiki security_write_gates §55c; R-CR-16
Attacker:    a member of the server with a modified client
Found:       2026-11-16 (track t15-verify-probe, the w2-d follow-up "sign follows_leave
             into JoinAsk")
Affected:    0.14.0
Fix commit:  82090231a
Disclosure:  published with 0.14.1
```

## Description

Since w2-d, a rejoin's ask is stamped just past the joiner's own last leave, which can sit
ahead of the wall clock when a co-member's clock carried the joiner's HLC forward. The
live gate (the swarm `ServerJoinRequest` arm) counts that stamp only when the request's
sealed `follows_leave` names the leave that ended the last membership; otherwise it counts
the frame's seal. The fold had no such rule: `members::opens` only asks that the ask be
newer than the last leave, and the leave it named was not signed into the ask. A spare
re-ask from an earlier rejoin, stamped past a second leave made inside the same clock
lead, therefore re-opened a membership in the fold whenever a member authored a
`MemberAdded` with it, although no honest member's live gate would.


## Fix

A rejoin's ask whose stamp leads the joiner's own wall clock signs what it follows
(`JoinAsk.follows`: the named leave and `made`, the joiner's wall clock at signing;
`hollow-join-ask3`). Every other ask, a first join's and a rejoin's with no clock lead
(`at <= made`), signs the exact 0.14.0 `hollow-join-ask2`/`ask1` bytes: the old rule
(`members::opens`, the ask newer than the joiner's last leave) already judges an ask
stamped no later than it was signed, and a 0.14.0 replica reads it whole and counts the
joiner. `admission_allowed` refuses an admission whose ask names a leave older than the
leave or removal that closed the joiner's last span before the admission
(`members::closer_before`), unless `made` is past it; the check runs only when `follows`
is present. The signature covers the head, so an ask3 cannot be stripped to an ask2 or
moved to another leave; an ask never carries both signatures (a 0.14.0 `read_op` would
still keep it unread, and a strip would re-open the hole). The joiner signs it at the
first ask, every re-ask and a restored parked row. The actor of the named leave must be a
peer id at signer and verifier (HOL-SEC-143).

## Test

`a_spare_reask_folds_out_after_a_second_leave` (failed with the fold check removed),
`a_spare_reask_folds_out_whichever_arrives_first`, `a_spare_reask_folds_out_on_a_checkpoint_base`,
`a_spare_reask_folds_out_after_a_leave_in_the_admissions_millisecond`,
`a_rejoin_ask_binds_the_leave_it_follows`, `a_rejoin_ask_names_a_leave_by_a_peer_id`,
`a_rejoin_ask_payload_is_pinned`, `a_rejoin_without_a_clock_lead_signs_the_0140_ask`,
`t15_asking_again_signs_the_leave_the_join_follows`; harness
`t15_a_member_readmits_no_leaver_on_a_spare_ask` (failed with the fold check removed; its
control admits on an ask signed after the second leave) and
`t15_a_rejoin_without_a_clock_lead_signs_the_0140_ask` (the harness runs one build: the
0.14.0 replica is modelled by the ask's bytes, `JoinAsk::reads_as_0140`, which re-reads
them through 0.14.0's `JoinAsk` shape and payload). Mutation passes: 11 of 12, then 8 of 8
after the compatibility fix (a signer that always signs ask3, one that never does, the
`at > made` boundary, the fold check off, `made` and the closer's boundaries, the first
ask and a re-ask naming nothing); the one survivor is the restored-row signer named under
Residual risk.

## Residual risk

- Only asks that carry `follows` are judged by it: rejoin asks an updated client signed
  with a clock lead. Ask2 spares that 0.14.0 joiners already signed, and every ask with
  no lead, stay under the 0.14.0 rule. For a rejoin with no lead that rule holds: a later
  leave of ours is stamped past the moment the ask was signed, so the ask is not newer
  than it. The gap left is clock skew between two devices of one identity (a sibling
  whose clock runs behind leaves with a stamp below the ask's), the bound the live gate
  already accepts.
- Kicks are covered only for asks carrying `follows`. `members::derive` sets no last leave
  on a removal, so a spare of a FIRST join's ask (or of any ask without `follows`) made
  before a kick still opens a span when a member authors the admission (reviewer test
  `review207_a_first_join_spare_after_a_kick`, not ported). Making `opens` count a
  removal would fork from 0.14.0 replicas, so it is planned for 0.15, the next clean
  break (Vitalii, 2026-11-16).
- Mixed with 0.14.0 members: a rejoin made inside a clock lead signs ask3, which a 0.14.0
  member refuses live and keeps unread in the fold until it updates, so it never counts
  the joiner or takes its MLS leaf. This lasts only while the lead does (at most
  `MAX_DRIFT_MS`): a re-ask once the wall clock has passed the stamp signs ask2.
- A rejoin pending across a restart re-signs its ask from the leave book. No test reaches
  that path (it re-sends only on a live peer or after 12 h), and a mutant that names no
  leave there survives; if it named none, that one ask would fall back to the 0.14.0 rule.
