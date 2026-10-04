# HOL-SEC-162: The device-link screens never said the code is only for a device you hold

```
ID:          HOL-SEC-162                 Status: Fixed (2026-10-04, session 35)
Severity:    Low
Category:    Social engineering
Component:   lib/src/ui/dialogs/device_link_dialog.dart (_showCode, _confirmPush)
Boundary:    TB-3
Traces to:   phase E+F identity part 2 C-IDENTITY-08; lead L-10; claim C-05
Attacker:    P-03 by social engineering ("support" asking for the code)
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

The link code screen never warned against reading the code out, and the approval prompt
named only a device kind, so a device someone talked the code out of looked the same as the
person's own phone.

## Fix

The code screen says to type the code only on a device you hold and that nobody from Hollow
will ever ask for it; the approval asks to add the device only if it is in your hands right
now. SPAKE2 already burns a code after one wrong guess.

## Test

`the code and the approval both say the code is never shared` (widget).
