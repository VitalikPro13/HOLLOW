# HOL-SEC-154: A destroy order could be dated in the future, judged without our roster, or have its targets re-split

```
ID:          HOL-SEC-154                 Status: Fixed (2026-10-04, session 34), relay mirror deployed 2026-10-04 after ASan and release canaries
Severity:    Low
Category:    Access control / Canonicalisation
Component:   rust/hollow_core/src/node/destroy.rs, crypto_handler.rs (verify_destroy_identity), storage/messages.rs, relay-uws/src/kill_order.h
Boundary:    TB-1, TB-3
Traces to:   phase E+F identity C-IDENTITY-10, -11; olm agent's destroy candidate
Attacker:    P-01 relay, P-08 master-key holder
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

An order dated far in the future had no upper bound, so it outlived every device linked
before its date and blocked later genuine orders at friends; an unreadable roster was taken
as "no recovery key yet", so the master key alone sufficed; and the targets join with ','
under the signature, so a carrier could rewrite ["A","B"] as ["A,B"], an order naming nobody
whose permanent refusals cleared the relay's proven slot.

## Fix

Orders dated past the allowed skew are refused for good; an unreadable roster gives no
verdict (our own: wait, never ack; a friend: refuse); every target must be a peer id, in
Rust and in the relay's `kill_order.h`, with two new shared vectors.

## Test

`a_destroy_order_from_the_future_is_refused`,
`a_destroy_order_is_never_judged_without_our_roster`,
`a_friend_order_is_never_judged_without_its_roster`,
`a_destroy_orders_targets_cannot_be_re_split_under_its_signature`, relay `test_kill_order`
"the signature half refuses it" (both failed with the guard off).
