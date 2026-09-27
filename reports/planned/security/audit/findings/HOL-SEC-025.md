# HOL-SEC-025: Members who cannot see a restricted channel received the keys to its files

```
ID:          HOL-SEC-025                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    High                        (Impact H: every file posted in a restricted channel of a server with
                                          six or more members readable by every member of the server; the key
                                          arrived on its own and shards were placed on and served to them;
                                          Exploitability H: plain membership, no modified client needed)
Category:    Information disclosure (a server-wide lane for channel-scoped content)
Component:   lib/src/core/providers/file_transfer_provider.dart :: sendFile (vault mode)
             lib/src/core/models/channel_info.dart :: usesSubgroup
             rust/hollow_core/src/node/vault_ops.rs :: handle_vault_upload_file, shard_serve_refused
             rust/hollow_core/src/node/file_handler.rs :: channel file send (use_vault_only)
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-06, C-12; candidate H13 (evidence files:V5-1, V8)
Attacker:    P-05 server member without access to the channel
Found:       2026-09-26, phase B files pass; confirmed by reading 2026-09-27
```

## Description

In a server of six or more members every channel file was also uploaded to the
vault. The vault manifest, which carries the file's key, went to the whole
server group, shards were placed across all members, and any member could pull
them. A restricted channel's messages ride their own MLS subgroup, but its files
reached every member of the server through the vault.

## Reproduction

`authz_restricted_channel_file_never_enters_the_vault` and
`vault_gates_stay_wired` (node/vault_ops.rs tests).

## Fix

- A file in a channel that uses a subgroup never enters the vault: Dart skips
  vault mode for it, the node refuses such an upload, and the channel send
  streams the file to members instead of relying on the vault.
- `shard_serve_refused` serves a shard only to a member who can read the
  channel the file was posted in, when we hold its manifest.
- Dart has one rule for "uses a subgroup", `ChannelInfo.usesSubgroup`, shared
  with the voice provider.

## Variants

- Files already vaulted from restricted channels before this fix keep their
  manifests on members' devices. Nothing can recall a key already delivered.

## Test

The upload test fails with the node's refusal removed (the restricted file is
taken into the vault) and passes with it; the wiring guard holds the serving
gate. Full suite green.
