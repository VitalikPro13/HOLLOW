# Area rules: mobile UI, notifications, App Lock

Moved out of CLAUDE.md on 2026-09-29, when the file was split by area. CLAUDE.md sends
every session here BEFORE it touches `lib/src/ui/mobile/`, local notifications, push
taps, UnifiedPush or App Lock. The push PRIVACY rules (payload `{wake, sender}`, device
targeting, channel push fan-out, the NSE) stay in CLAUDE.md; wiki `push_notifications`
has the whole pipeline.

## Mobile UI and lifecycle

- Mobile UI lives in `lib/src/ui/mobile/`; `MobileShell` (4 tabs) below 600px; floating
  pills in the MobileShell + MobileChatRoute stacks, NEVER the `app.dart` builder;
  selection providers are cleared in `.then()`, NOT `dispose()`. `feedback_mobile_ui_patterns`.
- Mobile lifecycle: resume = WiFi lock + rejoin; pause releases.
- App Lock (mobile): the PIN via the Rust Argon2id flow; the biometric secret in
  flutter_secure_storage after `local_auth` (3.x named params); the lock-type marker is
  readable BEFORE identity unlock; MainActivity MUST extend `FlutterFragmentActivity`.
  `project_app_lock_pin_biometric`.

## Notifications

- Local notifications (distinct from FCM): ONE surface per message; a desktop toast when
  hidden/unfocused, the in-app card only when visible AND focused; mobile foreground =
  `MobileInChatBanner` only. macOS toasts = `MacOSFlutterLocalNotificationsPlugin`
  (NEVER `local_notifier`, dead on macOS 26), Linux = `local_notifier`.
  `project_local_notifications_desktop_mobile`.
- Push tap -> chat: all 3 entry points (onMessageOpenedApp / getInitialMessage /
  local-notif payload + launch); `plugin.show()` MUST set `payload: sender`; cold-start
  taps are buffered. `feedback_push_tap_navigation`.
- Android push provider = the USER's choice (#75): ONE relay token per device, so a
  UnifiedPush endpoint REPLACES the FCM one and FCM re-registration no-ops while it is
  active; the sidecar = Web Push to PUBLIC https only; a killed app = `main()`
  `--unifiedpush-bg`. `project_unifiedpush_android`.
