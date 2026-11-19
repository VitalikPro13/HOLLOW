# HOL-SEC-208: Linux desktop toasts handed a peer's words to the notification server as markup

```
ID:          HOL-SEC-208                 Status: Fixed in 0.14.1
                                          (track t18-linux-notif, 2026-11-19)
Severity:    Low                         (Impact L: a message or display name renders as
                                          formatting, and on servers that allow them as a
                                          link or a local image, inside a system notification
                                          that carries Hollow's name; Exploitability M: any
                                          friend or co-member whose message raises a toast)
Category:    Output encoding / Injection
Component:   lib/src/core/services/linux_notifier.dart (linuxNotifyArgs),
             lib/src/core/services/desktop_notification_service.dart (Linux branch)
Boundary:    TB-1 (content from other people)
Traces to:   C-09, C-27
Attacker:    a friend or a member of a shared server
Found:       2026-11-19 (hostile review of track t18-linux-notif)
Affected:    every Linux build since desktop toasts (local_notifier, libnotify) through
             0.14.0
Fix commit:  pending (track t18-linux-notif, 0.14.1, embargoed on security/0.14.1)
Disclosure:  private until 0.14.1 ships
```

## Description

The Linux toast body was a peer's message preview, passed to
`org.freedesktop.Notifications.Notify` as is. The notification spec lets a server read the
body as markup when it lists the `body-markup` capability; GNOME 46 renders `<b>`, `<i>`
and `<u>`, KDE Plasma also keeps `<a href>` links and local `<img>`. A peer's text could so
show as formatting, links or images inside a notification headed by Hollow, and ordinary
text with `<` or `&` came out garbled. The same path wrote a U+0000 from a message or a
display name into a D-Bus string argument, which made the bus close Hollow's connection:
that toast was lost, and GNOME took back every earlier toast tied to the connection.

## Fix

`LinuxNotifier` asks the server's capabilities once per connection (`GetCapabilities`).
When `body-markup` is listed, the body is escaped (`&`, `<`, `>`) by `linuxEscapeMarkup`, so
it shows exactly as typed; otherwise it is sent raw. The summary is plain text by spec and
is never escaped. Every string argument passes `linuxDbusText`, which drops U+0000. A
server error reply (closing an expired toast) or a slow answer no longer replaces the
connection; only a failed connection does. The service reports itself not ready when no
notification server answers.

Reproduction: `test/linux_notifier_test.dart` "a markup server gets peer markup as literal
text", "a plain-text server gets the body as typed", "no string reaches the bus with a
U+0000 in it"; on a real bus, the track's probe "markup is escaped for a body-markup
server, capabilities asked once", "closing an expired toast keeps the connection", "a NUL
in a peer message posts at once on the same connection".
