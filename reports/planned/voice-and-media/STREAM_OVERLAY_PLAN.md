# Stream Overlay: your voice room in OBS, purely local

**Status:** PLANNED. Design agreed 2026-10-10 (Vitalik + Claude session). Nothing built.
**Owner:** Vitalik (architect).
**Issue:** #97, "[Feature suggestion] stream reactive overlay".
**Read before building:** wiki `rules_media_calls.md` (speaking state, calls), `rules_ui_flutter.md` plus the `hollow-ui` skill (the Settings tab, the profile tick), `rules_files_assets.md` (image processing, the asset rail), `rules_platforms.md` (desktop-only server), and `security_write_gates.md` (every new ingest path gets a row).
**Companion memory:** `project_issue37_speaking_indicators`, `feedback_getstats_no_local_audio_level`, `project_asset_rail_epic`, `project_profile_media_asset_rail`, `project_profiles_phase_d`, `project_support_credentials_phase2` (the separately signed profile field this copies).
**Plan checklist:** add a HOLLOW_PLAN.md entry when work starts.

---

## 0. TL;DR

Streamers want what Discord users get from "reactive images" (fugi's tool on top of Discord StreamKit): every person in the voice call drawn as an image that swaps when they talk, loaded into OBS as a browser source. Discord's version works because the OBS page talks to the Discord app on the streamer's own PC. It went paid, and Discord never built it in.

Hollow does it purely locally:

- The streamer's app already knows who is in the voice room, who is talking, and who is muted or deafened. It serves a small page on `127.0.0.1`, and OBS loads that page as a browser source. Nothing touches the relay, nothing is public, there are no shareable links.
- Everyone can set their own **look** in Settings: an image or animation for each state (idle, talking, muted, deafened) plus effects.
- A streamer adds a person to their overlay with a tick on that person's profile. Only then does that person's look travel, only if that person allows it, and only to friends or to people currently in a voice room with them.
- A streamer can also pick their own images for anyone they added, kept on their own machine.
- Outside any call, a "Listen to my mic now" button lets the "just me" view react to your voice, for a solo streamer with no camera. A call takes the mic over from it.
- Three toggles decide everything:

| Toggle | Default | Depends on | Scope |
|---|---|---|---|
| Let others show me on their stream overlay | On | nothing | your identity, synced to your devices |
| Share my overlay images | On | the first (off forces it off) | your identity, synced to your devices |
| Run the overlay for OBS | Off | nothing | this computer only |

One feature, built in one go. No relay change, no new relay frame, no public surface.

---

## 1. Decisions (locked 2026-10-10)

1. **Purely local.** The only URL is the loopback one the streamer pastes into their own OBS. No web hosting, no public overlay links, no web viewer. The relay route was rejected on three counts: the relay never hears audio (voice is peer to peer under SFrame), voice channels are never public (`effective_public()`), and publishing who talks when would hand strangers the metadata Hollow works to hide.
2. **Three toggles**, defaults and scope as in the table above.
3. **"Let others show me" is respected by every other Hollow app.** When it is off, other apps show no tick on your profile, let nobody pick images for you, never show you on their overlay, and delete whatever they held for you.
4. **"Share my overlay images" off with "Let others show me" on:** others may still show you and pick their own images for you; you share nothing.
5. **Sharing happens only on request.** Your look moves to someone only after they ticked you on your profile, only while both of your first two toggles are on, and only if they are your own device, a friend, or currently in a voice room with you. Nothing is broadcast and nothing syncs by default.
6. **Change detection:** your overlay field carries a stamp. A streamer's app re-asks when it meets you (you join its voice room, a friend comes online) and your stamp is newer than the one it holds.
7. **Turning sharing off stops new answers.** Copies already sent cannot be recalled; Hollow apps delete them when they see the off flag.
8. **Courtesy, not enforcement.** A streamer can always screen-capture the voice panel with OBS. We do not fight that, and the Settings copy never promises more than the app does.
9. **Port:** chosen at random once and saved. If it is busy at start, a new random port is chosen and saved, and the user is warned that the OBS link changed.
10. **Who appears on a room overlay** (confirmed by Vitalik): everyone in the call, DM call or voice channel (and meeting), with their avatar, except anyone whose "Let others show me" is off, who is not shown at all. People you added show their look (shared, or your own pick). A streamer-side filter "Only people I added" covers anyone who wants less.
11. **Reactive everywhere.** Inside a voice room the call's own speaking detection drives the overlay. Outside one, a "Listen to my mic now" button (desktop, section 7a) drives the "just me" view from the same capture path as the Settings microphone test. Joining a call stops it before the call claims the mic, so the two never fight; leaving the call starts it again if the button is still on. With neither a call nor the button, the "just me" view shows your idle look or nothing, as you choose.

---

## 2. What already exists (verified 2026-10-10)

- **Speaking state** (`lib/src/core/providers/speaking_provider.dart`): `vcSpeakingProvider` (a Set of remote DEVICE ids), `vcLocalSpeakingProvider` (a bool for us), `callSpeakingProvider` (`(local, remote)` for DM calls). Remote detection reads getStats `inbound-rtp` every 200 ms; local detection reads the native capture meter through `Helper.getCaptureLevel()` (`LocalSpeakingDetector`, `lib/src/core/services/local_speaking_detector.dart`).
- **Mute and deafen:** voice channel peers have `PeerAudioState(isMuted, isDeafened)` (`voice_channel_provider.dart:53`, fed by `audio_state` signals); DM calls have `remoteMuted` / `remoteDeafened` (`call_provider.dart:97`). All four overlay states are already known for every person.
- **Asset rail:** `node/assets.rs` `AssetKind` with `recv_cap` and `max_request_hashes`; `node/emotes.rs` `handle_emote_request` (:460) and `handle_emote_assets` (:516); the `PendingAsk` table in swarm.rs; bundles via `encode_asset_bundle`; answers ride `olm_lane::carry`.
- **Profile signatures:** `profile_signing_payload` (`hollow-profile2`, `crypto_handler.rs:421`), `card_signing_payload` (`hollow-card1`, :457, used by `node/profile_card.rs`). The pattern for a field with its OWN master signature: `sign_support_creds` / `verify_support_creds_sig` (`crypto_handler.rs:473-516`).
- **Profile audience:** `social::profile_audience` (`social.rs:1735`): Full for `voice_handler::data_channel_peer_allowed` (own devices, friends, co-members of any shared server), Card for a pending friend, None otherwise. Admitted meeting peers get the card.
- **Loopback server template:** `node/at_rest_server.rs` (127.0.0.1 bind, 32-byte token compared in constant time, GET and HEAD only, 8 KiB head cap, 64 connections, 30 s idle, `no-store`, nothing logged). Section 7 lists what the overlay server does differently.
- **Settings:** categories in `lib/src/ui/settings/settings_catalog.dart` (`SettingsCategory`), pages only via `settings_kit.dart`; mobile in `lib/src/ui/mobile/tabs/mobile_settings_tab.dart`.
- **Profile surfaces:** `lib/src/ui/components/profile_card_popup.dart`, `lib/src/ui/dialogs/profile_dialog.dart`, `lib/src/ui/mobile/mobile_profile_sheet.dart`; voice channel rows are `_VoiceParticipantRow` in the channel sidebar.
- **Per-identity, hash-keyed image notifiers to copy:** `avatar_frame_provider.dart`, `profile_anim_provider.dart` (an `_awaiting` set plus a retry when the owner comes back).

---

## 3. Settings > Stream overlay

A new `SettingsCategory.streamOverlay` in the App group (Lucide icon, for example `LucideIcons.cast`). Four sections, hairline dividers, every choice explained (`feedback_settings_sections_dividers_explanations`), every toggle keeps its place (`feedback_toggle_keeps_its_place`).

1. **Privacy.** "Let others show me on their stream overlay" and "Share my overlay images". The second greys out with its reason while the first is off.
2. **My overlay look.** Four state slots with a live animated preview, effect choices (section 4), and a press-and-hold "Talk" button to preview the talking state. While you are in a voice room the preview follows your real mic.
3. **People on my overlay.** One row per person you ticked: avatar, name in `nameColorFor(MASTER)`, a source chip (their images, my picks, avatar), your own per-state picks and effect overrides, Remove.
4. **OBS** (desktop only). "Run the overlay for OBS", link rows with Copy buttons (whole room, just me, each person), the port and the port-changed warning, Reset link, layout options (section 8), the "Listen to my mic now" button with its sensitivity slider and live meter (section 7a), and "When I'm not in a call and not listening: show my idle look / show nothing".

Phones get sections 1 to 3: a phone user appears on a desktop streamer's overlay and sets their look there. Section 4 is hidden on phones (there is no OBS to point at it).

Draft copy, final wording at build time and through the `sepia` skill:

- "Let others show me on their stream overlay": "Friends and people in a voice room with you can add you to the overlay they use in OBS."
- "Share my overlay images": "People who added you get your images. Turn this off and they can still show your avatar."
- "Run the overlay for OBS": "Starts a page only this computer can open. Paste the link into an OBS browser source."
- Port warning: "The overlay moved to a new port because the old one was busy. Copy the new link into OBS."
- "Listen to my mic now": "Lets your overlay react to your voice when you're not in a call. A call takes over the mic while it runs."
- Profile tick: "Show on my stream overlay".

---

## 4. Looks

A **look** is one image per state plus effects.

- **States:** idle, talking, muted, deafened.
- **Fallbacks:** no idle image means the avatar; no talking image means the idle image with the talking effect; no muted or deafened image means the idle image, dimmed, with a small mic-off or headphones-off badge. No avatar either means the initials circle in the name colour, as `HollowAvatar` draws it.
- **Effects:** talking (none, bounce, shake, pop, glow in the name colour); idle (none, dim, grayscale); transition (instant, crossfade); hold after speech ends (0 to 600 ms, default around 250 ms) so the image does not flicker between words.
- **Who sets what:** each person sets effects in their own look. A streamer can override them per person and sets the defaults used for people shown with a plain avatar.

**Processing** (new `image_convert::process_overlay_image`): decode through `load_bounded`; decide animation from the bytes (`is_animated_image`, never a GIF8 or extension check); encode through `node/webp_anim.rs` (`encode_still` for stills, method 4); any aspect ratio, since PNGtuber art is often tall; longest side capped (proposal 512), never upscaled; at most 2 MB per image; a decoded-bytes guard that refuses with a clear message rather than decimating, like `MAX_PROFILE_DECODED_BYTES`. Inputs: PNG, JPEG, GIF, WebP, APNG.

**Storage:** rail blobs in `emote_blobs` under a new `AssetKind::Overlay`: `recv_cap` 2 MB, equal to the authoring limit and pinned by a test like `Profile`; `max_request_hashes` 4, so four states at 2 MB fill `MAX_BUNDLE_REPLY_BYTES` exactly. `referenced_asset_hashes` (`api/storage.rs:1214`) pins your own look, the looks you fetched for people you ticked, and your local picks. Removing a person deletes theirs.

**Look manifest** (`look_json`): `{ v: 1, stamp, states: { idle, talking, muted, deafened }, effects: { ... } }`. State values are a 64-hex hash or `""`. Effects come from closed enums, numbers are clamped, unknown keys are ignored (an older client tolerates a newer look), and the whole body is size-bounded and shape-checked before use.

---

## 5. The overlay field: what others learn without asking

One field, `stream_overlay`, on the profile AND on the card:

- `"off"`: "Let others show me" is off.
- `"show"`: you may be shown, but you share nothing.
- `"share:<stamp>"`: you may be shown and you share your look; the stamp is when the look last changed (ms).

**It carries its OWN master signature** over `(master, field_updated_at, value)`, exactly like `support_creds`, and is NOT folded into `hollow-profile2` or `hollow-card1`. Folding it in would break the signature of every profile and card from every shipped client. The signature is REQUIRED: an unsigned or mis-signed field counts as absent, and the stored value is kept. The newest `field_updated_at` wins and an older field never replaces a newer one, so a replayed old `share` cannot undo an `off`. Absent (a client from before this feature) means the default, `show`: that person appears with their avatar and there is nothing to ask for. `#[serde(default)]` on every new struct field, an additive `user_profiles` column, and the field rides the LIGHT announce (it names a state, it carries no art).

**Why the card too:** pending friends and admitted meeting peers only ever see the card (`profile_audience`), and a meeting is a voice room. Without the field on the card, a meeting peer's `off` would be invisible to the streamer.

**How a streamer's app reacts to a change:**

- `off`: hide the tick, take the person off the overlay, delete their fetched look and your local picks for them, remove them from "People on my overlay".
- `show`: the tick is available, local picks only; delete any look fetched earlier.
- `share:<stamp>`: the tick is available; if you ticked them and the stamp is newer than the one held, ask when they are reachable.

---

## 6. The ask and the answer

Two new carried messages, `Lane::Carried` (Olm through `olm_lane::carry`; the relay reads nothing):

- `OverlayLookAsk { held: Vec<String> }`: the hashes of this person's look the asker already holds (at most 4).
- `OverlayLookAnswer { status, look_json, bundle_json }`: `status` is `show` or `share`; `look_json` and the bundle are present only for `share`, and the bundle carries only the blobs not in `held`.

**The answering side** runs one gate, `overlay_ask_allowed(asker_device)`, before anything else:

1. The asker is a roster-counted device: never a bare master (`resolver::is_bare_master`, G1), never revoked, never blocked (`blocklist::is_blocked` on its master).
2. And it is one of: our own sibling; an accepted friend (by master); or currently seated in the same voice room as us, meaning the same server voice channel seat (`voice_handler`), the DM call we are in (`call_book`), or the same meeting call.

A failed gate gets SILENCE: no "not allowed" reply, nothing to probe. A passed gate gets the status, and blobs only for `share`. The gate is deliberately narrower than `data_channel_peer_allowed`, which admits every co-member of every shared server. No `MessageStore::open` on the event loop: read friend status from the in-memory state or off the loop (`feedback_sqlcipher_open_hygiene`).

**The asking side:**

- An answer is accepted only for an ask WE made to that identity (a pending overlay ask with an asked-set per device, the `PendingAsk` shape), and only from a roster-counted device of that identity. Unsolicited answers are dropped whole.
- Every blob must be named in the answered look and pass the hash check, the container check and the `webp_header_dimensions` ceiling; the size cap comes from OUR recorded kind (`Overlay`).
- Then: store, pin, emit `OverlayLookReceived`.
- Asks fire on a tick, on meeting the person with a newer stamp, and through the pending-ask sweep while the person is unreachable.

**Keep overlay blobs out of the generic rail.** `handle_emote_request` (emotes.rs:460) serves ANY blob we hold, by hash, to anyone who asks ("content addressing makes every copy equally trustworthy"). If overlay blobs stayed in that path, "Share my overlay images" would only hide the hashes, and the images we fetched from others or picked locally would be served to anyone who learned a hash. So the generic responder never serves kind `overlay` (`emote_blobs.kind` already records it), and the gated answer serves only our OWN look. We never pass another person's look on: their consent covers their own answer only.

**Own devices:** your siblings are always entitled. Editing your look on any device bumps the stamp; the other devices see the newer stamp in your profile and pull through the same ask. Two devices editing at once: the newest stamp wins.

**Builder-secure checklist** (from CLAUDE.md): each new `HavenMessage` variant picks its `lane()` (Carried) and a `live_only()` class, is dispatched by its owner's `handle_envelope_*`, and has `#[serde(default)]` on every field; device-to-master through `resolver`; a row in `security_write_gates.md` for the answer-to-blob-store path and for the field ingest; signature failures REJECT, never log and continue.

---

## 7. The overlay server (desktop)

In Rust, `node/overlay_server.rs`, next to `at_rest_server.rs` and built from it. Networking stays in Rust, the template is already hardened, and the avatar and rail bytes are readable there directly.

**Differences from `at_rest_server`:**

- **A stable address.** The port is chosen at random once from a quiet range (proposal 20000 to 39999, clear of the Windows dynamic range 49152 to 65535) and saved together with a 32-byte token, per profile (#47). If the port is busy at start (another program, a Windows excluded port range, a second Hollow profile), pick a new random port, save it, and raise `OverlayPortChanged` so Settings shows the warning and a toast. "Reset link" mints a new token, and old links stop working. OBS scene collections store the URL with its token, so anyone who shares a scene collection should reset the link.
- **Bind `127.0.0.1` only**, never `0.0.0.0` or `::`. Links use the literal `127.0.0.1`, not `localhost`, which can resolve to `::1` first.
- **Host check:** the `Host` header must be `127.0.0.1:<port>` or `localhost:<port>`, else 404. This stops DNS rebinding (a website pointing its own domain at 127.0.0.1 to reach the server from the user's browser). `at_rest_server` does not check Host today; this server must.
- **Origin check:** a request whose `Origin` is not our own origin gets a 404. No CORS headers, ever.
- **Token** in the first path segment, constant-time compare; a wrong token gets a bare 404.
- **GET and HEAD only**, 8 KiB head cap, a small connection cap (proposal 16), 30 s idle for normal requests. Event streams are exempt from the idle timeout but capped (proposal 8 at once) and send a heartbeat comment every 15 s.
- **Headers:** `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, and a CSP of `default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self'; connect-src 'self'`. The page loads nothing from the internet, so OBS works offline.
- **Images only from the allowlist:** an image is served only while the CURRENT snapshot names it. Sources are overlay rail blobs, the animated avatar on the rail, and the still avatar from the profile store. Nothing else under the data root is reachable.
- **Nothing about paths or people is logged.**
- **It runs only while "Run the overlay for OBS" is on AND the app is unlocked** (identity unlocked, App Lock not engaged). When App Lock engages, the stream sends `locked` and the page goes blank; unlock resumes it. The duress and destroy wipe routine stops the server.

**Endpoints:**

| Path | What |
|---|---|
| `/<token>/room` | everyone in my voice room who may be shown, me first |
| `/<token>/me` | just me |
| `/<token>/p/<slot>` | one person I added, by a local slot number (never the peer id, so identities stay out of OBS scene files) |
| `/<token>/events?view=...` | the live state as Server-Sent Events |
| `/<token>/img/<hash>` | images on the allowlist |
| `/<token>/overlay.js`, `/<token>/overlay.css` | the page's own files, embedded with `include_str!` |

Server-Sent Events rather than a WebSocket: the feed only goes one way, it is plain HTTP with no upgrade step, and `EventSource` reconnects by itself.

**State flow.** Dart owns the inputs (participants, speaking, mute and deafen, looks, layout). It builds a compact snapshot and pushes it over FFI (`overlay_publish`) only when something changed, coalesced (proposal at most 20 per second). Rust keeps the latest snapshot, fans it to every open stream, and sends it at once to a new stream. The Dart publisher listens to providers with `ref.listen` outside any widget, so Hollow's own UI pays nothing.

**Snapshot, per view:** layout, plus a list of people with `slot`, `is_self`, `name`, `name_colour`, `state` (idle, talking, muted, deafened) and `look` (an image per state plus effects). No peer ids.

**FFI** (`api/overlay.rs`, then FRB codegen): `overlay_set_enabled`, `overlay_links`, `overlay_reset_link`, `overlay_status` (port, running, port changed), `overlay_publish`; for looks and the field: `process_overlay_image`, `set_own_overlay_look`, `set_overlay_flags(allow, share)`, `overlay_add_person`, `overlay_remove_person`, `overlay_set_local_pick`.

---

## 7a. Listening outside a call (desktop)

The "Listen to my mic now" button lets the "just me" view react to your voice with no call running.

- **It reuses the Settings microphone test's capture** (`_startMicTest`, `lib/src/ui/settings/audio_section.dart:344`): `record`'s PCM stream on Windows and macOS, `LinuxPulseCapture` on Linux (never `record` there, `rules_media_calls.md`), the selected input device with the same fallback to the system default. No WebRTC session. That code lives in the widget's state today: move the capture into one shared service (for example `MicLevelCapture`) that the mic test and the overlay both use, so there is one capture path, not two copies.
- **Detection:** RMS per chunk (`_levelFromPcm16` already computes it) against a threshold set by a sensitivity slider with a live meter beside it, plus the look's hold time. A raw capture has no denoiser, so its voice probability is not available; the slider is how a user tunes out keyboard and room noise. Start from the call path's -45 dBFS floor (`LocalSpeakingDetector.speakingFloorDb`, also measured before processing) and adjust after measuring.
- **Handover to a call:** every path that starts or accepts a DM call, joins a voice channel or joins a meeting first awaits one gate (for example `overlayMic.yieldToCall()`), which stops the listening and waits until the mic is released, and only then does the call run `getUserMedia`. Inside the call the overlay reads the call's own detector, so the "just me" view keeps reacting with only the handover gap.
- **After the call:** once the call's teardown has fully finished (the voice channel teardown is single-flight, `_teardownCall`), listening starts again if the button is still on.
- **The Settings microphone test** pauses the listening while it runs and resumes it afterwards; both claim the mic.
- **Never remembered across restarts:** the button is off at every app start, so the mic never opens without a click in the current session. It needs "Run the overlay for OBS" on, and turning that off stops it.
- **Always visible:** while listening, a small "Mic on for overlay" indicator with a stop action sits in the user bar, so an open mic outside a call is never hidden inside a Settings page. The OS mic indicator shows as well.
- **It stops when** App Lock engages, the identity locks, the duress or destroy wipe runs, or the server stops.

---

## 8. The overlay page

Plain HTML, CSS and a small script, no framework, no request to anything but our own server. Transparent background.

- **Layout:** row, column or grid; alignment; image size; gap; names on or off, drawn in the name colour.
- **Filters:** "Only show people who are talking" (fugi has it, streamers use it), "Only people I added".
- **Effects** in CSS only (transform, opacity, filter), so OBS's browser renders them cheaply.
- **Restyling:** stable class names and data attributes (`.person`, `[data-state="talking"]`, `[data-self]`) so OBS's own Custom CSS box can restyle everything. Settings lists the hooks under "Customise with CSS in OBS".

---

## 9. In the app (Dart)

- The Settings tab of section 3, desktop through `settings_kit.dart` and the mobile tab, following the `hollow-ui` skill.
- **The profile tick** "Show on my stream overlay" in `profile_card_popup.dart`, `profile_dialog.dart` and `mobile_profile_sheet.dart`, plus a menu item on voice channel participant rows through `showHollowMenu`. It shows only when the person's field is not `off`, never for ourselves, never for blocked people. Ticking adds them to the list and, when their field says `share`, asks.
- **Keys are MASTER ids** (`identityOf`). The speaking set is DEVICE-keyed, so collapse device to master before matching. We are `vcLocalSpeakingProvider` or `callSpeakingProvider.local`, never our own id inside a set.
- **Events** wired in `event_provider`: `OverlayLookReceived` (reload that person's look), `OverlayPortChanged` (warning plus toast); a profile update refreshes the field.
- Fire-and-forget FFI carries `.catchError((_) {})`; actions behind a button await and toast their failure.

---

## 10. The "alone in a voice channel" speaking bug

The "just me" view needs our own speaking state while we sit alone in a voice channel, and Vitalik has seen the self indicator stay dark there. Section 7a makes this matter more: joining an empty voice channel hands the mic from the listening to the call, so if the call's meter stays dark, the overlay stops reacting the moment you join.

- **What the code says:** the voice channel poll timer starts on join (`voice_channel_service.dart:300`), and `_pollAudioLevels` claims the native meter needs no peer connection, "so it also lights up while you are alone in the channel" (`:1668`).
- **Hypothesis (unverified):** libwebrtc's audio device module starts recording only when a send stream starts, which needs a PeerConnection carrying our mic track. Alone there is none, so `getCaptureLevel()` returns its -100 "no meter" default and `LocalSpeakingDetector.poll` holds its last state, false. The getStats fallback needs a PeerConnection too. The Linux anchor PeerConnection (#72) carries no sender, so Linux likely behaves the same.
- **Diagnosis (fleet, no voice needed):** log `levelDb` from `getCaptureLevel()` on every poll for the first 10 s alone in a channel, then again after a second peer joins. -100 while alone and real readings afterwards confirms it.
- **Fix candidates, after the diagnosis:** (a) in the fork, start recording when a local audio track is live even without a send stream (native work: delete `build/windows/x64/plugins/flutter_webrtc/` before rebuilding, test in Release); (b) Dart only, while alone, keep a local loopback PeerConnection pair that sends our mic track to itself. Prefer (a); take (b) only if (a) fights the engine.
- **Proof:** a real voice on Vitalik's machine, watching both the in-app self ring and the overlay. This also fixes the in-app self indicator while alone.

---

## 11. Tests

**Harness** (`node/test_harness.rs`):

- `overlay_look_answered_only_to_friends_or_people_in_the_room`: a stranger's ask gets silence; a friend gets an answer; a non-friend seated in our voice channel gets an answer; the same person after leaving the channel gets silence.
- `overlay_off_hides_and_share_off_sends_no_images`: `off` and `show` answers carry no blobs; flipping to `off` makes the streamer side delete what it held.
- `overlay_answer_nobody_asked_for_is_dropped`.
- `overlay_blobs_are_never_served_by_the_generic_rail`: an `EmoteRequest` for an overlay hash comes back as `missing`, our own look and a fetched one alike.
- `overlay_field_needs_its_own_signature_and_newest_wins`: unsigned or forged fields count as absent; a replayed older `share` never undoes `off`.
- `overlay_ask_from_bare_master_or_blocked_is_silent`.
- `overlay_answer_capped_by_the_kind_we_recorded`.
- `overlay_look_reaches_own_sibling_on_stamp_change`.

**Unit:** the server's Host and Origin checks, token, method gate, image allowlist, port fallback, and SSE heartbeat; the look manifest parser (closed enums, clamps, unknown keys ignored, size bound); `recv_cap` equal to the authoring limit.

**Widget:** the dependent toggle greys out and forces off; the tick is hidden for `off`, for ourselves and for blocked people; the snapshot builder collapses device to master and reads self from the bool.

**Listening (Dart unit):** the gate stops the listening and the call's capture starts only after the stop completed; listening restarts after the call's teardown only if the button is still on; the mic test pauses and resumes it; the button starts off after a restart; turning off the server stops it.

**Fleet** (throwaway peers only, `scripts/fleet.ps1`): two peers in a voice channel, one ticks the other, the look arrives, and `curl` against `/events` shows membership, looks, and the mute and deafen states (which the fleet can drive); the alone-in-channel meter log of section 10. Talking itself is checked with a real voice on Vitalik's machine in OBS.

---

## 12. Build order and team

It is one feature, but the work has an order:

1. **The alone-in-channel diagnosis and fix** (`builder`; native fork work). Independent, can start any time.
2. **Rust core** (`builder-secure`): the field and its signature, storage, carriage on profile and card; `AssetKind::Overlay`, processing, and the generic-rail exclusion; the ask, the answer and both gates; the harness tests.
3. **The overlay server, the embedded page, the FFI** (`builder-secure` for the server; the page can be built alongside). FRB codegen afterwards.
4. **Dart** (`builder`, `hollow-ui` skill): the Settings tab, the look editor, the people list, the profile tick, the snapshot publisher, and the listening service extracted from the mic test with its call handover (section 7a). Desktop and mobile together.
5. **`reviewer`** on steps 2 and 3 (the gates and the server).
6. **Fleet**, then Vitalik's check in OBS. Afterwards: rows in `security_write_gates.md`, a wiki page for the feature, the HOLLOW_PLAN.md checklist, and one changelog sentence through `sepia`.

---

## 13. Open questions

None as of 2026-10-10. Both earlier questions were answered the same day: who appears (decision 10) and listening outside a call (decision 11, section 7a).

---

## 14. Non-goals

- No public, shareable or web-hosted overlay links, and no web viewer.
- No relay involvement: no new relay frame, no new relay JSON type.
- No enforcement against screen capture.
- No overlay server on phones (no OBS there); phones still set their look and toggles.
- No audio, chat or video on the overlay.
- No passing on another person's look.
