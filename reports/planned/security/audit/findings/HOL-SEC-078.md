# HOL-SEC-078: The relay let a master-key holder read a protected identity's inbox and lock its devices out

```
ID:          HOL-SEC-078                 Status: Fixed on local main (2026-10-02), relay deployed
                                         2026-10-02, retest at release
Severity:    Medium                      (Impact M: the friend requests waiting for a person, the
                                          presence of their devices, and a mailbox their own devices
                                          could no longer read; Exploitability M: the master key, from
                                          a leaked backup or a removed device)
Category:    Authorization / Identity
Component:   relay-uws/src/ws_handler.cpp (inbox_owner_proved), relay-uws/src/state.h
             (device_list_max_version); rust/hollow_core/src/node/roster_book.rs (inbox_proof,
             inbox_version), node/ws_client.rs (the inbox join), node/swarm.rs
Boundary:    TB-1 (client and relay), TB-3 (own identity and its devices)
Traces to:   C-01, C-03; AR-15 (its inbox half); HOL-SEC-077
Attacker:    P-08 (own removed device), P-09 (a holder of a backup file and its passphrase)
Found:       2026-09-30 (design ID-1, left as its own item ID-1R)
```

## Description

The relay let a socket own an `inbox:{master}` room (read the mailbox of friend requests
and replies, see the identity's other devices and when they are online, take deposits
live) when it showed a device list signed by the master key that named its device. After
design ID-1 the master key admits no device, but anyone holding it, a restored backup or a
removed thief's phone, could still sign such a list naming itself. Because the relay kept
the highest list version it had seen per master and refused anything lower, the same
holder could sign a list at a huge version and lock every real device out of its own
mailbox.

## Fix (design ID-1R)

The inbox join carries the device's own roster (`inbox_roster`). The relay keeps one
roster per identity (`relay-uws/src/roster_book.h`), folds every roster shown for it into
that one with the same rules the apps use (`relay-uws/src/roster.h`, a rule-for-rule
mirror of `identity/roster.rs`), and lets a socket own the inbox only while its device is
a member of the result. What can only take a device away, a removal or a newer recovery,
therefore stays once any device has shown it, the first recovery key held is pinned, and
a change that drops a member drops its inbox at once (`drop_inbox_owners`). Waiting
devices count seven quiet days on the relay's own clock, unless the phrase turned that
off. The registry is bounded by fair share (`FairShare`, 128 MB) and rides the restart
snapshot (codec v7). Each device shows its roster on every connect and after every change
to it, the remover included. The 0.11 master-signed list is still read until 0.12 ships
(`ACCEPT_DEVICE_LIST_INBOX_PROOF`), and never for an identity whose roster the phrase
roots or for a device that roster removed.

## Test

Harness `authz_the_master_key_alone_never_owns_a_protected_inbox`,
`authz_a_removed_device_loses_the_inbox_at_once`,
`mailbox_requires_a_roster_that_counts_the_device`,
`authz_an_inbox_shows_its_devices_only_to_each_other`; relay `test/test_roster.cpp`
(117 vectors written by `identity/roster_vectors.rs`, each matched byte for byte, plus the
book and JSON rules), `test/test_snapshot_codec.cpp` (v7 and every older version); the
live probe against a canary and then production (`inbox_probe.py`, 19 checks: a 0.11 list
still opens a legacy inbox; a stolen roster, a recovery key the holder minted and a
master-signed list open no protected one; a removal takes the inbox at once and an older
roster gives nothing back).

## Residual

AR-15: after the relay box reboots (a service restart keeps the registry), the first
roster any device shows for an identity sets its recovery key there, so a master-key
holder who shows a forged one first holds that identity's inbox on that relay until the
next reboot. The relay's CPU for verifying shown rosters waits for phase G.
