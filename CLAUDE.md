# HOLLOW — Project Instructions for Claude Code

## What Is This
Distributed, encrypted Discord alternative: no central servers, members host it. `HOLLOW_PLAN.md` = architecture, phases, TODO.

## Tech Stack
- **UI:** Flutter (Dart), all 6 platforms (Win, macOS, Linux, Android, iOS, Web)
- **Backend:** Rust via `flutter_rust_bridge` v2.11.1
- **Networking:** WSS relay (signaling + text/CRDT/MLS) + WebRTC data channels (files/shards) + WebRTC media (voice/video).
- **E2EE:** vodozemac (Olm/Double Ratchet) DMs, OpenMLS 0.8 servers, SFrame (AES-128-GCM) voice/video/screen share
- **Local DB:** SQLCipher
- **Identity:** Ed25519 via BIP-39 mnemonic (ed25519-dalek, NativeKeypair)
- **Org ID:** com.anonlisten · **Project:** hollow

## Project Structure
- `lib/`: `main.dart` entry (ProviderScope + RustLib.init + window_manager); `src/core/` models+providers+services, `src/theme/` design system, `src/ui/` shell chat settings sidebar components dialogs animations mobile.
- `rust/hollow_core/src/`: `api/` FFI (frb scans these); `node/` swarm.rs + focused modules (types, handlers, ws_client, crdt_store, image_convert/webp_anim, test_harness cfg(test)); `crypto/` Olm+MLS (store.rs = CryptoStore); `identity/` Ed25519; `storage/` SQLCipher.
- `relay-uws/` production relay (native TLS); `relay/` legacy. `packages/flutter_webrtc/` FORK 1.5.2, libwebrtc m144 = OUR patched build, `screen_audio_capturer.exe` = SEPARATE target. `rust_builder/` cargokit. `vendor/ffmpeg/` gitignored. `legal/` policy+terms.

## Build & Run Commands
```bash
flutter run -d windows
flutter build windows
flutter test test/  # widget tests
cd rust/hollow_core && cargo check  # + clippy

cargo test --lib test_harness -- --nocapture  # multi-node harness
cargo nextest run --lib  # full suite 80s vs 16min

# FRB codegen after Rust API changes (MUST run from project root)
flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root "rust/hollow_core" --dart-output "lib/src/rust"

# Relay deploy: scp src/*.cpp *.h → ~/relay-uws/src/, cmake+make+setcap+restart (`feedback_relay_rules`)

# Windows release (build→sign→installer→zip; Certum PIN prompt)
pwsh scripts\build_release.ps1  # full pipeline (-SkipBuild to repackage)
pwsh scripts\sign_release.ps1  # sign every .exe/.dll in Release
```
**Certum signing:** self-healing CNG binding; output `installer\Output\` (`reference_certum_signing_procedure`). **Release zips: .NET '/' zipping, NEVER Compress-Archive** (`feedback_compress_archive_backslash_zip`).

## Hollow Design System
All UI = custom Hollow widgets, no Material defaults (`src/ui/components/`): HollowPressable, HollowButton (`.filled()/.ghost()/.outline()/.danger()`), HollowTextField, HollowDialog (`showHollowDialog()`), HollowTooltip, HollowToast, HollowToggle, StatusDot, StatBar.
- **CRITICAL: hover/dialog patterns:** NEVER animate a color from `Colors.transparent` (lerps via black — pass `backgroundColor: null`); hover never paints outside the control. Dialogs = ghost Cancel + filled confirm; `.danger` ONLY destructive; selection = chips, never `.filled`. `feedback_hover_state_patterns`.

## Key Architecture Notes
- **Multi-node harness (`node/test_harness.rs`) = PRIMARY testing for distributed logic.** ALWAYS verify ring-1/ring-2 changes before declaring done. NOT covered: media/native/relay C++ (pixels = the UI probe), nor device→master attribution (process-global resolver): carry a signed device list, test with `resolver::forget`. `feedback_harness_first_testing`.
- **Node modules:** `swarm.rs` = event-loop dispatcher; domain logic in focused modules as `handle_*()`; types in `types.rs`. No SwarmContext — pass state vars individually (`feedback_swarmcontext_borrow`). New envelope variants → the owner's `handle_envelope_*()` (`feedback_envelope_dispatch_pattern`).
- **Persistence actors:** `CrdtStore` + `CryptoStore` own long-lived SQLCipher conns in spawn_blocking threads, fire-and-forget mpsc (CrdtStore batches one DB write per server). NEVER `MessageStore::open()` in a sync handler or on the event loop. `feedback_sqlcipher_open_hygiene`.
- **Peer state in swarm.rs:** `ws_room_peers` + `synced_peers`; PeerJoined → key exchange + sync; 30s keepalive in ws_client.rs.
- **Relay domain (self-hosting):** `relayDomainProvider` + `set_relay_url()` FFI, default `relay.anonlisten.com`; ALL WS/signaling/STUN/TURN URLs derive from it.
- **Event streaming:** Rust→Dart via `StreamSink` — `watch_network_events()` → `EventStreamNotifier` (`event_provider.dart`).
- **Profiles/avatars:** profiles load light (`getAllProfilesLight()`, no blobs); `HollowAvatar` self-fetches — never pass `imageBytes:`; banners via `bannerProvider`; a reload MUST reuse the SAME `Uint8List` when unchanged (`reuseIfUnchanged`). `feedback_lazy_avatar_pattern`, `feedback_reload_unchanged_bytes_identity`.
- **CRITICAL: profile announces are LIGHT:** hashes only, NO blobs (blobs ride ONLY `ProfileRequest` response + `handle_update_profile`); sweeps per-conversation, ONE source, throttled. `feedback_profile_light_announce_bandwidth_leak`.
- **CRITICAL: avatar frames (#54):** profile carries an ID (`""`/`b:<hue>`/64-hex), art rides the ASSET RAIL (`AssetKind::Frame`), NEVER the push. Zero layout cost, none on voice/call surfaces, hover = the ROW (3 CI guards). `project_avatar_frames`.
- **CRITICAL: Profile Showcase Board:** wire field `Option<String>` (absent = PRESERVE, `""` = clear); NO relational blocks (VETOED); IGDB authoring-only; fetchers refuse non-Hollow-CDN URLs. `project_showcase_board_impl`.
- **CRITICAL: asset rail (emotes/banners/stickers/GIFs):** content-addressed WebP; bytes NEVER ride CRDT/envelopes/relay; receipt cap = kind WE recorded, unsolicited DROPPED; FFZ/Klipy proxies authoring-only, key SERVER-side; send sites read `expandedText()` NEVER `.text`. `project_asset_rail_epic`, wiki `emotes`.
- **CRITICAL: user avatar/banner ANIMATION rides the rail (`AssetKind::Profile`), only the STILL rides the push:** hash absent = PRESERVE, `""` = clear; NOT signed; ceilings never upscale; render `imageBytes` > rail > still. `project_profile_media_asset_rail`
- **CRITICAL: lossy WebP = `node/webp_anim.rs`** (`method` 4 everywhere; stills via `encode_still`, NEVER the anim encoder). Decide animation from BYTES via `is_animated_image` — a `GIF8`/extension branch silently FLATTENS APNG. `project_animated_avatar_encoding`.
- **CRITICAL: stickers/GIFs:** identity = HASH not name; Klipy sticker ids carry `~` EVERYWHERE, GIF ids BARE. **ONE block asset per message**, gated at send (`exceedsAssetLimit`), never receive. Pack import re-hashes, never re-encodes. `project_stickers_phase5`, `feedback_antialiased_seam_bleed`.
- **Emoji font:** NotoColorEmoji MUST stay emoji-only subset (`scripts/subset_emoji_font.py`).
- **CRITICAL: CRDT sync batches parse tolerantly:** always `parse_ops_tolerant`, never `from_str::<Vec<CrdtOp>>` — one unknown NEWER-client variant poisons the batch and wedges older clients' sync. `project_custom_emotes_ffz`.
- **CRITICAL: Dart traps that fail SILENTLY** — read the list before debugging layout or a stuck Future. `feedback_dart_patterns`, `feedback_badge_stack_clips_avatar_frame`.
- **CRITICAL: blocking & Saved messages:** block list = MASTER-keyed, process-global (`node/blocklist.rs`) — inbound DM-surface handlers drop via `blocklist::is_blocked(sender)` BEFORE store+emit. Saved messages = self-DM (fan-out skips self). `project_saved_messages_block_report`.
- **Navigation shell:** `layoutModeProvider` (sync Notifier loaded in `_bootstrap`, NEVER AsyncNotifier-in-build, #58): Dock (default, new UI in `bottom_bar.dart`) / Classic (4-panel, must not inherit Dock surfaces). Centre tabs = ONE selection via `setShellTab()` (CI-guarded). `feedback_shell_centre_tabs_exclusive`.
- **Theme:** `HollowTheme.dark()/.light()` + hue variants, `themeModeProvider` persisted. Contrast: `accentText` for accent TEXT (raw `accent` = fills only), `textTertiary` for faded metadata — both 4.5:1 (`contrast.dart`, CI-guarded).
- **Accessibility iron rules:** PURPOSE labels on icon-only controls; focus rides `HollowFocusRing` (both CI-guarded); reduce motion ONLY via `ReduceMotionController` + `hollowMobileRoute()`; StatusDot = SHAPE (`filled:`); never `dart format` mid-edit. `project_accessibility_*`.
- **CRITICAL: interface scale = ONE root scaled viewport** (`UiScale`, `app.dart`): window coords ≠ overlay coords, so anchor via `overlayAnchorOf`/`overlayPositionOf`, NEVER bare `localToGlobal`; `MediaQuery.size` is the SLOT; zoom SHRINKS the viewport. Chat text = `ChatTextScale`. `project_display_scaling`.
- **CRITICAL: user-visible text carries ZERO em dashes** (UI strings, README, WHITEPAPER, legal, Rust errors, website); comments/logs exempt. Settings labels = SENTENCE case; Title Case only for card/section titles, permission names, doc titles, proper nouns. `feedback_vitalik_writing_voice`.
- **Icons:** `lucide_icons_flutter ^3.1.14` (camelCase), `brand_icons.dart`, `atlas_icons ^0.0.12` (snake_case).
- **Identity at-rest protection:** two opt-in modes (Settings > Security): password (blocks launch) or OS keychain (silent). `unlock_identity()` before any identity/DB op. `project_identity_protection`.
- **License keys:** relay `keys.json` gates WS auth; app caches via `set_license_key()` FFI.
- **Temp nicknames:** relay-scoped RAM claims, reset on `RelayDisconnected`. `project_temporary_nicknames`.
- **Deep links:** `hollow://` on all 6 platforms via `DeepLinkService` (init pre-runApp). Invites COPY `webServerInviteLink()` (FRAGMENT url, id never hits server logs); ALL link input bars parse via `inviteIdFromInput`/`classifyHollowLink`. `project_deep_linking`.
- **Window chrome:** `window_manager` + `setAsFrameless()`, 32px `WindowTitleBar` in `MaterialApp.builder` ABOVE the Navigator; Navigator child in `ClipRect` (BackdropFilter bleed).
- **Logging:** `hollow_log!` → stderr + rotated `hollow_debug.log`; `hollow_crash.log` = Flutter errors.
- **CRITICAL: a running `Ticker` requests a frame EVERY VSYNC** (240fps on a 240Hz panel) even if nothing changed — never use one as a clock, and never leave an `AnimationController` restarted as often as its duration. Decorative motion = `Timer` + `GatedNotifier`. `feedback_ticker_is_a_frame_request`.
- **Perf sentinels:** grep `[SENTINEL]`; `timedChannelCall`; `FrameCensus`, `FrameScheduleProbe` (works in RELEASE); `scripts/perf_*.ps1`. `project_perf_sentinels`, `project_idle_cpu_frame_scheduling`.
- **Relay:** uWebSockets C++ (`relay-uws/`). NO rate limits; NEVER lower `maxPayloadLength` (64MB). Topics `0x07`, broadcast `0x03`. EVERY binary handler gates on SENDER room membership; abuse = fair-share eviction, NEVER a cap; **NO byte quotas** (CAKE + coturn peer-lock). Per-IP RAM = connection caps ONLY, keyed by `ip_limit_key()` (v6 /64; unmap v4-MAPPED first). `feedback_relay_rules`, `project_relay_fairshare_turn_lock`.
- **CRITICAL: relay offline delivery (availability cache, ON 3d):** anything reaching OFFLINE channel members MUST ride `0x07` topic frames — `0x03` and direct sends are invisible to the TTL rings. OPEN BUG: channel files don't render post-catchup. `project_relay_availability_cache`.
- **Storage & profiles (#47):** data root = `dirs::data_dir()/hollow` (override `set_data_dir()`/`HOLLOW_DATA_DIR`). Desktop precedence: env > `--portable` > profiles.json PIN > marker > `hollow_data` WITH identity data (NEVER `data`). Keychain = PER-PROFILE slots. `project_issue47_sframe_keystore_fix`, `project_portable_mode`.
- **CRITICAL: self-restart ONLY via `relaunchApp()`** (Rust waiter — anything Dart spawns dies pre-Flutter). `project_profile_switcher_issue47`.
- **CRITICAL: auto-download gate (#41):** pull paths gated in DART; pushes can't be cancelled (discard + `declined` pin); senders pre-negotiate via `auto_dl_pref`; VOICE exempt; RequestFile receipts bypass cap + gate, NEVER remove; `accept_header_thumb` = the ONE thumb filter. `project_autodownload_gate`.
- **CRITICAL: bundled ffmpeg is MINIMAL:** test flags against `vendor/ffmpeg`'s binary, NEVER system ffmpeg. `project_ffmpeg_minimal_build`.

## Coding Conventions
- Dart: `flutter_lints`/`analysis_options.yaml`. Rust: `cargo clippy`. snake_case filenames. Flutter only for UI — no Electron/Node/web frameworks.
- **NEVER pass `WidgetRef ref` as a constructor parameter**: use `ConsumerWidget`/`ConsumerStatefulWidget` (passing `ref` causes cascade rebuilds).
- Per-item opacity: `AnimatedOpacity` (GPU-composited), never the `Opacity` widget.
- **CRITICAL: backward-compatible DB schema:** ALWAYS add `#[serde(default)]` to ANY new field on a persisted Rust struct — else old data fails to deserialize and silently vanishes (servers disappear).
- **CRITICAL: flutter_webrtc native input selection (audio+video) uses `sourceId`:** `{'optional': [{'sourceId': deviceId}]}` — `{'deviceId': ...}` silently ignored.
- **CRITICAL: server switching batches the 4 selection providers atomically** in ONE synchronous block — canonical `server_strip.dart:_selectServer`.
- **CRITICAL: TURN ICE config:** each TURN URI = its OWN `IceServer` entry (native has one `uri` per struct). Credentials arrive via the authed WS (`NetworkEvent::TurnCredentials` → `iceConfigProvider`) — never re-add a Dart HTTP fetch; WS `discover_peers` is discovery.
- **CRITICAL: "Always relay calls" (force-TURN) lives ONLY in `IceConfigNotifier`:** `ref.listen` the toggle, NEVER `ref.watch` (rebuild wipes TURN creds); fails closed; never add TURN to `shareIceConfigProvider` or forwarder legs. `project_always_relay_calls`, `project_share_data_channel_reuse_turn`.
- **CRITICAL: VAD/speaking state lives in `speaking_provider.dart`**, NEVER in CallState/VoiceChannelState. REMOTE peers membership-select; OURSELVES = a bool (`vcLocalSpeakingProvider`, the set is DEVICE-keyed). LOCAL mic level = `Helper.getCaptureLevel()`, NEVER getStats. `feedback_getstats_no_local_audio_level`.
- **CRITICAL: MLS epoch staleness:** sync requests + CRDT fallback go plaintext on MLS failure; stale-PRESENT groups heal via commit catch-up (hints NEVER drop a group; frames only at own+1; commits ONLY via `broadcast_mls_commit`). `project_mls_epoch_catchup`, `feedback_mls_patterns` (all 8).
- **CRITICAL: WS sends: bounded + never silently discarded.** ALL ws_client.rs sink writes go via `bounded_send` (30s timeout) — a raw `write.send()` on a wedged socket freezes the select loop incl. the watchdog. `send_command()` false → break, buffer, reconnect. `feedback_ws_zombie_liveness_timeout`.
- **CRITICAL: in-memory message lists dedup by `message_id`** before append (`chat_provider`/`channel_chat_provider`) — the same message arrives via DB-load AND live event. `feedback_ui_dedup_by_message_id`.
- **CRITICAL: multi-device device-vs-master routing.** One MASTER = many DEVICEs: UI/lookups collapse device→master (`resolver::resolve`/`identityOf`); SENDS target a DEVICE, fan via `devices_for(master)`. Fresh installs ALWAYS have device≠master. `feedback_multidevice_targeting_sweep`.
- **CRITICAL: multi-device audit fixes:** raw master sends DROP — route via `send_raw_to_identity`/`preferred_online_device`/`friend_device_targets`; LEAVE tears down all 3 apply paths; ingest gates on `ServerState::op_allowed`. `project_multidevice_audit_2026_07`.
- **CRITICAL: targeted sends route to their DETERMINISTIC room, never `ws_room_for_peer`** (first-match = silent one-way loss): DMs → `dm_room_code`, forwarder → `fwd:{id}`; sibling self-echo keeps the flexible lookup. `feedback_dm_friend_establishment_bugs_2026_07`.
- **CRITICAL: multi-device data channels (`webrtc_service.dart`):** glare tiebreaker compares MASTER identities; answer/ICE match by `conn_id`, never peer_id; sends/sockets/keys stay DEVICE-keyed; `sendScreenAudio` drops over 256KB buffered. VC mesh glare is the OPPOSITE (`feedback_vc_join_double_announce_race`).
- **CRITICAL: multi-device servers/MLS:** MLS leaf credential = bare `device_peer_id`; CRDT `ServerState.members` is MASTER-keyed — bridge EVERY MLS↔CRDT compare through the resolver. A linked sibling MUST regenerate its own MLS signer/credential. `feedback_mls_sibling_identity_collision`.
- **CRITICAL: multi-device server sync:** lifecycle ops converge the actor's OWN siblings (`fan_to_own_siblings`) AND offline members. Server DELETE = replicable `ServerDeleted` tombstone (owner-author validated at EVERY ingest). RE-ANNOUNCE all servers on sibling reconnect. `feedback_server_lifecycle_sibling_sync`.
- **CRITICAL: multi-device push:** fetch node auths as its DEVICE (DB passphrase MASTER-derived); sender targets `devices_for(master)` ∩ has-session ∩ not-in-room; push tap resolves sender→master. wiki `push_notifications`.
- **CRITICAL: multi-device revocation + ghost fan-out:** device list carries a master-signed `revoked` tombstone array (max-version-wins), reaching the revoked device FIRST (`SelfRevoked` → `_selfNuke`). DM/file fan-out targets only devices CURRENTLY IN A ROOM (`has_session` is NOT liveness). `feedback_ghost_device_fanout`.
- **CRITICAL: device linking:** REUSES the `.hollow` backup pipeline (6-char code = passphrase, `link:{code}` room, one-shot); receiver stashes `pending_link.hollow` + RESTARTS; import runs pre-node-start — NEVER import in-place while the node runs. `feedback_link_import_identity_device`.
- **CRITICAL: channel device→master collapse:** channel messages are SIGNED by + attributed to the sender's MASTER — every Rust receive handler + `fetch.rs` resolves sender→master, Dart via `identityOf`; file-request stays RAW; wedged rows self-heal. `feedback_channel_display_device_master_collapse`.
- **CRITICAL: FCM push:** payload stays `{wake, sender}` — NEVER ciphertext; relay buffers offline DMs in RAM, replays on DM-room join; `RustLib.init()` throws on 2nd call (treat as ready); iOS NSE decrypts on-device (`push_enrich.rs`). Full rules: `project_push_notification_implementation`, wiki `push_notifications`.
- **CRITICAL: channel push:** sender fans one `0x09` frame per OFFLINE member (targets + mention flag from its CRDT, so the relay never learns membership); relay filters `set_push_prefs` + debounce. Prefs sync MOBILE-ONLY. `project_channel_push_notifications`.
- **CRITICAL: local notifications (distinct from FCM):** ONE surface per message — desktop toast when hidden/unfocused, in-app card only when visible AND focused; mobile foreground = `MobileInChatBanner` only. `project_local_notifications_desktop_mobile`.
- **Push tap → chat:** all 3 entry points required (onMessageOpenedApp / getInitialMessage / local-notif payload + launch details); per-peer `plugin.show()` MUST set `payload: sender`; cold-start taps buffered. `feedback_push_tap_navigation`.
- **CRITICAL: Windows mid-call media:** `addTrack`/`removeTrack` + renegotiate, NEVER `replaceTrack`. Live `setParameters` WORKS (rules + sentinel traps in the memory). `project_webrtc_engine_screenshare_research`.
- **CRITICAL: screen shares are OPT-IN (#38):** a share streams ONLY after the peer's `screen_watch{want:true}` (`vc_screen_watch`/`call_screen_watch`); receivers DROP unsolicited offers; badges never auto-focus/flip. `HotkeyController` = in-call only. `project_issue38_watch_gate_ptt_grid`.
- **CRITICAL: mic gain/loudness:** WebRTC APM AGC DISABLED, NEVER re-enable. Voice Enhancement owns loudness (`setCaptureGain`/`setVoiceEnhance`; `setVolume()`=NO-OP); NEVER a per-sample leveler or bypass of iOS VPIO. Chain/servo/3 ports + g++ harness: `project_voice_agc_loudness_rvox`.
- **AI noise suppression LIVE:** RNNoise default (DFN3 = desktop selector), ABI v3; WebRTC NS auto-disabled; its VAD gates upward boost; `frames>0` or the test didn't happen; capture buffers ALWAYS fullband mono. `project_dfn3_noise_suppression`, `project_voice_enhance_chain`.
- **CRITICAL: SFrame:** `setKeyIndexForPeer` after every enable; `rotateKey` (not `setSharedKey`) in `setSframeKey`; cryptors idempotent per (peer,kind); enables SYMMETRIC + self-healing; commit evicting OUR leaf = INACTIVE group. Reneg/new-PC re-enable ladder: `project_sframe_heal_ladder`.
- **CRITICAL: Share WebRTC reconnection = receiver-initiates, sender-catches.** `feedback_webrtc_patterns`.
- **CRITICAL: call/VC signal types are WHITELISTED in Rust** (voice_handler.rs) — unknown types silently dropped. A new one needs 3 touches: types.rs variant (`#[serde(default)]`), the send match arm, the swarm.rs dispatch arm. `feedback_mobile_call_audio_route`.
- **CRITICAL: a connected headset ALWAYS beats the loudspeaker (mobile):** "speaker on" = `AudioRoutes.preferLoudRoute()`, NEVER a raw `.speaker` override (outranks headphones, moves capture to the built-in mic); check availableInputs. `feedback_mobile_call_audio_route`.
- **CRITICAL: vc_screen_* carry `origin` (boxed StreamOrigin):** receivers key attribution/consent/SFrame (`'screen:$originator'`) on the ORIGINATOR, transport on the sender; absent = sender. `inbound_origin_ok` DROPS spoofed origins — never weaken.
- **CRITICAL: media forwarder lane (`fwd_*`, own `fwd:{id}` room):** CLIENT legs = **ZERO ice servers**, EXEMPT from Always-relay (media never touches a member's machine in ANY role). MEDIA LEGS = truth; assign trust = ORIGINATOR; feeder = SUPPLY NEVER AUTHORITY. Field iron rules: `project_media_forwarding_epic`.
- **CRITICAL: `disconnected` is NOT a hangup, and NEVER restarts ICE:** lanes HOLD it (`LinkWatchdog`, 45s); recovery REBUILDS the media session (in-place restart kills SFrame), only after `failed`; ONLY `onGiveUp` ends a call. Cameras carry a rung cap. `project_call_hold_open_resilience`
- **CRITICAL: renegotiation glare:** never drop an inbound `sdp_offer` — queue while busy + retry (`_queueRenegOffer`); camera auto-enable is STAGGERED (polite 300ms / other 1500ms). Any new reneg trigger must consider both sides acting simultaneously. `feedback_renegotiation_glare`.
- **CRITICAL: DM/VC camera codecs are VP8-ONLY** (`_constrainCameraCodecs`; anything else kills the iOS answerer); failed inbound reneg ROLLS BACK to stable; route inbound `sdp_offer` by CALL IDENTITY, never `status == active`. `project_ios_camera_black_screen_debug`.
- **CRITICAL: always `await` WebRTC disposal** (renderer/PC/stream) — unawaited leaks ~200 MB per session. Fork native: per-PC EventChannel teardown belongs in Dispose (after Dart cancels), NEVER Close. `feedback_webrtc_close_dispose_eventchannel`.
- **Screen capture:** native (WGC / ScreenCaptureKit); desktop share audio = out-of-process `screen_audio_capturer` over `0x03`; macOS SCK audio-only needs an ignored `.screen` output. `project_screen_capture`.
- **CRITICAL: Wayland share = PORTAL-FIRST:** NEVER enumerate desktop sources there; shares ride the `wayland-portal:<gen>` sentinel, same gen = silent re-share. `feedback_wayland_window_capture_sigsegv`.
- **Per-app share audio + anti-echo (Win+Linux):** window shares pass the SOURCE ID (`windowHwnd`/`--window-xid`), NEVER `pid`; per-app NEVER falls back to system; entire-screen EXCLUDEs Hollow's tree. `project_windows_per_app_screen_audio`.
- **Mobile screen share send+receive:** same `0x03` Opus pipeline both ways (`api/screen_audio.rs`); realtime Rust crates REQUIRE `[profile.dev.package.*] opt-level=3` (else fake "jitter bug"); iOS: NEVER add message types to the `rtc_SSFD` broadcast socket. `project_mobile_screen_share_send`.
- **CRITICAL: dialogs are keyboard-aware globally:** `showHollowDialog` pads every dialog by `viewInsets` — NEVER add viewInsets padding inside a builder (double-pad). `feedback_dialog_keyboard_insets`.
- **App Lock (mobile):** PIN via the Rust Argon2id flow; biometric secret in flutter_secure_storage after `local_auth` (3.x named params); lock-type marker readable BEFORE identity unlock; MainActivity MUST extend `FlutterFragmentActivity`. `project_app_lock_pin_biometric`.
- **CRITICAL: Olm key exchange is DEVICE-signed + ENFORCED** (`REQUIRE_SIGNED_KEY_EXCHANGE`): verify sig/recipient/freshness/device-in-signed-list BEFORE session creation. Relay auth re-derives peer_id from pubkey — KATs in BOTH Rust+C++. `project_signed_key_exchange_root_of_trust`.
- **CRITICAL: sig verification REJECTS, never logs;** `if sig.is_some()` IS the bypass. Verify RAW text BEFORE any clamp (4,000 CHARS ≈ 16,000 bytes non-Latin). LIVE enforces, backfill tolerates. `feedback_signature_enforcement_not_logging`.
- **CRITICAL: remote filenames via `safe_file_name()`** before any path join (an ABSOLUTE name makes `Path::join` DISCARD the base; manifest hash ≠ trust). `feedback_sender_controlled_filename_sanitization`.
- **CRITICAL: contact verification:** safety number = 60 digits from the two MASTER peer_ids (symmetric; survives reinstall + device change) — NEVER Olm keys/device ids; verified flag + alerts MASTER-keyed. New device = warn, FIRST list = baseline. `project_contact_verification_safety_numbers`.
- **Disclosure:** 6 GHSA drafts still private. **Never push a fix before release.** `project_security_disclosure_2026_07`.
- **CRITICAL: message signing is v2-ONLY:** `sign_message_versioned`; v1 verification GONE — NEVER add a fallback (downgrade oracle). Edit/delete sigs bind the row's FULL extras. New message-row paths MUST persist the SENDER's wire `order_us`; stamp via `chat_clock::next_send_stamp_us()`. `feedback_chat_clock_lamport`.
- **CRITICAL: EVERY remote-reachable store write sits behind a gate; the enumeration is wiki `security_write_gates.md` — add a row when you add an ingest path.** `project_close_all_known_holes_085`.
- **CRITICAL: link previews (#45):** receivers NEVER fetch to RENDER (inline video = explicit tap); `lp_set` re-signs, never `edited_at`; new `LinkPreviewRef` fields go in boxed `RichCard`; digest RECOMPUTED from the shipped card, never the wire. Full rules: `project_link_preview_revamp_plan`.
- **CRITICAL: message dedup is by message_id, NEVER content:** every insert pre-checks `dm/channel_message_exists(mid)`. Receive events ALWAYS emit a `duplicate` flag — never suppress emission on "row exists". `feedback_sync_dedup_watermark_events`.
- **CRITICAL: `WsEvent::Disconnected` purges sync-gating state + remote VC participants; `is_new` is NOT "a new socket"** — an unclean drop sends no `PeerLeft`, so reconnect work goes OUTSIDE it. `feedback_is_new_is_not_a_new_socket`.
- **CRITICAL: AltGr = Ctrl+Alt on Windows:** hand-rolled `isControlPressed` needs `&& !isAltPressed` (else AZERTY @/€ swallowed); `SingleActivator` immune. `feedback_altgr_ctrl_alt_shortcuts`.
- **App shortcuts REBINDABLE:** no hardcoded key checks — match `appShortcutsProvider` via `matchesEvent`; shell handler no-ops during keybind capture. `project_rebindable_shortcuts`.
- **CRITICAL: no raw `OverlayEntry` inside `SelectionArea`** — use `showDialog` with `barrierColor: Colors.transparent`.
- **CRITICAL: never construct `TextSelectionControls` in `build()`** (identity churn → app-wide selection-overlay crash); raw-OverlayEntry teardown needs a `removed` guard. `feedback_textfield_overlay_selectioncontrols`.
- **CRITICAL: `HollowToast` from non-widget code passes `overlayState:`** (`hollowNavigatorKey.currentState?.overlay`) — `Overlay.of(navKey.currentContext)` throws; run teardown BEFORE the toast. `feedback_toast_from_nonwidget_overlaystate`.
- **CRITICAL: sender side needs `FileCompleted` emit too:** any new `FileHeader`/`StoredFile` field is missing from the sender's UI unless the send path also emits it. `feedback_sender_file_completed`.
- **CRITICAL: Share-backed large files (>34 MB):** `FileHeader.share_ref` bypasses size checks in 3 places; skip `PendingFileStream` when `share_ref.is_some()`; >34 MB prompts `confirmLargeFileShare`. `feedback_share_backed_files`.
- **CRITICAL: sender stream temps (`.stream_send_*.tmp`) deleted after WS-relay sends** unless `pending_webrtc_sends` owns them; boot-time sweep mops orphans. `feedback_stream_send_temp_cleanup`.
- **Storage Manager:** caps ENFORCED via `enforce_storage_caps` on `FileCompleted`. `project_storage_manager`.
- **MLS coordinator model:** deterministic election (lowest online peer_id), server-group ops PREFER the OWNER — **COMMITTER only; epoch catch-up excludes the peer that is BEHIND** (`epoch_catchup_responder`), else a returning owner stays stale. **Commits broadcast via `broadcast_mls_commit`** (ONE SendToRoom + epoch guard), NEVER per-device loops; plaintext twin via `broadcast_crdt_op_to_members`. `feedback_owner_coordinator_mls_recovery`.
- **CRITICAL: `get_missing_file_ids()` checks DISK, not just DB** — files can exist without `completed_at`.
- **CRITICAL: public channels:** sends branch on `is_channel_public()` → plaintext signed `PublicChannelMessage` (files too). Voice NEVER public — read `effective_public()` only. FileRequest serving GATED; guest bytes ride `PublicFileHeader` against the receipt cap. `project_public_channels`, wiki `security_write_gates` §7.
- **CRITICAL: conferences are VIRTUAL SERVERS:** `conf:{id}` = WS room = MLS group = server_id (channel `"main"`); admission IS the MLS add; chat = RAM-only, NEVER persisted; guards branch on `is_conference_sid`. wiki `conferences`.
- **CRITICAL: unread counts compare MILLISECOND timestamps only** (never rowid/order_us — seen comes from a ms-sorted `.last`); `recomputeServerUnread` gated on `newMessageCount > 0`. `feedback_unread_ghost_ms_seen`.
- **CRITICAL: relay topic subscriptions are PER-SOCKET:** ws_client replays them on every reconnect; desktop's subscribe-listener microtask-defers past the selection batch (channel is written BEFORE server). `feedback_channel_topic_subscriptions`.
- **CRITICAL: fire-and-forget FFI needs `.catchError((_) {})`:** sync try/catch around an un-awaited Future catches NOTHING — rejections hit the zone crash handler. State-REGISTERING calls need a retry helper — subscribes ALWAYS via `subscribeChannelTopics()`. `feedback_ffi_fire_and_forget_catcherror`.
- **CRITICAL: context menus = ONE surface, `showHollowMenu`, opened via `ContextMenuTarget`** (`hollow_menu.dart`, both CI-guarded): dialog route, NOT an OverlayEntry; anchor via `overlayPositionOf`; builder ref = `menuRef`; dismiss by route IDENTITY. `project_issue61_context_menus`.
- **CRITICAL: the window's outer 8px are pointer-DEAD** (frameless resize border): a control hugging a window edge renders fine and never fires — inset by `kWindowEdgeDeadStrip`. Scrollbars = ONE app-wide gutter (`HollowScrollBehavior`), never a manual `Scrollbar` (double thumb). `feedback_window_edge_dead_strip`.
- **CRITICAL: channel layout = ONE write path, ONE read shape.** Writes via `ChannelLayoutNotifier.mutate` ONLY (never `updateChannelLayout`); channel LISTS render `effectiveLayoutFrom`, never the stored layout. Both CI-guarded. `feedback_one_mutation_path_per_state`.
- **CRITICAL: CRDT property changes: optimistic UI update BEFORE the fire-and-forget FFI, and NEVER a read-back right after the write returns** (set_* only queues — the read sees the PREVIOUS value; seed the cache via `applyLocalWrite`). `feedback_crdt_optimistic_update`, `feedback_crdt_read_after_write_race`.
- **CRITICAL: connection indicators read `overallConnectionProvider` ONLY** (both user bars via `connectionVisual()`): never node status (green with no internet), never who ELSE is online; sync may refine "Online", never contradict. Header `Offline` = OUR link down. `feedback_genuine_connection_status`.
- **CRITICAL: user actions visibly succeed, fail, or show busy:** mutating wrappers RETHROW — call sites await + toast failure (bare call = zone crash); slow FFI behind a button = `_busy` + spinner; success toast only AFTER the await. `feedback_ux_feedback_sweep_2026_07`.
- **Roles & permissions:** `AdminLwwReg::merge` = pure HLC LWW (authority ONLY in op_allowed/author gates); Dart reads `default_role_permissions()` FFI, never a mirror (`project_roles_design`). **Moderation trio:** enforce at send + LIVE ingest, never sync backfill; mute gates EDIT + ADD-REACTION (`project_moderation_trio`).
- **CRITICAL: channel access (#32):** Dart NEVER re-implements the access ladder — read `ChannelFfi.me_can_see/me_can_post`. ACCESS labels never self-assignable; label gates pair with an Admin+ tier stamp; grants = mute-pattern LWW, lazy expiry. `project_channel_access_labels_grants`.
- **CRITICAL: call audio:** Android mic survives backgrounding ONLY via `CallForegroundService` (mic FGS in `AudioSwitchManager.start/stop` — never remove); adaptive capture respects `setCaptureMuted` + `setCaptureServoHold`; voice-QUALITY bugs only count from a REMOTE peer. `feedback_capture_servo_mute_freeze`.
- **CRITICAL: audio-track ops (`setEnabled`/`setVolume`/dispose) = blocking signaling-thread hops:** ONLY via `runAudioTrackOp`/`HollowRunAudioTrackOp`/`HollowAudioOpQueue`; FRB TRACE loggers capped at Warn, NEVER remove. `feedback_android_audio_track_proxy_ui_freeze`, `feedback_frb_trace_logger_cap`.
- **CRITICAL: per-channel MLS subgroups:** restricted channels encrypt under their OWN group `"{server}#{channel}"` (`reconcile_subgroups_for_server`); voice SFrame from its `export_secret`; VC participants (SELF too) = ROUTABLE DEVICE ids; Dart branches on `is_self`, never id compares. `project_per_channel_mls_subgroups`.
- **CRITICAL: server-group MLS recovery:** CRDT-mutating handlers ALWAYS also broadcast the op as plaintext `CrdtOpBroadcast` (idempotent) — an MLS-only op silently drops at a skewed epoch. `feedback_owner_coordinator_mls_recovery`.
- **CRITICAL: channel visibility/posting UI reactivity:** `_refreshServerState` reloads `channelListProvider` + invalidates `serverChannelsProvider(id)` on a retry ramp; mobile chat route `loadForServer` on open. NEVER `ref.invalidate` in `initState`. `feedback_channel_visibility_posting_ui_reactivity`.
- **CRITICAL: new `CrdtPayload` variants emit `ServerUpdated` in BOTH match blocks** (`handle_envelope_crdt_op` + `handle_incoming_request`) — never fall into `_ =>` (emits `SyncCompleted`, no provider invalidation).
- **CRITICAL: received CRDT ops persisted via `insert_crdt_op` at EVERY apply site** (op_log is `skip_serializing`, state JSON alone loses history); joins send `ServerStateSnapshot` BEFORE the op log; permission checks validate `op.author`, not the sender. `feedback_crdt_sync_persistence`.
- **CRITICAL: `RoomMembers` = authoritative presence:** diff sets → `PeerDisconnected` for vanished; `PeerLeft` refreshes suspect rooms; OUR OWN leave purges the room (`WsEvent::LeftRoom`) — a stale self-left room silently blackholes targeted sends. `feedback_ws_presence_stale_rooms`.
- **CRITICAL: list rows with per-item loaded state need `ValueKey(item id)`** + a `didUpdateWidget` reload — else Flutter re-parents State across different conversations. `feedback_listview_state_reuse_keys`.
- **CRITICAL: chat lists are `reverse: true`** via shared `reversedChatList()`: newest = index 0 bottom-pinned, instant post-frame `jumpTo(0,0)` ONLY, scrolled-up reading FREEZES the display, `findChildIndexCallback` mandatory (CI-guarded). Extend the shared module, never copy. `feedback_reverse_chat_lists`.
- **CRITICAL: never wrap `SelectionArea` AROUND a scrolling message list:** under `UiScale` the selection delegate mis-locates the drag edge → clicks jump the viewport, autoscroll never stops (#35). Scope to ROWS via `selectionMustBeScopedToRows()`. `feedback_selection_area_scaled_viewport`.
- **`showHollowDialog` overlays need a `Material` ancestor** for `Text` widgets (else yellow debug underline).
- **Android:** SQLCipher needs vendored prebuilt OpenSSL 1.1.1w per-arch; target-prefixed env vars must be SYSTEM env vars (Cargo `[env]` doesn't reach cargokit); Rust TLS uses `webpki-roots`, NEVER `native-roots` (silently breaks all WSS). `feedback_android_platform`.
- **Mobile lifecycle:** `WidgetsBindingObserver` — resume: WiFi lock + rejoin rooms; pause: release.
- **Mobile UI:** `lib/src/ui/mobile/`; `MobileShell` (4-tab) below 600px; floating pills in MobileShell + MobileChatRoute stacks, NEVER `app.dart` builder; selection providers cleared in `.then()`, NOT `dispose()`. `feedback_mobile_ui_patterns`.
- **Widget tests:** `pumpHollowMobile()` mocks FFI, no device. **VERIFY UI BY DRIVING THE APP, never from source:** `scripts\ui_probe.ps1`; peer-to-peer = `scripts\fleet.ps1` (ONLY servers it creates AND deletes, wiki `fleet_probe`). Matrix `reports/FEATURE_MATRIX.md`. `feedback_verify_ui_by_driving`.
- **Forked `flutter_webrtc`** at `packages/flutter_webrtc/` (pubspec `path:`). When iterating its native C++, delete `build/windows/x64/plugins/flutter_webrtc/` first; ALWAYS `--release` if testing from the Release folder.
- **CRITICAL: Windows + Linux run SKIA, not Impeller** (`ImpellerSwitch::Disabled` / `fl_dart_project_set_enable_impeller`): Impeller render targets scale with WINDOW AREA (~189 MB/Mpx VRAM). `HollowShaderWarmUp` is gated to exactly those two — move both together. TEMPORARY. `project_desktop_skia_revert`.
- **CRITICAL: desktop libwebrtc (dll+so) is OUR patched build**, vendored at `third_party/libwebrtc/` (BUILDING.md). Shares ride `ScreenContentProfile`, NEVER hint 'motion'; encoding caps ride `addTransceiver` init `sendEncodings` (pre-neg setParameters DROPPED). `project_webrtc_engine_screenshare_research`.
- **CRITICAL: Linux window close: minimize to taskbar, never tray**; second close while minimized = quit. wlroots (Hyprland/sway) has NO minimize, so poll then arm a 2nd-press quit; never quit on `isMinimized()` false alone. `project_linux_window_fix`.
- **CRITICAL: Linux audio capture NEVER via `record`** (needs `parecord`, absent on PipeWire): mic test = WebRTC loopback, voice msgs = `LinuxPulseCapture` (libpulse ffi). `feedback_linux_mic_parecord`.
- **Linux audio enumeration:** prebuilt libwebrtc ADM reports 0 devices on pipewire-pulse → native libpulse shim (`hollowLinuxAudioDevices`). A distorted Linux mic is HARDWARE first (`amixer sget Capture`). `feedback_linux_audio_libpulse_enum_shim`, `feedback_linux_agc_clipping_distortion`.
- **CRITICAL: Linux window transparency:** set the RGBA visual at window CREATION in `my_application.cc` (before realize, guarded on `is_composited`) + FlView bg `#00000000` — an X11 visual can't swap at runtime. `feedback_linux_window_transparency_annotate`.
- **CRITICAL: Linux call stability:** every WebRTC teardown fully awaited with ownership flags (no shared-stream double-free); open V4L2 ONCE per call, toggle via `track.enabled` (never stop/dispose mid-call). `feedback_linux_thread_leak_heap_corruption`.
- **Flatpak:** `flatpak/` + `build-flatpak.sh`; requires `--socket=x11` (NOT `fallback-x11`), `--socket=session-bus`+`--own-name` (else it never launches, #59), and bundled libsecret. `feedback_flatpak_libsecret_and_vm_no_gui`.
- **CRITICAL: Windows annotation mode:** `window_manager` maximize/unmaximize only, never raw Win32 or `setFullScreen`. `feedback_annotation_window_management`.

## Semantic Memory Search (hollow-memory MCP)
- `memory_search(query)` — memory+wiki+plan/whitepaper; ALWAYS search before arguing, designing, or re-investigating. Wiki stays in sync during `/compush`; `memory_reindex()` after modifying indexed files.

## Rules
- Never commit secrets, keys, or credentials.
- Rust handles networking/crypto/CRDTs/storage; Dart handles UI/app logic/state.
- All crypto operations must use constant-time implementations.
- Ask before making architectural decisions not covered in HOLLOW_PLAN.md.
- **HOLLOW_PLAN.md is the authoritative source** for phase details, feature checklists, completion status; don't duplicate it here or in memory files.
- **HARD budget: 40,000 chars.** Entries = 1–3 lines: rule + memory pointer; war stories go in memory files.
- **SSH hosts (relay VPS, Mac, VM):** in `BUILD_GUIDE.md` (gitignored); key-only, free for checks/logs/deploys.
- **Local dev:** checks/tests/codegen run freely; Vitalik runs `flutter run -d windows`.
