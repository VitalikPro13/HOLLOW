# VoiceChannelPane -- a voice room: the stage, and its chat beside it

`lib/src/ui/chat/voice_channel_pane.dart` (rebuilt 2026-09-25, design language session 22; the shared stage, tiles and bar live in `lib/src/ui/call/`, see wiki `ui_call_surfaces`).

**Device->master collapse:** participant, camera and share ids are ROUTABLE device ids. Tiles key by them; names, avatars and ring colours resolve `deviceLinkProvider.identityOf(id)` first (`VcCallStageSource`). Speaking: remote = `vcSpeakingProvider.select(contains(device))`, you = `vcLocalSpeakingProvider` (never test the set for yourself).

## Layout

- `VoiceChannelPane` (ConsumerWidget): a 48 px stage header on the canvas (speaker icon, room name, "N people", the Chat toggle), then either `CallStage(source: VcCallStageSource(...))` when you are in this room, or `_RoomPreview` when you are not (who is there as tiles + one filled "Join voice"; empty = "Nobody's here yet" + Join voice; no bar). The channel chat is the ONE side panel (`ChannelChatPane(headerTitle: 'Chat')`, 300 wide, `surface`, `vcChatPanelOpenProvider`); a docked chat hides its own members/split buttons, and the shell hides the member panel for any selected voice channel.
- Deleted in the rebuild: the plain-chat audio-only mode, `_UnwatchedShareBanner`, the switcher pill, the self-share preview, the "Click to exit" camera focus, the 1 s overlay hide timer, `_VoiceControlsPill` (its Disconnect bypassed the conference path), `VcChatOverlay` / `_OverlaySlider`, `hideControlsPill` / `hideChatOverlay`.
- Conferences render the same `CallStage` + bar inside the meeting view (`conference_dashboard.dart _ConferenceCallArea`); Leave on the bar goes through `leaveVoiceRoom` (conference-aware). End meeting stays in the meeting header.
- Sidebar rows (`channel_sidebar.dart _VoiceParticipantRow`): 20 px avatar with `SpeakingRing.dense` in the person's colour, the name brighter while speaking, grey marks (sharing, camera, muted, deafened), the session timer on the joined room's row.

## Opt-in Watching (issue #38)

Remote shares are media-gated: the sharer only sends a `screen_offer` to peers that requested it via the targeted `screen_watch{want}` VC signal. Viewer methods on the provider: `watchScreenShare(peerId)` (optimistic `watchingScreenShares` add + focus + 20s "offer never came" timeout that reverts with a toast) and `stopWatchingScreenShare(peerId)` (closes the incoming PC, sends `want:false`, focus-repairs to another WATCHED source). `_handleScreenOffer` drops unsolicited offers; `_handleScreenState` never auto-focuses (badge must not hijack the view). Share audio rides the same gate (per-peer capture starts with the offer). ShareVolume controls gate on `isWatchingAnyShare`.

### Receiver-driven resolution capping (media forwarding step 1, 2026-08-05)

The watch payload also carries `viewer_width/viewer_height` (viewer's largest physical display via `largestDisplayResolution()`, `core/viewer_display.dart` — platformDispatcher, never MediaQuery). Sharer side: `_watcherDisplays` map per watcher; `_effectiveCapFor(peerId)` (→ `ScreenShareService.effectiveViewerCap`, orientation-normalized clamp that never raises the share cap) feeds each viewer's own `createOfferFromStream` — per-viewer PCs = per-viewer encoders. A RE-SENT `want:true` on an already-streaming viewer is a cap change: `updateResolutionCap` tries live setParameters (works since the phase-3 plugin fix), falling back to `_sendScreenShareToPeer` renegotiation on rejection. Viewer side shows a `ShareQualityChip` displaying the RECEIVED resolution live (listens to the incoming renderer; falls back to the sharer's `screen_state{quality}` label) — `ui/components/share_quality_chip.dart`. Old clients (absent fields) = no clamp.

**There is NO per-viewer "Source quality" opt-out (REMOVED 2026-08-15).** The clamp is keyed to the viewer's largest MONITOR, so it already delivers every pixel they can display; and on a forwarder branch ONE shared encoder serves many viewers, so the original "lifts the cap for that one connection only" premise no longer exists. A `source_quality` key from an older client is parsed away. On a branch the ingest cap is `max(effectiveViewerCap)` over that branch's audience, so a viewer can receive slightly MORE than its own display when a larger-display peer shares the branch — inherent to one shared encode.
