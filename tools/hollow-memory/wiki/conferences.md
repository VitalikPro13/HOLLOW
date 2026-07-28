# Conferences — Zoom-Style Rooms with MLS-Gated Waiting Room

## Overview

Ad-hoc meetings between people who share no server and no friendship. A host creates a durable **room**, shares a link, and admits knockers through a waiting room. **Admission IS the cryptography**: being let in = the host commits an MLS add; until then a joiner in the relay room holds only ciphertext. Design doc: `reports/CONFERENCES_PLAN.md`; memory `project_conferences_design`.

**The virtual-server model:** `conf:{conf_id}` is simultaneously the relay WS room code, the MLS group key, and the `server_id` fed to the untouched voice-channel machinery (channel id always `"main"` = `CONF_CHANNEL`). `server_states` never contains conf ids, so every CRDT-coupled path (sync, member fan-outs, restricted guards) skips naturally. v1 shipped + 2-machine field-tested 2026-07-13.

## Rust core (`rust/hollow_core/src/node/conference.rs`)

- Helpers: `conf_server_id(id)` → `"conf:{id}"`, `is_conference_sid`, `conf_id_from_sid`, `CONF_CHANNEL = "main"`, `derive_access_hash(conf_id, code)` = sha256("{conf_id}:{code}") hex (admission check, NOT key material).
- **Host state:** `conference_host: HashMap<conf_id, ConferenceHostState>` in the swarm loop (waiting_room flag, access_code_hash, host name/avatar-hash, `pending: HashMap<peer, ConfPendingJoin{key_package_b64}>`).
- **Start** (`handle_conference_start`): mints a FRESH MLS group (drops any previous — past attendees can't decrypt the next meeting), joins the relay room, clears stale conf voice state. **End**: broadcasts `ConferenceEnded`, leaves room, drops group.
- **Knock** (`handle_conference_request_join`): joiner joins the room, broadcasts `ConferenceJoinRequest{display_name, avatar_hash (hash only!), key_package, access_hash}`, and records a `PENDING_KNOCKS` entry (process-global static, blocklist-style; harness caveat: shared across in-process nodes).
- **Re-knock:** `reknock_if_pending` fires from the PeerJoined + RoomMembers(non-empty) arms — re-sends the request with a FRESH KeyPackage (2s throttle) so knocking on a not-yet-started meeting resolves when the host appears. Cleared on Welcome/denied/ended/leave.
- **Host gate** (`handle_inbound_join_request`): blocklist FIRST → access-hash compare (mismatch → `ConferenceJoinDenied{wrong_code}`) → `ConferenceLobbyInfo` direct (lobby banner) → auto-admit if waiting room off, else stash pending + emit `ConferenceJoinRequestReceived`.
- **Admit** (`admit_peer`): `add_member` → merge → persist → `MlsWelcome{server_id: conf sid, channel_id: None}` DIRECT (`send_message_to_peer_in_room`, never first-match lookup) → `broadcast_mls_commit` with epoch guard → local `MlsEpochChanged` (SFrame rotation). The MlsWelcome arm in swarm.rs emits `ConferenceAdmitted` for conf sids and clears the pending knock.
- **Kick** (`handle_conference_kick`): `remove_identity_leaves` → merge/persist → commit broadcast → `ConferenceKicked` courtesy signal direct. Receiver-side Dart validates by_peer_id is the known host before teardown.
- **Chat**: `ConferenceChat{conf_id, body}` = MLS application message of `{text, ts}`; RAM-ONLY both ends (never persisted, never rings). Attribution = the authenticated MLS **leaf credential** from `decrypt` (device id; Dart collapses via identityOf), NOT the WS frame sender. Send stamps ride `chat_clock::next_send_stamp_us` via the FFI.
- **Roster hygiene:** `handle_conf_room_peer_gone` (PeerLeft + RoomMembers-vanished arms) — room presence is a prereq for call presence: drops the peer from `voice_channel_participants["conf:x:main"]` and emits `VoiceChannelLeft` (live tile removal for kicked/crashed/left members whose VoiceChannelLeave raced the host's room-leave). `clear_conf_voice_state` wipes `conf:{id}:*` keys on start/end/leave (restart reuses the same key). Disconnected clears host pending lists.

## Conference-aware branches OUTSIDE conference.rs (only these)

1. `voice_handler::handle_envelope_voice_channel_join` — conf branch: membership = MLS decrypt success; channel must be `"main"`; PLUS **reply-on-join sync**: if we're already a participant, reply DIRECT with our own plaintext `VoiceChannelJoin` (a freshly-admitted member has no way to learn the pre-existing roster).
2. swarm.rs plaintext `HavenMessage::VoiceChannelJoin` guard — conf branch: sender must be in the conf group's `group_members` leaf set (only admitted peers pass; keeps phantom-participant spoofing out).
3. swarm.rs `MlsWelcome` arm — emits `ConferenceAdmitted` + clears pending knock for conf sids.
4. `message_ops::handle_envelope_channel_message` + `fetch.rs` — DROP ChannelMessage envelopes with conf sids (a modified client must never persist into a conference; live-only invariant).

## Persistence & FFI

- `conferences` table in `storage/messages.rs` (host-local rooms: conf_id PK, name, waiting_room, access_code_hash, co_hosts JSON (phase-2), broadcast_mode, created_at). CRUD: `upsert/list/get/delete_conference`.
- `api/conference.rs`: `conference_upsert` (None conf_id = new random 16-byte hex id; access_code COALESCE: None=keep/""=clear/set→hash), `conference_list/delete`, `conference_start/end`, `conference_request_join`, `conference_admit/deny/kick`, `conference_leave`, `conference_send_chat` (returns Lamport ms stamp). Room CRUD uses the long-lived `get_store()`; lifecycle rides NodeCommands.
- Events (both NetworkEvent enums + converter): `ConferenceJoinRequestReceived`, `ConferenceJoinDenied`, `ConferenceLobbyInfo`, `ConferenceAdmitted`, `ConferenceChatMessage`, `ConferenceEnded`, `ConferenceKicked`.

## Dart provider (`lib/src/core/providers/conference_provider.dart`)

- `conferenceTabOpenProvider` (Archive/Share tab pattern), `conferenceServerId(id)`, `kConferenceChannelId = 'main'`. It is one of the four exclusive centre tabs: `openTab()` calls `setShellTab(ref.read, ShellTab.conference)` and the FriendsBar button toggles it back off with `setShellTab(ref.read, null)`. NEVER write the boolean directly — the missing clears in both `_selectServer`s are what made the conference dashboard stick over a selected server (issue #28, `shell_tab.dart` + `test/shell_tab_test.dart`).
- `ConferenceState`: rooms list; active meeting (confId, isHost, lobbyStatus none/waiting/admitted/denied/inCall, denyReason, host peer/name/avatar-hash, waiting list). Meeting CHAT does NOT live here — it rides `channelChatProvider['conf:x:main']`.
- `requestJoin`: blocks during 1:1 calls; **SELF-CHECK** — own room's link → `startMeeting` instead of knocking (host handler ignores self-knocks; the lobby would hang forever). Wrong-code retry keeps lobby banner info.
- `startMeeting` → FFI start + `voiceChannelJoin('conf:x','main')`; `onAdmitted` does the same joiner-side. `_clearConfChat(confId)` = clears the RAM chat key AND `voiceChannelProvider.clearServerParticipants(sid)` — called on start/requestJoin(fresh)/end/leave/onEnded/onKicked.
- `onEnded`/`onKicked` validate `by_peer_id` against the known host via `sameIdentity` before teardown.
- `onJoinRequest` computes the Friend badge from OUR OWN friend list (identityOf collapse; no graph queries).
- event_provider: 7 dispatch cases; `conf:` guards on VoiceChannelJoined/Left so a conference join never hijacks `selectedChannelProvider`; ConferenceChatMessage feeds `channelChatProvider.receiveMessage` with message id `conf-{sender}-{ts}`.

## Chat = the screen-share drawer (ONE surface)

- `VcChatOverlay` (public, in `voice_channel_pane.dart`) packages the chevron toggle + `_OverlaySlider` + 360px `ChannelChatPane`. Conference audio-only view embeds it; video states use VoiceChannelPane's built-in overlay. NEVER a separate meeting-chat panel.
- `channelChatProvider`: `sendMessage` branches on `conf:` → `conferenceSendChat` FFI + optimistic insert (id `conf-{self}-{lamportTs}`); `loadHistory` early-returns (RAM-only, no DB, no sync request); `clearServerCache('conf:x')` wipes it.
- `ChannelChatPane` conf-gating (`_isConference`): attach/mic buttons hidden; member-panel + split-view header buttons hidden; onInfo/reactions/pins/edits/replies disabled (MLS authenticates — the Ed25519 proof dialog would read UNSIGNED); header shows a video icon + **"Ephemeral"** chip ("Meeting chat isn't stored…" tooltip).

## Desktop UI (`lib/src/ui/shell/conference_dashboard.dart`)

- Entry: FriendsBar icon between Saved Messages and Help (ONLY there — bottom-bar button removed by request). Opens via `conferenceProvider.openTab()` (canonical sibling-clear sequence).
- Views fade via the house AnimatedSwitcher pattern: rooms list (create/edit/delete/copy-link/start + **Join Meeting** dialog `showJoinConferenceDialog` — accepts either link form or a bare id) ↔ lobby ↔ denied (wrong_code → access-code prompt + retry) ↔ call.
- Lobby copy keys on hostName: null = "Waiting for the host to start the meeting" (LobbyInfo is the proof the meeting runs; re-knock delivers it); set = "waiting room for X's meeting". Host avatar collapses `identityOf(hostPeerId)` — LobbyInfo carries the DEVICE id.
- Call surface: video states embed `VoiceChannelPane(hideControlsPill: true)` + static `_ConferenceControls` bar below (the floating pill's Disconnect stranded the meeting — crash fixed by removal); audio-only = participant tile grid + the same controls + `VcChatOverlay`. Camera control paints red when active (parity with screen share).
- **`_ManageDrawer`**: left-edge mirror of the chat slider — search field, Waiting Room rows (admit ✓ / decline ✗, Friend chip, avatar via identityOf), Participants roster (speaking rings, kick with confirm dialog, host-only). Auto-opens on a knock; collapsed toggle shows a pending-count badge.

## Mobile (`lib/src/ui/mobile/mobile_conferences_route.dart`)

Entry icon in the Chats-tab header. Rooms list + create/edit + join dialog + lobby/denied states + host admit/deny list; the call pushes `MobileVoiceChannelRoute('conf:x','main', name)`. No chat on mobile — mobile VCs have no chat overlay either; conferences inherit it whenever mobile VC chat lands (same surface).

## Links & website

- `hollow://conference/<id>` + `https://hollow.anonlisten.com/join#conf=<id>` (FRAGMENT — id never in server logs). `HollowLinkType.conference` in `hollow_link_utils.dart`; `webConferenceInviteLink`; cards in both link-card renderers; DeepLinkService confirm → open tab/push mobile → `requestJoin`. Unit tests in `test/hollow_link_utils_test.dart`.
- Website `/join` page (`!hollow-website/src/routes/join/+page.svelte`) parses `#conf=` → bounces to the PATH form `hollow://conference/<id>`, copy "Joining a meeting".

## Testing

Harness guard `conference_waiting_room_admits_denies_and_chats` (test_harness.rs): knock → lobby → admit → SFrame key → authenticated chat → VC join through the envelope guard → **reply-on-join sync assertion** → **kick** → deny → wrong-code rejection. NOT covered: media/pixels, live relay.

## Phase 2+ (deferred)

Co-host ENFORCEMENT at ingest (DB field exists), broadcast mode (gated on the media-forwarding epic — only AUDIO gossip-forwards today), local RTMP ingest (OBS→localhost→ffmpeg→share track; never server-side), Flutter-web wasm guest.
