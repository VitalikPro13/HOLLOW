# HOL-SEC-148: A link preview made the sender's own machine fetch loopback and LAN addresses

```
ID:          HOL-SEC-148                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact M: requests from the user's machine into its local network, with the answer reflected into a card; Exploitability M: the user pastes a link, or a public link redirects inward)
Category:    SSRF
Component:   rust/hollow_core/src/node/link_preview.rs
Boundary:    TB-7
Traces to:   phase E+F files C-FILES-01
Attacker:    P-12 third-party web
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

The preview fetcher checked only the scheme, followed three redirects with no address check
and fired on a 600 ms compose debounce.

## Fix

A resolver refuses a name if any address it resolves to is not public and hands the
connector only the checked addresses (no rebinding); IP literals are checked on the first
request and on every redirect; no proxy.

## Test

The `address_guard` tests (a local listener on 127.0.0.1 and a redirect to it, both
refused).
