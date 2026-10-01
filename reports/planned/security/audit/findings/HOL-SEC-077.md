# HOL-SEC-077: A stolen device or a leaked backup held the identity for good

```
ID:          HOL-SEC-077                 Status: Fixed on local main (2026-10-01), retest at release
Severity:    Critical                    (Impact H: the identity, its devices and their data, for
                                          good; Exploitability H: one usable stolen device, or a
                                          backup file and its passphrase)
Category:    Authorization / Identity
Component:   rust/hollow_core/src/identity (device lists), node/crypto_handler.rs (verify_device_list,
             ingest), node/destroy.rs (judge_own_order), node/swarm.rs (sibling proof, revocation)
Boundary:    TB-3 (own identity and its devices)
Traces to:   C-01, C-02, C-03; AR-02; candidates F2 (unbound half), F3, F6;
             the stolen-device half of HOL-SEC-041
Attacker:    P-08 (own removed device, stolen and usable), P-09 (a holder of a backup file)
Found:       2026-09-26 (AR-02, while writing the claims); designed as ID-1, 2026-09-30
```

## Description

Every device holds the master key, and the master key was the authority over the
device list: any holder signed a newer list, which added any device, revoked the
owner's real devices (they wiped themselves) and issued destroy orders. A stolen phone
kept the identity for good, and so did a `.hollow` backup: restoring it minted a device
that signed itself into the list with nobody asked. A list could also name a device
that never agreed to belong to that master (F6), and an MLS certificate signed by the
master could name a device outside the identity (HOL-SEC-041).

## Fix (design ID-1)

A person's devices are a roster of statements that each verify alone: a device's
consent, a vouch by a current device, a pending join, a removal by a current device,
and the recovery phrase's statements (a recovery that starts a new base keeping chosen
devices, a phrase admission). The phrase derives a recovery key no device stores; M
signs it once to bind it, and every observer pins the first one. The fold gives the
same members to every observer: holding the master key admits nothing (outside a
legacy identity, see AR-15), a restored backup waits seven quiet days at each observer
unless a device approves it or the phrase is typed, a removed device locks at once and
erases itself after three days, and a remote destroy needs the phrase or a permission
it signed for one device. The resolver, MLS leaf judging, carried bundles and destroy
orders all read the fold's members.

## Test

Harness `authz_a_stolen_backup_is_never_a_member_until_approved`,
`authz_the_phrase_takes_the_identity_back_from_a_stolen_device`,
`authz_a_destroy_order_needs_the_phrase`,
`a_restored_device_matures_at_a_contact_after_seven_quiet_days`,
`a_restored_device_tells_its_ui_once_it_waits`, `device_revocation_cuts_off_and_ghost_fanout_holds`;
units in `identity/roster.rs` (every statement's payload and tag, the fold matrix, the
R pin), `identity/recovery.rs` (the R derivation known-answer vector),
`node/roster_book.rs`, `node/mls_authority.rs` (a disowned leaf is refused and
removable), `node/crypto_handler.rs` (source scan: the MLS arms ask
`resolver::disowns`). Mutation pass: 22/22 roster rules killed. Seen on throwaway fleet
peers (session 22): removal, the phrase lifting it, a restored backup waiting, refused,
joined with the phrase.

## Residual

AR-15 (design ID-1 section 10): a legacy identity until its phrase is confirmed, first
contact after a forged recovery key, the phrase holder is the identity, and the inbox
mailbox until ID-1R.
