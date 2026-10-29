# HOL-SEC-184: Peer discovery answered every device with full member lists every 30 seconds

```
ID:          HOL-SEC-184                 Status: Fixed (2026-10-22, wave g13, local commit 70f7f10e),
                                          relay deployed 2026-10-23, client ships with 0.13
Severity:    Medium                      (Impact H at scale: at 5,000 members one discovery round cost the
                                          relay's single thread about 30 s of CPU and 4.1 GB of egress, every
                                          30 s, which stalls the relay for everyone; Exploitability L: needs
                                          servers of several thousand members)
Category:    Uncontrolled resource consumption (cost quadratic in members)
Component:   relay-uws/src/ws_handler.cpp (discover_peers), relay-uws/src/presence_view.h (new),
             rust/hollow_core/src/node/presence_audit.rs (new), node/member_cap.rs (new)
Boundary:    TB-1 (client <-> relay)
Traces to:   AS-11 (availability); G1 scale probe
Attacker:    none needed (honest load at scale)
Found:       2026-10-22 (wave g13, G1 scale probe, track s1b)
```

## Description

Every device asked the relay for the full peer list of every server it was in every 30
seconds, and the relay answered whole, with N answers of N ids per server. The cost grew
with the square of a server's size. At 5,000 members the G1 probe measured 30.4 s of relay
CPU and 4.13 GB per round. Present in released versions.

## Fix

- Each server room is audited once every 300 s. The relay answers a 64-bit digest of exactly
  what it shows that socket, and the client compares it with the presence frames it was
  told. A mismatch is re-asked after 6 to 10 s and only a second one re-joins.
- 0.12.2 clients still get the old answer, capped to 64 ids.
- A server admits at most 512 identities, checked where a member answers a join (not a fold
  rule, so 0.12.2 replicas never diverge over it).

At 5,000 members a round now costs about 1 s of CPU and 1.7 MB.

## Residual risk

The 512-identity cap stays until a multi-device scale rerun proves more.

## Test

Unit `tag_matches_the_relays_pinned_vector` and the audit rules in node/presence_audit.rs;
`presence_audits_never_drift_under_churn_and_catch_one_lost_frame` (node/presence_e2e.rs);
harness `g13_drift_audit_heals_a_dropped_peer_joined`,
`g13_member_cap_refuses_past_the_cap`, `g13_member_cap_is_not_a_fold_rule`; relay
`test_presence_view` and the live `test_presence_digest` section. Mutation passes Rust 14/15
(one redundant), relay 9/9.
