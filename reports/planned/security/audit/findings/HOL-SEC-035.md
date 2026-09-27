# HOL-SEC-035: The push path ignored blocks, key changes, the mention setting and who sent the wake

```
ID:          HOL-SEC-035                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact M: a blocked person's DMs stored and shown by the push path; a
                                          key change first seen there never raised its notice; a mentions-only
                                          channel showed every post of a wake whose sender claimed a mention;
                                          anyone who knows a device id put banners naming themselves on the
                                          phone; a push naming any server made the phone join that room;
                                          Exploitability M: the push payload and the mention flag come from the
                                          sender or the relay)
Category:    Missing authorization on a second ingest path (parity)
Component:   rust/hollow_core/src/node/resolver.rs :: warm_from_store
             rust/hollow_core/src/node/fetch.rs :: run_fetch, try_decrypt_dm, try_process_channel_msg,
             push_sender_known, filter_by_notification_level
             rust/hollow_core/src/node/security_alerts.rs :: pin_olm_identity_key
             rust/hollow_core/src/api/network.rs :: push_sender_known, get_push_channel_meta,
             nudge_live_room_join
             lib/src/core/services/push_notification_service.dart, push_hints_cache.dart
             ios/NotificationService/NotificationService.swift
Boundary:    TB-1 (relay), TB-5 (push provider)
Traces to:   C-14, C-18; candidates K1, K2, K3, C14, J4 (evidence transport:S-01, S-02, S-11, S-12, relay:A-22a)
Attacker:    P-01 relay, P-02 stranger, P-05 server member, P-09 push sidecar
Found:       2026-09-26, phase B transport pass; confirmed by reading 2026-09-27
```

## Description

The push fetch node and the iOS extension are fresh processes. They warmed the
device resolver but never the block list, so their block check never matched.
They created Olm sessions from PreKeys without the key pin the live node keeps,
and the app, loading the session later, never saw the PreKey. A channel wake
trusted the sender's "mentions you" flag and then showed every post it fetched.
A wake whose fetch found nothing put up a fallback banner naming whoever the
relay said sent it, and the push payload's server id was joined without checking
that we are a member.

## Reproduction

`authz_a_fresh_push_process_knows_our_blocks`,
`authz_a_key_change_first_seen_by_push_is_recorded`,
`authz_an_empty_wake_names_only_a_sender_we_know`,
`authz_a_mentions_only_channel_shows_only_mentions_we_read`,
`a_channel_wake_for_a_server_we_do_not_hold_joins_nothing` (node/fetch.rs tests).

## Fix

- `warm_from_store` loads device links, enforced revocations and the block list,
  and every process that judges inbound frames calls it. A blocked member's
  channel post is stored as on the live node but never becomes a banner.
- The fetch path records a changed Olm key through `pin_olm_identity_key`, the
  store half of the live node's pin; the app shows the alert on its next start.
- Each fetched channel post carries our own reading of whether it mentions us,
  with the rule the sender uses, and `run_fetch` applies each channel's local
  level to the posts (nothing / mentions / all). The relay flag only decides
  whether to wake. The iOS extension's pre-fetch body no longer claims a mention.
- A content-free fallback banner names its sender only when Rust says we know
  them (not blocked or revoked; a friend, our own device, or someone we share a
  server with; for a channel wake, a member of that server). A locked identity
  shows the generic banner, which names nobody. A mentions-only channel shows no
  fallback at all.
- A channel wake for a server we are not a member of is dropped in Dart, and
  both the fetch node and the live-node nudge refuse to join it.
- The iOS push hints leave blocked friends out.

## Residual

- iOS shows the APNs alert ("New message") for any wake before the extension
  runs; without Apple's notification filtering entitlement the extension cannot
  withhold it. A stranger who knows a device id can still cause generic banners
  within the relay's push budget. Decision for Vitalik: request the entitlement.

## Test

Each test fails with its old rule put back and passes with the fix. Full suite
green.
