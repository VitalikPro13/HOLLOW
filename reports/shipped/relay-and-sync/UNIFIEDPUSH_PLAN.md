# UnifiedPush Support (issue #75)

Status: BUILT 2026-09-17 and verified on Vitalik's phone, both ways (ntfy carrying the wake-ups, then Google again). The sidecar is deployed on the production relay; the relay itself needed no change. F-Droid build (#56) and the app-held socket mode are follow-ups, see the end.

## Goal

An Android user can have their phone woken through a push provider they choose (ntfy or any UnifiedPush distributor) instead of Google's Firebase. A self-hosted relay can deliver pushes with no Google or Apple credentials at all.

Firebase stays the default on Android. iOS keeps APNs, which is the only way to wake a killed iOS app.

## How UnifiedPush works

```
relay ──> push-sidecar ──HTTP POST (Web Push, encrypted)──> push server ──> distributor app ──> Hollow
          (ours)                                             (ntfy.sh or     (ntfy, on the
                                                              self-hosted)    phone)
```

- The distributor app keeps ONE connection to its push server for every app that uses it. Play Services does the same job for FCM.
- Hollow asks the distributor to register. The distributor answers with an endpoint URL plus a Web Push key set (`p256dh`, `auth`) that the connector library generated on the phone.
- The sidecar encrypts the payload to that key set (RFC 8291, `aes128gcm`) and POSTs it to the endpoint. The push server and the distributor see only ciphertext; the connector library decrypts on the phone.
- When the app process is dead, the plugin starts a Flutter engine running `main()` with the `--unifiedpush-bg` argument and delivers the message there. When the process is alive, the message goes to the main isolate.

## What stays the same

- The payload is the same wake the FCM data block carries: `{type:'wake', sender}` or `{type:'channel_wake', sender, server, channel, mention}`. No content, ever.
- The on-device handling is the same: nudge the live node, else start the fetch node, decrypt, post the banner. The FCM handler and the UnifiedPush handler call one shared function.
- The relay is unchanged. `register_push_token` already stores an opaque `{token, platform}` per peer, re-sent on every reconnect by `swarm.rs`, persisted by the restart snapshot, and forwarded as-is to the sidecar. UnifiedPush rides it as `platform: "unifiedpush"` with `token` = a JSON string `{"v":1,"endpoint":...,"p256dh":...,"auth":...}`. The relay keeps one token per peer, so registering one kind replaces the other.

## Decisions

1. **Where the Web Push send lives: the sidecar, not the relay.** The sidecar is already the HTTP-out process and Node has the `web-push` library (maintained, `aes128gcm`, per-request `agent` and `timeout`). Doing TLS client requests and ECE in the uWebSockets C++ relay would be a new HTTP client on the event-loop host for no gain. The relay stays a dumb forwarder and needs no deploy.
2. **Firebase becomes optional in the sidecar.** No service account file = FCM and APNs pushes answer 503, UnifiedPush still works. `firebase-admin` moves to `optionalDependencies` and is required lazily, so a self-hoster's image never installs it.
3. **Encryption is mandatory.** A registration without a key set is refused on the phone (never sent to the relay) and again by the sidecar. Without it the push server would read the sender's peer id.
4. **No VAPID for now.** ntfy and the common distributors do not require it; the connector reports `VAPID_REQUIRED` when one does, and the UI names that distributor as unsupported. The sidecar signs with VAPID if `VAPID_PUBLIC_KEY`/`VAPID_PRIVATE_KEY`/`VAPID_SUBJECT` are set, so adding the client side later is only the `vapid:` argument plus a way for the app to learn the relay's public key.
5. **Server-side request forgery guard.** The relay forwards URLs a client chose, so the sidecar only POSTs to `https://` endpoints whose host resolves to a PUBLIC address. The check runs inside the socket's DNS lookup (a custom `https.Agent` `lookup`), so a DNS answer that changes between check and connect cannot slip through. No redirects are followed (`web-push` does not follow them). Endpoint length is capped. A LAN self-hoster can opt out with `UNIFIEDPUSH_ALLOW_PRIVATE=1`.
6. **The source of truth for "which provider" is the connector's saved distributor.** `UnifiedPush.getDistributor() != null` means UnifiedPush is active. No second setting that could disagree. Uninstalling the distributor fires `onUnregistered` and the app falls back to the FCM token.
7. **Expired endpoints.** A 404 or 410 from the push server answers the relay 410, the same as an expired FCM token (the relay ignores the reply today; it is there for later pruning).
8. **Self-hosting.** `docker-compose.yml` gains a `push` service built from `push-sidecar/`, sharing the relay container's network namespace (`network_mode: service:relay`) so the relay's hardcoded `127.0.0.1:3001` reaches it with no relay change. It runs without Firebase.

## Pieces

### Sidecar (`push-sidecar/index.js`)
- `platform === 'unifiedpush'`: parse the token JSON, validate (v, https endpoint, length caps, key set present), send with `web-push` (`TTL` 24 h to match the relay buffer, `urgency: high`, `timeout` 5 s, the guarded agent). Log only the endpoint HOST and the status, never the path (the path is the device's secret address).
- Lazy Firebase, 503 when absent.
- `Dockerfile` (node LTS alpine, `npm install --omit=optional`).

### App
- `pubspec.yaml`: `unifiedpush` (Android implementation only; iOS, desktop and web never call it).
- `main.dart`: `--unifiedpush-bg` short-circuits to the background receiver before any window, lock or UI work.
- `push_notification_service.dart`: `_handleWakeData(Map)` shared by FCM and UnifiedPush; UnifiedPush init in the main isolate; register the endpoint with the relay; FCM token registration skipped while UnifiedPush is active; public calls for Settings: list distributors, use one, go back to Firebase, current status.
- Settings, Notifications, a "Push delivery" card on Android: chips for Google (Firebase) and each installed distributor, a status line, and a hint to install ntfy when none is present.

### Docs
- `SELF_HOSTING.md`: push is no longer on the "does not have" list for Android; how to point the app at a UnifiedPush distributor.
- Wiki `push_notifications`.

## What was verified

- **Sidecar:** the address guard (private and loopback hosts refused, IP literals too, since a socket skips DNS for those), and a local HTTPS server that decrypted what the sidecar sent, proving the RFC 8291 payload. ntfy.sh answers 507 to a Web Push POST for a topic with no active subscriber, so it cannot be smoke-tested without a real phone.
- **Production:** Firebase still reaches Google after the deploy, and the UnifiedPush path refuses a private address.
- **Docker:** the image builds, runs as a non-root user with no Firebase inside, and is reachable from the relay's namespace on `127.0.0.1`; `docker compose config` parses.
- **Phone (2026-09-17):** DM and channel wake-ups arrive through ntfy with the app swiped away, and again through Google after switching back. The relay's log shows exactly one path in use at a time, which is the whole isolation guarantee: the relay holds ONE token per device, so registering ntfy replaces the Firebase token and the app stops registering it.
- **Build:** the UnifiedPush connector and `flutter_secure_storage` each bring Google's Tink library (`tink` against `tink-android`, same classes). `android/app/build.gradle.kts` keeps only `tink-android` 1.23.0, which is the superset.
- **Tests:** 1004 Dart tests pass.

## Follow-ups (not in this build)

- **F-Droid build (#56).** F-Droid's scanner rejects the Firebase classes even when unused, so it needs a build without `firebase_core`/`firebase_messaging`: a build-script `pubspec` swap plus a Dart stub for the two imports. UnifiedPush is the only push there.
- **App-held socket mode.** For a phone with neither Play Services nor a distributor: Hollow keeps its own foreground service and WebSocket. It costs a permanent notification and battery, and Play asks for a foreground-service justification, so it belongs to the F-Droid build first.
- **VAPID on the client** (decision 4) and relay-side pruning of 410 tokens.
