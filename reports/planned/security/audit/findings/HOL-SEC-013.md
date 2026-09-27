# HOL-SEC-013: A decrypted payload that was not an envelope was shown as a DM with no signature and no block check

```
ID:          HOL-SEC-013                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact M: text of the sender's choosing shown as a DM although it carries
                                          no signature, from a blocked contact too, attributed to the raw device id;
                                          Exploitability M: needs an Olm session with the victim, which a friend,
                                          a blocked former friend or an own device holds)
Category:    Missing authentication of content (legacy fallback); access control (block list skipped)
Component:   rust/hollow_core/src/node/swarm.rs :: Olm arm, envelope parse failure
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-09, C-13; candidate L4 (evidence dm:S-04, transport:S-15)
Attacker:    P-04 friend or blocked former friend with a modified client
Found:       2026-09-26, phase B DM and transport passes; confirmed by reading 2026-09-27
```

## Description

After decrypting an Olm frame, the live node parses it as a message envelope.
When the parse failed it treated the plaintext as a DM from a client that
predates envelopes and emitted it to the interface with no signature, no block
check and no revoked-device check, keyed by the sender's device id. Every
current sender wraps its payload in an envelope, and DMs are refused unless their
signature verifies, so this fallback was the one way an unsigned DM reached the
screen. It also showed version skew (an envelope type the receiver does not
know) as a JSON bubble. The push path already dropped such payloads.

## Reproduction

`a_dm_reaches_the_ui_only_after_its_signature_verifies` (node/crypto_handler.rs
tests): swarm.rs emits a DM from one place, the arm that verified it.

## Fix

A decrypted payload that does not parse as an envelope is logged and dropped,
as on the push path. The friend-handshake sentinel, which is deliberately not
JSON, is still matched before the parse.

## Variants

- Other surfaces that show content from a decrypted frame go through signed
  envelope handlers; the blocklist gaps on those handlers are candidate L3.

## Test

The guard fails on the old code (two DM emissions, one unverified) and passes
with the fix. Full suite green.
