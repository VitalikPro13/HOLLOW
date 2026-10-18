# Area rules: mobile UI, notifications, App Lock

Moved out of CLAUDE.md on 2026-09-29, when the file was split by area. CLAUDE.md sends
every session here BEFORE it touches `lib/src/ui/mobile/`, local notifications, push
taps, UnifiedPush or App Lock. The push PRIVACY rules (the wake block sealed to the
device, device targeting, channel push fan-out, the NSE) stay in CLAUDE.md; wiki
`push_notifications` has the whole pipeline.

## Mobile UI and lifecycle

- Mobile UI lives in `lib/src/ui/mobile/`; `MobileShell` (4 tabs) below 600px; floating
  pills in the MobileShell + MobileChatRoute stacks, NEVER the `app.dart` builder;
  selection providers are cleared in `.then()`, NOT `dispose()`. `feedback_mobile_ui_patterns`.
- The ONE thing meant to sit over every phone route is the connection indicator
  (`mobile_connection_indicator.dart`): a ROOT-overlay entry that `MobileShell` owns (so the
  narrow desktop layout gets it too), registered with `OverlayHosts` so the lock removes it
  before the cover rises and it returns after. Speaks after 1.5 s down ON SCREEN (the count
  restarts on every return from the background), leaves at once, never takes a tap; silent
  before an identity, while a call rings in, and over a `ConnectionIndicatorCover` (DM call
  screen, fullscreen share: their own link state, the call rides peer to peer). A new
  full-screen call surface wraps itself in the cover; any other route needs nothing.
- Mobile lifecycle (`RelayTriggers`, plan 3.8): away (hidden, paused, detached; `inactive` is
  still on screen) = `relay_set_background(true)` at once, `relay_suspend()` 10 s later unless
  `relayRealtimeProvider` (a call, voice channel, meeting, or a call ringing in) holds the
  socket; iOS holds a background task until the suspend returned. `relay_set_background(true)`
  HIDES the phone from everyone's presence (plan decision 6: online only while on screen), so
  while such a session is live it is NOT sent; it goes out once that session ends while still
  away, once per trip (others drop a hidden device from their voice channel on
  `PeerDisconnected`). Back = ONE `relay_set_background(false)`, never also a `foreground` nudge,
  call or not. A session that goes live while the phone is already hidden only nudges `call`
  and stays hidden until the return. A relay back while away (a
  push wake) closes again 10 s later; a session going live while away nudges `call`. No
  battery-exemption prompt, no `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, no Wi-Fi lock (guard:
  `test/relay_triggers_native_test.dart`).
- A push wake on Android with the node alive goes through `rejoinThroughLiveNode`: a `push`
  nudge brings the suspended session back BEFORE the live node rejoins, or the rejoin waits in
  the queue until the app returns.
- A phone presenting a device link (`linkPresentingProvider`: showing or renewing a code,
  asking to confirm, sending) holds the relay like a call (`relayRealtimeProvider`; hidden, it
  never hears the joiner arrive) and on Android runs `LinkKeepAliveService`, a `shortService`
  foreground service (not exported, both `onTimeout` overloads stop it), so Android keeps its
  network while the code is typed on the other device. Each phase must end on its own: the
  code's 300 s countdown, `dialogGone()` for a code waiting for the relay, `kLinkSendingTimeout`
  (10 min) for a send never confirmed. Guards: `test/link_keep_alive_test.dart`,
  `test/device_link_wait_test.dart`, `test/widget/device_link_dialog_close_test.dart`.
- App Lock (mobile): the PIN via the Rust Argon2id flow; the biometric secret in
  flutter_secure_storage after `local_auth` (3.x named params); the lock-type marker is
  readable BEFORE identity unlock; MainActivity MUST extend `FlutterFragmentActivity`.
  `project_app_lock_pin_biometric`.
- App Lock entries are PER PROFILE (`<key>.<app_lock.id>`, never a path hash: an iOS
  container moves); a stored secret (launch, biometric) unlocks via
  `unlock_identity_with_stored_secret`, never `unlock_identity` (that one is paced and a
  relaunch would reset the count). The wrap is tied to the phone's hardware key
  (`HollowHwKey.kt` registered in `MainActivity`, the enclave in `AppDelegate.swift`);
  the key must never need user auth or biometry. `hardware_key_missing` (the keystore
  says the key is gone) leads to the recovery phrase; `hardware_key_busy` (an op failed
  or the keystore could not say) to `HardwareKeyBusyDialog`, Try again first, and a
  stored secret (launch, biometric) is dropped ONLY on `isWrongSecret`. Wiki
  `security_write_gates` §43.

## Notifications

- Local notifications (distinct from FCM): ONE surface per message; a desktop toast when
  hidden/unfocused, the in-app card only when visible AND focused; mobile foreground =
  `MobileInChatBanner` only. macOS toasts = `MacOSFlutterLocalNotificationsPlugin`
  (NEVER `local_notifier`, dead on macOS 26), Linux = `local_notifier`.
  `project_local_notifications_desktop_mobile`.
- Every FCM/APNs wake goes through `openFirebaseWake` (Rust `open_push_wake`) before
  anything reads it, the tap router included; the NSE through `hollow_push_open_wake`.
  Never read `message.data[...]` directly: a phone with a key set drops what is not
  sealed to it, stale (`ts` past 24 h) or already opened by that reader (AR-26). The
  tap router passes `tap: true` (routes only, never spends the blob). Guard:
  `test/push_wake_seal_test.dart`.
- iOS banners of a sealed wake group and replace ON THE PHONE (no
  `apns-collapse-id`): NSE thread = person (hints `master`) or `server:channel`,
  matching Dart's `iosDmThreads`/`iosChannelThread`; a new thread key must change
  both sides and the AppDelegate `removeDeliveredInThreads` call.
- Push tap -> chat: all 3 entry points (onMessageOpenedApp / getInitialMessage /
  local-notif payload + launch); `plugin.show()` MUST set `payload: sender`; cold-start
  taps are buffered. `feedback_push_tap_navigation`.
- Android push provider = the USER's choice (#75): ONE relay token per device, so a
  UnifiedPush endpoint REPLACES the FCM one and FCM re-registration no-ops while it is
  active; the sidecar = Web Push to PUBLIC https only; a killed app = `main()`
  `--unifiedpush-bg`. `project_unifiedpush_android`.
- The pick STICKS (AR-33, 0.12.1): `push_unifiedpush_distributor` is changed only by `use()` /
  `useFirebase()`, never by a failure; "Fall back to Google" (`push_firebase_fallback`, default
  on) lets Google cover only WHILE the pick is broken, off = no Google token at the relay. The
  controller heals itself (start, resume `_recheck`, `RelayTriggers.networkChanges`, backoff)
  and shows a Home Needs Attention item after 20 s; `UnregisterPushToken` also clears the
  node's held token, else a fresh session re-sends it.
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
