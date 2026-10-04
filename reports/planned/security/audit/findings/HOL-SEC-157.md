# HOL-SEC-157: A duress code typed at a Settings prompt wiped but left the session running, and Settings could show a dead duress code

```
ID:          HOL-SEC-157                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact H for duress: the coercer still sees the chats on screen; Exploitability: a coerced user typing the duress code at a Settings prompt)
Category:    Access control
Component:   rust/hollow_core/src/api/identity.rs (open_typed_secret, forget_duress_code), lib/src/core/services/destroy_flow.dart (withTypedSecret)
Boundary:    TB-4
Traces to:   phase E+F identity C-IDENTITY-13, C-IDENTITY-07; claim C-07
Attacker:    P-09 coercer
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

Only the launch unlock checked the duress slot fully: at "confirm your password" a duress
code wiped the data but the app kept running on what it held in memory and logged "duress",
and other prompts never checked the slot. Turning the password off and on replaced the
duress slot but kept `duress_scope`, so Settings showed a code that no longer worked.

## Fix

One gate, `open_typed_secret` (both slots, equal cost), for every typed prompt, each wrapped
in `withTypedSecret`, which ends the session exactly as a duress unlock does; the duress
state is cleared wherever the slot goes, and shown only when a password prompt exists.

## Test

`a_duress_code_at_any_settings_prompt_wipes_like_the_launch_prompt`,
`turning_the_password_off_and_on_never_reports_a_dead_duress_code`, `wipe_traces_test`
source guard.
