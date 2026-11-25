# HOL-SEC-268: the AVI metadata strip recursed without a bound

```
ID:          HOL-SEC-268                 Status: Fixed in 0.14.3
Severity:    Medium                      (Impact M: the stack overflows and the whole app
                                          process aborts; Exploitability L: the user has to
                                          send or pass on a crafted AVI someone gave them)
Category:    Denial of service (stack exhaustion on peer-supplied bytes)
Component:   rust/hollow_core/src/node/media_strip.rs (strip_avi, strip_riff_chunks)
Boundary:    TB-2 (a peer's file on our device)
Traces to:   R-RB-03, C-FILES-03
Attacker:    anyone who can send the user a file
Found:       2026-11-23 (builder of track S7b, session B)
Affected:    every client since the strip shipped (HOL-SEC-150), through 0.14.2
Fix commit:  ef8fd4e64
Disclosure:  published with 0.14.3
```

## Description

The AVI strip walks the RIFF chunks and steps into every `LIST hdrl` it meets, one call
deeper each time. A header list may hold another header list, and nothing limited how
many, so a file of nested header lists (12 bytes a level) recursed until the thread's
stack ran out. A stack overflow is not a panic: it aborts the process. The strip runs on
every video the user sends, including a file received from someone else and sent on, a
vault upload and a large-file share.

## Fix

Header lists nest at most 16 deep (`MAX_LIST_DEPTH`); a deeper one refuses the file
(`media_strip::REFUSED` for the sender). A real AVI nests them once.

## Test

`media_strip::tests::a_deeply_nested_avi_is_refused` (16 levels strip, 17 are refused,
200,000 are refused on a 1 MiB stack), `a_forwarded_crafted_file_is_refused_or_cleaned_in_time`
(a received file sent on), harness
`fms_a_crafted_file_sent_on_is_refused_or_cleaned_in_time` (a received file kept at rest,
sent on through `SendFile`; the node sends the next file), and `strip_answers_as_0_14_did`.
