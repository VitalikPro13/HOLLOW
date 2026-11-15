# HOL-SEC-160: The relay, the forwarder's disk and the shareable logs held more about people than they need

```
ID:          HOL-SEC-160                 Status: Fixed (2026-10-04, session 34)
Severity:    Low
Category:    Privacy / Metadata
Component:   lib/src/core/services/push_prefs (pushPrefsForRelay), rust/hollow_core/src/forwarder/, node/ws_client.rs and log sites, lib about_section export
Boundary:    TB-1, TB-4, TB-10
Traces to:   phase E+F relay_push C-RP-06, -07, -08; local C-LOCAL-11
Attacker:    P-01 relay operator, P-09 log reader
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

Phones sent the relay every server's push settings including default ones; the forwarder
kept every client device id on the relay box's disk; logs and the support export carried
display names, server, channel and file names, and the device-link code.

## Fix

Only non-default push settings are sent; forwarder sessions live in RAM and heal themselves
after a restart; log lines carry no names and never the link code, and the export is
redacted.

## Test

`push_prefs_relay_test.dart`, `fwd_keeps_no_client_device_id_on_disk`,
`a_restarted_forwarder_heals_its_clients_sessions`,
`log_lines_name_no_person_place_file_or_link_code`.
