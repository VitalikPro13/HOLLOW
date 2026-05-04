# Social, Identity, and Connection Providers

Covers friends, peers, profiles, identity, per-peer connection status, invisible presence, favourite friends, local nicknames, and ICE configuration. All are Riverpod `Notifier`-based providers living in `lib/src/core/providers/`.

---

## FriendsProvider

**File:** `lib/src/core/providers/friends_provider.dart`
**Provider:** `friendsProvider` — `NotifierProvider<FriendsNotifier, Map<String, FriendInfo>>`

### State Shape

`Map<String, FriendInfo>` keyed by peer ID. Each `FriendInfo` has:

- `peerId` — the friend's peer ID
- `status` — `'pending'` or `'accepted'`
- `direction` — `'outgoing'`, `'incoming'`, or `''` (empty for accepted friends)
- `requestedAt` — epoch timestamp of original request
- `updatedAt` — epoch timestamp of last state change

Initial state is an empty map `{}`.

### Loading from DB

`FriendsNotifier.loadAll()` calls `storage_api.loadFriends()` (Rust FFI — `api/storage.rs:load_friends`, no status filter). The Rust side reads the `friends` table from SQLCipher and returns `Vec<FriendFfi>`. Dart maps each `FriendFfi` into a `FriendInfo` and replaces `state` with the full map.

Called during bootstrap in `hollow_shell.dart:_bootstrap()` after profiles and local nicknames are loaded. Also called after every friend event — the provider does a full reload rather than incremental updates.

### Request Handling

All four operations follow the same pattern: call Rust FFI network command, then `loadAll()` to refresh local state from DB.

- **`sendRequest(peerId)`** — calls `network_api.sendFriendRequest(peerId:)`. Rust saves a `pending/outgoing` row in SQLCipher and sends the request to the peer over the encrypted channel.
- **`acceptRequest(peerId)`** — calls `network_api.acceptFriendRequest(peerId:)`. Rust updates the row to `accepted`, notifies the requesting peer.
- **`rejectRequest(peerId)`** — calls `network_api.rejectFriendRequest(peerId:)`. Rust removes the pending row and notifies the peer.
- **`removeFriend(peerId)`** — calls `network_api.removeFriend(peerId:)`. Rust deletes the friend row and notifies the peer.

All methods catch and log errors without throwing, so the UI never crashes on friend operation failures.

### Friend Events (event_provider.dart dispatch)

Four `NetworkEvent` variants trigger friend state updates. All four call `friendsProvider.notifier.loadAll()`:

- `NetworkEvent_FriendRequestReceived` — incoming request from a peer
- `NetworkEvent_FriendRequestAccepted` — peer accepted our outgoing request
- `NetworkEvent_FriendRequestRejected` — peer rejected our outgoing request
- `NetworkEvent_FriendRemoved` — peer removed the friendship

On `FriendRemoved`, the event handler also clears the `selectedPeerProvider` if the removed friend was the active chat, and closes the split pane if it was showing the removed friend.

### Favourite Friends Ordering

**File:** `lib/src/core/providers/favourite_friends_provider.dart`
**Provider:** `favouriteFriendsProvider` — `NotifierProvider<FavouriteFriendsNotifier, List<String>>`

State is an ordered `List<String>` of peer IDs. When non-empty, the FriendsBar displays only these friends in this exact order. When empty, the FriendsBar falls back to showing all accepted friends.

- **Persistence:** JSON-encoded list stored in `app_settings` table under key `'favourite_friends'`. Loaded via `storage_api.loadSetting(key:)` during bootstrap (`_bootstrap` calls `favouriteFriendsProvider.notifier.load()` after friends load).
- **Mutations:** `add(peerId)` appends to end, `remove(peerId)` filters out, `toggle(peerId)` flips membership. All call `_persist()` which writes the JSON array back to `app_settings`.
- **Reorder:** `reorder(oldIndex, newIndex)` does in-place list reorder with standard remove/insert logic (adjusts `newIndex` when moving downward). Persists immediately.
- **Query:** `isFavourite(peerId)` returns `state.contains(peerId)`.

---

## PeersProvider

**File:** `lib/src/core/providers/peers_provider.dart`
**Provider:** `peersProvider` — `NotifierProvider<PeersNotifier, Map<String, PeerInfo>>`

### State Shape

`Map<String, PeerInfo>` keyed by peer ID. Each `PeerInfo` (from `lib/src/core/models/peer_info.dart`) has:

- `peerId` — the peer's Ed25519-derived peer ID
- `addresses` — `List<String>` of known relay/network addresses (merged across discoveries)
- `isEncrypted` — `bool`, `true` once an Olm/MLS session is established

Initial state is an empty map `{}`.

### PeerInfo Model

**File:** `lib/src/core/models/peer_info.dart`

Simple immutable data class with `copyWith` support. Fields: `peerId`, `addresses` (default `[]`), `isEncrypted` (default `false`).

### Peer Discovery

`PeersNotifier.addPeer(peerId, addresses)` is called from `event_provider.dart` on `NetworkEvent_PeerDiscovered`. Logic:

1. If the peer already exists, merges the new addresses with existing (using `Set` union to deduplicate, then converts back to `List`).
2. Preserves existing `isEncrypted` flag if the peer was already known.
3. Creates a new `PeerInfo` with merged addresses and replaces the map entry.

This means peers accumulate addresses across multiple discovery events without losing encryption status.

### Peer Expiry / Disconnection

Two removal paths:

- **`NetworkEvent_PeerExpired`** — peer went offline (gossip/keepalive timeout). Calls `peersProvider.notifier.removePeer(peerId)` + `invisiblePeersProvider.notifier.removePeer(peerId)` + disconnects WebRTC. Does NOT clear `selectedPeerProvider` (friends stay visible offline).
- **`NetworkEvent_PeerDisconnected`** — clean disconnect from WS room. Calls `peersProvider.notifier.removePeer(peerId)` + `invisiblePeersProvider.notifier.removePeer(peerId)` + `connectionStatusProvider.notifier.onPeerDisconnected(peerId)` + disconnects WebRTC, call, and voice channel state.

`removePeer(peerId)` creates a copy of the map, removes the entry, and replaces `state`.

`clearAll()` sets `state = {}`. Called on `NetworkEvent_RoomCleared`.

### Encryption Marking

`markEncrypted(peerId)` is called from `event_provider.dart` on `NetworkEvent_SessionEstablished`. Looks up the existing `PeerInfo`, calls `copyWith(isEncrypted: true)`, replaces the map entry.

### Online/Offline Determination

A peer is online if it exists in the `peersProvider` map (was discovered and not yet expired/disconnected). A peer is considered offline if it is NOT in the map. Friends remain visible in the UI when offline — the `selectedPeerProvider` is never cleared on peer removal.

---

## InvisiblePeersProvider

**File:** `lib/src/core/providers/peers_provider.dart` (same file as PeersProvider)
**Provider:** `invisiblePeersProvider` — `NotifierProvider<InvisiblePeersNotifier, Set<String>>`

### State Shape

`Set<String>` of peer IDs that are currently set to invisible status.

### Tracking

- **`setInvisible(peerId)`** — adds the peer ID to the set. Called from `event_provider.dart` on `NetworkEvent_PeerStatusChanged` when `status == 'invisible'`.
- **`setOnline(peerId)`** — removes the peer ID from the set. Called when `status != 'invisible'` (i.e., the peer switched back to online).
- **`removePeer(peerId)`** — removes from set. Called on `PeerExpired` and `PeerDisconnected` events (cleanup — peer is gone entirely, no longer relevant to track their visibility).

### Relationship to InvisibleModeProvider

`invisiblePeersProvider` tracks OTHER peers that are invisible. The user's OWN invisible mode is managed by `invisibleModeProvider` (in `settings_provider.dart`), which is a `Notifier<bool>` loaded during bootstrap and toggled via `network_api.setInvisible(invisible:)`.

---

## ProfileProvider

**File:** `lib/src/core/providers/profile_provider.dart`
**Provider:** `profileProvider` — `NotifierProvider<ProfileNotifier, Map<String, UserProfile>>`

### State Shape

`Map<String, UserProfile>` keyed by peer ID. Each `UserProfile` (Rust FFI struct from `api/storage.rs`) has:

- `peerId` — peer ID string
- `displayName` — user-chosen display name (can be empty)
- `status` — short status text (e.g., "Available")
- `aboutMe` — bio/about section text
- `updatedAt` — epoch timestamp of last profile update
- `avatarBytes` — **always null** (light load, blobs managed by `avatarProvider`)
- `bannerBytes` — **always null** (light load, blobs managed by `bannerProvider`)
- `twitchUsername` — linked Twitch handle

### Loading and Caching

`ProfileNotifier.loadAll()` calls `storage_api.getAllProfilesLight()` (Rust FFI — `api/storage.rs:get_all_profiles_light`). Reads all rows from the `user_profiles` table in SQLCipher **without avatar/banner BLOB columns** and returns `Vec<UserProfile>` with `avatarBytes: None, bannerBytes: None`. Dart maps them into a `Map<String, UserProfile>` keyed by `peerId` and replaces `state`.

Called during bootstrap in `hollow_shell.dart:_bootstrap()` after node start, before friends list load. This means profiles are available in memory before the FriendsBar renders.

### Single Profile Reload

`ProfileNotifier.reloadProfile(peerId)` calls `storage_api.getProfileLight(peerId:)` which queries SQLCipher for a single peer's metadata (no blobs). If found, merges it into the existing state map with spread + override: `state = {...state, peerId: profile}`. Called from `event_provider.dart` on `NetworkEvent_ProfileUpdated`. The event handler also invalidates `avatarProvider` and `bannerProvider` caches for the affected peerId.

## AvatarProvider

**File:** `lib/src/core/providers/avatar_provider.dart`
**Provider:** `avatarProvider` — `NotifierProvider<AvatarNotifier, Map<String, Uint8List>>`

Lazy avatar cache. Same pattern as `ServerAvatarNotifier`. Avatars are loaded on-demand when `HollowAvatar` mounts — calls `storage_api.getAvatar(peerId:)` which fetches only the avatar BLOB column from SQLCipher.

**Deduplication:** `_loading` Set prevents duplicate in-flight FFI calls for the same peerId.

**`invalidate(peerId)`** — removes cached entry and clears loading flag. Called from event handler on `ProfileUpdated`.

## BannerProvider

**File:** `lib/src/core/providers/banner_provider.dart`
**Provider:** `bannerProvider` — `FutureProvider.family<Uint8List?, String>`

Lazy banner loading per peer. Calls `storage_api.getBanner(peerId:)`. Used by profile card popup, DM profile header, and user settings dialog. Invalidated via `ref.invalidate(bannerProvider(peerId))` on `ProfileUpdated`.

### Profile Update Propagation

`ProfileNotifier.updateMyProfile(displayName, status, aboutMe, avatarBytes, bannerBytes)` calls `network_api.updateProfile(...)`. The Rust side:
1. Saves the profile to SQLCipher locally.
2. Broadcasts the profile to all connected peers.
3. Emits `NetworkEvent_ProfileUpdated` for our own peer ID, which triggers `reloadProfile` to update the Dart cache.

`avatarBytes`/`bannerBytes` semantics: `null` = no change, empty `Uint8List` = clear the image, non-empty = set new image.

### Display Name Resolution

Two helper functions (NOT in the notifier, exported as free functions):

**`displayNameFor(profiles, peerId)`** — Resolution order:
1. Local nickname (from `_localNicknames` static map, set by `setLocalNicknamesRef()`)
2. Profile `displayName` (if non-empty)
3. Truncated peer ID: first 8 chars + `'...'`

**`serverDisplayNameFor(profiles, peerId, {nickname})`** — Resolution order:
1. Server nickname (the `nickname` parameter, from server member data)
2. Falls through to `displayNameFor()` (local nickname > profile > truncated ID)

### Local Nicknames Integration

**File:** `lib/src/core/providers/local_nickname_provider.dart`
**Provider:** `localNicknameProvider` — `NotifierProvider<LocalNicknameNotifier, Map<String, String>>`

Purely local, never synced. Maps peer_id to a user-chosen nickname. Stored in `app_settings` table under key `'local_nicknames'` as JSON. Loaded during bootstrap via `localNicknameProvider.notifier.loadAll()`.

A static reference `_localNicknames` in `profile_provider.dart` is kept in sync via `setLocalNicknamesRef()`, called twice:
1. During bootstrap after `loadAll()` completes.
2. In the shell's `build()` method via `ref.watch(localNicknameProvider)` to stay reactive.

This avoids passing `localNicknameProvider` state through every `displayNameFor()` call site.

---

## IdentityProvider

**File:** `lib/src/core/providers/identity_provider.dart`
**Provider:** `identityProvider` — `NotifierProvider<IdentityNotifier, IdentityState>`

### State Shape

`IdentityState` is an immutable class with `copyWith`:

- `peerId` — `String?`, the Ed25519-derived peer ID (format: `12D3KooW...` base58-encoded multihash)
- `mnemonic` — `String?`, the 24-word BIP-39 phrase. Only present on FIRST creation. `null` on subsequent loads.
- `isLoaded` — `bool`, `true` once identity load succeeds
- `error` — `String?`, error message if load/restore failed

Initial state: all `null`, `isLoaded = false`.

### Startup Flow

`IdentityNotifier.load()` is called early in `hollow_shell.dart:_bootstrap()`:

1. **Check existing identity:** Before `load()`, bootstrap calls `storage_api.hasIdentity()` to check if `identity.key` exists on disk.
2. **First launch:** If no identity exists, shows the welcome dialog. User can create new or restore from mnemonic/backup.
3. **Load or create:** `load()` reads `identityServiceProvider` (thin wrapper around Rust FFI) and calls `identityService.loadOrCreateIdentity()`.
4. **Rust side (`identity/keys.rs:load_or_create_identity`):**
   - If `identity.key` file exists at `~/.hollow/identity.key` (or `%APPDATA%/hollow/identity.key`): reads protobuf-encoded keypair, returns `IdentityData` with `mnemonic: None`.
   - If no file: generates 256-bit entropy via `getrandom`, creates BIP-39 mnemonic (24 words), derives Ed25519 keypair via `NativeKeypair::from_mnemonic()` (first 32 bytes of BIP-39 seed), saves keypair to disk, returns `IdentityData` with `mnemonic: Some(phrase)`.
5. **Open message store:** After identity loads, `storageService.openMessageStore()` opens the SQLCipher database (keyed from the identity).
6. **State update:** Sets `peerId`, `mnemonic` (if new), `isLoaded = true`.
7. **Mnemonic dialog:** If `mnemonic` is non-null (first creation), bootstrap saves it to DB via `storage_api.saveMnemonic()` then shows `MnemonicDialog` for user backup.

### Mnemonic Availability

- **First-time:** `mnemonic` is non-null. Displayed once in `MnemonicDialog`. Saved to DB for later retrieval (user can view it again in settings).
- **Restored from mnemonic:** `restoreFromMnemonic(phrase)` calls `identityService.restoreIdentityFromMnemonic(phrase:)`. Rust parses the mnemonic, derives the keypair, saves to disk, returns with `mnemonic: Some(phrase)`.
- **Subsequent loads:** `mnemonic` is `null`. The keypair file on disk does NOT contain the mnemonic — it's a one-time backup responsibility.

### Peer ID Derivation (Rust)

**Files:** `rust/hollow_core/src/identity/native_identity.rs`, `rust/hollow_core/src/identity/keys.rs`

1. BIP-39 mnemonic (24 words, 256-bit entropy) is generated or parsed.
2. `Mnemonic::to_seed("")` produces 64-byte seed (empty passphrase).
3. First 32 bytes become the Ed25519 `SigningKey` (via `ed25519-dalek`).
4. Peer ID is derived from the public key via:
   - 36-byte protobuf public key encoding: `[0x08, 0x01, 0x12, 0x20, ...32_byte_pubkey]`
   - Identity multihash wrapping: `[0x00, 0x24, ...36_byte_protobuf]` (code 0x00 = identity, length 36 = 0x24)
   - Base58 encoding with Bitcoin alphabet: produces `12D3KooW...` string

This is backward-compatible with libp2p's PeerId format. The keypair is stored on disk in protobuf encoding: `[0x08, 0x01, 0x12, 0x40, secret(32), public(32)]` (68 bytes).

---

## ConnectionStatusProvider

**File:** `lib/src/core/providers/connection_status_provider.dart`
**Provider:** `connectionStatusProvider` — `NotifierProvider<ConnectionStatusNotifier, ConnectionStatusState>`

### State Shape

`ConnectionStatusState` is immutable, contains:

- `peers` — `Map<String, PeerConnectionStatus>` keyed by peer ID
- `relayStatus` — `RelayConnectionStatus` enum

### PeerConnectionStatus

Per-peer status object with:

- `peerId` — peer identifier
- `stage` — `PeerConnectionStage` enum: `dialing`, `connected`, `keyExchange`, `encrypted`, `failed`
- `method` — `String?`, connection method descriptor (preserved across stage transitions)
- `detail` — `String?`, sub-stage detail (e.g., `'fetching_prekey'`, `'key_request_sent'`, `'session_created'`)
- `failReason` — `String?`, why connection failed
- `lastUpdated` — `DateTime`, when this status was last changed

The `label` getter returns a human-readable string per stage:
- `dialing` -> `'Connecting...'`
- `connected` -> `'Connected'`
- `keyExchange` -> depends on `detail`: `'key_request_sent'` -> `'Requesting keys...'`, `'session_created'` -> `'Session created'`, default -> `'Encrypting...'`
- `encrypted` -> `'Encrypted'`
- `failed` -> `'Connection failed'`

### RelayConnectionStatus

Enum: `disconnected`, `connecting`, `connected`, `reconnecting`. Updated via `onRelayStatusChanged(status)` which maps string values from Rust events to enum variants. The `relayLabel` getter produces human-readable text for the dashboard.

### Connection Stage Transitions (event mapping)

**Guard:** All `onPeer*` and `onKeyExchange*` methods check if the peer is already at `PeerConnectionStage.encrypted` and skip the update if so. This prevents downgrading a fully-encrypted peer's status.

1. **`NetworkEvent_PeerDiscovered`** -> `onPeerConnected(peerId)`:
   Sets stage to `connected`. Preserves existing `method` if the peer was already tracked.

2. **`NetworkEvent_KeyExchangeStarted`** -> `onKeyExchangeStarted(peerId)`:
   Sets stage to `keyExchange`, detail to `'fetching_prekey'`. Creates a new `PeerConnectionStatus` if the peer wasn't tracked yet.

3. **`NetworkEvent_KeyExchangeProgress`** -> `onKeyExchangeProgress(peerId, stage)`:
   Updates stage to `keyExchange`, detail to the `stage` string from Rust (e.g., `'key_request_sent'`, `'session_created'`). Creates status if not yet tracked.

4. **`NetworkEvent_SessionEstablished`** -> `onSessionEstablished(peerId)`:
   Sets stage to `encrypted`. Preserves existing `method`. This is the terminal happy-path state.

5. **`NetworkEvent_PeerDisconnected`** -> `onPeerDisconnected(peerId)`:
   Removes the peer entirely from the `peers` map.

### Automatic Cleanup

A `Timer`-based cleanup mechanism runs every 5 seconds (scheduled by `_scheduleCleanup()`):

- **Failed entries** expire after 10 seconds (`_failedExpiry`)
- **Dialing entries** expire after 30 seconds (`_dialingExpiry`)

`_runCleanup()` iterates all peers, removes stale entries, then reschedules itself if there are still `activePeers` (peers in `connected` or `keyExchange` stage). The cleanup timer is cancelled on provider dispose.

### Active Peers Filtering

`ConnectionStatusState.activePeers` returns only peers in `connected` or `keyExchange` stages — excludes `dialing` (routine rebootstrap noise) and `failed` (auto-expires). Used by UI to show meaningful connection activity.

### State Mutation Helpers

- `copyWithPeer(peerId, status)` — returns new state with one peer added/updated
- `removePeer(peerId)` — returns new state with one peer removed
- `copyWithRelay(status)` — returns new state with updated relay status

---

## IceConfigProvider

**File:** `lib/src/core/providers/ice_config_provider.dart`
**Provider:** `iceConfigProvider` — `NotifierProvider<IceConfigNotifier, Map<String, dynamic>>`

### State Shape

`Map<String, dynamic>` representing a WebRTC ICE configuration, with key `'iceServers'` containing a list of server entries. Each entry has `'urls'` (and optionally `'username'`, `'credential'` for TURN).

### Initial State (STUN-only fallback)

On `build()`, state is immediately set to STUN-only config (covers ~85-90% of peers):
```
{
  'iceServers': [
    {'urls': 'stun:relay.anonlisten.com:3478'},
    {'urls': 'stun:stun.cloudflare.com:3478'},
    {'urls': 'stun:stun.l.google.com:19302'},
  ]
}
```

TURN credential fetch is kicked off asynchronously during `build()`.

### TURN Credential Fetching

`_fetchTurnCredentials()` makes an HTTP GET to `https://relay.anonlisten.com/turn-credentials`:

1. Uses `HttpClient` with 5-second connection timeout.
2. Expects HTTP 200 with JSON body: `{ "username": "...", "password": "...", "uris": ["turn:...", ...] }`.
3. **Critical:** Each TURN URI becomes a SEPARATE `iceServer` entry. This is required because `flutter_webrtc`'s native C++ `CreateIceServers` has a single `uri` field per `IceServer` struct — a list of URLs gets overwritten to only the last one.
4. Final state includes STUN servers (own coturn + Cloudflare + Google) plus individual TURN entries with credentials.
5. Logs to `hollow_debug.log` via `network_api.logFromDart()`.

### 50-Minute Auto-Refresh Cycle

TURN credentials from coturn last 1 hour (HMAC-SHA1 time-limited). After a successful fetch:
- Cancels any existing timer.
- Schedules `_fetchTurnCredentials()` again in 50 minutes (`_kRefreshInterval`).

On fetch failure:
- Cancels any existing timer.
- Retries in 30 seconds.

Timer is cancelled on provider dispose via `ref.onDispose()`.

### Consumption by WebRTC Services

The `iceConfigProvider` state is `ref.watch()`ed or `ref.read()` by WebRTC services when creating `RTCPeerConnection` instances for:
- Voice calls (1:1 DM calls)
- Voice channels (multi-peer)
- File transfer data channels
- Screen share connections

These services pass the map directly as the RTCConfiguration to `createPeerConnection()`.

### Share-Specific ICE Configs

Two additional providers for Share (Phase 7A) traffic that MUST NOT use TURN:

**`shareIceConfigProvider`** — `Provider<Map<String, dynamic>>` (simple computed, not a Notifier). Returns a const STUN-only config. Used for `RTCPeerConnection` calls whose room ID begins with `share:`. Rationale: Share traffic must not consume relay TURN bandwidth reserved for messaging and voice.

**`streamIceConfigProvider`** — `Provider<Map<String, dynamic>>`. Delegates to `ref.watch(shareIceConfigProvider)`. Used for hidden Share connections (video streaming, large files). Also STUN-only.
