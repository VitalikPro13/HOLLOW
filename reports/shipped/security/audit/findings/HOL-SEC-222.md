# HOL-SEC-222: a removed device could found a held server a second time

```
ID:          HOL-SEC-222                 Status: Open, fix planned for 0.14.3
                                          (track phrase-restore)
Severity:    Low                         (Impact M: a device the roster removed rewrites a
                                          server's founding op on every replica that folds
                                          it from genesis, its name and founding clock
                                          included, past its removal; Exploitability L:
                                          needs the master key a lost or stolen device holds)
Category:    Authorization (a removed device's write)
Component:   rust/hollow_core/src/crdt/verdict.rs (clause_exempt),
             rust/hollow_core/src/crdt/fold.rs (fold_remote)
Boundary:    TB-3 (server members and their replicated state)
Traces to:   DEVICE_PROOF_DESIGN 7, 8.3; R-CR-07
Found:       2026-11-22 (phrase-restore, while fixing HOL-SEC-221)
Affected:    0.14.0 through 0.14.2
Fix commit:  pending (feat/phrase-restore)
Disclosure:  private until 0.14.3 ships
```

## Description

Past the cut only an op from a device the author's roster counts folds, but the founding op
is exempt from that device clause: it anchors its server whichever device wrote it, and
that device may have been retired or lost since. The exemption covered every
`ServerCreated` op, not only the one a replica already held. A device the roster removed
still holds the master key, so it could sign another founding op of the same id: the same
owner and nonce (so the same self-certifying id), any name, any clock. Replicas stored it
like any other op and served it in sync. A replica that folds the server from genesis takes
the founding op with the lowest clock, so one clocked before the real founding op replaced
it there: the server took its name, and the real founding op stopped folding. Checkpointed
replicas kept their state from the base, but still held and passed on the second op.

## Fix

A replica takes one founding op per self-certifying id (`fold_remote` -> `founded_once`,
before dedup, so a variant at the real op's own clock is caught too). Only the founding op
it already holds (folded, a row, or held) passes; with none held, the batch's best (a
counted device's first, then fold order, then content id). Every other `ServerCreated` is
refused unstored. A fresh replica's first founding op, a join (snapshot plus the founding
op from the join answer) and a checkpoint-anchored server are unchanged: each holds no
founding op until the first arrives, or holds the one that arrives again. The settling's
`founding_stand` (HOL-SEC-221) still picks among founding ops an older build stored.

Residual: a replica that stored a second founding op before this fix keeps it as stored;
a fold from genesis there still orders by clock. The fix stops it spreading to replicas
that hold the real one.

Tests: `a_second_founding_op_from_a_removed_device_founds_nothing` (the founder's replica,
a replica folding from genesis, a fresh replica handed both in one batch),
`a_legacy_founding_op_still_founds_a_fresh_replica` (the rule leaves legacy ids alone), harness
`pr222_a_lost_founders_second_founding_op_changes_nothing_on_a_replica_folding_from_genesis`
(the lost founder's ops carried before and after its removal, through a "not sure" settling
from genesis and a restart). Both failed before the fix (the replica kept the second op;
the harness replica founded on it).
