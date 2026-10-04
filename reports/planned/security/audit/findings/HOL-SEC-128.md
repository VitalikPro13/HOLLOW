# HOL-SEC-128: One join frame from any identity crashed the relay and lost every buffer

```
ID:          HOL-SEC-128                 Status: Fixed (2026-10-04, session 34), relay deployed 2026-10-04 after ASan and release canaries
Severity:    High (Impact H: every offline buffer, ring, push token, kill order, join lock and roster lost, repeatable; Exploitability H: any authenticated identity, one frame)
Category:    Relay / Availability
Component:   relay-uws/src/ws_handler.cpp (inbox_owner_by_roster, subscribe), new client_json.h
Boundary:    TB-1
Traces to:   phase E+F relay_push C-RP-01; AR-15, AR-19 (their "rare reboot" loss became attacker-triggered)
Attacker:    P-03 stranger with a throwaway identity
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

The relay re-serialised a client's raw `inbox_roster` to measure it, and the `subscribe`
handler copied the client's `topics` array. nlohmann's serializer and copy constructor
recurse once per nesting level, so one frame nested about 200,000 levels deep (well inside
the 1 MiB text cap) overflowed the stack. A SIGSEGV skips the restart snapshot, so the crash
lost everything the relay holds in RAM.

## Fix

Every client JSON (text frames, auth frames, kill-deposit blobs) is parsed only through
`client_json::parse`, which refuses nesting deeper than 32 with a string-aware bracket scan
before nlohmann builds anything, without throwing into uSockets. The roster is measured as
the relay holds it (`roster::to_json(*shown).dump()`).

## Test

Relay `test_relay_live` section `test_deep_json` (crashed the old relay: SIGSEGV, ASan
stack-overflow at the serializer), `test_client_json.cpp`, `test_auth_frame.cpp` "a frame
nested past the depth cap is refused", `test_kill_order.cpp` "an order nested past the depth
cap is no order". Mutation 9/9.
