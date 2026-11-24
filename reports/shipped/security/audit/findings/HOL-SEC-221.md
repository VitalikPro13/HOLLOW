# HOL-SEC-221: a settling dropped the founding op of a server the lost device founded

```
ID:          HOL-SEC-221                 Status: Open, fix planned for 0.14.3
                                          (track phrase-restore)
Severity:    Low                         (Impact M: a lost-or-stolen removal or a phrase
                                          recovery leaves the server unsettled, so what only
                                          a settling undoes stays; Exploitability L:
                                          no attacker action, an honest removal of the
                                          device that founded the server)
Category:    Availability of a security control
Component:   rust/hollow_core/src/crdt/settle.rs (settling_input)
Boundary:    TB-3 (server members and their replicated state)
Traces to:   DEVICE_PROOF_DESIGN 8.1, 8.3, 8.4; R-CR-13
Found:       2026-11-21 (phrase-restore fix round, while writing the HOL-SEC-216 tests)
Affected:    0.14.0 through 0.14.2
Fix commit:  pending (feat/phrase-restore)
Disclosure:  private until 0.14.3 ships
```

## Description

A settling counts a dropped device's op only when this device stored it before T. The
founding op of a server is an op like any other there, so on a server the lost device
founded it dropped whenever this device first stored it at or after T. That is always the
case for "Longer ago, or not sure": T is then the first fold of the oldest restore point
held here (0 when there is none), and a device that first got the server together with
that restore point, or holds none, stored the founding op at T or later. With no restore
point before T the settling folds from the founding op, so without it the fold was empty
and the settling was never written ("Could not settle"). The removal itself still landed,
but no settling base, settle mark or carried roster went to members, so what only a
settling undoes, such as a checkpoint the lost device signed after T, could stay in force.
The witness restore paths share the input and had the same gap whenever the server carried
no owner pin.

## Fix

The settling keeps the founding op of the server whoever wrote it and whenever it was
stored here (`ServerState::founding_stand`): it is R when no checkpoint precedes T, and it
names the owner a checkpoint R must come from. Only the founding op the fold founds on
counts this way (since HOL-SEC-222 chosen by content and the view, never by when it was
stored: the first version of this fix took the one first stored here, which depended on
arrival order), and the settling folds no other founding op. The founding op of
a self-certifying id carries nothing the id does not already fix except its name and clock,
and on a server the lost device did not found the rule changes nothing. Every other op of
the lost founder stored at or after T still drops, so on a device that first held the
server with its oldest restore point the settling undoes everything that device did there,
members it admitted included, as "a vague answer undoes more"
(DEVICE_PROOF_DESIGN 8.1) says.

Decided (Vitalik, 2026-11-22): this stays the rule. A "not sure" settling of a server the
lost device founded, with no restore point before T, undoes everything that device did
there, members it admitted included (DEVICE_PROOF_DESIGN 8.1). A not-sure T is the first
fold of the oldest restore point held here and R must have folded before T, so such a
settling always folds from the founding op; it never stands on that restore point.

Alternatives not taken: reading the derived T as one millisecond later, or making the
restore point search inclusive for it, leaves the case with no restore point (T = 0)
failing. On every server, founded by the lost device or not, the first would count the
lost device's ops stored in the same millisecond as the oldest restore point (a joiner's
whole first batch), and the second would stand on that restore point, a checkpoint the
lost device may have written after it was lost.

Tests: `a_not_sure_settling_stands_on_the_founding_op_the_lost_device_wrote`,
`a_settling_stands_on_the_founding_op_the_fold_chose_whenever_stored` (the same choice
whenever the founding op was first stored; renamed from
`a_founding_op_the_lost_device_minted_later_never_founds_the_settling`, which asserted the
arrival-order rule HOL-SEC-222's review replaced), `a_settling_folds_no_founding_op_but_the_stand`, harness
`pr216_a_not_sure_removal_of_the_founding_device_settles_from_the_joiners_oldest_point`,
`pr216_a_not_sure_recovery_dropping_the_founding_device_settles_its_server`,
`pr216_a_not_sure_lost_removal_settles_from_the_founding_op` (renamed from
`..._settles_from_the_oldest_restore_point`, which it never did: its remover holds no
restore point, now a precondition).
