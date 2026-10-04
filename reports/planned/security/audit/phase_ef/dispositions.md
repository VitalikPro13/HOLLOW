# Phase E+F: where every candidate went

Every candidate in this folder is named by a finding's "Traces to" line, an accepted risk, or
the table below (session 35, 2026-10-04). The "Info (no candidate)" notes in `mls.md` and
`media.md` are observations, not candidates; I-5 of `mls.md` is the one with a decision (AR-35).

| Candidate | Severity | Where it went |
|---|---|---|
| C-DIST-07 | Info | AR-35 (no build provenance) |
| C-FILES-06 | Low | AR-35 (bounded by the hash-list tie) |
| C-IDENTITY-08 | Low | Fixed, HOL-SEC-162 |
| C-IDENTITY-09 | Low | AR-34 |
| C-IDENTITY-14 | Info | AR-15 (the seven-day path while every owner device is away) |
| C-IDENTITY-15 | Info | AR-34 |
| C-IDENTITY-16 | Info | AR-34 |
| C-LOCAL-08 | Low | No finding: the marker is the first fallible step and nothing destructive precedes it; `wipe_routine_is_idempotent_and_marker_resumes` covers the resume |
| C-LOCAL-12 | Info | No finding: the loopback server's residual (a same-user process with the token) is the one `security_write_gates.md` section 12 records, and that process could read the key material anyway |
| C-LOCAL-13 | Info | No finding: the random path token is the gate, so a `Host` check adds nothing while it stands |
| C-LOCAL-14 | - | Non-finding (no authorisation decision lives only in Dart) |
| C-LOCAL-15 | - | Non-finding (helper arguments are not built from remote input) |
| C-LOCAL-16 | - | Non-finding (Android backup and device transfer are off) |
| C-LOCAL-18 | Low | AR-33 (lock-screen previews are the OS setting outside App Lock) |
| C-LOCAL-19 | Info | Fixed with HOL-SEC-156 (the wipe clears `push_hints`) and HOL-SEC-158 (excluded from backups) |
| C-LOCAL-20 | - | AR-04 (an unlocked running device) |
| C-LOCAL-21 | - | Non-finding (no remote-triggered panic in the parsers walked) |
| C-LOCAL-22 | Info | AR-33 |
| C-LOCAL-23 | - | By design: a profile this machine can unlock silently erases without a prompt |
| C-MEDIA-08 | Low | AR-35; WHITEPAPER 6.3 corrected |
| C-OLM-05 | Info | AR-35 |
| C-OLM-07 | Info | AR-35 |
| C-OLM-08 | Info | Fixed, HOL-SEC-161 |
| C-OLM-10 | Info | Fixed, HOL-SEC-161 |
| C-RP-10 | Low | AR-32 |
| C-RP-11 | Low | AR-32; the privacy policy says what a disk copy allows |
| C-RP-12 | Info | AR-32 |
| C-RP-13 | Info | Fixed in session 34 with HOL-SEC-160's deploy: `IPAddressDeny=` in `hollow-push.service`, the sidecar refuses the box's own addresses, `check-host.sh` checks `PUSH_TOKEN` |
| C-RP-14 | Info | AR-33 |
| C-RP-15 | Info | Fixed in session 34: `check-host.sh` checks kdump, the forwarder's secrets, coturn's live config and `PUSH_TOKEN`; the forwarder unit and example config match the box rules |
