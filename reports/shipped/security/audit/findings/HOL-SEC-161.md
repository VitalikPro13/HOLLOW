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

Since 0.14 (vodozemac 0.11.2) a PreKey's inner ratchet key is refused when it has small order
too: vodozemac refuses a non-contributory ratchet step only at our first send, so a session
built on one would install and could never answer. A session that fails to encrypt is
retired, so the next send re-keys. The ratchet keys of later messages are refused by
vodozemac itself since 0.10 (the ratchet step fails to decrypt), and its own 3DH refuses
small-order keys and a v1 PreKey under the v2 config; Hollow's checks run first and keep their
own reason.

## Test

`a_prekey_with_a_truncated_mac_never_opens_a_session`,
`a_small_order_key_never_starts_a_session`,
`a_prekey_with_a_small_order_ratchet_key_never_opens_a_session`,
`the_crafted_prekey_with_an_honest_ratchet_key_opens_and_answers`,
`a_session_that_cannot_encrypt_is_retired_so_the_next_send_re_keys`,
`vodozemac_alone_refuses_a_v1_prekey_under_the_v2_config`,
`vodozemac_alone_refuses_an_outbound_session_on_a_small_order_key`. Since 0.14 the two
original tests also check that the refusal is Hollow's own, not vodozemac's.
