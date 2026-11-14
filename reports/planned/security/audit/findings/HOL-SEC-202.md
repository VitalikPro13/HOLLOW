# HOL-SEC-202: A file name cut to length could come out as a Windows device name

```
ID:          HOL-SEC-202                 Status: Fixed on local branch security/0.14
                                          (82df7694, 2026-11-07), retest at release
Severity:    Low                         (Impact L: a Share download saved on Windows
                                          under a device name such as CON opens the device
                                          instead of a file, so that download fails or its
                                          bytes go nowhere; nothing leaves the downloads
                                          folder; Exploitability M: any Share publisher
                                          picks the file name, no interaction beyond the
                                          download)
Category:    Input validation (a sanitizer judged the name before its last change)
Component:   rust/hollow_core/src/node/share_handler.rs (safe_file_name,
             reserved_device_name, is_inert_file_name)
Boundary:    TB-2 (peer and peer)
Traces to:   C-FILES (remote file names via safe_file_name before any path join);
             the 2026-07 Share file name fix (35999512)
Attacker:    a Share publisher, or anyone whose file name reaches safe_file_name
Found:       2026-11-07, writing the file_names fuzz target's property (t14-fuzz); the
             target's assertion fails on the old code with the input kept in
             fuzz/regressions/file_names/
Affected:    every release since 0.10.0-beta (2026-07-23) through main 8350841b (0.13.0)
Fix commit:  82df7694 (security/0.14, 2026-11-07)
Embargo:     EMBARGOED until the 0.14 release (local branch security/0.14, never pushed);
             advisory with the 0.14 GHSAs
```

## Description

`safe_file_name` prefixed a reserved device name with `_` before it cut the name to 200
bytes and trimmed the trailing spaces and dots the cut exposed. A name of `CON`, about 200
spaces and one more character passed the device check (its stem was not `CON`), was cut to
`CON` and spaces, and was trimmed to `CON`: the one shape the function promises never to
return. The device list also missed names Windows reserves (`COM0`, `LPT0`, `COM¹` to
`COM³`, `LPT¹` to `LPT³`) and a stem with spaces before its extension (`CON .txt`).

## Fix

The name is cut and trimmed first (`cut_name`), and the device check judges the name as it
is kept; a reserved one gets its `_` and is cut again, which can never make it reserved. The
check strips spaces at the end of the stem and lists every name Windows reserves.
`is_inert_file_name` uses the same check, so snapshot and archive names follow. The same
fuzz run showed the sanitizer was not stable (a trim of trailing dots could expose Unicode
whitespace that a second pass removed); both trims now take dots and every whitespace, so
a kept name passes again unchanged (not a security change).

## Tests

- `node::share_handler::tests::a_device_name_is_judged_on_the_name_kept` (RED on the old
  code: `left: "CON"`, right `"_CON"`).
- `fuzz_entry::tests::fuzz_regressions_stay_fixed` replays
  `fuzz/regressions/file_names/hol_sec_202_device_name_after_cut` (the old fuzz binary
  panics with `safe_file_name kept an unsafe name: "CON"`).
- `node::share_handler::tests::a_kept_name_ends_and_starts_with_no_whitespace` and the kept
  input `fuzz/regressions/file_names/unicode_space_after_dot` (stability).
- Mutation pass: 9/10 killed; the survivor (step 2 back to the old trim) is equivalent,
  since the cut's trim removes the same characters before anything is returned.
- The `file_names` fuzz target asserts every result is inert, stays in its folder and is
  stable under a second pass.

## Residual risk

None known. Whether a device name inside a folder opens the device depends on the
Windows version; the rule holds on all of them and costs one character on a name nobody
chooses by accident.
