# HOL-SEC-063: A captured relay login opened an invisible socket in the device's name

```
ID:          HOL-SEC-063                 Status: Fixed on local main (2026-09-29), retest at release
Severity:    Medium                      (Impact M: a socket beside the live device takes its room
                                          slots, drains its offline buffer and acks away its parked
                                          destroy orders, unseen by members; Exploitability M: needs a
                                          relay the victim also uses to capture a login, replayed within
                                          about a minute)
Category:    Authentication
Component:   relay-uws/src/auth_frame.h, ws_handler.cpp :: handle_auth, handle_join, leave_room,
             discover_peers, close; state.h; rust/hollow_core/src/node/ws_client.rs :: connect_and_auth;
             node/fetch.rs; forwarder/signaling.rs
Boundary:    TB-1 (client <-> relay)
Traces to:   C-25; candidates A17, I4 (fetch sockets); relay inventory A.1..A.4, B.2
Attacker:    P-01 operator of a second relay the victim connects to; P-06 anyone in a room with a
             fetch socket (presence)
Found:       2026-09-26 (phase B), re-confirmed 2026-09-27 in the design A inventory
```

## Description

A client logged in by signing `hollow-ws-auth:{device}:{timestamp}`. The string named
no relay and carried no challenge, and the `fetch`, `guest` and license key fields rode
beside it unsigned. The operator of any relay the victim used could replay a captured
login to another relay within the 60 second window. As a `fetch` socket it evicted
nothing and was never listed, yet its joins overwrote the live device's room slots,
drained the device's offline buffer and acknowledged its parked destroy orders. A
genuine fetch socket did the same to its own device's full socket, and its close could
leave that device out of a room without anyone seeing it leave. `discover_peers`
listed fetch sockets, so a push wake in a DM room told the other side when that phone
woke.

## Reproduction

`auth_v2_message_matches_the_relays_pinned_vector`, `auth_domain_is_the_dialled_host_without_port`,
`test_auth_message_format` (node/ws_client.rs); relay-uws/test/test_auth_frame.cpp, section
"auth v2".

## Fix

Auth v2. The client asks for a challenge (`auth_hello`), the relay answers with a fresh
32-byte nonce for that socket, and the client signs `hollow-ws-auth2`, the relay's domain
(the host it dialled), the nonce, its device id, the time, the mode (`full`, `fetch` or
`guest`) and the SHA-256 of its license key. The relay takes a signature only over its
own domain and the nonce it handed that socket, once. The Rust node, the push fetch
node, the media forwarder and the web viewer all log in this way; a relay older than
0.12 answers the hello as a bad login, which the client reports as a relay that needs
updating.

A fetch socket never takes a slot its device's full socket holds, tracks its rooms on
its own so the full socket's reset cannot strand them, leaves only its own slots, gets
no roster or presence, and is never listed or announced. A full socket arriving where
its own fetch socket holds the slot is announced as present.

Pre-0.12 clients still sign v1 until 0.12 ships (`ACCEPT_AUTH_V1` in ws_handler.cpp,
turned off on release day); a v2 signature cannot be read as v1, so only 0.11 logins stay
replayable meanwhile, as before.

## Test

The Rust unit tests above pin the signed string byte for byte against the relay's copy
(`auth_v2_message` in auth_frame.h); `only_the_relays_exact_codes_are_license_refusals`
covers the typed refusal. test_auth_frame.cpp adds 18 checks: hello recognition, v2
parsing, refused versions and field types, the mode rule (guest and fetch at once is no
mode), the domain rule, nonce shape and the pinned vector. The relay handlers
(challenge bookkeeping, fetch slots) have no C++ harness; the whole relay was built and
every relay test run on the VPS from a temporary copy.
