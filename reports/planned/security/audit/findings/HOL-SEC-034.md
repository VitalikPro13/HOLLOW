# HOL-SEC-034: An old destroy notice applied again after the identity returned, and any list said it had

```
ID:          HOL-SEC-034                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Low                         (Impact L: a contact's "destroyed" banner raised again and their
                                          verified mark removed, as often as anyone replayed the notice; a false
                                          "identity reappeared" alert cleared the banner; Exploitability M: every
                                          notified friend and the relay hold a copy of the signed notice, and
                                          device lists are public)
Category:    Replay
Component:   rust/hollow_core/src/node/destroy.rs :: apply_friend_order, note_identity_reappeared
             rust/hollow_core/src/node/crypto_handler.rs :: ingest_device_list
Boundary:    TB-1 (relay), TB-2 (peer <-> peer)
Traces to:   C-07; candidate F8 (evidence identity:S10)
Attacker:    P-01 relay, P-04 friend
Found:       2026-09-26, phase B identity pass; confirmed by reading 2026-09-27
```

## Description

When a destroyed identity came back, the banner stamp was written as an empty
value, which reads as "never destroyed". The only freshness rule for a friend's
destroy notice compared against that stamp, so the same old notice applied again:
banner back, verified flag removed, every time it was replayed. In the other
direction any device list we could bind, an unchanged or replayed one included,
cleared the banner and raised "identity reappeared".

## Reproduction

`authz_a_friend_destroy_order_applies_once_even_after_the_identity_returns`
(node/destroy.rs tests), `authz_only_a_new_member_means_a_destroyed_identity_returned`
(node/roster_book.rs tests; the roster successor of
`authz_only_a_new_device_means_a_destroyed_identity_returned`), and the updated
harness test `destroy_friend_announce_flips_verified_and_banner`.

## Fix

- The newest applied notice is kept in its own stamp that is never cleared; a
  notice must be newer than it.
- Only a list that adds a device we have never seen for that identity counts as
  the identity coming back (the mnemonic restores onto a new device).

## Test

Both unit tests fail with the old rules and pass with the fix. The harness test
now also checks that the old device announcing its old list keeps the banner up.
Full suite green.
