# HOL-SEC-161: Olm sessions accepted the truncated MAC of v1 and keys of small order

```
ID:          HOL-SEC-161                 Status: Fixed (2026-10-04, session 35)
Severity:    Info
Category:    Crypto
Component:   rust/hollow_core/src/crypto/olm_manager.rs (open_prekey, create_outbound_session)
Boundary:    TB-1, TB-2
Traces to:   phase E+F olm C-OLM-08, C-OLM-10; lead L-02
Attacker:    P-03 stranger running its own client
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

A PreKey asking for the 8-byte MAC of Olm v1 opened a v1 session, although Hollow only
starts v2 sessions. vodozemac's 3DH never checks that a key agreement is contributory, so a
session could be built on an identity, one-time or base key of small order.

## Fix

A PreKey with a truncated MAC is refused on every path; an identity, one-time or base key of
small order is refused before any session is built, inbound or outbound.

## Residual risk

The ratchet keys of later messages are not checked; vodozemac rejects nothing there either,
and L-02 found no way to use one.

## Test

`a_prekey_with_a_truncated_mac_never_opens_a_session`,
`a_small_order_key_never_starts_a_session`.
