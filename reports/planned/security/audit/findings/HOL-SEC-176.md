# HOL-SEC-176: A ground master id led a server's encryption group while the owner was away

```
ID:          HOL-SEC-176                 Status: Fixed (2026-10-23, wave g13, local commit eb7ed684),
                                          ships with 0.13
Severity:    Medium                      (Impact M: the attacker becomes the group's committer, join
                                          answerer, bootstrap target, catch-up responder and leaf repairer,
                                          and its fork is the one that survives; it can stall joins and
                                          repairs and force churn, but every commit and Welcome it makes is
                                          still judged; Exploitability M: grind a master id, be admitted,
                                          wait for the owner to go offline)
Category:    Access control (authority by a value the attacker chooses)
Component:   rust/hollow_core/src/node/standing.rs (new), node/mls_authority.rs (group_authority,
             elect_server_coordinator, epoch_catchup_responder, server_bootstrap_target,
             may_repair_our_leaf), node/door_room.rs (first_to_answer), crdt/server_state.rs (MemberSpan)
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-19; design D (HOL-SEC-042..044)
Attacker:    P-05 member with a ground master id
Found:       2026-10-22 (wave g13, hostile review of track s3)
```

## Description

While no owner device was online, every MLS leadership role of a server fell to the online
member with the lowest master id by string sort. That member became the committer, join
answerer, bootstrap target, catch-up responder and leaf repairer, and its side of a fork
survived. Master ids are free to mint, so a member could grind one that sorts first and lead
the group. The same held for door answers. The three members that answer a `DoorAsk` were
ranked per device, so one identity with several devices, or device ids ground in advance,
could hold every answer slot and withhold the door. This costs availability and churn, not
confidentiality, since commits and Welcomes stay judged (HOL-SEC-042, -043). Present since
design D (0.12.0).

## Fix

- Leaders are ranked by standing (`node/standing.rs`), which orders by role tier, then by
  the position of the member's current admission in the signed fold (never before its
  admitter's), then by id, among masters with an online device holding a bound leaf. A
  backdated admission by a removed member buys no standing.
- A leaf repair is still committed by the coordinator alone; the member that asked for it
  forwards the KeyPackage and names that committer, and the prober takes the Welcome only
  for the package it answered with, from the owner or a seated, unbanned member.
- Door answerers are one slot per identity, ordered by a hash salted with the asker's fresh
  nonce, so nothing can be ground in advance.
- 0.12.2 replicas still pick the lowest id, so the rule is gated per group. It is on only
  when every bound leaf declares the capability and the anchor is not legacy.

## Residual risk

A group with any pre-0.13 leaf keeps the old rule until 0.14 removes the gate (the squatting
residual, decided for 0.14). AR-11 is widened to backdated admission by any former member.

## Test

Harness `g13w2f_a_ground_low_id_never_becomes_the_stand_in_committer` (red before the fix:
the ground id got a commit, a Welcome and two leaf asks),
`g13w2f_a_ground_id_is_neither_catch_up_responder_nor_repairer`,
`g13w2f_the_join_answerer_follows_standing`,
`g13w2f_a_mixed_group_keeps_the_old_rule_exactly`; units
`rank_masters_orders_by_tier_then_position_then_id`,
`a_removed_members_backdated_admission_buys_no_standing` (node/standing.rs),
`g13w2f_door_answerers_are_three_identities_whatever_their_device_ids` (node/door_room.rs).
Mutation passes 48/52 (four argued), 17/19 in the fix round and 12/12 after the merge;
Windows fleet with the owner away passed.
