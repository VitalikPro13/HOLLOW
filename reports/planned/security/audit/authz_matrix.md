# Authorisation matrix (phase B)

Started 2026-09-26, session 3 of the audit. One row per inbound state-changing
message type. Columns follow plan section 3.1.

**How this file is built.** Nine enumeration passes gathered the evidence, one
per area: every dispatch site, check, state change, signer, transport,
freshness rule and absent field, with file:line and a verbatim quote. It lives
in `phase_b_evidence/authz_<area>.md` (about 275 rows). A row counts only once
I have re-read its binding cell in the code. Rows not yet re-read point to
their evidence and carry `E` (evidence only).

**Verdict legend.** `V` = binding verified by reading. `F` = a finding exists.
`E` = evidence gathered, not yet re-read. **Policy** (who SHOULD be allowed) is
proposed here and settled with Vitalik, never delegated.

## Verified rows

| Row | Message / action | Target | Who can sign | Policy (proposed) | Binding check | Transports | Verdict | Test |
|---|---|---|---|---|---|---|---|---|
| A-DM-01 | `KeyRequest`: tear down our session, publish a fresh one-time key | our Olm session with the sender device | sender DEVICE (`hollow-keyrequest:`) | a device in its master's signed, unrevoked list | `verify_key_exchange` + `key_exchange_device_unauthorized` (swarm.rs KeyRequest arm) | plaintext | V; replay within 300 s possible (L6); revoked devices pass (F5) | none yet |
| A-DM-02 | `KeyBundle`: build an outbound session | our Olm session with the sender device | sender DEVICE (`hollow-keybundle:`) | same | same | plaintext | V | `substituted_olm_keys_are_rejected` |
| A-DM-03 | `Encrypted` PreKey: build an INBOUND session on the frame's identity key | our Olm session with the sender device | was nobody; now the sender DEVICE (`hollow-olm-identity:`) | the claimed device's own signature over its key | `verify_olm_identity` before any session change (swarm, fetch, forwarder) | plaintext | F HOL-SEC-003, fixed | `authz_olm_prekey_relay_cannot_open_a_session_as_another_device` |
| A-DM-19 | `DmSyncRequest`: serve a conversation's history | our DM rows with the requester's master | unsigned (relay-stamped `from`) | the counterparty, proven by its Olm session | none beyond `resolve(from)`; the answer rides the session | plaintext request, Olm answer | V; safe only while sessions are authenticated (HOL-SEC-003), request itself still unauthenticated (class A) | via HOL-SEC-003 test |
| A-ID-01 | Foreign `SignedDeviceList` ingest | device ids, resolver bindings, friend rows, server member keys | the list's master | a master names only its own devices | `speaks_for` in `ingest_device_list` (refuses ids bound elsewhere and known masters) | plaintext profile sync, friend request, join request | F HOL-SEC-001, HOL-SEC-006, fixed; F4..F7 open | `a_foreign_device_list_cannot_claim_a_master_id_or_silence_a_legacy_contact` |

## Remaining rows

Every other row is `E`: its evidence is in `phase_b_evidence/authz_<area>.md`
and its suspicions in `candidate_findings.md`. Session 3 re-reads them in the
plan's priority order and moves each into the table above.
