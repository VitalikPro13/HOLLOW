# FFI Share, Identity, Twitch, Updater, and Archive API

Covers the remaining `api/` FFI modules that bridge Dart to Rust for file sharing, identity/keypair management, Twitch OAuth, application updates, and cryptographic archive export/import. All functions are `#[frb]`-annotated for flutter_rust_bridge codegen.

## Share API (`api/share.rs`)

Phase 7A file-sharing surface. Every function except `share_decode_link` and `evict_vault_cache` pushes a `NodeCommand` into the swarm event loop via `cmd_tx.send()` and returns immediately. Results stream back to Dart via `watch_network_events()` as `Share*` network events.

### Command dispatch pattern

All share commands follow an identical lock-send pattern:
1. `get_node()` acquires the global `Mutex<Option<RunningNode>>`.
2. Extracts the `cmd_tx` (tokio mpsc sender) from the running node state.
3. `get_runtime().block_on(cmd_tx.send(NodeCommand::Share*))` to dispatch.
4. Returns `Ok(())` immediately; the swarm event loop processes asynchronously.

### `share_decode_link(link: String) -> Result<ShareLinkInfo, String>`

Pure synchronous helper with no I/O. Delegates to `share_handler::decode_link()`. Returns `ShareLinkInfo { root_hash: String, room_id: String }`. The link format is `hollow://share/{base64url}` where the payload is `[version:1][root_hash:32][key:32]` (65 bytes, URL_SAFE_NO_PAD base64). The `room_id` is `"share:{root_hash_hex}"` used as the relay room identifier.

### `share_create_from_file(source_path: String) -> Result<(), String>`

Sends `NodeCommand::ShareCreate { source_path }`. The swarm event loop builds a manifest from the local file, encrypts every chunk with a fresh random AES-256-GCM key (256 KiB chunks matching `ws_stream_transfer` framing), persists the share row in SQLCipher, writes the encrypted stream to `~/.hollow/shares/{root_hash}.{ext}`, joins the swarm relay room, and starts seeding. Emits `NetworkEvent::ShareCreated { root_hash, link, file_name, total_size }` on success or `ShareFailed` on error.

### `share_open_link(link: String) -> Result<(), String>`

Sends `NodeCommand::ShareOpenLink { link, server_id: None, context_type: None }`. Decodes the share link, persists a placeholder row, joins the swarm relay room, and queues a manifest request. Emits `NetworkEvent::ShareManifestReady` when the manifest arrives from a seeder. This is the first step for a receiver -- download does not begin until `share_start_download` is called.

### `share_start_download(root_hash, save_dir, link, sequential: bool) -> Result<(), String>`

Sends `NodeCommand::ShareStart { root_hash, save_dir, link, sequential }`. Called after `ShareManifestReady`. When `sequential` is true, chunks are fetched in order (0, 1, 2, ...) for progressive video streaming instead of rarest-first order. Emits `ShareProgress` events during download and `ShareCompleted` when finished.

### `share_cancel(root_hash: String) -> Result<(), String>`

Sends `NodeCommand::ShareCancel { root_hash }`. Stops an in-flight download but keeps the partial file and bitmap on disk so that a subsequent `share_start_download` resumes from where it left off.

### `share_set_seeding(root_hash: String, seeding: bool) -> Result<(), String>`

Sends `NodeCommand::ShareSetSeeding { root_hash, seeding }`. Toggles seeding for a completed share. When enabled, the node serves chunk requests to other peers in the swarm room.

### `share_remove(root_hash: String, delete_file: bool) -> Result<(), String>`

Sends `NodeCommand::ShareRemove { root_hash, delete_file }`. Drops the share entry from SQLCipher. If `delete_file` is true, also unlinks the on-disk file (including partial downloads).

### `share_start_from_ref(root_hash, key_hex, save_dir, sequential, server_id, context_type) -> Result<(), String>`

Used when a `FileHeader` carries a `ShareRef` (hidden share-backed large files >34 MB). Reconstructs a share link from raw `root_hash` (32 bytes hex) + `key_hex` (32 bytes hex) via `share_handler::encode_link()`, then sends `NodeCommand::ShareOpenLink` with the synthesized link and optional `server_id`/`context_type` for context tracking. Validates both hex strings are exactly 32 bytes. This is the receiver-side entry point for share-backed channel files.

### `share_list() -> Result<(), String>`

Sends `NodeCommand::ShareList`. The swarm enumerates all persisted shares from SQLCipher and emits `NetworkEvent::ShareList { entries: Vec<ShareEntryRef> }` back to Dart.

### `evict_vault_cache(exempt_paths: Vec<String>) -> Result<u64, String>`

Synchronous function (not a NodeCommand). Calls `vault::pipeline::evict_cache_if_needed()` with `VAULT_CACHE_CAP` (1 GB = 1,073,741,824 bytes). Evicts LRU files from `~/.hollow/vault_cache/` that exceed the cap, skipping any paths in `exempt_paths` (e.g., currently playing video). Returns bytes freed. Runs every 30 minutes from the Dart side.

### `share_keep_and_seed(root_hash: String) -> Result<String, String>`

"Keep & Seed" action for share-backed video/file cards. Copies the completed file from `vault_cache` to `~/.hollow/files/{filename}`, deletes the cache copy, updates the share's `disk_path` in SQLCipher via `update_share_disk_path()`, sets seeding to true via `set_share_seeding()`, and sends `NodeCommand::ShareSetSeeding` to the swarm. Returns the new file path string. Operates in two phases: first acquires the message store lock for DB + filesystem operations, releases it, then acquires the node lock to dispatch the seeding command.

### Share link format (from `share_handler.rs`)

- Scheme: `hollow://share/`
- Payload: `[LINK_VERSION:u8=1][root_hash:32 bytes][key:32 bytes]` = 65 bytes total
- Encoding: base64url no-pad
- Room ID derived as: `"share:{hex(root_hash)}"`
- Chunk size: 262,144 bytes (256 KiB), matching `ws_stream_transfer` framing
- Encryption: AES-256-GCM per chunk, nonce derived as `[0;4] || chunk_index_be:8` (12 bytes)

### NetworkEvent variants for Share

- `ShareCreated { root_hash, link, file_name, total_size }` -- share created and seeding started
- `ShareCreatedHidden { root_hash, key_hex, file_name, total_size }` -- hidden share (no link URL, used for channel file backing)
- `ShareManifestReady` -- manifest received from seeder, ready to start download
- `ShareProgress` -- chunk download progress
- `ShareCompleted` -- download finished
- `ShareFailed` -- error during any share operation
- `ShareList { entries: Vec<ShareEntryRef> }` -- response to `share_list()`

## Identity API (`api/identity.rs`)

Manages Ed25519 keypair creation, loading, and restoration. The keypair is the user's cryptographic identity -- the peer_id (derived from the public key) is the permanent user identifier across all of Hollow.

### FFI struct: `IdentityInfo`

```
pub struct IdentityInfo {
    pub peer_id: String,
    pub mnemonic: Option<String>,  // Only present on first creation
}
```

### `load_or_create_identity() -> Result<IdentityInfo, String>`

Primary entry point called during app startup. Delegates to `identity::load_or_create_identity()` in `identity/keys.rs`. Detects identity file format: plaintext protobuf (68 bytes, header `0x08 0x01 0x12 0x40`) or HKEYV1 encrypted (119 bytes, header `HKEYV1`). If encrypted, decrypts via session wrapping key (set by `unlock_identity()`). If no file exists, generates a fresh identity.

### `generate_new_identity() -> Result<IdentityInfo, String>`

Force-generates a fresh identity, replacing any existing one. Same flow as the creation path in `load_or_create_identity()`: 32 bytes entropy, BIP-39 mnemonic, keypair derivation, save to `identity.key` (encrypted if session key active). Always returns the mnemonic. Used for identity reset.

### `restore_identity_from_mnemonic(phrase: String) -> Result<IdentityInfo, String>`

The in-app phrase restores (key missing, identity locked, hardware key gone). Same path as `welcome_restore`'s No branch without the kept-data check, the mark or the keychain default: `identity::keys::restore_with_phrase(.., Admit, false)`. Returns NO mnemonic (0.14.3). Errors are the approved copy ("A recovery phrase is 24 words. This one has {n}." and the word and checksum lines).

### `welcome_restore(phrase, mode: WelcomeRestoreMode, check_kept) -> Result<RestoreOutcome, String>` (0.14.3, #155)

Welcome's "Use your recovery phrase". `Admit` (No: nobody else has the old device) or `Recover { lost_since_ms }` (Yes, or not sure). Order: `parse_phrase` (exactly 24 English words, lowercased, single-spaced; errors `phrase_words:{n}`, `phrase_word:{i}` from 1, `phrase_checksum`, which Dart maps to its copy) -> `finish_wipe_before_a_new_identity` -> `refuse_while_not_ready` -> with `check_kept`, the read-only kept-folder probe (`KeptMatch { path, profile_name: None }` / `KeptNoneOpens`, nothing lands) -> a gone identity's `identity.duress` zeroed -> `land_identity_key` -> open the store, held roster = stored merged with an unimported bootstrap -> KEEP the device already there (Admit only: decodes, not the master, counted, MLS credential names it) or MINT (after `forget_device_secrets`) -> sign through `api::roster::sign_restore` (`admit_by_phrase` / `recover`, dated by `phrase_time`; Yes on an empty install signs `no_wait`) -> `welcome_restore` mark when minted -> `identity.device` last -> the keychain default inside (`Restored { locked_to_keychain }`; skipped while a `.locked` pair exists). Trap: Dart never calls `protect_new_identity_by_default` on this path. Rules: wiki `security_write_gates` §80.

### Phrase-restore companions (0.14.3)

`api::roster::welcome_restore_state()` (the Home card: `{at_ms, branch, empty, no_wait}`, `None` unless THIS device was minted by a Welcome restore within 30 days); `may_set_aside_this_identity()` / `set_aside_this_identity()` (the typo retry: only while no friend accepted and no server holds us; writes `set_aside.pending` = `{digest, relay, at_ms}`, the move runs in `settle_relink` at the next launch only: a mark older than 10 minutes, one met while another step is unfinished, or a move that fails is dropped); `api::recovery::take_set_aside_failure()` (true once after a set-aside that did not run, read by the Home card); `api::recovery::set_aside_welcome()` (`Option<SetAsideWelcome { relay }>`, the relay the set-aside identity used) and `clear_set_aside_welcome()`; `RosterStatus.too_early` (`"admit"`/`"recover"`, from this device's own last phrase statement a base dated at most 10 minutes later outdated; any later base reads `dropped_by_recovery_at_ms` instead), `too_early_lost_since_ms`, `dropped_by_recovery_at_ms` (a device that counted once, left out by a recovery typed elsewhere).

### `unlock_identity(password: Option<String>) -> Result<IdentityInfo, String>`

Must be called before any identity/DB operation. Reads `identity.key`, detects format. For plaintext: auto-wraps with DPAPI/Keychain if available. For encrypted: if `flags=0x01` (password), requires password param and derives wrapping key via Argon2id. If `flags=0x02` or `0x03` (OS keychain), keychain unlock goes through `keychain_key_that_decrypts()` (2026-08-05, issue #47→#27 fix): it fetches ALL stored candidates via `platform_keystore::retrieve_key_candidates()` (per-profile slot → legacy machine-global slot → Windows DPAPI blob), tries each against `decrypt_identity` on the actual file, and re-stores the verified winner to every slot (self-heal). NEVER trust a single slot unverified — with multiple profiles the legacy slot routinely holds the OTHER profile's key, and the old unverified path funneled users into mnemonic recovery → device-key rotation → MLS identity/groups discarded → SFrame garbage audio. Stores wrapping key in session static.

### `lock_identity() -> Result<(), String>`

Zeros and clears the session wrapping key. All subsequent identity operations fail until `unlock_identity()` is called again.

### `enable_password_protection(password: String) -> Result<(), String>`

Encrypts identity with Argon2id-derived key from password. Sets `flags=0x01`. Deletes any existing DPAPI/Keychain key. Password required on every app launch.

### `change_password(old_password: String, new_password: String) -> Result<(), String>`

Verifies old password, re-encrypts with new. Keeps `flags=0x01`.

### `remove_password_protection(password: String) -> Result<(), String>`

Verifies password. If OS keychain available: transitions to `flags=0x02` (keychain-only, silent unlock). Otherwise writes plaintext.

### `get_identity_protection_status() -> Result<ProtectionStatus, String>`

Returns `{ is_encrypted, has_password, has_os_keychain, os_keychain_available }`. Used by Settings UI.

### `is_identity_unlocked() -> Result<bool, String>`

Whether the session wrapping key is set.

### `settle_keychain_move() -> Result<(), String>` (macOS, 0.14, HOL-SEC-187)
Once per start, after the pending wipe and `settle_relink` and before the launch unlock or any prompt: moves every Hollow key out of the login keychain (and out of the app-ID group once the keys group works) into the data-protection keychain, copy first, read back, delete exactly the item read (the login keychain's item object, never its persistent reference, which resolves by name); it counts as moved only when that delete answered 0 AND a new read by name finds nothing ("not found" from the delete = another process rewrote it: kept, retried next start); every kept or skipped item logs one line (status only), and the start logs `Keychain move: N moved, K kept for the next start, S left alone` only when something happened; a missing or unknown answer changes nothing. Unsigned tests prove the login-keychain half only; the signed proof is by hand on a notarized build (`scripts/macos_keychain_check.sh`, check A, the `0x03` password case), re-run for any release that changes keychain code; no CI job is required (2026-11-15). Nothing else starts it. A no-op elsewhere. Wiki `security_write_gates` §43b.

### First-run link throwaway (`api/storage.rs`, 0.14, eeb0e8b1, #123)
Linking a fresh device runs on a throwaway identity. `mark_link_throwaway()` marks it by a digest of its key file the moment it exists; `settle_link_throwaway() -> bool` (at launch, BEFORE the wipe check) queues its wipe when that key is still in place, no link is stashed and no other wipe is queued (a destroy keeps its own marker); any other key only clears the marker. `perform_pending_wipe()` never sweeps while this process holds an identity open (`identity_open_here`: the store, a node or a fetch node). Dart side: every way out of `runFirstRunLink` but a landed link relaunches to Welcome (`rules_ui_flutter` dialogs).

### Device removal and recovery (`api/network.rs`, `api/roster.rs`, 0.14 track C, 060ca581)
- `revoke_device(device_peer_id, lost_since_ms: Option<i64>, with_dependents: bool)`: remove one of OUR devices. Retiring (`None`) keeps what it did (re-signs everything it removed, writes `DeviceRetired` with its post window); lost or stolen keeps only what this device saw from it before `lost_since_ms`, and takes the devices it linked afterwards with it; `with_dependents` also removes the devices only it placed. Refused for this device or an id not ours.
- `remove_device_plan(device_peer_id, lost_since_ms) -> DeviceRemovalPlan`: what the removal will take, shown under the choice; false when a device closer to the phrase removed this one first.
- `recover_with_phrase(phrase, keep: Vec<String>, lost_since_ms)`: a recovery keeping this device and `keep`; every other device counts as lost or stolen since `lost_since_ms`. `recovery_kept_by_default(lost_since_ms)` = the devices this device counted before then.
- Server authority reads `Roster::authority()` (the removal walk with reserved slots, so a flood cannot push out the removal that keeps a device out). One helper adds every removal and re-signs the removals that kept a device out until nothing comes back. The first sight of each roster statement is kept locally (`roster_statement_first_seen`); the upgrade dates what an older install held. Roster notices and syncs are kept only for masters this node already knows (R31-8).

### Underlying identity system (`identity/keys.rs`, `identity/native_identity.rs`, `identity/encryption.rs`, `identity/platform_keystore.rs`)

- **Data directory:** `identity::data_dir()` returns `~/.hollow/` (or `DATA_DIR_OVERRIDE` set by `set_data_dir()` on mobile, or `HOLLOW_DATA_DIR` env var). Falls back to `dirs::data_dir().join("hollow")` which is `%APPDATA%/hollow` on Windows.
- **Storage:** `identity.key` file in either plaintext protobuf (68 bytes, legacy) or HKEYV1 encrypted envelope (119 bytes). Format auto-detected.
- **NativeKeypair:** Wraps `ed25519_dalek::SigningKey` + `VerifyingKey`. Methods: `peer_id()`, `sign(msg)`, `public_key_bytes()`, `secret_key_bytes()`, `verify_peer_signature()`, `public_key_protobuf()`.
- **Mnemonic flow:** BIP-39 24-word (256-bit entropy) -> SHA-512 HMAC seed -> first 32 bytes -> Ed25519 secret key.
- **Peer ID derivation:** Public key -> protobuf encoding -> identity multihash -> base58 string.
- **Encryption:** `encryption.rs` — HKEYV1 format, Argon2id KDF (64MB/3iter), AES-256-GCM, session key static.
- **Platform keystore:** `platform_keystore.rs`: Windows Credential Manager + DPAPI blob (`windows-sys`), macOS: since 0.14 (HOL-SEC-187) ONLY the data-protection keychain in the keys app group (`group.com.anonlisten.hollow.keys`), read only after the bundle self-check, the legacy login-keychain item moved once by `settle_keychain_move` (copy, read back, delete by reference); Linux fallback (not available). Slots are PER-PROFILE since 2026-08-05: suffix = first 8 bytes of SHA-256 over the data-dir path (`com.hollow.identity.wrapping_key.<hex16>` / mac account `wrapping_key.<hex16>`), with the legacy unsuffixed slot still written and read as a fallback. `store_key` writes per-profile + legacy + (Windows) the `identity.dpapi` blob; `retrieve_key_candidates()` returns all, most-authoritative first. Tests snapshot/restore the REAL slots via `SlotGuard` (they used to nuke a keychain-protected dev profile's key on every `cargo test`).

## Twitch API (`api/twitch.rs`)

Full Twitch OAuth Device Code Grant flow + proof generation for Hollow server join gates. Uses an in-memory token cache (`OnceLock<Mutex<Option<CachedToken>>>`) and persists refresh tokens + user info in SQLCipher settings.

### Persistence layer

Three SQLCipher settings keys managed via `save_tw_setting()` / `load_tw_setting()`:
- `twitch_refresh_token` -- OAuth refresh token (rotated on each use)
- `twitch_user_id` -- Twitch numeric user ID
- `twitch_username` -- Twitch display login

### In-memory token cache (`CachedToken`)

```
struct CachedToken {
    access_token: String,
    expires_at: Instant,
    last_validated: Instant,
}
```

Stored in a `OnceLock<Mutex<Option<CachedToken>>>` static. Token is cached with an expiry 60 seconds before the actual OAuth expiry (safety margin). Hourly re-validation is tracked via `last_validated`.

### `twitch_start_device_flow() -> Result<TwitchDeviceFlowResult, String>`

Initiates the Twitch Device Code Grant flow. Calls `twitch::start_device_flow()` (in `node/twitch.rs`) via the tokio runtime. Returns `TwitchDeviceFlowResult { user_code, verification_uri, device_code, interval_secs }`. Dart displays the `user_code` and opens `verification_uri` in a browser for the user.

### `twitch_poll_for_token(device_code: String, interval_secs: u64) -> Result<String, String>`

Polls Twitch until the user completes browser authorization. Calls `twitch::poll_for_token()` which retries at the specified interval. On success:
1. Validates the access token via `twitch::validate_token()` to get `user_id` and `login`.
2. Persists `refresh_token`, `user_id`, and `username` to SQLCipher.
3. Caches the access token in memory with expiry (`expires_in - 60s` safety margin).
Returns the Twitch `user_id` string.

### `twitch_ensure_token() -> Result<bool, String>`

Silent token maintenance. Called before any Twitch API operation. Logic:
1. Check in-memory cache: if token exists and not expired, check if hourly validation is due. If under 1 hour since last validation, return `true` (token valid).
2. If cache miss or expired: load refresh token from SQLCipher.
3. If no refresh token stored, return `false` (not connected).
4. Call `twitch::refresh_access_token()` with the stored refresh token.
5. If refresh fails (expired/revoked): clear stored refresh token, return `false`.
6. On success: save the new refresh token (Twitch refresh tokens are one-time use), validate the new access token, update cached username, cache the new access token.
7. Return `true`.

### `twitch_generate_proof(broadcaster_id: String) -> Result<String, String>`

Generates a cryptographic proof that the user follows/subscribes to a specific Twitch channel. Flow:
1. Calls `twitch_ensure_token()` -- fails if not connected.
2. Loads `user_id` and `username` from SQLCipher.
3. Extracts `access_token` from the in-memory cache.
4. Calls `twitch::generate_proof(access_token, user_id, username, broadcaster_id)` which checks follow/sub status against the Twitch API and produces a signed proof.
5. Serializes the proof to JSON via `serde_json::to_string()`.

### `twitch_disconnect() -> Result<(), String>`

Clears all Twitch state: empties the three SQLCipher settings keys and sets the in-memory cache to `None`.

### `twitch_is_connected() -> Result<bool, String>`

Returns `true` if `twitch_user_id` is stored and non-empty in SQLCipher.

### `twitch_get_user_id() -> Result<Option<String>, String>`

Returns the stored Twitch user ID, or `None` if empty/missing.

### `twitch_get_username() -> Result<Option<String>, String>`

Returns the stored Twitch username, or `None` if empty/missing.

## Updater API (`api/updater.rs`)

Cross-platform application self-update system (Windows, macOS, and since 2026-09-06 Linux for both install kinds). Fetches a signed version manifest from a remote URL, downloads the platform artifact with progress streaming and a SHA-256 pin, and generates a platform-specific helper script that replaces the app while it is closed, then relaunches it. Linux: a portable tarball swaps its own bundle directory; a Flatpak installs the downloaded bundle on the HOST through `flatpak-spawn` and relaunches through `flatpak run` (memory `project_linux_auto_update`).

### `linux_install_kind() -> String`

Sync. `"flatpak"` when `/.flatpak-info` exists, `"tarball"` on any other Linux, `""` elsewhere. The ONE detector: `apply_update`, `launch_update_script` and `spawn_relaunch_waiter` all branch on it, and Dart reads it once (lazy top-level `linuxInstallKind` in `updater_provider.dart`) to pick the download URL/checksum, the download file name (`<v>.flatpak` / `<v>.tar.gz`), whether to probe the app dir for writability (never inside a flatpak, `/app` is read-only by design), and the Settings copy ("Installing" vs "Preparing", "v<x> is installed" + "Restart now").

### Constants

- `APP_VERSION: &str` -- current version string (`0.10.1` at the time of writing) (single source of truth; the Flatpak build script also derives the bundle filename from it).

### FFI struct: `DownloadProgress`

```
pub struct DownloadProgress {
    pub bytes_downloaded: u64,
    pub total_bytes: u64,
    pub error: Option<String>, // final item only: refused/failed download, partial file already deleted
}
```

### `get_current_version() -> String`

Sync function (`#[frb(sync)]`). Returns `APP_VERSION` (always three numeric parts).

### `get_current_build() -> u32`

Sync. Returns `APP_BUILD`, the quick-patch number on top of `APP_VERSION` (0 = the release, 1 = the first same-version patch, shown as `0.12.2+1`). Unrelated to pubspec's `+N` (Android versionCode / iOS build). Dart reads both through `runningReleaseProvider` (`updater_provider.dart`).

### `fetch_version_manifest(manifest_url: String) -> Result<String, String>`

Fetches `manifest.json` AND its `manifest.json.sig` sidecar (same URL plus `.sig`, same cache-buster, 10-second timeout, `Cache-Control: no-cache`), then `verify_strict`s the base64 Ed25519 signature over the manifest's EXACT bytes against `MANIFEST_SIGNING_PUBKEYS` (hex list baked into the binary; more than one entry only during a key rotation). Returns the manifest text only when a listed key verifies it; otherwise `Err` and Dart shows "check failed". The download host can serve bytes, it cannot mint a signature. Dart then treats only a strictly NEWER `latest` as an update (`version_compare.dart::isNewerVersion`), so a replayed old signed manifest is not a downgrade lever. Signing side: `rust/hollow_manifest` + `scripts/sign_manifest.ps1` (see memory `project_update_integrity`). Both `legal/manifest.json` and `legal/manifest.json.sig` are committed and uploaded to the release folder.

### `fetch_signed_feed(url: String, feed: String) -> Result<String, String>`

Fetches `status.json` or `news.json` AND its `.sig` sidecar (same URL plus `.sig`, same cache-buster) and returns the text only when the base64 Ed25519 signature verifies under a `MANIFEST_SIGNING_PUBKEYS` key over `"hollow-feed-sig-v1\0" + feed + "\0" + bytes` (`feed_message`). The prefix is the domain separation: the manifest is signed BARE, so a feed signature never passes as the manifest's, nor one feed's as the other's. `feed` must be `status` or `news` (refused before any fetch). Dart (`signedFeedFetchProvider`) treats every error as "nothing to show". Replaced the unsigned `fetch_release_feed` in 0.12.2. Signing side: `hollow-manifest feed-sign` / `feed-verify`, `scripts/sign_feeds.sh` / `.ps1`.

**Quick patches and platform subsets (0.12.2):** a version entry may carry `"build": N` (integer 0 to 9999, absent = 0) and `"critical": true`. `version` and `latest` stay three numeric parts forever (apps up to 0.12.1 refuse the WHOLE manifest otherwise); Rust refuses a manifest whose `build` is not a bounded integer or whose `critical` is not a boolean. New apps ignore `latest` and pick the newest (version, build) entry that has a URL for THEIR platform and install kind and is newer than the running build (`VersionManifest.updateFor`); an entry without their URL is invisible, phones see none. Old apps and the website read the FIRST entry whose version is `latest`, so the full-platform entry stays first.

**Per-platform manifest URLs (no legacy single `url` field as of v0.5.0):** each version entry has `url_windows`, `url_macos` (zip, used by the updater), `url_macos_dmg` (DMG, used by the website's new-user download button), `url_linux` (Flatpak bundle, checksum `sha256_linux`), `url_linux_targz` (portable tarball, checksum `sha256_linux_targz`, both filled by `hollow-manifest fill-hashes`), `url_android` (APK). Dart `VersionInfo.platformUrl` / `platformSha256` (in `updater_provider.dart`) select by `Platform` and, on Linux, by `linuxInstallKind`. A Linux release therefore needs BOTH artifacts uploaded before the manifest is signed.

### `download_update(url: String, dest_path: String, expected_sha256: String, sink: StreamSink<DownloadProgress>) -> Result<(), String>`

Spawns an async download task on the tokio runtime (non-blocking). `expected_sha256` is the `sha256_<platform>` field of the SIGNED manifest entry (Dart `VersionInfo.platformSha256`; Dart refuses to start when it is empty). Refuses non-`https://` URLs. Streams the update ZIP from `url` to `dest_path`, hashing every chunk, and pushes `DownloadProgress` events after each write. When the stream ends the digest must equal `expected_sha256`, else the file is deleted. ANY failure (mismatch, cancelled sink, transport, non-2xx) deletes the partial file and sends a final `DownloadProgress { error: Some(reason) }`; Dart surfaces it as the error state and never reaches `apply_update`. Creates parent directories for `dest_path` if needed.

### `apply_update(zip_path: String, app_dir: String, version: String, build: u32) -> Result<String, String>`

`version` must be `is_release_version` and `build` at most `MAX_BUILD` before anything is staged. Paths use the release TAG (`0.12.2`, `0.12.2-b1` for a patch: `release_tag`), so a patch never reuses the staging folder or download name of the release it patches; scripts and logs show `0.12.2+1` (`release_display`).


Extracts the update and generates a platform-specific helper script that performs the swap after the app exits, then relaunches. Returns the path to the generated script; Dart's `installAndRestart` launches it detached and then `exit(0)`s. Branches by `#[cfg(target_os)]`:

**Windows:**
1. Creates staging dir `~/.hollow/updates/staging-{version}`.
2. Extracts the ZIP via `extract_zip_to()` (Rust `zip` crate), stripping a common top-level prefix (e.g. `Release/`) via `detect_common_prefix()`. **Entry names are normalized `\`→`/` before every check** (issue #52, 2026-08-05): PowerShell's Compress-Archive wrote backslash-separated names and trailing-`\` empty-dir entries, which the old `ends_with('/')`-only directory detection treated as files → `File::create` os error 267/123 on every updater ≤0.9.4 once the Release tree gained an empty dir. Path-traversal (`..`) entries are rejected. Unit-tested with a Compress-Archive-style fixture + a hand-crafted hostile zip (`extract_zip_tests`). Release zips themselves are now built with forward-slash .NET zipping (`build_release.ps1`) — see memory `feedback_compress_archive_backslash_zip`.
3. Generates `update.bat` (`update_bat_script`): `setlocal DisableDelayedExpansion` + `chcp 65001` first (UTF-8 file, `!` literal whatever the registry says), polls `tasklist` until the pid that wrote it exits, `xcopy /E /Y /Q` staging → `app_dir` (a failure is tried again 5 times, 2 s apart by `ping`, then the window names the staged folder and tries again on each key press; nothing relaunches until a copy succeeds), removes staging + ZIP, 5-1 countdown, relaunches `hollow.exe` WITH this process's argv minus a `hollow:` link (`carried_args`; `bat_relaunch_line`, each argument through `bat_quoted_arg`; an argument holding `"` or a control character, or one that is not Unicode, refuses the whole update before extraction, #155).

**macOS** (`write_macos_update_script()`):
1. Extracts the ZIP with **`ditto -x -k`** (NOT the `zip` crate — `ditto` preserves the `.app` bundle's symlinks, executable bit, and code signature; the crate corrupts them).
2. Finds the single `*.app` bundle in staging.
3. Refuses when the data root lies inside the installed bundle (`DATA_INSIDE_APP`; a portable copy keeps `hollow_data` BESIDE the `.app`, which the swap never touches). Generates an executable `update.sh`: waits via `pgrep -f "<installed_app>/Contents/MacOS/"` for the app to quit, `rm -rf` the old bundle, `ditto` the staged bundle into `app_dir`, strips quarantine (`xattr -dr com.apple.quarantine`), cleans staging + ZIP, relaunches with `open -n` (`macos_relaunch_line`: the original argv after `--args`, a `HOLLOW_DATA_DIR` override as `--env`, because LaunchServices starts the app with neither; every path and argument `sh_quote`d). Logs to `~/.hollow/updates/update.log`. `app_dir` is the bundle's containing folder (e.g. `/Applications`).

**Linux, tarball** (`apply_update_tarball()`):
1. `tar xzf` (never the `zip` crate: it drops exec bits and symlinks, and the bundle carries `hollow`, `screen_audio_capturer`, `lib/*.so`) into `<data>/updates/staging-{version}`, or, when the data root lies INSIDE the app folder (a portable copy's `<app>/hollow_data`), into `<app>.update-{version}` beside it with the log at `<app>.update.log` (`tarball_places`: the swap moves the whole app folder aside, so nothing the script needs may sit in it). A data root elsewhere inside the app folder refuses the update (`DATA_INSIDE_APP`). Locates `bundle/hollow` (or a top-level `hollow`), refuses anything else and a non-executable binary, and deletes any `hollow_data`/marker the archive brought (`BUNDLE_PROFILE_NAMES`).
2. Writes `<data>/updates/update.sh` (0700): waits for OUR pid with `kill -0`, `mv app app.old`, `mv staged app` (puts `.old` back if that fails), then moves the person's `hollow_data`, `portable`, `portable.txt`, `portable.txt.txt` from `.old` into the new build BEFORE starting it (#155 review: the old script deleted them with `.old`). It relaunches with `nohup` forwarding the original argv (NOT `setsid`: the script's shell is already a session leader, so `setsid` forks and `$!` would name a helper that exits at once), sleeps 8 s and if the new binary is gone moves the data back, swaps `.old` back and relaunches the previous version. A folder still holding data is never deleted: a leftover `.old` with data stops the next update, a data move that cannot be undone leaves both builds in place. On success removes `.old`, the staging dir and the archive.

**Linux, flatpak** (`apply_update_flatpak()`): parses `/.flatpak-info` (`[Instance]` `app-path` decides `--user` vs `--system`, `instance-id` is what `flatpak ps` prints), then runs SYNCHRONOUSLY `flatpak-spawn --host flatpak install -y --noninteractive <scope> <bundle>` (the running instance keeps its old deployment; "already installed" counts as success because `--or-update` does not apply to bundles and a retry after a failed relaunch must still relaunch). Writes `<data>/updates/relaunch.sh`, a HOST-side script: delete the bundle, wait until our instance id leaves `flatpak ps --columns=instance`, export `DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus` when that socket exists (the env forwarded by flatpak-spawn carries the sandbox's bus address), `exec flatpak run com.anonlisten.Hollow <argv>`. If `flatpak-spawn` is missing or prints the "only works when the Flatpak is allowed to talk to org.freedesktop.Flatpak" hint, the error tells the user to run `flatpak update com.anonlisten.Hollow`.

**Other targets:** returns an error ("not supported yet").

### `launch_update_script(script_path: String) -> Result<(), String>`

Linux only. Starts the script `apply_update` returned so that it OUTLIVES this process, then Dart `exit(0)`s. Tarball: `setsid /bin/sh <script>` detached (plain `/bin/sh` if util-linux is absent). Flatpak: `flatpak-spawn --host sh -c 'setsid nohup sh <script> >/dev/null 2>&1 &'`, AWAITED, because everything inside the sandbox dies with the app (bwrap is pid 1 of the PID namespace) and waiting for flatpak-spawn is what guarantees the host has forked the script before the exit. macOS and Windows keep their Dart-side detached launches.

### `detect_common_prefix(archive) -> Option<String>`

Internal helper (Windows path only). Iterates all ZIP entries and checks if they all share the same first path component (e.g., `Release/`). Returns `Some("Release/")` if uniform, `None` otherwise. Used to strip wrapper directories from release ZIPs.

### `spawn_relaunch_waiter() -> Result<(), String>`

App SELF-RESTART (no update involved): spawns a detached, windowless waiter that idles until THIS process exits, then starts the exe again — **forwarding the ORIGINAL argv** (2026-08-05: a relaunch that dropped `--portable` came back on a DIFFERENT data root than the running profile, alternating identities between the waiter relaunch and the next manual launch). Called by Dart's `relaunchApp()` (`lib/src/core/app_relaunch.dart`), the single restart path for the profile switcher (#47), device-link restart, relay Apply & Restart, and the revocation self-nuke. **The spawn MUST live in Rust:** a child spawned directly from Dart dies against the Windows runner's pre-Flutter `SendAppLinkToInstance()` while the old window is alive, and Dart's detached mode can't run the waiter itself (kills powershell instantly — no console, no `CREATE_NO_WINDOW`; a detached cmd batch wedges its `tasklist|find` pipeline). Windows: powershell with `creation_flags(CREATE_NO_WINDOW)`, `Get-Process -Id <pid>` poll loop, then `Start-Process`. Unix: `/bin/sh` `kill -0` loop; macOS relaunches the `.app` via `open`, Linux tarball `exec`s the binary. **Linux flatpak (2026-09-06):** the in-sandbox waiter was silently dead (the sandbox PID namespace dies with the app and kills it), so inside a flatpak the waiter is the same HOST-side recipe as the update relaunch (`spawn_flatpak_relaunch_waiter()`: wait for our instance id to leave `flatpak ps`, restore the session bus address, `exec flatpak run com.anonlisten.Hollow <argv>`), started through `flatpak-spawn --host`. Guarded by cargo test `relaunch_waiter_tests` (Windows-only) and `linux_updater_tests` (Linux-only, run on the VM). See memory `project_profile_switcher_issue47`.

## Archive API (`api/archive.rs`)

Cryptographic evidence archive system for exporting, verifying, and loading `.hollow-archive` files (ZIP bundles containing signed messages, edit histories, deletion evidence, reactions, and optionally file attachments). Also handles `.hollow-shards` bundles for vault shard recovery.

### FFI result structs

#### `ArchiveVerifyResult`

Quick verification summary returned by `verify_archive()` and embedded in `ArchiveData`:
- `archive_type: String` -- `"dm"`, `"channel"`, or `"server"`
- `exporter_peer_id: String` -- who exported the archive
- `export_timestamp: i64` -- millis since epoch
- `message_count: u32` -- total messages
- `archive_signature_valid: bool` -- Ed25519 signature over the canonical content hash
- `messages_with_valid_sig / messages_with_invalid_sig / messages_without_sig: u32` -- per-message breakdown
- `participant_ids: Vec<String>` -- all unique sender peer IDs
- Context fields: `peer_id` (DM), `server_id`/`channel_id`/`channel_name` (channel), `server_name`/`channels` (server)

#### `ArchiveChannelInfoFfi`

Per-channel metadata for multi-channel (server) archives: `channel_id`, `channel_name`, `message_count`.

#### `ArchiveMessageFfi`

Full message record: `message_id`, `sender_id`, `text`, `timestamp`, `signature`, `public_key`, `edited_at`, `hidden_at`, `reply_to_mid`, `file_id`, `album_id` (the loader verifies it into the v3 payload), `channel_id` (server archives only), `reactions: Vec<ArchiveReactionFfi>`, `signature_valid: Option<bool>` (verified during load).

#### `ArchiveReactionFfi`

Reaction on a message: `emoji`, `peer_id`, `added_at`, `signature`, `public_key`.

#### `ArchiveEditFfi`

Edit history entry: `message_id`, `old_text`, `new_text`, `edited_at`, `signature`, `public_key`, `prev_signature`, `prev_public_key`, `prev_timestamp`. The `prev_*` fields form a chain linking to the previous version for tamper detection.

#### `ArchiveDeletionFfi`

Deletion evidence: `message_id`, `deleted_text`, `deleted_at`, `signature`, `public_key`. Preserves the deleted content as cryptographic evidence.

#### `ArchiveReactionRemovalFfi`

Reaction removal evidence: `message_id`, `emoji`, `peer_id`, `removed_at`, `signature`, `public_key`.

#### `ArchivePubKeyFfi`

Public key entry for offline verification: `peer_id`, `public_key_b64`. Included in archives so signatures can be verified without network access.

#### `ArchiveFileFfi`

File attachment metadata: `file_id`, `file_name`, `file_ext`, `mime_type`, `size_bytes`, `is_image`, `width`, `height`, `sha256` (hex, only when included), `included: bool`.

#### `ArchiveData`

Full loaded archive for the POV (point-of-view) viewer. Contains all the above plus `file_mode: String`, `participants: Vec<String>`, `messages`, `edits`, `deletions`, `reaction_removals`, `pubkeys`, `files`, `verification: ArchiveVerifyResult`, and `files_dir: Option<String>` (temp directory with extracted file bytes).

### Export functions

All export functions follow the same pattern: acquire the message store lock, load the identity keypair, call `archive::exporter::export_archive()` with the appropriate `ArchiveTarget`, write the resulting ZIP bytes to `output_path`, and return the file size in bytes.

#### `export_dm_archive(peer_id, output_path, file_mode) -> Result<u64, String>`

Exports a DM conversation. Target: `ArchiveTarget::Dm { peer_id }`.

#### `export_channel_archive(server_id, channel_id, channel_name, output_path, file_mode) -> Result<u64, String>`

Exports a single channel conversation. Target: `ArchiveTarget::Channel { server_id, channel_id, channel_name }`.

#### `export_server_archive(server_id, server_name, channels_json, output_path, file_mode) -> Result<u64, String>`

Exports all text channels of a server as a single archive. Parses `channels_json` (JSON array of `[{"channel_id": "...", "channel_name": "..."}]`) into `Vec<(String, String)>`. Target: `ArchiveTarget::Server { server_id, server_name, channels }`.

#### File mode (`archive::types::FileMode`)

Three modes controlling file attachment inclusion:
- `"full"` -- all file attachments included with SHA-256 integrity hashes
- `"images_only"` -- only image attachments included
- `"placeholder"` -- metadata only, no file bytes (smallest archive)

### Verification and loading

#### `verify_archive(archive_path: String) -> Result<ArchiveVerifyResult, String>`

Quick verification. Reads the ZIP bytes, calls `archive::loader::verify_archive()`, which parses `manifest.json` and `archive_signature.json`, verifies the archive-level Ed25519 signature over the canonical content hash, and checks per-message signatures. Returns an `ArchiveVerifyResult` summary without loading full message data into memory.

#### `load_archive(archive_path: String) -> Result<ArchiveData, String>`

Full archive load for the POV viewer UI. Reads the ZIP bytes, calls `archive::loader::load_archive()`, which extracts all content. Processing:
1. Builds a `HashMap<String, bool>` from `per_message_results` mapping message_id to signature validity.
2. Converts all internal types to FFI types: messages (with per-message `signature_valid` lookup), edits, deletions, reaction_removals, pubkeys, file metadata.
3. Recomputes verification summary counts (valid/invalid/unsigned) from `per_message_results`.
4. Assembles `ArchiveData` with the full manifest metadata, all converted data, and the verification summary.

### Archive ZIP structure (from `archive::types`)

```
manifest.json              -- ArchiveManifest (type, exporter, timestamp, participants, etc.)
archive_signature.json     -- Ed25519 signature over content hash
pubkeys.json               -- Array of peer_id + public_key_b64
messages/{message_id}.json -- Per-message data with text, sig, reactions
edits/{message_id}.json    -- Edit history arrays (old_text -> new_text chains)
deletions/{message_id}.json -- Deletion evidence with preserved text
reaction_removals/{message_id}.json -- Reaction removal evidence
files/{file_id}.meta.json  -- File attachment metadata
files/{file_id}.{ext}      -- Actual file bytes (if included per file_mode)
```

### Shard export/import (Evidence Recovery Phase B)

#### `ShardImportResultFfi`

Result of importing a `.hollow-shards` bundle: `server_id`, `manifests_imported`, `shards_imported`, `shards_skipped`, `new_reconstructable` (files now having enough shards for erasure-code reconstruction).

#### `export_server_shards(server_id, output_path) -> Result<u64, String>`

Exports all vault shards for a server as a `.hollow-shards` ZIP bundle. Opens the `ContentStore` using the identity keypair's protobuf encoding (first 32 bytes hex-encoded as passphrase). Lists all manifests and shards for the server. Builds a bundle manifest JSON with `format_version: 1`, server_id, exporter_peer_id, timestamp, counts, and full manifest data. Writes a ZIP containing `manifest.json` and `shards/{content_id}/{shard_index}.shard` files. Returns file size in bytes.

#### `import_server_shards(archive_path: String) -> Result<ShardImportResultFfi, String>`

Imports a `.hollow-shards` ZIP bundle. A bundle names no sender, so nothing in it is believed; it is judged against what this device holds (HOL-SEC-205, HOL-SEC-206; wiki `security_write_gates` §73, authz row files:A-V12):
1. `check_shard_bundle` bounds it whole before anything is stored: the zip index (`zip_budget::index_refused`, at most 65536 entries, read from the file's tail before the zip reader parses it), the manifest (16 MiB), each shard (no larger than the bundle) and the total (max(64 MiB, 4 x size)), counted in bytes inflated.
2. Our master must be a member of a server we hold (`held_server_state`). Then each manifest only FILLS (`ContentStore::fill_manifest`, `INSERT OR IGNORE`, counted only when a row was added) after `bundle_manifest_refused`: content id well formed, creator a current member who sent the file card we hold for its `message_id` (`card_is_creators`, the live relink rule), its channel one of the server's that we may read, never a restricted one, never over a manifest we hold. It relinks no file card.
3. For a server we do not hold (an ex-member, the offline fallback bundles exist for) no manifest is added at all.
4. Each `shards/{content_id}/{shard_index}.shard` lands only when a manifest WE hold names that server as its home; a member's write also passes `vault_ops::shard_write_refused` (pledge, never over a held shard); every write passes `shard_bytes_refused(.., pulling = true)`, so only the bytes the held manifest pins are stored. k, m, size and tier come from the held manifest.
5. Counts newly reconstructable files and returns `ShardImportResultFfi`.

### Content store passphrase derivation

Both `export_server_shards` and `import_server_shards` derive the content store passphrase from the identity keypair: `hex::encode(keypair.to_protobuf_encoding()[..32])`. This ensures the content store is tied to the user's identity.
