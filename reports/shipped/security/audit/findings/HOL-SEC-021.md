# HOL-SEC-021: An Admin could make every member delete a server's files and message history

```
ID:          HOL-SEC-021                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact H: every member's retention sweep deletes the server's vault
                                          content and channel files, or its channel history back to the start;
                                          Exploitability L: needs the Admin role or Manage Server, granted by the
                                          Owner)
Category:    Missing input validation; authority wider than intended
Component:   rust/hollow_core/src/crdt/server_state.rs :: op_allowed, setting_change_allowed
             rust/hollow_core/src/vault/adaptive.rs :: parse_retention_days
             rust/hollow_core/src/node/sync_handler.rs :: handle_update_server_setting
             lib/src/ui/server_settings/pages/files_storage_page.dart :: _Retention
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-17; candidate E10 (evidence crdt:S11); decision 2c
Attacker:    P-06 admin with a modified client
Found:       2026-09-26, phase B CRDT pass; confirmed by reading 2026-09-27
```

## Description

`ServerSettingChanged` accepted any key and value from anyone holding Manage
Server, and every member's sweep deletes by the retention settings. A value of
`0d` for files, or any number of days the app does not offer, deleted every
vault manifest and channel file past that age on every member. Message
retention prunes only after its `_since` stamp, but the stamp is a setting of
its own, so setting it to 0 opened the whole history to the prune.

## Reproduction

`authz_retention_is_owner_only_and_takes_only_app_values` (crdt/server_state.rs
tests) and `a_value_the_app_does_not_offer_keeps_everything`
(vault/adaptive.rs tests).

## Fix

- One rule for authoring and ingest, `setting_change_allowed`: the retention
  policies (`retention_files`, `retention_messages`) and their `_since` stamps
  are written by the Owner only, a policy only with a value the app offers
  (30, 90, 180 or 365 days, or permanent) and a stamp only as a number. Every
  other key still needs Manage Server.
- A reader treats any value the app does not offer as "keep everything", so a
  bad value already stored deletes nothing.
- The settings page shows retention as read-only to everyone but the Owner.

## Variants

- A `ServerSettingChanged` for any other key is still free-form. Every other
  key the node reads (file size cap, relay catch-up window, privacy, NSFW,
  member cap, Twitch gate, server avatar and banner) changes reach or admission
  within Manage Server's authority; none deletes content.

## Test

The ingest test fails with the old rule (an Admin's retention change is
admitted) and passes with the fix. Full suite green.
