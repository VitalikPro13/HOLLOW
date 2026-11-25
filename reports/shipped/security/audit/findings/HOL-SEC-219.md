# HOL-SEC-219: a removed access key left the fetch and guest connections it let in open

```
ID:          HOL-SEC-219                 Status: Fixed in relay 0.14.3
                                          (track fix-153c, 2026-11-21)
Severity:    Low                         (Impact L: a person whose access key the operator
                                          removed keeps a background fetch or a guest view
                                          of public channels on a members-only relay until
                                          that connection closes by itself; Exploitability L:
                                          needs a key holder the operator has just removed)
Category:    Stale authorization
Component:   relay-uws/src/license.cpp (try_reload), relay-uws/src/license_pool.h
             (replace_keys), relay-uws/src/ws_handler.cpp (handle_auth, close handler)
Boundary:    TB-4 (relay host and its operator)
Traces to:   R-RS-25
Attacker:    a holder of an access key the operator removed from keys.json
Found:       2026-11-21 (track fix-153c, while fixing the access-key seats of #153)
Affected:    every relay with access keys, through 0.14.2
Fix commit:  774d75fc3 (relay 0.14.3)
Disclosure:  with the 0.14.3 release
```

## Description

A members-only relay closes the connections of a key the operator removes from keys.json.
The reload looked those connections up by device id among full connections only, so the
background fetch connections and guest connections the same key had let in were never
found and stayed open after the key was gone.

## Fix

A seat belongs to the connection that took it, so the reload knows every connection a key
let in, whatever its kind. A removed key closes all of them, full, fetch and guest alike,
with close 1008 `license_revoked`, and the key admits nobody afterwards. The close handler
gives the seat back for every connection, whatever ended it. HOL-SEC-220's fix, in the same
release, also ends the sessions in grace a removed key's devices left behind.

## Test

Relay live variant `license`: `license_revoked_key_closes_every_socket` (a full, a fetch and
a guest connection on one key are all closed `license_revoked` by the reload, and the key
then refuses a new login), with `license_every_path_back_to_zero`; relay unit
`test_license_pool` (the reload returns every connection of a revoked key).
