# HOL-SEC-152: A device whose clock stepped back forgot its recovery key for good

```
ID:          HOL-SEC-152                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact H: the master key alone again admits devices and orders the wipe at that device, and a forged recovery key shown first is pinned; Exploitability L: a dead RTC battery, a manual clock change or spoofed time, plus a master-key holder)
Category:    Access control
Component:   rust/hollow_core/src/identity/roster.rs (reverified), node/roster_book.rs
Boundary:    TB-3, TB-4
Traces to:   phase E+F identity C-IDENTITY-02; claims C-01, C-02
Attacker:    P-08 master-key holder with P-02 or luck
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

Every stored roster was judged against the current clock on each load; a phrase statement
then dated in the future was dropped, the pinned recovery key cleared, and start-up saved
the stripped roster.

## Fix

Held rosters are checked without the clock and always keep the pinned key; only rosters
arriving from the network or the bootstrap file are judged by time; a phrase typed behind
the clock is dated past the newest held statement.

## Test

`authz_a_clock_behind_the_newest_recovery_keeps_the_phrase_pinned` (failed: the pin was
cleared), `a_held_roster_is_never_judged_by_the_clock_again`,
`the_phrase_keeps_the_last_word_behind_a_stepped_back_clock`.
