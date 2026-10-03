# HOL-SEC-096: Junk from a few addresses could push a lost device's destroy order out

```
ID:          HOL-SEC-096                 Status: Fixed on local main (2026-10-03), relay
                                          deployed; client half retest at release
Severity:    Medium                      (Impact H: the order that wipes a stolen or lost
                                          device, parked until it connects, evicted before it
                                          is delivered; Exploitability L: the device id and
                                          eight address blocks, or the order's exact stamp)
Category:    Relay / Availability of a security control
Component:   relay-uws/src/kill_list.h, kill_order.h (new), ws_handler.cpp
             (handle_kill_deposit, handle_kill_ack, auth delivery), snapshot codec v8;
             rust/hollow_core/src/node/ws_client.rs (KillSignalId), destroy.rs, fetch.rs
Boundary:    TB-1 (client <-> relay)
Traces to:   C-21; decision D5 (2026-10-02); phase B re-check relay A-12b, identity A-32
Attacker:    P-02 any account that knows the device id (room rosters show it)
Found:       2026-10-02 (phase B re-check)
```

## Description

HOL-SEC-029 gave every issuer its own slot per target, but a target held at most eight
issuers and a full target evicted the oldest entry of the address share holding the
most. Junk deposits from eight different address blocks therefore evicted the genuine
order the owner had parked for a stolen device. Separately, the target's ack named only
a stamp, so turning away a junk deposit that carried the genuine order's exact stamp
also removed the genuine order.

## Fix

The relay now reads a parked order. When the master signed it and the recovery key pinned
in the roster the relay holds for that master (design ID-1R) stands behind it, directly
or through a phrase-signed permission for a member device, and the target is a device
that consented to that identity, the order waits in the target's proven slot. Opaque
deposits never reach that slot: only a newer proven order replaces it, the target's own
ack removes it, and a list-wide cap of its own evicts by address share. Every other blob
stays opaque, as before. Each kill signal now names its issuer, and an ack that turns
one away names issuer and stamp; a stamp alone removes nothing. The bare ack after a wipe
still clears everything. The snapshot codec (v8) keeps which entries are proven.

## Residual risk (AR-18)

An identity whose phrase was never typed on 0.12 (a legacy roster, AR-15) has no key the
relay can check, so its orders stay opaque and keep the HOL-SEC-029 eviction rules.
Proven slots are bounded list-wide by address share, so an attacker minting free
identities from many address blocks can still evict one (phase G, like AR-16). The relay
now learns that an identity ordered some of its devices wiped; it already knew the devices
of every identity whose roster it holds.

## Test

Relay unit `test_kill_list` (the D5 blocks: junk from forty address blocks and a
list-wide flood leave the proven order, same-stamp junk is acked alone, only a newer
proven order replaces one) and `test_kill_order` against 30 vectors the Rust code writes
(`node/kill_vectors.rs`, `relay-uws/test/kill_vectors.json`). Both D5 checks failed on
the deployed `kill_list.h`. Rust unit `a_kill_signal_keeps_its_issuer_for_the_ack`,
`a_junk_kill_deposit_is_acked_alone`; harness
`authz_turning_away_junk_that_shares_an_orders_stamp_keeps_the_order`. Live probe
`kill_probe.py`. Mutation pass `tmp_d5_mutate.py` (23 of 24 killed, the survivor is an
equivalent early exit).
