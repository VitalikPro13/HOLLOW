# Phase B re-check brief (Hollow security audit)

Repo root: C:\Users\Jabun\Documents\Coding\HOLLOW
Audit folder: reports/planned/security/audit/
- `phase_b_evidence/authz_<area>.md`: evidence gathered 2026-09-26, one `### ` section per
  inbound message type / ingest path, each with dispatch sites, checks, the BINDING cell
  (the line tying the signer's authority to the object the message names) and suspicions.
  Line numbers there are STALE: since then designs D (MLS), E (CRDT fold), A (sealed frames,
  Olm `carry` lane, join lock, meeting lane), ID-1 (roster, recovery phrase, SPAKE2 link)
  and ID-1R rewrote most handlers. Many message types were deleted or moved.
- `candidate_findings.md`: the suspicions grouped by root cause (rows A1, B3, E4, H14 ...)
  with their resolution (FIXED HOL-SEC-nnn / ACCEPTED AR-nn / folded ...).
- `findings/HOL-SEC-001..082.md`: each fixed finding, naming its reproducing test.
- `accepted_risks.md`: AR-01..AR-15.
- `authz_matrix.md`: the matrix; only 5 rows were ever moved to "verified".
- Wiki claim under test (NOT evidence): tools/hollow-memory/wiki/security_write_gates.md

## The question

`authz_matrix.md` lists only 5 verified rows; every other row is `E` (evidence only).
We need to know, for EVERY section of your evidence file, what the truth is in the CURRENT
code: is the binding really there now, was it fixed by a finding, is the path gone, or is
something still missing (a real gap, or a fix that was planned but never built)?

## Hard rules

1. READ-ONLY. Do not edit any repo file. Do not run cargo, flutter, git write commands or
   builds/tests (the tree is shared). Read, grep, and write ONLY your output file.
2. Every verdict cites CURRENT `path:line` you actually read plus a short verbatim quote.
   Never infer a check from a comment, a doc, a function name, the wiki or a finding file.
   Follow calls into the function that decides.
3. Unsure = say UNSURE and why. Never guess a line.
4. Attacker model: a hostile relay (forges any `from`, replays, drops, reorders, lies about
   rooms; cannot forge signatures or break Olm/MLS) and peers with VALID keys for their OWN
   identity. The question is never "is it signed" but "may THIS signer say THIS about THIS
   object", on EVERY transport that can deliver it (Olm, MLS, sealed plaintext frame, relay
   topic ring, sync backfill, push fetch node `fetch.rs`, data channel, forwarder).

## Output (write to the output file named in your task)

1. A table, one row per `### ` section of your evidence file, in file order:

| Evidence id | Message / path | Verdict | Current binding (path:line + quote) | Transports checked | Guard test(s) | Notes |

Verdict is exactly one of:
- `V` binding present now and matches the policy on every transport
- `FIXED HOL-SEC-nnn` (you confirmed the fix is in the current code; cite it)
- `ACCEPTED AR-nn`
- `GONE` the message type / path no longer exists (say what replaced it, if anything)
- `GAP` the binding is missing or weaker than policy on at least one transport: say exactly
  which transport and what an attacker could do, one sentence, no exploit walkthrough
- `PARTIAL` a fix exists but a sub-point of the section (freshness, absent-field handling,
  transport parity, blast radius) is still open
- `UNSURE`
Guard test: grep the Rust tests (`authz_*`, the findings' named tests) for one that would
fail if the binding were removed; name it, or write `none`.

2. A list of every SUSPICION line in your evidence file -> the `candidate_findings.md` row it
   became (or `NOT CARRIED` if no row picked it up) -> that row's status -> whether the
   current code agrees.

3. A short summary: counts per verdict, and every GAP / PARTIAL / NOT CARRIED / UNSURE item
   in one line each.

Then reply with: the output file path and section 3 only.
