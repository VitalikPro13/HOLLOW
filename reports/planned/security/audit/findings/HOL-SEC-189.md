# HOL-SEC-189: A removed device's vouch flood could uncount a device another voucher holds

```
ID:          HOL-SEC-189                 Status: Fixed in worktree t14-ident (2026-11-04), uncommitted,
                                         EMBARGOED until the 0.14 release
Severity:    Medium                      (Impact M: an honest linked device stops counting at every
                                          contact, in DMs and at the relay's inbox fold, until the
                                          phrase re-roots it; Exploitability M: needs a removed
                                          device's key, which a thief holds)
Category:    Authorization / Identity
Component:   rust/hollow_core/src/identity/roster.rs (compacted), relay-uws/src/roster.h (compacted)
Boundary:    TB-3 (own identity and its devices), TB-2 (peer and peer)
Traces to:   HOL-SEC-079, HOL-SEC-080; DEVICE_PROOF_DESIGN rev 3.2 R31-4, RECHECK_REV32 RC32-10
Attacker:    a removed (stolen) device
Found:       2026-11-01 (REVIEW_REV31, R31-4)
```

## Description

The vouch cap kept each standing device's first vouch by signer rank as its tree vouch,
then the rest by signer rank, and ignored removals. A removed device that ranks before an
honest voucher could sign a vouch for that voucher's vouchee and flood vouches for keys
nobody consented under. Its vouch became the vouchee's tree vouch, the honest vouch fell
past the cap, and the vouchee stayed valid only through the removed device: it stopped
counting in ID-1's fold (contacts, DMs) and at the relay's inbox.

## Fix

Before the cap, compaction runs the removal walk over every held statement (signers in
rank order; a signer counts only if no earlier counted removal removed it and it is in its
tier's valid closure at its turn) and the valid closure over what it counted. A vouch is
valid when its signer is in that closure and no counted removal of the signer voids it.
Kept first: each standing device's vouch from its nearest valid voucher (a tree rooted in
the phrase), the vouches that made each walk-alive signer valid at its turn (RC32-10), and
each standing device's vouch from its best-ranked voucher (so ranks, and the walk, come out
the same after compaction). The rest give way by validity, then signer rank. The relay
mirrors the same rules; `roster_vectors.json` gained fourteen cases.

Its review added two rules. The cap's walk counts only removals by tier-0 signers, the
removals every view counts: a pending join can be made with the master key alone and never
matures without anyone's consent, so letting its removal demote a vouch let a person
holding only the master key uncount a linked device with a junk flood. And standing is
ranked over the consents the cap keeps: past 96 standing devices only the best ranked keep
theirs and the rest rank again, so a merge of two shows judges what its compacted self
judges and the kept classes never exceed the vouch cap.

## Test

Units `hol_sec_189_*` (nine cases, each a vector too) and
`compaction_is_idempotent_under_a_vouch_flood` (300 random flooded identities: compacting
twice changes nothing and the compacted roster walks as every statement did);
`roster_vectors_are_current`; C++ `test_roster` (every vector, plus each vouch-cap vector
compacts to itself at the relay); from the review,
`review189_a_master_key_pending_join_uncounts_a_linked_device` with its control,
`review189_a_master_key_pending_join_never_demotes_a_backup_vouch`,
`review189_b_a_pending_junk_flood_keeps_every_case`,
`authz_pending_joins_removing_the_phrases_devices_never_displace_them`, a consent-overflow
round in the property test, and the vectors `review189-master-key-pending-flood`,
`review189-master-key-pending-backup-vouch` and `review189-pending-junk-over-the-consent-cap`; mutation
passes `.team/mutate_p1.py` and `.team/mutate_p1_fix.py` in t14-ident.

## Residual

A counted device that floods its own base can still push out vouches ranked after it, as
HOL-SEC-079 states; the kept classes protect membership, ranks and the walk. A 0.13
contact compacts the old way, so for a flooded roster the AR-29 digests differ and the two
sides re-trade views.
