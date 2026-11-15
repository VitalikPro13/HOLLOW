# HOL-SEC-155: App Lock showed message content and a reply box in notifications, and a link could open above the lock

```
ID:          HOL-SEC-155                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact M: names and message text on a locked device, a message sent from it; Exploitability H: anyone who sees or holds the locked device)
Category:    Access control / Data exposure
Component:   lib/src/core/providers/system_notification_provider.dart, push_notification_service.dart, push_hints_cache.dart, deep_link_service.dart, ios/NotificationService
Boundary:    TB-4
Traces to:   phase E+F local C-LOCAL-02, C-LOCAL-03; relay_push C-RP-04; claim C-35
Attacker:    P-09 whoever holds the locked device
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

With App Lock on, desktop toasts, phone banners (live and push) and the iOS extension showed
the sender's name and text, and a Windows or macOS toast reply sent a message; a `hollow://`
link arriving while the phone was locked could put its confirm dialog above the lock.

## Fix

While locked, one neutral "Hollow / New message" notification with no avatar and no reply;
replies refused while locked; earlier toasts withdrawn when the lock rises; the iOS hints
hold only a locked marker; links are buffered while locked and replayed on unlock.

## Test

`notification_lock_test.dart`, `deep_link_lock_test.dart`. Mutation Dart 17/17, Rust 5/5
with HOL-SEC-158, -159.
