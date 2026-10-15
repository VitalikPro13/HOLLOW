# Stream Overlay: your voice room in OBS (#97)

## Overview

A streamer's own Hollow app serves a page on `127.0.0.1` that OBS loads as a browser source: everyone in the voice room (DM call, voice channel, meeting) drawn as an image per state (idle, talking, muted, deafened, plus optional blink and loud), reacting live. Purely local: no relay frame, no web host, no public link. Design: `reports/shipped/voice-and-media/STREAM_OVERLAY_PLAN.md` (sections 15 and 16 = the decisions and seams of 2026-10-15). Memory `project_stream_overlay`. Security rows: `security_write_gates.md` §38.

## Consent and sharing (Rust, `node/overlay.rs`, `node/overlay_look.rs`, `api/overlay.rs`)

- **The field** `stream_overlay`: `off` | `show` | `share:<stamp>`, on the profile AND the card, with its OWN master signature (not folded into `hollow-profile2`/`hollow-card1`); unsigned/forged = absent, newest `at` wins, absent = `show`. Toggles in Settings: "Let others show me" (default on) and "Share my overlay images" (default on, forced off when the first is off).
- **Ask/answer** `OverlayLookAsk { held }` / `OverlayLookAnswer { status, look_json, bundle_json }`: `Lane::Carried`, `live_only`. Answer gate `overlay_ask_allowed`: roster-counted device (never bare master, revoked, blocked); own sibling, accepted friend, or THIS device seated in the same VC seat set / connected DM call / meeting. Refusal = silence. Answers serve only OUR OWN look from `overlay_blobs`.
- **Asking side:** only for people we added and only while their field is `share`; per-device asked-set, `Want.unanswered`, paging (six 2 MB images exceed `MAX_BUNDLE_REPLY_BYTES`, so re-ask with the grown `held`). An answer counts only from an asked, roster-counted device of that identity, only while its field still says `share`, blocked senders dropped first. Received images: named in the look, hash-checked, 2 MB, canvas 512, frames x canvas x 4 within the 128 MiB authoring budget (`received_overlay_image_fits`).
- **Storage:** overlay images live in their OWN table `overlay_blobs` (never `emote_blobs`, never the generic rail; there is no `AssetKind::Overlay`). `sweep_images` keeps every image a kept look names plus 1 h of drafts. The people list `overlay_people` (slot, local picks, fetched look) is LOCAL to this device and profile.
- **Reactions:** `off` removes the person, their fetched look and our picks; `show` drops the fetched look; a block does the same as `off` (`forget_blocked`, FFI and sibling block). Field notices sit in a process-global queue keyed by the DB file (bounded 256; overflow sets a sticky `lost` flag that emits a catch-all `OverlayFieldChanged` with an empty master and re-projects).
- **Announce:** a flag or look change is coalesced (1 s) and built in `spawn_blocking` per audience (`profile_audience_known` + `audience_by_friend_status`), sent from the loop.

## The server and page (Rust, `node/overlay_server.rs`, `node/overlay_page/`, `api/overlay_server.rs`)

- 127.0.0.1 only; random port 20000-39999 + 32-byte token saved per profile in `<data root>/overlay_server.json` (never in a link snapshot); busy port = new port AND new token + `OverlayPortChanged`. Host check (DNS rebinding), Origin check, constant-time token; every refusal = bare 404 + close; 16 connections, 8 SSE streams, 5 s first-head and total head deadlines, 30 s idle, `: hb` every 15 s.
- **Starts LOCKED**: Dart calls `overlay_server_set_enabled(true)` THEN `overlay_server_set_locked(false)` after unlock; App Lock or the roster gate re-locks; the wipe stops it.
- `overlay_publish(snapshot)` / `overlay_publish_live(live)` (plan 16.4). `project()` drops `master`, any non-self person whose field is `off`, who is blocked, who resolves to US, or who has no master; draws a look image only if `drawable_images` allows it (our picks, or their shared look while `share`); names lose control/bidi chars, colours `#rrggbb` only. `reproject()` re-runs it on field/block changes.
- Page: plain HTML/CSS/JS, transparent; names via `textContent`. CSS hooks for OBS Custom CSS: `.overlay .person .stage .frame img.layer(.on) img.layer.avatar .initials .badge .name`, `[data-state] [data-self] [data-added] [data-loud] [data-blink] [data-slot] [data-kind] [data-badge]`, `--c`. The avatar circle belongs to the LAYER (`img.layer.avatar`), so a crossfade never squares it.

## Dart

- Data layer `lib/src/core/models/overlay_look.dart` (`OverlayLookState`, not `OverlayState`: Flutter clash), `providers/overlay_settings_provider.dart` (`overlayOwnProvider`, `overlayPeopleProvider`, `overlayFieldProvider`, `overlayLayoutProvider`, `overlayServerProvider`, `overlayListenSettingsProvider`, `overlayImageBytes` -> `overlay_image_bytes` FFI), events via `applyOverlayEvent` in `overlay_runtime_provider.dart`.
- Publisher `services/overlay_publisher.dart`: `ref.listen` outside widgets; snapshot on change (self slot 0, room people DEVICE->MASTER via `identityOf`, added people stable slots, others transient from 1000, every non-self carries `master`, own colour = accent); live feed only while `open_streams > 0`, max 20/s; across one person's devices the most active wins.
- Levels `providers/voice_level_provider.dart`: 0..1 = `clamp((dBFS+60)/60)`; local from the capture meter, remote from inbound-rtp `audioLevel`; polls 100 ms while a stream is open, else 200 ms.
- Listening `services/overlay_mic.dart` + `mic_level_capture.dart`: "Listen to my mic now" (desktop, never remembered, needs the server), the bounded `yieldToCall` hand-off, the "Mic on for overlay" chip. See `rules_media_calls.md` (record pool, yield, alone meter).
- UI `lib/src/ui/settings/stream_overlay/`: Settings > Stream overlay (phones: sections 1-3), the look editor with a preview engine mirroring `overlay.css/js`, instant saves (`OverlayLookAutosave`, 300 ms debounce, sliders on release), People on my overlay (first 5, Show all, filter above 8, per-row copy-link), the profile tick in `profile_identity_column.dart` More menu + the voice row menu (`UserMenuSurface.voice`).

## Tests

Harness blocks `// so-core`, `// so-core-fix`; `overlay_server_tests.rs` (incl. ignored `shots::page_fixture_screenshots` and `crossfade_keeps_the_avatar_circle`, headless Edge with `HOLLOW_OVERLAY_SHOTS=<dir>`); Dart `overlay_*_test.dart`, `stream_overlay_*_test.dart`, `alone_meter_*_test.dart`, `mic_plugin_recorders_test.dart`, `so_crash_guard_test.dart`. Fleet scenarios `so_ui_e2e_setup/states.json`, `so_ui_settings.json`, `so_polish.json`, `overlay_listen.json`.
