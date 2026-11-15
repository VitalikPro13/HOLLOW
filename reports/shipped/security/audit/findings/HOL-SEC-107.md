# HOL-SEC-107: The push process had no file header size cap

```
ID:          HOL-SEC-107                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact: a large file written by the push process, inline bytes decoded before any check;
                                          Exploitability L: needs a DM session)
Category:    Files / Availability
Component:   rust/hollow_core/src/node/file_handler.rs (header_size_refused), fetch.rs,
             swarm.rs (Olm header arm), MLS header path
Boundary:    TB-2 (contacts)
Traces to:   phase B re-check transport A-T06
Attacker:    a friend
Found:       2026-10-02 (phase B re-check)
```

## Description

The main node capped DM file headers at the 34 MiB send limit with a literal in two places; the push fetch process had no copy of the cap and decoded inline bytes before checking anything.

## Fix

One gate, `header_size_refused`, serves the Olm, MLS and push fetch arms: the declared size against the server limit or the send limit (share-backed files exempt), and inline bytes judged by their encoded length before they are decoded.

## Test

Unit `fetch_refuses_a_dm_header_over_the_send_limit` (failed before), `header_size_gate_judges_inline_bytes_before_decoding`; wiring scan `file_header_gate_stays_wired`; mutation killed.
