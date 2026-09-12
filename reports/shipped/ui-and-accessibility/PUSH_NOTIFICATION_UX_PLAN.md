# Push Notification UX Improvement Plan

_Authored 2026-06-09. Goal: make the on-device push notification feel fast, correct-on-first-appearance, and properly grouped per peer with live N-count + content — on Android and iOS. Data sync is already correct; this is purely the notification rendering/timing layer._

## Diagnosis (why it feels janky today)

The system is architecturally sound (relay buffer + Tier 1 cached profile + Tier 2 fetch-and-decrypt). The bad *feel* comes from concrete timing/UX issues, not data loss:

1. **Two visible states with a gap.** Tier 1 posts "Sent you a message" immediately, then ~4-5s later Tier 2 swaps in real content. The generic intermediate banner + visible swap is the main jank.
2. **`run_fetch` has a 4s blind idle (`IDLE_AFTER_FIRST`).** Even the normal case stalls ~4s before content appears. (`fetch.rs:72`)
3. **One-shot fetch.** `start_fetch_node` drains the buffer once and returns; no live update as later messages arrive within the same wake. (`network.rs:1697`)
4. **No Android notification group.** Each peer is a separate loose notification (correct per the desired model) but they don't bundle under a "Hollow" summary header.
5. **Debounce blindness.** Within the 10s `PUSH_DEBOUNCE_SECS` window a 2nd message's wake is suppressed; its content only appears if msg-1's fetch was still draining. (`ws_handler.cpp:434`)
6. **iOS: two notification systems.** APNs alert (priority 10, `apns-push-type:alert`) shows a banner *immediately on delivery*. The NSE (`mutable-content:1`) rewrites it to name+avatar within ~30s. Separately, the `content-available:1` Dart bg handler posts its *own* local notification with content. Two notifications, racy, tight iOS bg budget.

## Desired UX (from Vitalik)

- **Per-peer notifications:** up to ~3 distinct peers each get their OWN notification (not one merged blob). 3 peers → 3 notifications.
- **Per-peer live N-count + content:** each peer's notification updates in place showing count ("Alice — 3 new messages") + last ~3 messages' content. Matches Android InboxStyle, extend to iOS.
- **Show content fast, correct on first appearance.** Prefer waiting ~1-4s for decrypted content and showing ONE populated banner over showing a generic banner then swapping. (Vitalik: "don't show the notification until the content is properly derived… then put it into the banner.")
- **Graceful fallback** to name+avatar (or generic) only when the fetch fails / times out / identity locked.

---

## Phase 1 — Fast, correct-on-first-appearance happy path (Android-clean; iOS best-effort)

**Core idea:** in the rust-ready path, DON'T post the generic Tier 1 banner first. Run the fetch, and post a single, already-populated notification once content is decrypted. Keep draining briefly and update in place if more arrive. Fall back to Tier 1 only on failure.

### 1a. Make the fetch fast (Rust — `fetch.rs`)
- **Reduce `IDLE_AFTER_FIRST` 4s → ~1.2s** for text. Keep the longer hold ONLY for the `outstanding_image` case (companion FileHeader still expected). This alone removes the biggest stall.
- Keep the overall `timeout` as the bound for the empty/first-message wait.
- (Optional, deferred) streaming emit: convert `run_fetch` to emit each `FetchedDm` via a callback/StreamSink so Dart can render incrementally. **Decision: skip for Phase 1** — "wait then show one populated banner" makes streaming low-value; the short idle window already gives near-immediate first content. Revisit only if multi-message bursts within one wake feel slow.

### 1b. Reorder the Dart bg handler (`push_notification_service.dart`)
Current order: init → Tier 1 banner (generic) → Tier 2 fetch → swap.
New order (rust-ready path):
1. init Rust + data dir (unchanged).
2. Resolve `getPushProfile` (name+avatar) but DO NOT post yet.
3. Run `startFetchNode` (now fast).
4. **If messages returned:** post ONE notification already populated (name+avatar + InboxStyle content + N-count + image preview). This is the first thing the user sees. `silent:false` (this is the first/alerting post).
5. **If fetch returns empty OR errors OR rust not ready:** NOW post the fallback (name+avatar + "Sent you a message", or generic). This is the only path that shows a content-free banner.

Net effect on Android: user sees one correct banner ~1-1.5s after the push, no swap, no generic intermediate. On the failure path, behavior is today's Tier 1.

**iOS caveat (must verify against NSE during impl):** the APNs alert banner appears on delivery regardless of the Dart handler. So on iOS the NSE still shows name+avatar instantly, and the Dart handler updates content into the *same* notification id a moment later — the swap Vitalik wanted to avoid is **unavoidable on iOS** for the alert banner. Phase 1's "wait then show" cleanliness fully applies to **Android**; iOS keeps NSE-instant + Dart-content-update. Confirm the Dart local notification reuses/updates the NSE notification rather than double-posting (see Phase 3).

### 1c. Files touched (Phase 1)
- `rust/hollow_core/src/node/fetch.rs` — idle window tuning.
- `lib/src/core/services/push_notification_service.dart` — reorder handler; only post-after-content on happy path; fallback-only generic.
- No FFI signature change → no codegen needed (unless streaming emit is added later).

### 1d. Test (Vitalik, physical devices)
- Android: single DM while app killed → expect ONE populated banner, ~1-1.5s, no generic flash.
- Android: 2 quick DMs → expect ONE notification, "Name — 2 new messages" + both lines.
- iOS: single DM → NSE name+avatar instant, content fills in shortly (acceptable swap).
- Failure path: lock identity (password mode) → expect name/generic fallback, no crash.

---

## Phase 2 — Per-peer grouping polish (Android)

- Add Android `groupKey` (e.g. `"hollow_dms"`) to every per-peer notification (keep per-peer id = `sender.hashCode`, keep InboxStyle).
- Post a **group summary** notification (`setGroupSummary`) with `InboxStyleInformation` summarizing "Hollow · N messages from M people". Android then bundles the ≤3 peer notifications under one expandable header.
- Verify `flutter_local_notifications` group APIs (`groupKey`, `setAsGroupSummary`) and that dismissing the group clears children.
- Files: `push_notification_service.dart` only.

---

## Phase 3 — iOS content + resolve the two-system conflict

**Chosen approach (Vitalik): Dart bg handler fills content; NSE stays name+avatar.** No full Tier B (no Olm-from-NSE, no App-Group data-dir migration, no Rust C-ABI).

Work:
1. **Verify on real iOS** whether the `content-available:1` Dart bg handler reliably runs and finishes the fetch within iOS's background budget for an alert push. (This is the open risk.)
2. **Ensure single notification:** the Dart-posted local notification must UPDATE the NSE/APNs notification, not create a second one. Match identifiers — iOS notifications collapse by `threadIdentifier` + matching request identifier. The Dart local notification id (`sender.hashCode`) and the APNs `apns-collapse-id` / thread must align so iOS replaces rather than stacks. Set `threadIdentifier = sender` on both the NSE-built content and the Dart `DarwinNotificationDetails`.
3. **Per-peer threading on iOS:** use `threadIdentifier = sender` so iOS groups by peer natively (mirrors Android groupKey-per-peer intent).
4. If (1) proves unreliable, fall back to: NSE name+avatar is the final iOS banner (Tier A only on iOS), accept no content. **Full Tier B remains a documented future option but is NOT in this plan** due to Olm cross-process ratchet desync risk.

Files: `push_notification_service.dart` (iOS thread id), `ios/NotificationService/NotificationService.swift` (thread id), possibly `push-sidecar/index.js` (add `apns-collapse-id`/`thread-id`).

---

## Explicitly out of scope
- Full Tier B (NSE-side Rust decryption). Documented as future option only.
- Removing/raising the relay 10s debounce (it protects FCM rate + battery; the buffer already prevents loss). The streaming/short-idle fetch makes the debounced 2nd-message case far less visible.
- Relay/sidecar changes beyond optional iOS collapse-id in Phase 3.

## Risks
- **iOS bg-handler timing (Phase 3 #1)** — the one real unknown. Mitigated by Phase 1's faster fetch. Fallback is Tier-A-only iOS.
- **Double notifications on iOS** — must get thread/collapse ids matching; verify on device.
- **No new Olm cross-process surface** — by choosing Dart-handler over Tier B, we avoid the ratchet desync class of bug entirely.
