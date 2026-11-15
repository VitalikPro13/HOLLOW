# HOL-SEC-203: A wrong-typed keys.json ended the relay without its restart snapshot

```
ID:          HOL-SEC-203                 Status: Fixed in 0.14
                                          (883aa238, 2026-11-08)
Severity:    Low                         (Impact M: the relay ends without its SIGTERM path,
                                          so every offline buffer, topic ring, parked kill
                                          signal, session and push token on the box is lost,
                                          and a start with the same file crash-loops;
                                          Exploitability L: only the operator's own
                                          root-owned file triggers it, by a typo or a script
                                          that writes the wrong type)
Category:    Robustness (an exception escaping a timer callback)
Component:   relay-uws/src/license.cpp (LicenseState::load_from_file, try_reload),
             relay-uws/src/main.cpp (the license timer), new license_pool.h
             (parse_keys_file, LicensePool::reload_text) and file_stamp.h
Boundary:    TB-10 (the relay process and its host)
Traces to:   CLAUDE.md relay rule "a throw into uSockets kills the process"; R-RS-07
Attacker:    none needed; the relay operator's own file
Found:       2026-11-07 (t14-deny design, out-of-scope note; confirmed by the hostile
             design review, D14)
Affected:    every relay release through 0.13.0 build 1 (8350841b) that reads keys.json
Fix commit:  883aa238 (0.14, 2026-11-08)
Disclosure:  advisory with the 0.14 GHSAs
```

## Description

`LicenseState::load_from_file` and `LicenseState::try_reload` read `j.value("enabled",
false)` outside the parse's try block. A `keys.json` whose `enabled` is not a boolean, or
whose top level is not an object, threw `nlohmann::json::type_error`. On a reload that
throw left the 30 s license timer callback, which had no catch, and unwound into
uSockets: the process ended without its SIGTERM path, so no restart snapshot was taken. At
start the same throw came before the relay listened, so the unit crash-looped until the
file was fixed. The reload also compared `st_mtime` in whole seconds, so a second edit
inside the same second was never read.

## Fix

One pure reader that never throws, `parse_keys_file` in `license_pool.h`, type-checks
`enabled` and `keys` before any read, refuses a top level that is not an object and checks
the depth before parsing. `LicensePool::reload_text` changes nothing when the file does not
read, so a reload keeps the previous keys and says so. The start and the reload both go
through it, and every read sits in a try/catch. The license timer callback, and the
denylist timer added beside it, are wrapped in try/catch, so a throw can no longer reach
uSockets from either. Reloads compare `st_mtim` with nanoseconds, the size, the inode and
the device (`file_stamp.h`), so an edit inside the same second and an atomic rename are both
read.

## Residual risk

A `keys.json` that does not read at start leaves the license gate off, as invalid JSON
always did, so a members-only relay with a broken file starts open until the file is
fixed; the next reload then reads it. `check-host.sh` does not parse `keys.json` yet.

## Test

- `relay-uws/test/test_license_pool.cpp`: "a keys.json with enabled as a string keeps the
  previous keys", the other wrong shapes (`keys` as a string, a top-level array, a string,
  a number for `enabled`, truncated text, empty text), "a good keys.json still reloads",
  "missing fields read as off with no keys".
- `relay-uws/test/test_relay_live.cpp` with `RELAY_LIVE_ONLY=deny` (the `deny` variant of
  `run_live.sh`): `deny_license_wrong_types` writes the wrong-typed file, waits past the
  30 s reload and logs in.
- `relay-uws/test/test_deny_list.cpp`: "an edit inside the same second shows" and "a rename
  onto the path shows" (the shared `file_stamp.h`).

RED on the base: `j.value("enabled", false)` over `{"enabled":"yes"}` throws
`[json.exception.type_error.302] type must be boolean, but is string`.
