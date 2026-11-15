# HOL-SEC-156: A wipe left Hollow files, log lines and the push registration behind

```
ID:          HOL-SEC-156                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (High on iOS, where wiped phones kept showing friends' names in banners; Impact H for duress: the traces show the identity existed and was wiped; Exploitability H for whoever holds the device afterwards)
Category:    Data exposure
Component:   rust/hollow_core/src/api/wipe.rs, lib.rs, api/storage.rs, push_enrich.rs, node/fetch.rs, lib/src/core/services/destroy_flow.dart and push services, ios/
Boundary:    TB-4, TB-6
Traces to:   phase E+F local C-LOCAL-05, -07; relay_push C-RP-02, -09; identity C-IDENTITY-03; claims C-02, C-07
Attacker:    P-09 coercer or forensic examiner
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

The wipe was a name list under the data root, so it missed push previews, the debug log
beside the Windows executable, the iOS App Group hints and logs, temp-folder leftovers and
the wipe marker itself; it logged "Duress code entered"; the push token was never deleted,
so a wiped phone kept being woken and the token linked the destroyed identity to the next
one; pasted images and video posters were staged in plain OS temp.

## Fix

The wipe sweeps everything under the root and clears what Hollow writes beside it, zeroing
plaintext logs first, and writes no log lines; the log exists only while an identity does
and release builds keep stderr quiet; the push token is deleted locally (FCM, APNs,
UnifiedPush) and unregistered at the relay; the extension shows nothing without an identity;
temp staging moved under the data root.

## Residual risk

On iOS without the notification filtering entitlement, a push that still arrives shows a
neutral banner (phase G, K3); Google and Apple can link old and new tokens through their own
installation ids.

## Test

`a_wipe_leaves_nothing_hollow_wrote_under_the_root`,
`a_wipe_leaves_nothing_hollow_wrote_beside_the_root`,
`no_log_line_tells_of_a_wipe_or_a_duress_code`,
`the_log_exists_only_while_an_identity_does`,
`a_wipe_in_the_fetch_node_drops_the_push_token`, `the_boot_sweep_empties_temp_folders_too`,
Dart `wipe_traces_test.dart`. Mutation Rust 22/22, Dart 8/8 with HOL-SEC-157, -160.
