# HOL-SEC-001: Any identity could remotely wipe a device with its own signed device list

```
ID:          HOL-SEC-001                 Status: Fixed on security/foreign-device-list (0bb09321), retest at release
Severity:    Critical                    (Impact H: data destruction; Exploitability H: any identity that can reach you, unilaterally)
Category:    Access control (authenticated but not authorised)
Component:   rust/hollow_core/src/node/crypto_handler.rs :: ingest_device_list, foreign-master branch
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-01, C-02; class 1 of the plan's section 2.2
Attacker:    P-03 stranger, P-04 friend, P-05 server member, P-01 relay operator with its own keys
Found:       2026-09-26, answering "can the relay trigger a wipe?"
```

## Description

A foreign device list (signed by some other master) was verified for its
signature and for the sender being in it, then acted on: our own device id in
its `revoked` set raised `SelfRevoked`, the full wipe. Its `revoked` entries
also silenced third parties' devices (`resolver::mark_revoked`), and its
`devices` rebound other identities' device ids to the signer
(`resolver::update_many`). The signer's authority over the ids it named was
never checked.

## Reproduction

`authz_a_foreign_roster_cannot_claim_or_remove_anyone_elses_devices` (at the fix:
`a_foreign_device_list_cannot_revoke_or_claim_other_identities_devices`): before
the fix, a list signed by another identity that named our device as revoked
wiped it.

## Fix

`speaks_for` filter: a foreign list keeps only ids that are unbound or already
bound to that master, never ours; the foreign-branch self-nuke is removed
(only our own master revokes us, through the sibling path).

## Variants

The September 3 audit's finding 4 (a device list bound to whichever device
delivered it) is the same class and was fixed as a single instance. Full
variant analysis is phase D of the plan.

## Test

`authz_a_foreign_roster_cannot_claim_or_remove_anyone_elses_devices`
(`node/roster_book.rs`): since design ID-1 replaced the device list with the
roster, a foreign roster that claims or removes our device, a friend's device or
a friend's master leaves every binding as it was, revokes nothing and raises no
`DeviceRemoved`. It replaces
`a_foreign_device_list_cannot_revoke_or_claim_other_identities_devices`, which
failed before the 0bb09321 fix and passed after (lib suite 893/893 then).
