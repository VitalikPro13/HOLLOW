# HOL-SEC-032: A revoked device came back through the sibling proof and after a restart

```
ID:          HOL-SEC-032                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    High                        (Impact H: a revoked sibling was bound to our identity again and
                                          handed our friend list, servers and full DM history; any revoked
                                          device passed key exchange again after a restart; Exploitability M:
                                          needs a device that was once ours or a contact's, running a
                                          modified client)
Category:    Missing authorization (revocation not enforced); state lost across restart
Component:   rust/hollow_core/src/node/swarm.rs :: on_verified_sibling
             rust/hollow_core/src/node/crypto_handler.rs :: key_exchange_device_unauthorized,
             sibling_proof_refused, enforce_revocation
             rust/hollow_core/src/node/resolver.rs :: warm_from_store
             rust/hollow_core/src/storage/messages.rs :: revoked_devices table
Boundary:    TB-2 (peer <-> peer), TB-3 (device <-> device of one identity)
Traces to:   C-05, C-06; candidates F4, F5 (evidence identity:S4, dm:S-18)
Attacker:    P-07 revoked device, P-01 relay
Found:       2026-09-26, phase B identity pass; confirmed by reading 2026-09-27
```

## Description

Every device holds the master key, so a revoked device can still answer the
sibling-proof challenge. The proof handler bound the device to our identity in
the resolver before anything read our own list's tombstones, and then shared our
friend list, servers, read markers and a full DM backfill with it; the list merge
refused it only afterwards.

Revocation also lived only in memory. The resolver forgets a revoked device, so
it resolves to itself and reads as first contact; after a restart nothing
remembered it, and it passed key exchange and the Olm identity check again.

## Reproduction

`authz_a_revoked_sibling_is_not_re_bound_by_the_proof` (node/swarm.rs tests),
`authz_a_revoked_device_stays_refused_after_a_restart` (node/crypto_handler.rs tests).

## Fix

- `sibling_proof_refused` runs first in `on_verified_sibling`: a device in our
  own list's tombstones, or recorded as revoked, is neither bound nor sent
  anything.
- Every enforced revocation (own device, reset, a friend's list, a sibling's
  list) is recorded in a `revoked_devices` table, and `warm_from_store` loads it
  at every start, with our own list's tombstones on top for installs older than
  the table.
- `key_exchange_device_unauthorized` refuses a revoked device, which covers
  KeyRequest, KeyBundle and the PreKey identity check.

## Variants

- A revoked device can still sign a newer list that un-revokes itself (F3); the
  fix is design ID-1.
- Revocations of a friend's device applied before this build are not recorded,
  since a stored list cannot tell an enforced tombstone from one that was not;
  our own list's tombstones are.

## Test

Both tests fail with the old rule put back (the refusal skipped; the revoked mark
not consulted at key exchange) and pass with the fix. Full suite green.
