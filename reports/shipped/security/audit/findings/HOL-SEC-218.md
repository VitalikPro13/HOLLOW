# HOL-SEC-218: a phrase admission dated before the identity's current base counted nowhere

```
ID:          HOL-SEC-218                 Status: Open, fix planned for 0.14.3
                                          (track phrase-restore, S218)
Severity:    Low                         (Impact L: the restored device is cut off from
                                          contacts and the relay while it believes it
                                          belongs, and the lock then names the wrong cause;
                                          Exploitability L: a clock behind, or a recovery
                                          signed by a device a few minutes ahead)
Category:    Clock dependence in a membership decision
Component:   rust/hollow_core/src/identity/keys.rs (restore_identity_from_mnemonic),
             api/roster.rs (roster_status)
Boundary:    TB-2 (the identity's own devices)
Traces to:   HOL-SEC-152, R-ID-16 (new)
Found:       2026-11-21 (hostile review of the phrase restore design)
Affected:    0.12.0 through 0.14.2
Fix commit:  pending (feat/phrase-restore)
Disclosure:  private until 0.14.3 ships
```

## Description

A phrase admission counts only when it is dated after the identity's current base. The restore
dated it by the restoring machine's clock alone, so a clock behind, or a base signed by a device
running a few minutes ahead, left the new device uncounted at every contact and at the relay
while it looked like a member to itself. Once it learned the real roster, the lock told it that
it was a backup waiting to join.

## Fix

The restore signs through the same calls as the in-app phrase paths, which date a statement
after the newest one the device holds, never by the relay's clock. A device whose admission or
recovery the base outdated is told so ("Type your recovery phrase again", with a line about the
clock), and typing the phrase signs a statement dated after the base it now holds. The rule
that a base outdates older admissions stays. Tests:
`an_admission_dated_before_the_current_base_never_roots`,
`a_restore_beside_a_held_roster_dates_its_admission_after_its_newest_statement`,
`roster_status_says_too_early_for_an_admission_the_base_outdated`, harness
`pr218_a_restore_on_a_clock_behind_asks_for_the_phrase_again_and_then_counts`.
