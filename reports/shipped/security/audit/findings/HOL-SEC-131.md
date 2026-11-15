# HOL-SEC-131: Every Welcome into a server would fail once any member's leaf was 84 days old

```
ID:          HOL-SEC-131                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact M: no device can join or be repaired into the group, and 0.12's migration re-keys most leaves at once, so many servers would fail together about three months after release; Exploitability: none needed, it happens by itself)
Category:    Availability
Component:   rust/hollow_core/src/crypto/mls_manager.rs (stage_welcome)
Boundary:    TB-2
Traces to:   phase E+F mls C-MLS-04; RFC 9420 section 7.3
Attacker:    none (time)
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

OpenMLS 0.9 validates by default the lifetime of every leaf in a Welcome's tree that was
never updated, and its default KeyPackage lifetime is 84 days. Hollow never self-updates
leaves and add-only commits carry no path, so leaves keep their KeyPackage lifetime.

## Fix

`.skip_lifetime_validation()` on the Welcome builder: seats are judged by the roster and the
CRDT, never by leaf age.

## Test

`a_welcome_still_installs_after_an_old_members_leaf_lifetime_ends` (failed:
`LeafNodeValidation(Lifetime(Expired))`).
