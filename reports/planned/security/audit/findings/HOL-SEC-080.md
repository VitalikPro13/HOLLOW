# HOL-SEC-080: A removed device could bring a new device in through that device's own removal of it

```
ID:          HOL-SEC-080                 Status: Fixed on local main (2026-10-02), retest at release
Severity:    Medium                      (Impact M: a removed device keeps adding devices that every
                                          contact counts as the person's until the phrase is typed;
                                          Exploitability M: a removed but usable device)
Category:    Authorization / Identity
Component:   rust/hollow_core/src/identity/roster.rs (fold, kept_by)
Boundary:    TB-3 (own identity and its devices)
Traces to:   C-01, C-03; HOL-SEC-077 (design ID-1, "a removed device's later vouches are void")
Attacker:    P-08 (own removed device)
Found:       2026-10-02 (session 25, while mirroring the fold on the relay for ID-1R)
```

## Description

A removal names the devices the removed one had vouched for that it keeps, so replacing an
old phone keeps the new one, and every other vouch the removed device made counts for
nothing. The kept devices were the union over every removal of that device. A removed
device could therefore vouch a fresh key of its own and have that key sign a removal of it
keeping itself: the key counted as a member everywhere, and so did anything it vouched
next.

## Fix

A removed device keeps only the vouchees that every removal of it keeps (the intersection),
so its own new device's removal adds nothing the owner's removal did not keep. Replacing an
old phone from the new one still works: that removal is the only one. The relay mirrors the
rule.

## Test

Units `authz_a_removed_device_cannot_bring_a_device_back_through_its_own_removal`,
`a_removed_device_keeps_only_what_every_removal_keeps`,
`a_removed_devices_later_vouches_are_void_unless_its_remover_kept_them`; mutation pass.

## Residual

The app keeps, by default, every current member the removed device had vouched for, so a
thief who vouched a device of its own before being removed keeps it until that device is
removed too ("Remove all other devices" or the phrase).
