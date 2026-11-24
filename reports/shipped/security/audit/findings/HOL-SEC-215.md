# HOL-SEC-215: a device the recovery phrase added raised no warning on the identity's other devices

```
ID:          HOL-SEC-215                 Status: Open, fix planned for 0.14.3
                                          (track phrase-restore, R3)
Severity:    Low                         (Impact L: the owner learns of a device added
                                          with the phrase only from the device list or a
                                          contact's warning; Exploitability L: needs the
                                          recovery phrase, which already is the identity)
Category:    Missing security notice
Component:   rust/hollow_core/src/node/roster_book.rs (vouched_by_a_sibling)
Boundary:    TB-2 (the identity's own devices)
Traces to:   C-IDENTITY-09, R-ID-14 (new)
Found:       2026-11-21 (phrase restore design, revision 1)
Affected:    0.12.0 through 0.14.2
Fix commit:  pending (feat/phrase-restore)
Disclosure:  private until 0.14.3 ships
```

## Description

Our other devices record "a device was added" only for a device a sibling vouched for. A
device the phrase admitted on another machine, or one a phrase recovery kept, became a member
with no alert anywhere on the identity's other devices.

## Fix

`vouched_by_a_sibling` becomes `added_by_another`: it also reports a device newly counted
whose root is a phrase admission or a recovery's keep set, never this device itself, never an
upgrade admission, and never before this device was a member. The alert says the device was
added with the recovery phrase. Tests: `a_device_the_phrase_admits_alerts_our_other_devices`,
`a_device_a_recovery_keeps_alerts_our_other_devices`,
`the_device_the_phrase_admitted_alerts_nothing_about_itself`,
`an_upgrade_admission_still_alerts_nothing`, harness
`pr_the_phrase_alert_reaches_a_sibling_that_was_hidden`.
