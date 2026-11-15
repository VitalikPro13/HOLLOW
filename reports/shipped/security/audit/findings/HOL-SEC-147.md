# HOL-SEC-147: News posts fetched remote images, and a manifest version reached file names and update scripts

```
ID:          HOL-SEC-147                 Status: Fixed (2026-10-04, session 34)
Severity:    Low
Category:    Data exposure / Data validation
Component:   lib/src/ui/dialogs/news_post_dialog.dart, rust/hollow_core/src/api/updater.rs
Boundary:    TB-5
Traces to:   phase E+F distribution C-DIST-02, C-DIST-06
Attacker:    P-10 update host (with the offline signing key for the version half)
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

The news body rendered with the default image builder, which fetches network images on
render. The signed manifest's version named the download and staging folder and went into
the generated update scripts on all three desktops without a shape check.

## Fix

News renders alt text only; a version must be exactly three numeric parts on the signed
manifest and again before staging; Windows script paths double `%` and refuse quotes and
control characters.

## Test

"opening a post fetches no image and shows its alt text",
`a_malformed_version_stages_nothing`, `a_manifest_with_a_malformed_version_is_refused`,
`release_versions_are_three_decimal_parts`,
`bat_paths_keep_percent_literal_and_refuse_quotes`.
