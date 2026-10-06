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
- App Lock on: every notification (desktop toast, phone banner live or push, iOS NSE) is
  ONE neutral "Hollow / New message" with no avatar and no reply action; replies are
  refused while locked, earlier toasts withdrawn when the lock rises; the iOS hints hold
  only the `~locked` marker. Protection state unknown counts as on. HOL-SEC-155.
- A `hollow://` link arriving while locked is buffered and replayed after unlock.
- A wipe deletes the push token LOCALLY (FCM `deleteToken`, APNs unregister, UnifiedPush
  unregister) and at the relay, fire-and-forget; with no identity the wake handlers and the
  NSE show and write nothing. HOL-SEC-156.
- iOS: the App Group data, push hints and caches are excluded from device backups at every
  start; keychain items use this-device-only classes. HOL-SEC-158.
- Push prefs to the relay carry only non-default entries (`pushPrefsForRelay`). HOL-SEC-160.
- An Android resource named only from Dart (`@drawable/ic_stat_hollow`) is STRIPPED from
  release APKs unless `res/raw/keep.xml` lists it; a missing notification icon fails EVERY
  local banner with `invalid_icon` (#96). Guard: `test/android_resource_keep_test.dart`;
  proof: `aapt2 dump resources <apk>`.
- iOS foreground presentation = `ForegroundBannerPresenter` (AppDelegate), set before launch
  finishes so firebase_messaging adopts it as its forward target: pushes stay silent, banners
  Hollow posts itself show by their flags. With no delegate, firebase shows nothing (#96).
