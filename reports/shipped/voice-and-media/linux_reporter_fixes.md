# Linux reporter fixes, 2026-09-08

The patch is ready for a two-machine test. The Linux build is on `hollowvm` at `/home/jabun/Documents/HOLLOW/build/linux/x64/release/bundle/hollow`. Rebuild the Windows client too, because the remote-track lookup and volume-popup fixes affect that side of the call.

I read `tmp3.txt`, `reporter_debug.log`, and `reporter_crash.log`, searched hollow-memory, and checked the relevant Claude Code notes against the current code. No commits or releases were made.

| Finding | Change |
| --- | --- |
| The headset picker supplies PulseAudio names, but selection asks the WebRTC device enumerator. On the VM, PulseAudio sees both devices while WebRTC lists none. | Linux selection now routes existing and future WebRTC audio streams through libpulse. An instance marker plus PID keeps separate Flatpak instances apart. System defaults are not changed. |
| Audio enumeration could wait indefinitely, and the zero-device capture path read uninitialized device-name buffers. | Enumeration and connection waits have monotonic deadlines; device-name buffers are initialized and the invalid default-device lookup is skipped. |
| The crash log shows a camera capture returning no video tracks, followed by `.first` throwing. | Empty capture is disposed, the camera stays off, and another attempt can run. Synthetic remote-video attachment is awaited so its failures reach cleanup. |
| The crash log repeatedly calls `setState` on a disposed inline call panel while dragging volume. | The volume control uses the shared menu route and its own provider reference; updates to the old panel check whether it is mounted. |
| Native lookup only searched remote streams. Unified Plan can deliver a track without a stream. | Remote tracks are registered directly, allowing volume and renderer operations to resolve them. |
| The reconnect bursts contain `SecretReuseError`. The message generation was already consumed. | Typed replay detection skips these frames without triggering sync or group eviction. Other decryption errors retain recovery. |
| Voice-channel signaling used an arbitrary shared room. | Targeted offers, answers, and ICE now use the server's room explicitly. |
| A late progress tick could reconstruct a completed streamed download and lose completion and metadata. | Completed transfers ignore progress ticks; active progress updates preserve metadata. |
| Device linking had neither an offline gate nor a waiting deadline. | Link is disabled while offline; unanswered requests fail after 60 seconds. Progress cancels that timer, and a canceled attempt's late failure cannot fail its retry. |

The replay classification follows OpenMLS's [secret-tree persistence test](https://docs.rs/crate/openmls/0.9.0/source/src/group/mls_group/tests_and_kats/tests/secret_tree_persistence.rs). The Linux instance marker uses libpulse's [environment property support](https://github.com/pulseaudio/pulseaudio/blob/master/src/pulsecore/proplist-util.c).

Validation passed:

- 60 Dart tests covering linking, camera capture, transfer completion, file cards, and audio routes.
- Three Linux Dart tests checking microphone-selection ordering, missing-device failure, and camera-only capture.
- 12 Rust tests covering MLS replay, fresh-message decryption, and voice-channel signaling/reconnection. Replaying consumed ciphertext over several seconds leaves both peers at the same MLS epoch.
- Native Linux tests covering existing and future playback/capture, a foreign client with a colliding PID, missing devices, restoring the default output, and an unresponsive audio server.
- Linux plugin compilation and a full Linux release build. The bundle contains the patched Rust library and WebRTC plugin.
- Analysis of every changed Dart file is clean. Repository-wide analysis reports 110 warnings/notices outside the changed files, with no errors.

For the manual test, select the Linux microphone and headset, then test server voice in both directions. Try camera on/off with and without a camera present. Share a screen with audio, stop it, and accept another call. Keep the volume menu open while switching away from the call panel, then drag it. Finally, transfer the crash log again and link a device using a fresh code.

The logs do not establish one cause for every reported symptom. MLS decrypts successfully during the silent voice-channel attempts, while outgoing call offers receive no visible answers. Explicit room routing removes a defect in that path, but the other machine's debug log is needed if silence persists. Screen-audio capture produces non-silent packets and stops cleanly in this log; remote share-audio playback and the reported hard freezes still need the two-machine test. The stuck crash-log transfer itself is not present in the supplied debug log, so the completion-race fix needs confirmation against that reproduction. There are no device-link trace lines to verify the original linking failure end to end.

# Laptop fleet verification, 2026-09-09

The patch above was tested on Vitalik's real Ubuntu laptop (GNOME on X11) with the fleet, which gained a Linux backend for this (`scripts/fleet.ps1`, wiki `fleet_probe`). Two real instances, fresh identities, the real relay. What the day found, in the order it mattered:

| Finding | Evidence | Change |
| --- | --- | --- |
| Calls connected with no audio and 10 to 20 s freezes. The instance that had closed a PeerConnection before the call (the polite side of the data-channel glare) sent 0 audio packets; the other sent 250 per 5 s. | libwebrtc's own log: `Close` → `WebRtcVoiceEngine::Terminate` → audio module `Terminate` → `Init` again → `audio_device_pulse_linux.cc: failed to activate recording`. The engine's connection context terminates the audio module when its last PeerConnection dies and re-initialises it for the next one; the PulseAudio module does not survive that. | `flutter_webrtc_base.cc` creates one PeerConnection on Linux at plugin construction and never closes it. Three consecutive calls in both directions then carried audio on both sides with no stall. |
| libwebrtc logged nothing anywhere, so the failure above was invisible. | Its log sink was never installed, and the plugin's `initialize` call replaced any sink with severity "none". | A stderr sink from plugin construction (`HOLLOW_WEBRTC_LOG` widens it), `initialize` no longer downgrades it, and `WebRtcNativeLog` forwards warnings into hollow_debug.log on desktop. |
| Pressing Play on a received video killed the process. | `/var/log/kern.log`: `mdk.vdec0@...: segfault at 0 ip 0` on Sep 8 and again on the fleet. A null function pointer in mdk's hardware decode path on an NVIDIA laptop without libnvcuvid. | `registerVideoBackend()` gives fvp software decoders on Linux; `main()` and the probe share it. Play now brings up the player. |
| Every Rust log line panicked once stderr lost its reader; the node died while the window stayed up. | `PanicException(failed printing to stderr: Broken pipe)` from `hollow_log!`, then `Failed to send command: channel closed` on every call. The app ignores SIGHUP and SIGPIPE, so a closed terminal produces the same state for a user. | `hollow_log!` writes with `writeln!` and ignores errors; the three production `eprintln!` in `storage/messages.rs` go through it. |
| Server voice channel. | `voice_channel.json` (rung 3): both peers in a new voice channel for 15 s, SFrame keys set, ICE direct, PipeWire capture and playback streams on both instances, leave and delete clean. | No change needed beyond the anchor connection. |

Verified on the laptop: `friend_dm` (39 s), three DM calls both ways with audio both ways, the video Play tap, `voice_channel` (1:31). Windows release build compiles with the plugin changes.

Not verified here: a Linux to Windows call (the reporters' topology; the Windows side never had the failure), device linking with a fresh code, the stuck 99.6 KB transfer, screen share with audio. Hardware video decoding on Linux stays off until a fleet run proves a path. The proper fix for the audio module re-init lives in libwebrtc itself and needs a rebuild of the vendored engine.

# Verification, 2026-09-10

Three things were checked against the reporter's log and the fleet, with the laptop off.

## The MLS failures were replays, not a crypto fault

All 109 `SecretReuseError` lines in `reporter_debug.log` follow a frame from the relay's catch-up ring, and every one sits in the second after a restart. The client asks the ring for its watermark age plus a 30-minute overlap, so the relay replays half an hour of frames the client had already decrypted before it restarted, and OpenMLS refuses a consumed generation. The frames that were new decrypted normally (3 and 14 per restart). Both bursts fit inside one second, below the 3 s sustained window, so no group was ever dropped and no epoch moved. The cost before the fix was log noise, the burst warnings and one throttled sync request. The `decrypt_fresh` change in de1f179 returns before any of that, and the two tests behind it pass. The next log from the reporter should carry zero of these lines. These failures explain none of the audio symptoms. Those were the audio module re-init below.

## The audio module defect is fixed in the engine

`AudioDeviceLinuxPulse::Terminate()` sets `quit_` and `Init()` never clears it, so every audio thread spawned by a later init exits on its first wake and each stream start times out at 10 s. Upstream WebRTC main still has the bug. A small harness (`third_party/libwebrtc/adm_probe/`) reproduced it on the build VM: first cycle 21 ms and 16 ms, second cycle 10010 ms and 10008 ms with the reporter's exact log lines. With the one hunk in `hollow-pulse-reinit.patch` three cycles start in 7 to 8 ms. `libwebrtc.so` was relinked from the same tree and vendored; exports, linked libraries and section sizes match the previous binary. The anchor connection stays. The fleet run with the anchor disabled still needs the laptop.

## Device linking works and everything syncs afterwards

`scripts/fleet_device_link.ps1` walks the whole journey on two fresh Windows instances plus a friend: code shown, code entered, data sent, stash, the app's own relaunch, then the linked device holds the same master, the server with its history, the friend and the DM rows, and both devices list two devices. After the link, a DM and a channel post from the friend reach both devices, and a post or DM from the new device reaches the friend and the sibling. 14 gates green, then the two refusal gates (offline, 60 s unanswered). By hand, a Windows master linked an iOS Simulator and an iOS master linked a Windows instance, with the same result in both directions, including the new device alert on the friend's side. The reporter's stuck link is therefore not reproducible on a clean identity. Their case needs a log from the linking device.

Found on the way and not yet decided: the "Device linked" view said new server messages would arrive "once multi-device servers ship", which the journey disproves (rewritten); the offline Link button is disabled at 40 percent opacity, which is the design system's convention; and the mnemonic pull path (`pullFromSibling`) has no caller, so its failure copy never renders.

Issue #71 (voice channels missing visibility, who can post and temporary access in the mobile server settings) is fixed and verified by screenshot on desktop, on the mobile settings list and on the long-press sheet. Rust never consults the posting gate for a voice channel, so who can post is now text only on every surface.
