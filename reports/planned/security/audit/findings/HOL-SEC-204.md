# HOL-SEC-204: A self-hosted install's background push fetch dialled the official relay

```
ID:          HOL-SEC-204                 Status: Fixed on local branch security/0.14
                                          (5965e6b9, 2026-11-13), retest at release
Severity:    Medium                      (Impact M: the official relay learns that a device
                                          uses Hollow, its device id and public key, its IP
                                          address, the room it asks for and when it gets a
                                          push, although its person chose another relay to
                                          keep that metadata away from us; the content never
                                          arrives either, so the banner stays generic;
                                          Exploitability M: happens on its own on every wake
                                          that finds the app killed; reading it needs the
                                          official relay's operator or someone who controls
                                          that box)
Category:    Information disclosure (metadata to a party the person did not choose)
Component:   rust/hollow_core/src/node/fetch.rs (run_fetch, new fetch_relay_domain),
             api/network.rs (start_fetch_node), push_enrich.rs,
             ios/NotificationService/NotificationService.swift
Boundary:    TB-1 (client and relay)
Traces to:   C-24 (what a relay may see is promised for the relay the person uses);
             relay-uws/SELF_HOSTING.md (every connection derives from the chosen relay domain)
Attacker:    none needed to trigger; the operator of relay.anonlisten.com to read it
Found:       2026-11-12 (track t14-iospush, while finding why channel pushes against a
             self-hosted test relay were generic; confirmed by a failing test)
Affected:    Android installs on a self-hosted relay with UnifiedPush, from 0.12.0
             (04cd3a25) through 0.13.0; the iOS extension only where a self-hosted relay
             has push credentials of its own (test setups)
Fix commit:  5965e6b9 (security/0.14, 2026-11-13)
Embargo:     EMBARGOED until the 0.14 release (local branch security/0.14, never pushed);
             advisory with the 0.14 GHSAs
```

## Description

Only the official relay holds Hollow's Google and Apple push credentials, so a self-hosted
relay wakes Android phones through UnifiedPush (ntfy and other distributors). When such a
wake finds the app killed, Android starts a background process that fetches the waiting
messages itself. That process never received the relay domain the person picked, because
Dart sets it only in the running app (`set_relay_url`), and the fetch fell back to the
official relay. So on a self-hosted Android install each such wake made the device log in
to the official relay with its device key and ask for the DM or server room the wake named.
That relay held nothing for the device, so the banner stayed generic, and the official
relay saw metadata the person had moved to their own relay.

The iOS Notification Service Extension had the same fallback. It is reached only where a
self-hosted relay has push credentials of its own (a test setup); on the official relay it
already dialled the right relay.

## Fix

`fetch::fetch_relay_domain` decides the relay inside `run_fetch`: the domain the caller
gave, else the `relay_domain` setting this install saved in its own database, else the
official relay, which a default install never saves. A database the fetch cannot open or
read refuses the fetch; only a database that reads and holds no choice means the official
relay. `start_fetch_node` and both extension paths now pass an empty domain instead of
naming the official relay, so every fetch process dials the relay the app itself uses.

## Residual risk

None known.

## Test

`w4_iospush_a_fetch_with_no_relay_given_dials_the_installs_own_relay` (a fetch given no
relay must reach a listener at the install's saved relay; failed before the fix with "the
fetch never dialed the relay this install uses") and
`w4_iospush_an_unreadable_relay_choice_refuses_the_fetch`. Mutation: the stored lookup
dropped (M1) and an unreadable choice taken as the official relay (C20) are both killed.
Android emulator proof: a cold-process wake against the self-hosted test relay; on real
devices the fetch dialled the test relay and never the official one (the run's relay
guard found no official relay line in any log).
