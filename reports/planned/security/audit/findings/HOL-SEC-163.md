# HOL-SEC-163: Saving a received file on iOS let its sender's name replace any file in the app's sandbox

```
ID:          HOL-SEC-163                 Status: Fixed (2026-10-06, local, ships with the next release)
Severity:    Medium (Impact M-H: the sender's bytes replace a file or whole folder inside the app sandbox, including Documents/hollow, which is the whole data root on an install without the App Group; Exploitability M: a friend or co-member sends the file, the victim taps Save on iOS)
Category:    Data validation / Path traversal
Component:   lib/src/ui/mobile/mobile_chat_route.dart (_saveFile), mobile/mobile_archive_message_actions.dart, every desktop Save dialog seeded with a received name
Boundary:    TB-2
Traces to:   claim C-29; same family as HOL-SEC-129; found while triaging an Aikido path-traversal report on 2026-10-06
Attacker:    P-04 malicious friend or P-05 co-member who can send a file (a plain client is enough, since `hollow` is an ordinary file name)
Found:       2026-10-06 (scanner triage session)
```

## Description

The phone Save action handed the sender's file name straight to file_picker. On iOS the
plugin builds `Documents/<name>`, removes whatever already exists there (recursively), writes
the bytes, and only then opens the export sheet. A name that matches one of our own entries,
`hollow` above all, deleted that folder and left the sender's file in its place; a name with
`..` reached the rest of the sandbox. The desktop dialogs and the message-proof export took
remote names unscrubbed too, though there a person confirms the path.

## Fix

Every Save dialog seeded with a name someone else chose goes through `attachment_export.dart`:
`pickSavePathFor` (desktop) and `saveBytesFromPhone` (phones) scrub the name with the node's own
`safe_file_name` (new sync FFI `safe_save_name`), and on iOS the copy is staged in a fresh
`Documents/.save_<time>/` folder that is removed when the sheet closes, so the plugin can never
delete or overwrite anything of ours and no plaintext copy stays behind. A killed app cannot run that cleanup, so every launch and every new stage first removes leftover `Documents/.save_*` folders (`sweepStaleSaveStages`). A source guard keeps
direct `FilePicker.platform.saveFile` calls to files that suggest names they build themselves.

## Test

`only own-named saves call the picker directly` and `every listed file still calls the picker`
(`test/save_name_guard_test.dart`); the Rust `safe_name_*` unit tests cover the scrub. Device
check before release: save a received file named `hollow` on the iOS simulator.
