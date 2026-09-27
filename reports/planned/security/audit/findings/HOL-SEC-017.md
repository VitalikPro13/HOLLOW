# HOL-SEC-017: A server member or a meeting guest could be seated in the encryption group under someone else's name

```
ID:          HOL-SEC-017                 Status: Member and guest halves fixed on local main (2026-09-27); the
                                          relay half stays open with the class D design
Severity:    High                        (Impact H: a leaf credentialed as the owner or another member, so every
                                          MLS envelope it sends is attributed to that identity (meeting chat
                                          included), and a restricted-channel subgroup keeps a leaf whose name
                                          qualifies; Exploitability M: a modified client and plain membership, or a
                                          meeting knock)
Category:    Authentication (a credential nobody checked); spoofing
Component:   rust/hollow_core/src/node/swarm.rs :: MlsKeyPackage arm
             rust/hollow_core/src/node/conference.rs :: meeting join request (knock)
             rust/hollow_core/src/crypto/mls_manager.rs :: key_package_identity
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-09, C-17, C-19; candidates D1, D6, D7; lead L-03
Attacker:    P-05 member with a modified client, P-03 meeting guest
Found:       2026-09-26, phase B server/MLS pass; confirmed by reading 2026-09-27
```

## Description

An MLS leaf's credential is a bare device id, and the group attributes every
envelope to it. The KeyPackage a device sends to ask for a leaf carries that
credential as a claim. The parked-join path already refused a KeyPackage whose
credential was not the sending device, but the live `MlsKeyPackage` path and
the meeting knock seated whatever the package named. A member could therefore
obtain a leaf in the owner's name, and a meeting guest a leaf in the host's,
with chat and every unsigned envelope attributed accordingly.

## Reproduction

`authz_key_package_must_name_its_sending_device` (node/crypto_handler.rs tests)
and `key_package_identity_reads_the_leaf_credential` (crypto/mls_manager.rs
tests).

## Fix

The live KeyPackage arm and the meeting knock both refuse a package unless
`key_package_identity` equals the device the frame came from, before anything
is queued. All three seating paths now apply the same rule.

## Variants

- The device a frame "came from" is the relay's word. A relay can still name a
  victim device as the sender of its own package; binding the credential to a
  device key, validating credentials at Add, Welcome and Commit, and deciding
  who may commit are the class D design (D1 relay half, D2 to D5, D9, D10).
- A member can still commit an Add of an arbitrary credential itself (D2).

## Test

The guard fails on the old code (the live arm and the knock never read the
credential) and passes with the fix; the meeting harness test
`conference_waiting_room_admits_denies_and_chats` still admits an honest guest.
Full suite green.
