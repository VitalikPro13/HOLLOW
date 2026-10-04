# HOL-SEC-145: One-time keys could be spent by another requester, extreme stamps panicked debug builds, and padded keys made alias ids

```
ID:          HOL-SEC-145                 Status: Fixed (2026-10-04, session 34)
Severity:    Low
Category:    Crypto / Data validation
Component:   rust/hollow_core/src/node/frame_auth.rs, crypto_handler.rs, identity/native_identity.rs, archive/loader.rs
Boundary:    TB-1, TB-2
Traces to:   phase E+F olm C-OLM-03, -04, -06
Attacker:    P-01 relay, P-03 stranger
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

A PreKey could spend a one-time key slotted to a different requester; unchecked i64
subtraction on sender-chosen stamps panicked a debug node or forwarder before any signature
check; public-key encodings longer than 36 bytes gave one key several ids.

## Fix

A PreKey spending another requester's slotted key is refused; stamp arithmetic saturates;
public keys must be exactly 36 bytes.

## Test

`a_requesters_key_opens_only_that_requesters_session`,
`a_frame_stamped_at_the_i64_extremes_is_judged_without_overflow`,
`a_key_exchange_stamped_at_the_i64_extremes_is_refused`,
`a_public_key_encoding_with_trailing_bytes_is_refused`,
`an_archive_signed_under_a_padded_key_never_verifies`.
