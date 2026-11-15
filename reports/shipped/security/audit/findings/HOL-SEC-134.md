# HOL-SEC-134: A meeting guest could keep another guest out for good by spending its KeyPackage

```
ID:          HOL-SEC-134                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact M: a chosen guest is never admitted; Exploitability H: any link holder reads every knock's KeyPackage)
Category:    Access control
Component:   rust/hollow_core/src/node/conference.rs, crypto/mls_manager.rs (join_from_welcome_judged), node/mls_authority.rs (welcome_sender_refusal)
Boundary:    TB-2
Traces to:   phase E+F mls C-MLS-05; RFC 9750 section 5.1
Attacker:    P-05 meeting guest holding the link
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

OpenMLS deletes our KeyPackage as soon as a Welcome names it, before checking anything, and
Hollow staged every Welcome before judging its sender. A knock shows the KeyPackage to every
link holder, so a rogue Welcome spent it, the knocker re-knocked at once (and minted a
package per junk Welcome), and the host's later admit seated a ghost leaf that blocked every
further admit. The same skip kept a guest who left from ever being admitted again.

## Fix

A meeting Welcome carries the host's proof and is staged only from a device the meeting id's
host certifies while we knock (servers: never from a revoked or disowned device);
KeyPackages a Welcome names are put back unless it installs; re-knocks only after a package
was really spent, with a 2 s gap; the host replaces an existing leaf when a device knocks
again with a fresh package.

## Test

`authz_a_guest_cannot_spend_another_guests_key_package`,
`a_welcome_that_spends_nothing_sends_no_new_knock`,
`a_guest_who_left_a_meeting_is_admitted_again`,
`a_welcome_that_is_not_installed_spends_no_key_package`. Mutation 18/18 (with HOL-SEC-135,
-136).
