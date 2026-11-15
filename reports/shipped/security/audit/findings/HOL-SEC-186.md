# HOL-SEC-186: The relay read client JSON only up to a raw NUL byte

```
ID:          HOL-SEC-186                 Status: Fixed (2026-10-22, wave g13, local commit 22116aa5),
                                          relay deployed 2026-10-23
Severity:    Low                         (Impact L: the relay judged a different value than the one the
                                          client's own parser reads; no way to use the difference was
                                          found; Exploitability M: any client)
Category:    Data validation (parser differential)
Component:   relay-uws/src/client_json.h (parse), relay-uws/src/auth_frame.h
Boundary:    TB-1 (client <-> relay)
Traces to:   C-25; HOL-SEC-028, HOL-SEC-128 (client JSON enters only through client_json::parse)
Attacker:    any client
Found:       2026-10-22 (wave g13, relay fuzzing track)
```

## Description

nlohmann's parser stops reading at a NUL byte after a complete value, so a text frame such
as a complete JSON object followed by a NUL and more bytes was read as the object alone,
and the rest was ignored. The client's serde refuses such input. The relay therefore
judged a different value than the client side would. Present in every released relay.

## Fix

`client_json::parse` refuses any client JSON text holding a raw NUL (JSON never has one).
The same fuzzing track moved the binary opcode parsers into `binary_frame.h` (proven
byte-identical by an exhaustive comparison) and put nine relay parsers under libFuzzer with
ASan and UBSan, nightly on the Mac mini.

## Residual risk

None known.

## Test

`test_client_json.cpp` ("a frame with bytes after a NUL is refused", "a frame ending in a
NUL is refused", "a NUL inside a string is refused") and `test_auth_frame.cpp` ("a hello
with bytes after a NUL is no hello", "an auth frame ending in a NUL is refused"); every
fuzz seed and saved crash input is replayed by `run_tests.sh`, plain and sanitized.
