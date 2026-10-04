# HOL-SEC-130: A restored backup the owner refused gained the power to remove every owner device by waiting seven days

```
ID:          HOL-SEC-130                 Status: Fixed (2026-10-04, session 34), relay deployed 2026-10-04 after ASan and release canaries
Severity:    High (Impact H: every owner device locked at contacts, at the relay and on itself, erased after three days unless the phrase is typed, repeatable after each recovery; Exploitability M: a stolen backup with its passphrase, or any device that ever held the master key)
Category:    Access control
Component:   rust/hollow_core/src/identity/roster.rs (fold), relay-uws/src/roster.h
Boundary:    TB-3
Traces to:   phase E+F identity part 2 C-IDENTITY-04; design ID-1; HOL-SEC-079/080
Attacker:    P-08 thief holding the master key
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

A pending join matured after seven days whether or not a member had removed (refused) it,
and a matured device counted as rooted, so its removals counted. A master-key holder whose
restored backup the owner refused could wait out the week and remove every owner device, and
could start again in each new base, since the master key signs a fresh pending join.

## Fix

A pending join that a device belonging without waiting (the roots and their vouch closure)
removed never matures, so its removals never count. Mirrored in the relay's `roster.h` with
a new shared vector.

## Residual risk

The `no_wait` setting already closed it for identities that turned the wait off.

## Test

`authz_a_refused_join_never_gains_removals_by_waiting` (failed: every owner device removed),
vector `a-refused-join-removes-nobody` (the old `roster.h` fails exactly this vector), relay
`test_roster`.
