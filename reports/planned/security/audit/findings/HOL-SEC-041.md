# HOL-SEC-041: An encryption-group seat proved nothing about who held it

```
ID:          HOL-SEC-041                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Critical                    (Impact H: whoever controls the relay could take a seat in any server
                                          group, private servers and restricted channels included, and read
                                          every group-encrypted message, file key and voice key; a member could
                                          appear as any identity, the owner included; Exploitability H for the
                                          relay operator, M for a member with a modified client)
Category:    Authentication (an unbound credential); spoofing; confidentiality
Component:   rust/hollow_core/src/crypto/mls_manager.rs :: leaf credentials, KeyPackages, sender attribution
             rust/hollow_core/src/node/swarm.rs :: MlsKeyPackage arm, parked-join KeyPackage, startup identity
             rust/hollow_core/src/node/conference.rs :: meeting knock, chat attribution
             rust/hollow_core/src/node/crypto_handler.rs :: subgroup reconcile
Boundary:    TB-1 (relay), TB-2 (peer <-> peer)
Traces to:   C-09, C-17, C-19; candidates D1, D6, D7, D10; the relay half of HOL-SEC-017; lead L-03
Attacker:    P-01 relay operator, P-05 member with a modified client, P-03 meeting guest
Found:       2026-09-26, phase B server/MLS pass; confirmed by reading 2026-09-27
```

## Description

An MLS leaf was signed by a random key minted per install, and its credential
was a bare id its holder chose. Receivers attributed every group envelope to
that id and never checked it against a key they could verify. A KeyPackage was
seated when its id matched the device the relay said sent it, so the relay
could speak for any member device with a package of its own and receive the
Welcome. A member could put any id in its own package, and subgroup membership
and meeting chat followed that id.

## Reproduction

`authz_no_one_seats_a_leaf_in_another_devices_name` (node/test_harness.rs),
`a_leaf_is_bound_only_by_its_device_key_and_its_masters_certificate` and
`a_copied_certificate_never_becomes_a_leaf` (crypto/mls_manager.rs).

## Fix

- A device's MLS signing key is its Ed25519 device key. A peer id encodes its
  public key, so a leaf's signature key must decode from the device id it
  names; nobody without that device's key can make such a leaf.
- The credential carries the master's certificate for the device,
  `hl1:{device}:{master}:{signature}`, over `hollow-mls-leaf:{master}:{device}`.
  Every receiver judges a leaf from the leaf alone: bound, with a proven device
  and master, or unbound.
- A KeyPackage is seated only when bound to the device that sent it, and for a
  parked join to the joiner's master as well. Membership, bans and subgroup
  qualification are decided on the certified master, not on a lookup.
- Messages from an unbound leaf are ignored. While our own leaf is unbound we
  neither encrypt nor commit in that group; sends fall back to Olm.
- Groups formed before the fix are kept: the group authority rebinds its own
  leaf in place with the old key, everyone else is repaired in one commit, and
  the old key is deleted once no group needs it.

## Variants

- A device holding the master key can certify new device ids for the same
  master. That is the stolen-device question of design ID-1.
- A revoked device is refused only where its revocation has arrived.

## Test

Each test fails with the old bare-id rule put back and passes with the fix; the
persisted 0.8.1 fixture rebinds in place. Full suite green.
