# HOL-SEC-129: A device-link code, a backup file or an archive from someone else could write files anywhere the user can

```
ID:          HOL-SEC-129                 Status: Fixed (2026-10-04, session 34)
Severity:    High (Impact H: arbitrary file write as the user, so code execution on desktop through the Startup folder, autostart or the install folder; Exploitability M: the victim types the attacker's link code on a fresh install, restores the attacker's .hollow file with its passphrase, or opens an archive the attacker sent)
Category:    Data validation / Path traversal
Component:   rust/hollow_core/src/api/storage.rs (import_snapshot_bytes), archive/loader.rs (extract_files_to_temp), api/updater.rs (extract_zip_to)
Boundary:    TB-2, TB-4
Traces to:   phase E+F identity C-IDENTITY-01, local C-LOCAL-01, C-LOCAL-06; claim C-29; AT-5
Attacker:    P-03 stranger running a modified client as the link presenter, or anyone who can hand a new user a file
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

Snapshot import (device link and backup restore) wrote each zip entry to
`data_dir.join(entry.name())` with the raw name: an absolute name makes `Path::join` drop
the base and `..` climbs out of it; any in-root name also landed (key files, markers,
profiles.json), and entries were read with no size limit. The imported-archive viewer did
the same for attachment names and pointed the viewer at a path built from the archive's own
metadata. The updater refused `..` but not absolute or drive names (its archive is signed,
so lower risk). SPAKE2 proves only that the presenter showed the code.

## Fix

Snapshot entries are read only through `enclosed_name()` and must be what the exporter
writes (`identity.key`, `messages.db`, `vault/<name>`, `files/<name>` with inert names); any
other entry, link or directory refuses the whole snapshot in a check pass before anything is
written, and the unpacked total is capped at max(64 MiB, 32 x the snapshot's size). The
archive viewer lands attachments only as inert names under its own folder, marks a file
included only if it landed, and caps memory. The updater refuses any entry `enclosed_name()`
refuses or whose parts are not plain names.

## Test

`a_snapshot_lands_only_what_a_snapshot_holds`,
`a_snapshot_that_unpacks_past_its_size_is_refused`,
`an_archive_lands_attachments_only_in_its_own_folder`,
`an_archive_that_unpacks_past_its_size_is_refused`, `rejects_absolute_entries` (all failed
on the old code). Mutation 34/37 (the three survivors are layered checks each holding alone;
removing both updater checks is killed).
