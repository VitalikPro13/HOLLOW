# HOL-SEC-006: A stranger's device list could claim a friend's master id, taking over the friendship and, on the victim's replica, the friend's server role

```
ID:          HOL-SEC-006                 Status: Fixed on local main (2026-09-26), retest at release
Severity:    Critical                    (Impact H: a friendship moves to the attacker, the friend's server membership and
                                          role fold into the attacker at the next canonicalisation, the owner's included;
                                          a legacy contact can be silenced. Exploitability H: any identity, through the
                                          friend-request inbox or a profile sync in any shared room)
Category:    Access control (authenticated but not authorised): a variant of HOL-SEC-001
Component:   rust/hollow_core/src/node/crypto_handler.rs :: ingest_device_list, foreign branch, `speaks_for`
             consequences in storage/messages.rs :: migrate_friend_to_master, crdt/server_state.rs :: canonicalize_members
Boundary:    TB-2
Traces to:   C-01, C-12, C-15; plan section 2.2 class 1 and class 5 (identifier confusion); candidates F1, F2
Attacker:    P-03 stranger (friend request), P-05 member (profile sync in a server room), P-01 with its own keys
Found:       2026-09-26, phase B identity pass (the variant analysis HOL-SEC-001 asked for), confirmed by reading and test
```

## Description

HOL-SEC-001's fix made a foreign list speak only for ids that are unbound or
already bound to its own master: `speaks_for(id) = resolve(id) == id || resolve(id) == list.master`.
The resolver maps DEVICE ids to masters, so a MASTER id is never one of its
keys and always "resolves to itself". A foreign list could therefore name any
other identity's master id:

- in `devices`: `update_many` then binds that master id to the attacker, the
  device_links index is rebuilt with it, and `migrate_friend_to_master` moves
  our friend row for that person (accepted) to the attacker and deletes the
  original. At the next start `warm_from_links` restores the binding and
  `canonicalize_members` folds that person's member entry and role register into
  the attacker's key, so on our replica the attacker holds their role;
- in `revoked`: a legacy contact (device id == master id) is marked revoked,
  its DMs and typing dropped, its Olm session and MLS leaf queued for removal.

The same gap let a list tombstone ids it never held and apply the process-wide
revoked mark to them.

## Reproduction

`authz_a_foreign_roster_cannot_claim_or_remove_anyone_elses_devices`
(node/roster_book.rs tests; it replaced the device-list test
`a_foreign_device_list_cannot_claim_a_master_id_or_silence_a_legacy_contact` when
design ID-1 turned device lists into rosters): before the fix, a friend's master
id resolved to the attacker's master and a legacy contact was marked revoked.

## Fix

- `speaks_for` refuses an id that resolves to itself when it is another
  identity's master: a value of the resolver map (`resolver::is_known_master`)
  or a master we hold a signed list for.
- Revocation ENFORCEMENT (the process-wide mark, `forget_many`, the
  `newly_revoked` the caller turns into dropped sessions and leaves) reaches only
  devices this master already held; other ids stay as tombstones in its own list,
  which still stops a stale list from adding them later.
- Long term (class kill, design ID-1): every entry of a device list carries the
  DEVICE's own signature over `(master, device)`. A list then cannot name a
  device, or a master, that never consented, and first-come squatting of ids we
  have not met yet (candidate F6, still open) goes away with it.

## Variants

- Still open in the same function family: F4 (a revoked sibling re-enters through
  the sibling proof), F5 (revoked devices resolve to themselves and pass the key
  exchange), F6 (squatting unmet device ids), F7 (three carried-list paths drop
  `newly_revoked` and attribute to the list's master even when binding failed).
- Every consumer that treats "resolves to itself" as "unbound": search
  `resolve(x) == x` across the node.

## Test

The original test failed before the fix and passed after; 89 device-list,
revocation, sibling, friend and destroy tests passed, HOL-SEC-001's included. Its
roster successor asserts the same three claims (a friend's device, a friend's
master, our own device) and that the foreign removals revoke nobody.
