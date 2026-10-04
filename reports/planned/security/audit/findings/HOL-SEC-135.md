# HOL-SEC-135: A member could Welcome a leafless member into a group that seats an outsider

```
ID:          HOL-SEC-135                 Status: Fixed (2026-10-04, session 34)
Severity:    Low (Impact M: an outsider the attacker chose reads the victim's posts until a probe repairs the fork; Exploitability M: needs a leafless victim and its KeyPackage, and the inserting member could leak the plaintext itself)
Category:    Access control
Component:   rust/hollow_core/src/node/mls_authority.rs (welcome_verdict)
Boundary:    TB-2
Traces to:   phase E+F mls C-MLS-03; RFC 9420 section 12.4.3.1
Attacker:    P-05 member
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

A server Welcome was held only for a non-member sender or a banned leaf, never for a non-
member leaf or, in a subgroup, a leaf that cannot see the channel; the wiki already
described the stronger rule.

## Fix

Every bound leaf in a Welcome must pass the membership rule (member, not banned, can see a
subgroup's channel), else the Welcome is held and judged again each tick, so an honest join
beside a member newer than our view still completes.

## Test

`welcome_rules`, `authz_a_welcome_never_seats_a_non_member`; honest-lag guard
`a_join_whose_view_lacks_a_newer_member_still_takes_its_seat`.
