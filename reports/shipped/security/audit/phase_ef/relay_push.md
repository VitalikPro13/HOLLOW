# Phase E+F slice `relay_push`: push, and the privacy and host half of the relay

Session 34, merged phase E (STRIDE, LINDDUN GO, checklists, 13 classes) and phase F
(WP6 push, the non-authz half of WP4 relay). Code read in the detached worktree
`D:/dev/wt/s34-ef` at HEAD `aa104d48`. Nothing built or run. Paths below are relative to
the repo root; Rust paths under `rust/hollow_core/src/` are written in full.

## Scope

Elements: X-2 relay (`relay-uws/src`) and TURN (coturn as configured by
`relay-uws/deploy/coturn/coturn-start.sh` and `relay-uws/deploy/coturn-sandbox.conf`) as
host processes; the push sidecar (`push-sidecar/index.js`, `unifiedpush.js`,
`hollow-push.service`); the media forwarder as a host process
(`relay-uws/deploy/hollow-forwarder.service`, `rust/hollow_core/src/forwarder/`); X-5 push
providers (FCM, APNs) and a UnifiedPush push server and distributor; E-04 the push
extension (Android Dart background isolate `lib/src/core/services/push_notification_service.dart`,
the UnifiedPush background entry `lib/src/core/services/unified_push_service.dart`, the iOS
NSE `ios/NotificationService/NotificationService.swift` with `rust/hollow_core/src/push_enrich.rs`,
the push fetch `rust/hollow_core/src/node/fetch.rs`, the iOS hints cache
`lib/src/core/services/push_hints_cache.dart`); the relay box (units, `check-host.sh`,
`harden-host.sh`, `docker-compose.yml`).

Boundaries: TB-1 (client and relay), TB-6 (push providers and the extension process),
TB-10 (relay process and its host).

Flows: F-50 room join/leave/RoomMembers, F-51 0x03/0x07/rings/availability cache, F-52 the
memfd snapshot, F-53 push token and prefs registration, F-60 relay to sidecar to
FCM/APNs/UnifiedPush to device, plus F-36 (0x09 channel push) and F-44 (TURN credentials)
where they touch push and the host.

Specs: RFC 8030 (Web Push), RFC 8291 (Web Push encryption), RFC 8292 (VAPID), the
UnifiedPush server spec, RFC 8656 (TURN) security considerations. Privacy method: LINDDUN GO
against P-01 (relay operator or whoever compromises the box) and P-11 (Apple, Google, a
UnifiedPush push server and distributor).

Authz of relay inputs is the matrix's (`authz_matrix.md` rows `relay:*`, `transport:*`) and is
cited, not redone.

## Summary

- STRIDE cells walked: 79 (5 processes x 6, 6 stores x 3, 9 flows x 3, 2 interactors x 2).
- Candidates: 15. High 3 (C-RP-01, C-RP-02, C-RP-03), Medium 2 (C-RP-04, C-RP-05),
  Low 6 (C-RP-06 .. C-RP-11), Info 4 (C-RP-12 .. C-RP-15). CONFIRMED 13, SUSPECTED 2
  (C-RP-03 on iOS backup behaviour, C-RP-10 for the official box's coturn config).
- Claims that no longer match the code: C-26 (channel wakes), C-35 (App Lock and
  notifications), C-07 (duress shows nothing), privacy policy relay section, WP 3.1, WP 23.1
  rows "Relay compromise", "Push-provider metadata harvesting" and "Coercion at the unlock
  prompt". Table in the LINDDUN section.
- Requirements: 24 (R-RP-01 .. R-RP-24), 5 of them NOT MET today.
- Leads: L-09 holds as AR-01 (the crash in C-RP-01 is not a rate question); K3 deferral still
  matches the code; AR-14, AR-16, AR-18 unchanged.
- Fuzz targets for phase G listed with priority (13 classes section, class 9 and the end of
  the STRIDE grid).

## Candidates (most severe first)

### C-RP-01: Any free identity can crash the relay with one join frame, and the crash loses every buffer, parked destroy order, push token and roster pin

- Severity: High (Impact H: the whole relay goes down with no snapshot, so every offline
  buffer, ring, push token and pref, parked kill order, join lock chain, roster record and
  device-list mark is gone, and a loop of it is a permanent outage; it also turns AR-15's and
  AR-19's "only after a rare box reboot" residuals into attacker-on-demand ones.
  Exploitability H: one frame from any self-minted identity; the official relay is open to
  all).
- Attacker: P-03 (any authenticated non-guest socket, fetch sockets included).
- Evidence:
  - `relay-uws/src/ws_handler.cpp:699-700`
    `    std::optional<roster::Roster> shown = roster::from_json(roster_json);`
    `    if (!shown || roster_json.dump().size() > roster::MAX_ROSTER_BYTES) return false;`
  - `relay-uws/src/roster.h:611` `// the whole roster; a missing one takes its default; unknown ones are ignored. --`
  - `relay-uws/src/ws_handler.cpp:3013` `                if (message.size() > 1024 * 1024) return;`
  - `relay-uws/src/json.hpp:19177` `                         dump(*i, false, ensure_ascii, indent_step, current_indent);`
    (nlohmann 3.12's serializer recurses once per nesting level; its parser
    `sax_parse_internal` (json.hpp:13233) and destructor (`destroy`, an explicit heap stack)
    are iterative, so a deep document parses fine and only `dump()` overflows.)
  - `relay-uws/src/main.cpp:217` `                snapshot_to_fdstore(*g_shutdown.state);` (the
    snapshot is written only by the SIGTERM tick; a SIGSEGV skips it).
- Why it breaks: `roster::from_json` accepts an `inbox_roster` object whose only member is an
  unknown key, then the size check serializes the RAW attacker JSON. A text frame up to
  1 MiB holds about 500,000 nested `[`, far past the 8 MB main-thread stack. The
  `try/catch` around `handle_text_message` (ws_handler.cpp:3017-3021) catches C++ exceptions,
  not a stack overflow. Rule broken: CLAUDE.md "a throw into uSockets kills the process"
  class, AS-11, and the restart-persistence promise (privacy policy: buffers survive updates).
  Guests are refused at ws_handler.cpp:698 (`if (data->is_guest || !is_inbox_room(room)) return false;`),
  everyone else reaches the dump. `ws_handler.cpp:700` is the only `dump()` of raw client
  JSON in `relay-uws/src` (grep of `dump()`).
- Test: `relay-uws/test/test_relay_live.cpp`, an authenticated socket sends
  `{"type":"join","room":"inbox:<any>","inbox_roster":{"x":[[[ ... ]]]}}` nested 200,000
  deep, then a second socket asks `get_turn_credentials` and must get an answer; run also
  under `SANITIZE=1`. A unit test beside `test_roster.cpp` that a hostile depth is refused
  before any recursive walk.
- Fix idea: short term, measure the parsed roster (`roster::to_json(*shown).dump()`, depth 3)
  instead of the raw JSON; class kill, parse every client text frame with a depth cap (a
  nlohmann parser callback that throws past depth 32, caught by the existing try) so no
  handler ever holds a deep document.
- Confidence: CONFIRMED (every guard upstream traced; exact overflow depth not measured, per
  the no-run rule).

### C-RP-02: A phone wiped by duress, remote destroy or roster erase keeps its friends' names and a timeline of who wrote to it, and keeps being woken for the identity it destroyed

- Severity: High (Impact H: the duress wipe announces itself to the coercer holding the
  phone, with the contacts' names on iOS banners, which defeats C-07's "shows nothing"; after
  a remote destroy the thief keeps the friend list and push timeline. Exploitability M: any
  friend messaging the device after a duress wipe triggers it on screen; the files need
  filesystem access).
- Attacker: P-09 (coercer, thief, forensic lab).
- Evidence:
  - The one wipe routine lists what it erases, and neither push file is in it:
    `rust/hollow_core/src/api/wipe.rs:16-26`
    `const WIPE_ENTRIES: &[&str] = &[` ... `    "hollow_debug.log",` `    "hollow_crash.log",` `    "pending_link.hollow",` `];`
  - iOS hints live outside the wiped root: `lib/src/core/services/push_hints_cache.dart:76`
    `    final base = Directory('$dir/push_hints');` (App Group root) while the data root is
    `lib/src/core/services/ios_data_dir_migration.dart:38` `    final target = '$container/hollow_data';`.
    The hints hold every friend's master and device ids, display name and avatar file.
  - The push log is plaintext and outside WIPE_ENTRIES:
    `lib/src/core/services/push_notification_service.dart:264-265`
    `    final dir = await getApplicationDocumentsDirectory();`
    `    final file = File('${dir.path}/hollow/push_debug.log');`
    with lines such as :299-301 (`'Handler started, type=${data['type']} sender=${data['sender']} '`)
    and :388 (`await _pushLog('getPushProfile: name=${profile?.displayName}, ...`). On iOS this
    path is the private sandbox, not even the data root.
  - The duress path cannot unregister the push token, because the node never started:
    `lib/src/ui/shell/hollow_shell.dart:699-704` (`if (_isDuressResult(e)) {` ...
    `await clearLocalSecretsAfterDestroy();`), `lib/src/core/services/destroy_flow.dart:17-22`
    (`.unregisterPushToken()` / `.timeout(const Duration(seconds: 2));` / `push unregister skipped`),
    `rust/hollow_core/src/api/network.rs:2874-2875`
    `pub fn unregister_push_token() -> Result<(), String> {` / `    send_node_command(node::NodeCommand::UnregisterPushToken)`.
    No caller deletes the FCM token or unregisters UnifiedPush on a wipe (grep `deleteToken`:
    none in `lib/`). The relay keeps tokens with no expiry (`ws_handler.cpp:1365`
    `    state.push_tokens[data->peer_id] = { token, platform };`, evicted only by the byte budget).
  - Duress is local-only, so the device stays in the roster and friends keep targeting it.
    On iOS the NSE then titles the banner from the surviving hints:
    `ios/NotificationService/NotificationService.swift:79-83`
    `    if let name = entry["name"] as? String, !name.isEmpty {` / `      content.title = name` ...
    `    content.body = "Sent you a message"`. On Android the background handler, finding no
    identity, posts the generic banner: `push_notification_service.dart:543`
    `    if (!Platform.isIOS) await _showGenericNotification();`.
- Why it breaks: C-07 (duress "shows nothing"), C-02/C-03 intent (a destroyed device keeps no
  usable data), WP 23.1 "Coercion at the unlock prompt ... while showing nothing", AS-05.
- Test: harness or a Rust unit next to `wipe_routine_is_idempotent_and_marker_resumes`:
  after `destroy_data_root`, no `push_debug.log` remains in the root; a Dart test that
  `clearLocalSecretsAfterDestroy` clears the hints directory and calls the FCM token delete
  and UnifiedPush unregister through fakes; an iOS fleet check that a wake to the old device
  id after a duress wipe shows no named banner.
- Fix idea: move both push files under the data root (or add them, and the App Group
  `push_hints/`, to the wipe) and, in every wipe path, delete the FCM token and unregister
  UnifiedPush locally (no relay needed), so the old device id stops reaching this phone.
- Confidence: CONFIRMED (all paths traced in code; on-device banner not driven).

### C-RP-03: Apple, or whoever holds the user's iCloud or Finder backup, gets Hollow's data folder and the push hints, identity file included

- Severity: High (Impact H: without App Lock the identity file is unwrapped (WP 2.3 no-protection
  mode, the mobile default), so a backup carries the master key, the device key and the
  SQLCipher key's source; with App Lock it carries a PIN-wrapped file open to offline search
  (lead L-07). Restoring the backup onto a second iPhone clones the device id, which then
  takes the relay's one push slot for that id. Exploitability M: Apple without Advanced Data
  Protection, legal process to Apple, a phished Apple ID, or an unencrypted Finder backup).
- Attacker: P-11 (Apple), P-09.
- Evidence: the data root is in the App Group container
  (`lib/src/core/services/ios_data_dir_migration.dart:38` `    final target = '$container/hollow_data';`),
  the hints beside it (`push_hints_cache.dart:76`), and nothing in `ios/` or `lib/` marks a
  path excluded from backup (grep `isExcludedFromBackup`, `NSURLIsExcludedFromBackupKey`,
  `setResourceValue`: none). Android made the opposite decision:
  `android/app/src/main/AndroidManifest.xml:31-33` `android:allowBackup="false"` /
  `android:fullBackupContent="false"` / `android:dataExtractionRules="@xml/data_extraction_rules"`.
  The hints writer's comment claims otherwise: `push_hints_cache.dart:17-18`
  "contained to the app-private group container, never iCloud-synced".
- Why it breaks: C-06's scope (a copy of the identity file), C-01 (a cloned device is
  indistinguishable from the original), AS-01/AS-08.
- Test: on the Mac mini simulator or a phone, set and read `isExcludedFromBackup` on
  `hollow_data` and `push_hints` after first start (an XCTest or a Dart method-channel test).
- Fix idea: set `isExcludedFromBackup` on the App Group `hollow_data`, `push_hints`,
  `push_diag` and the private `Documents/hollow` at every start (the `.hollow` backup stays the
  only sanctioned copy, as on Android).
- Confidence: SUSPECTED for the platform behaviour (Apple includes app and App Group
  containers in device backups unless excluded; not checked on a device). The missing
  exclusion is CONFIRMED. Overlaps WP8 (local storage); reported here because the container
  layout is the push extension's.

### C-RP-04: Someone holding a phone or desktop with App Lock engaged reads incoming senders and message text in notifications

- Severity: Medium (Impact M: C-35 promises "no message content, name or notification is
  visible until unlock"; Exploitability H: wait for a message).
- Attacker: P-09.
- Evidence:
  - Mobile, app alive in the background: `lib/src/core/providers/system_notification_provider.dart:138-149`
    (`if (Platform.isAndroid || Platform.isIOS) {` ... `if (lifecycle.isBackground) {` ...
    `await push.showLocalDmNotification(` ... `displayName: senderName,` ... `text: text,`) with no
    `appLockedProvider` check.
  - Desktop: `system_notification_provider.dart:359-361`
    `    // Locked is away: the cover hides the in-app card, so the OS toast is the`
    `    // only surface left, exactly as on a phone's lock screen.`
    `    if (ref.read(appLockedProvider)) return true;` (the toast then carries name and text).
  - iOS NSE, identity locked behind the App Lock PIN: the fetch returns nothing, but the banner
    is still titled from the plaintext hints (`NotificationService.swift:79-80`).
  - Android background isolate with a locked identity names nobody
    (`push_notification_service.dart:532-545`), so the Android push path itself is consistent.
- Why it breaks: C-35. WP 2.6 describes notifications arriving while locked ("a notification
  tapped then is held until the lock lifts"), so the claim and the design disagree; one of
  them must change.
- Test: a widget test that with `appLockedProvider` true `notifyDm` posts a content-free
  banner (mobile) and toast (desktop); an iOS check that the NSE leaves the APNs generic text
  when an App Group "locked" flag is set.
- Fix idea: while App Lock is on, every notification surface shows "Hollow" / "New message"
  with no name or avatar (Signal's "Name and content hidden" default under screen lock); the
  app writes an App Group flag the NSE reads before it uses the hints.
- Confidence: CONFIRMED in code. Overlaps WP8 (App Lock).

### C-RP-05: Google and Apple can build each user's contact graph and every server's member list from the stable ids in wake payloads

- Severity: Medium (Impact M: AT-6 "learn who Alice talks to" via F-60, linked to real
  Google and Apple accounts and retained by them as delivery records; Exploitability H for
  P-11, passive).
- Attacker: P-11.
- Evidence: `push-sidecar/index.js:107-115`
  `      const data = isChannel` / `          ? {` / `              type: 'channel_wake',` /
  `              ...(sender ? { sender } : {}),` / `              server,` /
  `              ...(channel ? { channel } : {}),` / `              mention: mention ? '1' : '0', ...` /
  `          : { type: 'wake', ...(sender ? { sender } : {}) };`,
  sent in clear to FCM (`index.js:130` `      const message = { token, data };`); the relay supplies
  them (`relay-uws/src/ws_handler.cpp:958-962` `json body = {{"token", job.token}, {"platform", job.platform}, {"sender", job.sender}};` ...
  `body["server"] = job.server;` `body["channel"] = job.channel;` `body["mention"] = job.mention;`).
  `sender` is the depositing socket's device id, stable for the device's life.
- Why it breaks: C-26 promises "only a wake-up and a sender id"; channel wakes add a server id,
  a channel id and a mention bit. WP 13.1 lists those fields but says Apple and Google "never
  see ... who-is-who beyond opaque IDs", which understates it: the same server id at many
  accounts is the server's member list, the same sender id across accounts and reply timing
  maps device ids to accounts, and the mention bit says who was addressed. WP 23.1 still says
  `{wake, sender}` only. The UnifiedPush path already encrypts the same block to the device
  (`push-sidecar/unifiedpush.js:105-108`, RFC 8291), so the gap is FCM and APNs only.
- Test: a sidecar unit test (none exists today) asserting the FCM `data` carries no stable
  identifier, or one opaque ciphertext field.
- Fix idea: short term, correct C-26, WP 13.1 and WP 23.1. Long term, register a Web Push key
  set beside the FCM token (the app already generates one for UnifiedPush) and send FCM and
  APNs one fixed-size encrypted field, decrypted by the Android handler and the NSE; or drop
  `server`/`channel` and let the fetch ask the relay which of its rooms hold frames for it.
- Confidence: CONFIRMED.

### C-RP-06: The relay keeps each phone's full server list, its notification settings and the ids of the contacts it muted, while the privacy policy says it cannot tell which servers you are in or whom you talk to

- Severity: Low (Impact L: the relay sees server rooms when the phone is online anyway; the
  increment is mute levels per server and channel, the muted contacts' master and device ids,
  and keeping all of it across restarts while the phone is offline. Exploitability H for P-01).
- Attacker: P-01.
- Evidence: `lib/src/core/providers/notification_provider.dart:151-156`
  `    for (final entry in state.serverLevels.entries) {` / `      prefs[entry.key] = {` /
  `        'level': entry.value.name,` (every server, default levels included, from
  `lib/src/ui/shell/hollow_shell.dart:918-919` `loadAll(servers.keys.toList(), ...)`), and
  :170-175 the `~dm` entry from `_mutedDmDeviceIds()` which adds the contact's master
  (:88 `      out.add(master);`). Stored at `relay-uws/src/ws_handler.cpp:1591`
  `    state.push_prefs[data->peer_id] = std::move(prefs);` and carried across restarts
  (`relay-uws/src/snapshot.cpp:128-139`). The relay already treats an absent server as "all"
  (`ws_handler.cpp:1800-1802` `// Prefs filter. Unregistered peer / unknown server = "all" ...`),
  so the default entries are pure disclosure. `legal/PRIVACY_POLICY.md:47` lists among what the
  relay does NOT have access to: "Which servers you are a member of or who you communicate
  with (room identifiers are opaque hashes)".
- Why it breaks: C-24 ("never ... server or channel details ... or any other data"), the
  privacy policy (GDPR transparency and data minimisation: LINDDUN Non-compliance), and the
  client comment at notification_provider.dart:168-169 ("the relay never learns device→master").
- Test: a Dart unit test that `_syncPushPrefsToRelay` sends no server or channel whose level
  is "all" or inherit.
- Fix idea: send only non-default levels; rewrite the privacy policy's relay section to C-24
  (rooms, device grouping, rosters, push filters), with WP 3.1 at close-out.
- Confidence: CONFIRMED.

### C-RP-07: The media forwarder writes the id of every device that ever shared or watched through it to the relay box's disk

- Severity: Low (Impact L: a durable list of screen-share users on a disk the privacy policy
  says holds only the report counter; Exploitability M: disk image, provider snapshot, seizure).
- Attacker: P-01, P-09 applied to the relay host.
- Evidence: `rust/hollow_core/src/forwarder/mod.rs:159-160` `    let db_path = data_dir` /
  `        .join("forwarder.db")` and :168-169 `                let sessions = store.load_all_olm_sessions()?;`;
  every inbound sender's session is saved, `rust/hollow_core/src/forwarder/signaling.rs:346`
  `            persist_olm_session(olm, crypto_store, &sender);`, into
  `olm_sessions (peer_id TEXT PRIMARY KEY, pickle TEXT NOT NULL)`
  (`rust/hollow_core/src/storage/messages.rs:591-594`); nothing in `forwarder/` deletes a
  session. The SQLCipher passphrase is derived from `forwarder.key` in the same directory
  (mod.rs:157-158). `legal/PRIVACY_POLICY.md:129`: "The only user-related record our
  infrastructure writes to disk is the abuse-report counter".
- Why it breaks: CLAUDE.md relay-box rule "nothing to disk", the privacy policy, C-24's spirit
  (routing metadata in RAM only). HOL-SEC-075 removed the forwarder's log file but not this.
- Test: a forwarder unit test that a restarted forwarder holds no sessions (RAM-only store),
  or that sessions idle past N hours are deleted.
- Fix idea: keep the forwarder's Olm sessions in RAM only (clients re-key after a restart, as
  they recover legs today), or prune idle sessions and say so in the policy.
- Confidence: CONFIRMED.

### C-RP-08: A copy of a phone's app storage shows, without the identity, a timeline of who woke it and their display names

- Severity: Low (Impact L: names, sender ids, server and channel ids and times, outside
  SQLCipher and HFE1; Exploitability M: forensic extraction, or a user sharing the diagnostics
  export with support).
- Attacker: P-09, the support channel.
- Evidence: `push_notification_service.dart:299-301` logs sender, server and channel per
  wake; :388 `await _pushLog('getPushProfile: name=${profile?.displayName}, hasAvatar=...')`;
  :553 `await _pushLog('Fallback notification shown: $displayName');`; the export reads it:
  `lib/src/ui/settings/about_section.dart:273` `  appendFile('Dart push log', '$hollowDataDir/push_debug.log');`.
- Why it breaks: AS-08 (logs readable by the device's holder), C-37's intent for support logs,
  and the at-rest design (only SQLCipher and HFE1 hold user data).
- Test: a source-scan guard that `_pushLog` arguments carry no `displayName` and no raw ids
  (lengths or booleans only), the rule the NSE already follows (`NotificationService.swift:113`).
- Fix idea: log only event kinds and counts; drop names and ids from `push_debug.log`.
- Confidence: CONFIRMED.

### C-RP-09: The relay, and Google, can link an identity destroyed on a phone to the next identity created on it

- Severity: Low (Impact L: linkability of a "fresh start" after a wipe; Exploitability H for
  P-01 holding the old registration, and for Google which sees one token throughout).
- Attacker: P-01, P-11.
- Evidence: `push_notification_service.dart:1456` `        _currentToken = await _messaging.getToken();`
  re-registers the same per-install token under the new device id (`:1551-1553`
  `registerPushToken(token: token, platform: platform)`); no wipe path calls `deleteToken` or
  `UnifiedPush.unregister` (grep). After a duress wipe the old registration also stays live
  (C-RP-02), so both device ids map to one token string at the relay.
- Why it breaks: C-07/duress deniability and the duress design's "fresh start".
- Test: as C-RP-02's Dart test (token delete called on every wipe path).
- Fix idea: delete the FCM token and unregister UnifiedPush in `clearLocalSecretsAfterDestroy`
  (shared with C-RP-02).
- Confidence: CONFIRMED.

### C-RP-10: Anyone with free TURN credentials can reach any UDP service on the relay host's own address

- Severity: Low (Impact L: UDP only (`--no-tcp-relay`); reaches services the firewall blocks
  from outside but that listen on the public address, since packets to the host's own
  address arrive on `lo`; Exploitability M: credentials go to every authenticated identity).
- Attacker: P-03.
- Evidence: `relay-uws/deploy/coturn/coturn-start.sh:60-62`
  `    --denied-peer-ip=0.0.0.0-255.255.255.255 \` / `    --denied-peer-ip=::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff \` /
  `    --allowed-peer-ip="$ip"` (an address on both lists is allowed, per the script's own
  comment). Loopback, RFC1918, link-local and 169.254.169.254 are denied, so the classic
  metadata SSRF is closed. Credentials: `relay-uws/src/ws_handler.cpp:2838-2841`
  (`uint64_t ttl = 3600;` ... `std::string username = std::to_string(expiry) + ":hollow";`),
  not bound to a user (matrix `relay:A-18`, by design).
- Why it breaks: RFC 8656 §21 security considerations (a TURN server must not become a path
  into networks its operator firewalls). The official box's `/etc/turnserver.conf` is not in
  the repo (memory says the same own-address allowance there).
- Test: none possible in the repo; a check in `check-host.sh` that no UDP socket outside
  coturn's listener and relay range, and the forwarder range, listens on the public address.
- Fix idea: an nftables rule on the box (`meta skuid turnserver ip daddr <self> udp dport != 49152-65535 drop`),
  and the same note in `SELF_HOSTING.md`.
- Confidence: CONFIRMED for the repo's Docker path; SUSPECTED for the official box (config
  not readable here).

### C-RP-11: Whoever images the relay's disk can test "did device A report device B" for pairs they guess

- Severity: Low (Impact L: reporter identity, a guessed pair at a time; Exploitability L:
  disk access plus candidate ids).
- Attacker: P-01, P-09 applied to the relay host.
- Evidence: `relay-uws/src/reports.cpp:49-50`
  `std::string ReportsState::secret_path_for(const std::string& reports_path) {` /
  `    return reports_path + ".key";` (the key sits beside the fingerprints in
  `/var/lib/hollow-relay`), fingerprint at :30-41 (BLAKE2b keyed over reporter, target,
  category). `legal/PRIVACY_POLICY.md:67` says "without that secret the fingerprint reveals
  nothing about who filed the report".
- Why it breaks: the policy's "no readable record of who filed a report" holds against reading,
  not against testing a guess when the key is on the same disk.
- Test: none needed beyond a doc fix; if the key moves to RAM, `test_reports.cpp` covers dedup
  within a run.
- Fix idea: keep the key in RAM (dedup then resets per process, which AR-08 already tolerates)
  or say in the policy that disk access plus a guessed pair confirms a report.
- Confidence: CONFIRMED.

### C-RP-12 (Info): Anyone on the internet can poll the relay's online-user count every five seconds

- `relay-uws/src/http_handlers.cpp:127` `        {"online_users", state.online_users()},` and :131-132
  (`fwd_delivered`, `fwd_buffered`), served with `Access-Control-Allow-Origin: *` (:14). On a
  small self-hosted relay the count steps when one known person connects; the forwarder
  counters show when screen shares run. Detecting (LINDDUN), matrix `relay:A-28` calls it
  counters only. Fix idea: coarsen (round, or 60 s cache) or serve `/server-stats` only on
  loopback. CONFIRMED.

### C-RP-13 (Info): The push sidecar's address guard has residuals and no second layer

- `push-sidecar/unifiedpush.js:25-35` blocks loopback, RFC1918, CGNAT, link-local (with
  169.254.169.254), ULA, multicast and documentation ranges, checked inside the socket's
  lookup (:49-63) and for literals (:89-93); `https:` only, no userinfo (:89). Residuals:
  the box's own public addresses are allowed (reaches its own HTTPS listeners, harmless today);
  the sidecar is a blind POST reflector to any public HTTPS URL a client registers, at the
  push budget's rate; `hollow-push.service` has no `IPAddressDeny=`; `PUSH_TOKEN` empty means
  any local process may push (`push-sidecar/index.js:15`, `:19` `  if (!PUSH_TOKEN) return true;`),
  which the Docker stack ships and `check-host.sh` never checks. Redirects: `web-push` treats
  any non-2xx as an error and the sidecar passes no proxy (not verified against the library
  source, which is not in the tree). Fix idea: `IPAddressDeny=` for private ranges in the unit,
  a `check-host.sh` line that the sidecar's EnvironmentFile sets `PUSH_TOKEN`. CONFIRMED.

### C-RP-14 (Info): A failing UnifiedPush distributor silently hands the user's wake-ups back to Google

- `lib/src/core/services/unified_push_service.dart:185-191`
  (`_onRegistrationFailed` ... `onFallBackToFirebase?.call();`) and :164-170 (no key set ->
  Firebase). The status shows "failed" in settings, but a user who chose UnifiedPush to keep
  Google out is back on FCM (C-RP-05's metadata) without being asked. LINDDUN Unawareness.
  Fix idea: ask before falling back, or fall back to no wake-ups. CONFIRMED.

### C-RP-15 (Info): Host checks and deploy docs drift from the box rules

- `check-host.sh` does not check kdump (a kernel crash dump writes the relay's RAM, memfd
  snapshot included, to `/var/crash`; :102-105 checks only `kernel.core_pattern`), the
  forwarder's `/etc/hollow-forwarder` secrets (:69-71 search `/etc/letsencrypt/archive
  /etc/hollow-relay /etc/hollow-push`), coturn's live peer lock, log file and CLI, or the
  sidecar's `PUSH_TOKEN` (C-RP-13). `relay-uws/deploy/hollow-forwarder.service:15-18` still says
  the engine writes `hollow_debug.log` (it no longer does, `forwarder/mod.rs:148-149`), and
  `relay-uws/deploy/forwarder.toml.example:5` sets `data_dir = "/home/ubuntu/forwarder/data"`,
  which `ProtectHome=yes` in the unit forbids. CONFIRMED (repo); the box itself not checked.

## Leads

- **L-09 relay rate limits (WP4).** Holds as AR-01: no per-message limits, connection caps
  (`ws_handler.cpp:2960-2973`), fair-share eviction (HOL-SEC-070), push budget
  (`ws_handler.cpp:1305-1312`, 30 per hour) and channel debounces (:1815-1838). C-RP-01 is not
  a rate issue (one frame), so AR-01 does not cover it.
- **K3 (iOS stranger wakes, matrix `relay:A-22`, `relay:A-24`, `transport:A-T10`, DEFERRED
  phase G).** The code still matches the deferral: Android names nobody for an unknown sender
  (`push_notification_service.dart:532-545`, test `authz_an_empty_wake_names_only_a_sender_we_know`),
  iOS shows the APNs generic alert before the NSE runs. A member can also wake any device id
  through 0x09 in a room it sees (threat_model F-36: yes, bounded by the channel debounces);
  same class, same deferral.
- **AR-14 (forwarder pin), AR-16 (D1 residuals), AR-18 (readable kill orders).** Unchanged by
  this slice. AR-15 and AR-19 assume the roster book and marks are lost only on a planned box
  reboot; C-RP-01 makes that loss attacker-triggered, so both ARs need re-review after the fix.
- **threat_model questions.** F-50 "which rooms may a stranger join": any room name; inbox
  rooms show owners only, D1 hides locked server rooms, DM rooms are HMAC names nobody outside
  the pair derives (`c24_a_dm_room_is_named_by_the_two_master_keys`), legacy rooms are AR-16.
  F-52: the snapshot codec is a P3 fuzz target. F-53: holds (R-RP-01). F-60 "what does sender
  reveal": the depositing device id, and for channels the server, channel and mention bit
  (C-RP-05).

## Protocol checklist

| Spec | Obligation on us | Compliance | Evidence |
|---|---|---|---|
| RFC 8030 §5.2 | The application server sets a TTL | Met: 24 h, matches the relay buffer | `push-sidecar/unifiedpush.js:13`, `:106` |
| RFC 8030 §5.3 | Urgency for a time-sensitive message | Met: `high` | `unifiedpush.js:107` |
| RFC 8030 §8 (security and privacy) | Push service sees metadata; app servers should avoid identifying content in what it sees | Met for UnifiedPush (body encrypted); not applicable to FCM/APNs, which are not Web Push, see C-RP-05 | `unifiedpush.js:105-108` |
| RFC 8291 (aes128gcm, the device's `p256dh`/`auth`) | Encrypt every push message to the subscription's keys | Met through `web-push` 3.6.7 with `contentEncoding: 'aes128gcm'`; a registration without keys is refused by the app | `unifiedpush.js:105-108`, `unified_push_service.dart:161-170` |
| RFC 8291 (receiver) | Drop what does not decrypt | Met | `unified_push_service.dart:75-84` |
| RFC 8292 (VAPID) | Optional | Off unless `VAPID_*` env is set; no targeted distributor requires it | `unifiedpush.js:16-23` |
| UnifiedPush server spec | Stop sending to an endpoint that answers 404/410 | Not met: the sidecar returns 410 to the relay (`unifiedpush.js:115-117`) and the relay discards the reply (`ws_handler.cpp:986-987` `recv(fd, buf, sizeof(buf), 0);`), so a dead endpoint is retried for every wake (availability and a needless request per wake; Info) | same |
| RFC 8656 §21 (security considerations) | Keep the TURN server from relaying into networks the operator protects; short-lived credentials | Met for private, loopback and metadata ranges; own address open (C-RP-10); credentials 1 h, HMAC over `expiry:hollow` | `coturn-start.sh:57-62`, `ws_handler.cpp:2838-2841` |
| FCM / APNs | Keep payloads free of content | Met for content; ids in clear (C-RP-05) | `push-sidecar/index.js:107-115`, `:182` |

## 13 classes (plan 2.2), asked of relay and push

1. **Authenticated but not authorised.** Relay registrations are keyed by the authenticated
   socket only (`ws_handler.cpp:1365`, `:1375`, `:1591`, `:1609`), and auth binds the peer id to
   the key (`:313-317`). Push payload fields are relay-authored hints the client authorises
   against its own state (fetch joins only a friend's DM room or a held server,
   `node/fetch.rs:72-85`). The sidecar trusts any holder of `PUSH_TOKEN` (by design). Nothing new.
2. **Infrastructure controls membership.** Through push the relay can make a phone fetch only
   rooms it already belongs to, and every fetched frame passes the live gates (matrix
   `transport:A-T00..A-T08`). It can name any friend in a forged wake, which shows a content-free
   "Name: Sent you a message" fallback on Android (AS-10 cosmetic, by K3's design). The roster
   book decides inbox routing only, never E2E membership. Nothing found beyond.
3. **Split view.** A relay can wake some devices of an identity and not others (availability).
   Nothing detects it; out of scope for push (no state changes from wakes).
4. **Withheld or rolled-back revocation.** The relay keeps a removed device's push token, but
   senders stop targeting removed devices (C-03). A duress-wiped device is not removed, so it
   keeps being targeted and woken (C-RP-02). A relay crash (C-RP-01) loses the roster book's
   removals; an old roster shown first after it re-opens a removed device's inbox at that relay
   until a newer roster is shown (HOL-SEC-078 residual made attacker-triggerable).
5. **Identifier confusion.** `sender` is a device id; the client resolves device to master
   (`identity_for_persisted`, hints keyed by master and every device). The reserved `~dm` key
   cannot be a room code (`~` is outside `is_valid_room_code`, `ws_handler.cpp:195-204`). iOS
   collapse ids hash `sender` or `server:channel`, disjoint shapes. Nothing found.
6. **Channel confusion.** FCM, APNs and UnifiedPush all land in `handlePushWake`; the NSE, the
   Android isolate and the live-node nudge share the Rust fetch gates (K class, HOL-SEC-035,
   HOL-SEC-086). Nothing found.
7. **Unknown key-share.** No key agreement in push. Web Push keys are minted on the device by
   the connector and registered over the authenticated socket; a relay can only register keys
   for its own registrations. n/a.
8. **Replay.** A replayed wake only triggers a fetch; buffered frames are judged by seal time
   and the Olm read mark (AR-19), deduped by message id. Snapshot replay across a restart is the
   same frames. Nothing found beyond C-RP-01's loss of state.
9. **Downgrade and length checks.** `PUSH_TOKEN` unset means open (C-RP-13); the four
   `ACCEPT_*` release-day switches are tracked elsewhere. UnifiedPush without a key set is
   refused (good). Length checks: push token 4096 B at the relay (`state.h:99`), 2048 B and
   endpoint 1024 B at the sidecar (`unifiedpush.js:9-10`); pre-auth frames 16 KiB
   (`auth_frame.h:40`); text frames 1 MiB, but NESTING DEPTH is unchecked (C-RP-01).
10. **Unauthenticated metadata.** `sender`, `server`, `channel`, `mention` in a wake and the
    0x09 flag byte are unauthenticated; each is used as a hint and re-judged on the device
    (mention by `post_mentions_member`, HOL-SEC-035; server membership, J4). The relay's own
    prefs filter trusts the sender's mention bit, so a member can wake a "mentions only" phone,
    which then shows nothing (K3 class).
11. **State and key lifecycle.** The wipe misses the push files (C-RP-02); the forwarder never
    prunes sessions (C-RP-07); a crash skips the snapshot (C-RP-01). SUSPECTED, not traced to
    the end: the NSE checks the 12 s app heartbeat only when it starts, and nothing stops the app
    starting its node during the NSE's 18 s fetch, so both can persist an Olm session for the
    same peer and the later write wins (availability, re-key through AR-19's rules).
12. **Device linking and cloning.** An iOS device backup restored onto a second phone clones the
    device id and keys (C-RP-03, SUSPECTED); the clone's push registration then replaces the
    original's at the relay ("one token per device"), so the original silently stops waking.
13. **What a stranger can trigger or observe.** Wakes: through 0x04 into a non-existent room
    (`ws_handler.cpp:2138-2160`), 30 per hour per device (K3, deferred). Presence: fetch sockets
    are never listed (`:741-754`, `:2780`), `check_peers` and `discover_peers` answer co-members
    only (HOL-SEC-064, HOL-SEC-091), nickname resolve tells whether a claimed nickname's holder is
    connected (by design), `/server-stats` counts users (C-RP-12). A stranger can also crash the
    relay (C-RP-01) and use TURN between two allocations of its own (by design, open relay).

## LINDDUN GO: relay (P-01) and push providers (P-11)

### What each relay registry and frame lets P-01 learn

| Registry or frame | What is learnable | Where it lives | Notes |
|---|---|---|---|
| `ws_rooms`, `peer_rooms`, `members`/`peer_joined` | Which device ids are in which rooms, when | RAM only, not in the snapshot | Accepted routing metadata (C-24) |
| `inbox:{master}` rooms and owners | The master id in clear; every owning device of it | RAM | Links all of a person's devices (C-24 note 2) |
| DM rooms (`node/dm_room.rs`) | A name nobody outside the pair derives; which two identities' devices share it | RAM | Who talks to whom (C-24) |
| Server rooms, join lock chains | Server id; its owner (a genesis id commits to the owner, the chain carries owner and door keys) | RAM + snapshot | Owner of each locked server is readable: list it in C-24's note |
| 0x07 topics and per-socket subscriptions | Channel id per frame; which channels each device follows | RAM | Reveals who can see a restricted channel (as routing); add "topics" to C-24's note |
| Offline buffer (0x04/0x08/0x09) | Target device, room, sender device, size, age, depositor's address share | RAM + snapshot | Ciphertext only |
| Rings | Per-channel frames with sender device ids and ages | RAM + snapshot | Ciphertext or signed public posts |
| `push_tokens` | Device id to FCM/APNs token or UnifiedPush endpoint + keys | RAM + snapshot | A self-hosted push server's host names its owner; same token across identities (C-RP-09) |
| `push_prefs` | Every server id of each phone, mute levels per server and channel, muted contacts' masters and devices, own siblings | RAM + snapshot | C-RP-06 |
| `offline_optin`, `registrations` | Retention choice; device to hashed address share | RAM + snapshot | Share ids are keyed by an hourly key never persisted |
| `kill_list` | That an identity ordered devices destroyed, issuer, targets | RAM + snapshot | AR-18 |
| `roster_book` | Every identity's full device graph, recovery public key, pending-join first sights | RAM + snapshot | ID-1R; the privacy policy does not mention it (C-RP-06) |
| `device_list_max_version` | Per-master list version | RAM + snapshot | |
| nicknames, link codes | Nickname to device and master; code to device | RAM only | |
| `ip_states`, `link_guesses` | Address (v4, v6 /64) to connection counts and failed guesses | RAM only | Never logged (`ws_handler.cpp:2953-2976`) |
| push throttles | When each device was last woken | RAM only | |
| `reports.json` + `.key` | Reported device ids with counts; keyed fingerprints and their key | DISK | The one documented disk record (C-RP-11) |
| `forwarder.db` | Every device id that used the forwarder | DISK | C-RP-07 |
| `/server-stats` | Online count, bandwidth, forwarder counters, to anyone | public HTTP | C-RP-12 |
| coturn | Client addresses, which allocations talk, bytes, time | RAM; logs `/dev/null` in Docker; official box unverified | TURN username `expiry:hollow` names no user |

IP addresses: RAM only in the relay (`ip_limit_key`, `share_block`, both keyed maps never
written; `socket_share` hashes under a key replaced hourly, `ws_handler.cpp:71-79`, never in the
snapshot). Logs: relay stderr carries counts only (`ws_handler.cpp:457`, `:1236`,
`snapshot.cpp:282-288`); journald volatile, rsyslog drops `hollow-*` and `turnserver`, ufw
logging off (`harden-host.sh`, checked by `check-host.sh:100-127`). Sidecar logs platform, status
and code only (`index.js:199`, `:203`, `unifiedpush.js:116-125`).

### The seven categories

- **Linking.** P-01: a person's devices through inbox owners and the roster book; two people
  through a shared DM room; a device across a wipe through its push token (C-RP-09); servers to
  owners through join locks. P-11: one install's token across every wake; recipients sharing a
  `server` id, senders across accounts by `sender` id (C-RP-05). UnifiedPush server: one endpoint
  only, ciphertext body.
- **Identifying.** P-01 holds no names; a UnifiedPush endpoint on a self-hosted push server names
  its owner. P-11 maps Hollow device ids to Google or Apple accounts by reply timing (C-RP-05).
- **Non-repudiation.** The relay keeps no logs (deniability preserved); the report fingerprints
  are testable with the key on disk (C-RP-11). Google and Apple keep delivery records naming a
  sender id per account: evidence that account X received messages from device Y (C-RP-05).
- **Detecting.** P-01 sees when each phone is woken and fetches (fetch sockets are invisible to
  peers, not to the relay). Anyone sees the online count (C-RP-12). A coercer detects a duress
  wipe from post-wipe banners (C-RP-02). P-11 detects Hollow use and activity levels (inherent).
- **Data disclosure.** Push prefs (C-RP-06), the forwarder's disk (C-RP-07), FCM data block
  (C-RP-05), iOS backups (C-RP-03), the push log (C-RP-08), notifications under App Lock (C-RP-04).
- **Unawareness.** Silent UnifiedPush fallback to Google (C-RP-14); the privacy policy says Google
  and Apple never learn "who anyone is in any real-world sense" (`PRIVACY_POLICY.md:59`), which
  the stable ids undercut.
- **Non-compliance.** The privacy policy's relay section (`PRIVACY_POLICY.md:42-48`, `:129`) states
  the relay has no access to server membership or contacts and that only the report counter
  reaches disk; both are wrong (C-RP-06, C-RP-07). Data minimisation: default push-pref entries
  serve no filter (C-RP-06).

### Claims and documents against the code

| Statement | Code | Verdict |
|---|---|---|
| C-24 (relay sees routing only, never "other data") | Push prefs carry mute settings and muted contacts; roster book; topics; join-lock owners | Mostly holds; push prefs exceed it (C-RP-06); note 2 should list rosters, topics, owners, push filters |
| C-25 (relay cannot forge a message ...) | A relay can forge a wake that names a friend in a content-free fallback banner | Holds (no content); note the cosmetic spoof |
| C-26 (only a wake and a sender id) | Channel wakes add server, channel, mention | Overclaimed (C-RP-05) |
| C-07 (duress shows nothing) | Post-wipe banners, surviving hints and push log | Broken (C-RP-02) |
| C-35 (App Lock hides names and notifications) | Notifications carry names and text while locked | Broken or overclaimed (C-RP-04) |
| WP 3.1 "the relay never learns that two peer IDs belong to one person" | Inbox owners, roster book | Wrong; known, rewrite pending at close-out (claims.md note 2) |
| WP 13.1 "never ... who-is-who beyond opaque IDs" | Stable ids are linkable | Understated (C-RP-05) |
| WP 13.3 "a coarse ... signal" for push prefs | Full server list, channel levels, muted contacts | Understated (C-RP-06) |
| WP 13.7 UnifiedPush encrypted, https, public address at connect | Matches | Holds (R-RP-09, R-RP-11) |
| WP 23.1 "Relay compromise ... learns only peer IDs and room membership" | Plus rosters, push prefs, kill orders, tokens; forwarder disk | Overclaimed |
| WP 23.1 "Push-provider metadata ... `{wake, sender}` only" | Channel fields | Overclaimed (C-RP-05) |
| WP 23.1 "Coercion at the unlock prompt ... showing nothing" | C-RP-02 | Broken |
| Privacy policy, relay and TURN sections | C-RP-06, C-RP-07, C-RP-11; TURN logging unverified on the box | Overclaimed |

## STRIDE grid

Legend: covered (matrix row, finding or AR) | met (evidence) | candidate | n/a.

**P1 relay process (X-2 as a host process; TB-1, TB-10)**
- S: covered `relay:0.1`, `relay:A-01` (HOL-SEC-063: auth v2, peer id derived from the key,
  `ws_handler.cpp:313-317`); TLS to clients via the domain certificate, reloaded in place
  (`main.cpp:56-70`).
- T: met: binary root-owned, `check-host.sh:41-44` fails if the service can rewrite its program;
  `ProtectSystem=strict`, only `StateDirectory` writable (`hollow-relay.service`).
- R: met by design: no per-user logs (deniability over audit); reports counter only.
- I: met for logs and IPs (see LINDDUN); `LimitCORE=0`, no swap, `ProtectProc=invisible`,
  secrets in the root-only `EnvironmentFile` (`hollow-relay.service`, HOL-SEC-074); candidate
  C-RP-15 (kdump unchecked), C-RP-12 (stats).
- D: candidate C-RP-01 (one-frame crash). Flood and rate limits are phase G (AR-01). One-frame
  allocation bounds: text 1 MiB (`:3013`), pre-auth 16 KiB, proof arrays 1024
  (`:509`), subscription caps (`state.h:105-106`), push token 4096, kill blob and targets
  (`KillList`), lock chains 256 links, budget eviction for buffers (512 MB) and registrations
  (128 MB). Exceptions caught on every path (`:3004-3009`, `:3017-3021`, `:3047-3082`).
- E: met: own account `hollow-relay`, only `CAP_NET_BIND_SERVICE` ambient,
  `NoNewPrivileges`, `SystemCallFilter=@system-service ~@privileged @resources`,
  `SystemCallErrorNumber=EPERM` (EPERM, never kill), `MemoryDenyWriteExecute`,
  `RestrictNamespaces`; HOL-SEC-073.

**P2 push sidecar**
- S: met when `PUSH_TOKEN` is set: constant-time compare (`index.js:18-24`), loopback bind
  (`:211`); candidate C-RP-13 (empty token means open).
- T: met: code root-owned in `/opt/hollow-push` (unit header), `ProtectSystem=strict`.
- R: met by design: no per-push log (`index.js:192`).
- I: met: logs platform, status, code; Firebase credential via `LoadCredential` (RAM dir,
  `hollow-push.service`); SSRF guard (R-RP-09) with residuals C-RP-13.
- D: met: relay-side queue bounded at 4096, drop-oldest (`ws_handler.cpp:938`, `push_queue.h`),
  2 s socket timeouts (`:944-946`), 5 s Web Push timeout; request body unbounded only for
  callers past the token check (local, C-RP-13).
- E: met: own account, `PrivateUsers=yes`, empty capability set, `NoNewPrivileges`, syscall
  filter with EPERM; no `MemoryDenyWriteExecute` (V8 JIT, documented in the unit).

**P3 media forwarder (host process)**
- S: covered `media:*` rows (forwarder PreKey check, HOL-SEC-041 class); relay pins it by
  `--forwarder-peer-id` (AR-14).
- T: met: root-owned binary, `ProtectSystem=strict`.
- R: n/a (no user-facing actions).
- I: candidate C-RP-07 (`forwarder.db`); logs RAM-only (`the_headless_forwarder_opens_no_log_file`).
- D: met: refuse-new budgets (`forwarder.toml.example:14-20`), stale-leg TTL (`engine.rs`);
  unbounded session table growth across identities (C-RP-07, phase G).
- E: met: own account, `PrivateUsers`, no capabilities, EPERM filter.

**P4 coturn**
- S: met: `use-auth-secret` HMAC credentials, 1 h (`ws_handler.cpp:2838-2841`), not user-bound
  (`relay:A-18`, by design).
- T: met (Docker: read-only root, secret in a 0600 tmpfs file, `coturn-start.sh:13-16`; box:
  drop-in sandbox `coturn-sandbox.conf`).
- R: met by design: logs to `/dev/null` with `--simple-log` (`coturn-start.sh:54-56`); box config
  not checked.
- I: met for metadata ranges; candidate C-RP-10 (own address).
- D: phase G (bandwidth); `no-multicast-peers`, `no-tcp-relay`.
- E: met: Docker `cap_drop: [ALL]` + `NET_BIND_SERVICE`, `no-new-privileges`; box drop-in with
  EPERM filter.

**P5 push extension E-04 (Android isolate, UnifiedPush background entry, iOS NSE)**
- S: covered `transport:A-T00`, `A-T11`, `A-T12` (joins only friends' DM rooms and held servers;
  frames sealed and judged). Forged wakes name only known senders on Android (K3; iOS deferred).
- T: covered `transport:A-T02..A-T08` (rows changed only by their owners' gates); NSE and app
  as concurrent DB writers SUSPECTED (class 11).
- R: n/a.
- I: candidates C-RP-02, C-RP-03, C-RP-04, C-RP-08; met for the NSE's own log (lengths only,
  `NotificationService.swift:113-114`, `:193-194`).
- D: met: fetch timeouts (the 18 s argument at `NotificationService.swift:108`), `FETCH_ACTIVE` guard;
  a panic inside `hollow_push_fetch_and_decrypt` aborts the NSE (Rust 2024 `extern "C"`
  unwinding aborts; there is no `catch_unwind`), which leaves the APNs generic banner: Info.
- E: met: the NSE is a separate sandboxed process; the C-ABI takes only strings
  (`push_enrich.rs:47-81`).

**D1 relay RAM registries** (buffers, rings, tokens, prefs, opt-ins, kill list, locks, rosters, marks)
- T: covered by the matrix rows for each writer (`relay:A-02`, `A-11..A-17`, `A-22..A-24`).
- I: see the LINDDUN table; candidate C-RP-06.
- D: covered HOL-SEC-069/070 (fair-share budgets); candidate C-RP-01 (all lost on crash).

**D2 memfd snapshot (F-52, TB-10)**
- T: met: written only on SIGTERM, read once and removed from the store before parsing
  (`snapshot.cpp:291-296`), size bounded (`:299`), decode failure discards (`:321-324`); only
  root or systemd can reach the fd.
- I: met: memfd in RAM, `MFD_CLOEXEC`, no swap, no core dumps; kdump unchecked (C-RP-15).
- D: met: a box reboot loses it (AR-15, AR-19 name the effects); C-RP-01 adds crash loss.

**D3 `reports.json` + `.key` (disk)**
- T: met: atomic 0600 writes (`reports.cpp:66-85`).
- I: candidate C-RP-11.
- D: met: 500,000 key cap (`reports.cpp:19`); count inflation AR-08.

**D4 `forwarder.db` + `forwarder.key` (disk)**
- T: met: `StateDirectoryMode=0700`, key 0600 (`forwarder/mod.rs:135-139`).
- I: candidate C-RP-07.
- D: unbounded rows (C-RP-07, phase G).

**D5 iOS App Group (`hollow_data`, `push_hints`, `push_diag`)**
- T: met: app and NSE only (App Group entitlement); atomic hints swap (`push_hints_cache.dart:133-140`).
- I: candidates C-RP-02 (survives wipes), C-RP-03 (backups), C-RP-04 (names under App Lock).
- D: met: hints rewrite debounced; NSE metrics log capped 64 KB.

**D6 `push_debug.log`**
- T: n/a (diagnostics).
- I: candidates C-RP-08, C-RP-02.
- D: met: capped at 1 MB (`push_notification_service.dart:268-277`).

**F-50 room join, leave, RoomMembers (TB-1)**
- T: covered `relay:A-02`, `A-03`, `B-07` (HOL-SEC-040/083/091).
- I: covered `relay:0.2`, `A-06`, `A-07` (inbox and D1 audiences); fetch sockets never listed
  (R-RP-03).
- D: candidate C-RP-01 (the join frame); room caps per socket (`ws_handler.cpp:722-728`).

**F-51 0x03, 0x07, rings, availability cache**
- T: covered `relay:A-21`, `A-23`, `A-16`, `A-17` (HOL-SEC-030/065/091).
- I: covered; ciphertext only; topics visible (LINDDUN table).
- D: covered HOL-SEC-069/070 (byte budgets), AR-01.

**F-52 memfd snapshot**: as D2 (T met, I met, D met plus C-RP-01).

**F-53 push token and prefs registration**
- T: met: self-only (R-RP-01); covered `relay:A-11`, `A-13`, `A-14` (no ws_handler test).
- I: candidate C-RP-06 (prefs content), C-RP-09 (token reuse).
- D: covered HOL-SEC-070 (registration budget evicts the heaviest share).

**F-60 relay to sidecar to FCM/APNs/UnifiedPush to device (TB-6)**
- T: met: loopback hop with `X-Push-Token` (`ws_handler.cpp:971-981`); provider hops over TLS;
  UnifiedPush body AEAD-encrypted to the device.
- I: candidate C-RP-05 (FCM/APNs ids); met for UnifiedPush.
- D: met: debounce 10 s and 30 per hour per target (`ws_handler.cpp:1289-1312`); channel
  debounces (`:1815-1838`); a stranger's wakes are K3 (deferred).

**F-36 0x09 channel push (TB-1)**
- T: covered `relay:A-24` (HOL-SEC-127: only a socket that sees the room).
- I: as F-60.
- D: covered by the channel debounces and `MAX_PUSH_SERVERS_PER_TARGET` (`state.h:102`); K3.

**F-44 TURN credentials**
- T: covered `relay:B-16` (HOL-SEC-066, relay-supplied host refused by the client).
- I: met: credentials ride the authenticated socket only (`ws_handler.cpp:2833-2847`,
  `http_handlers.cpp:38-44`).
- D: phase G.

**Relay to sidecar loopback flow**
- T: met: localhost, shared secret header.
- I: met: carries token, platform and ids only; no content.
- D: met: bounded queue, 2 s timeouts, never on the event loop (`push_queue.h`).

**Sidecar to provider flows**
- T: met: TLS (firebase-admin; `https.Agent` for Web Push).
- I: candidate C-RP-05 (FCM/APNs), met (UnifiedPush).
- D: n/a (provider availability, AR-04).

**X-5 push providers (FCM, APNs)**
- S: n/a for us to prevent (a provider can inject any wake); effect bounded as P5-S.
- R: candidate C-RP-05 (provider-side delivery records are evidence about users).

**UnifiedPush push server and distributor**
- S: met: undecryptable messages dropped (`unified_push_service.dart:75-84`).
- R: met: sees only ciphertext of fixed shape for one endpoint.

### Fuzz targets for phase G (network-facing parsers, by priority)

- P1 (any internet socket, before auth): `parse_auth_frame`, `is_auth_hello`
  (`relay-uws/src/auth_frame.h`), including nesting depth.
- P1 (any free identity, one frame): `handle_text_message` as a whole with a depth-limited
  harness, and each field reader behind it: `roster::from_json` plus the size check
  (C-RP-01), `parse_inbox_proof`, `kill_order::from_json` after `base64_decode`,
  `join_lock::links_from_json`, `ring_auth::parse`, the nickname claim, `handle_set_push_prefs`,
  `handle_subscribe`, `check_peers`.
- P1: the binary opcode parsers 0x02, 0x03/0x0A, 0x04/0x08, 0x07, 0x09 (inline in
  `ws_handler.cpp:1851-2325`; pull into testable functions first).
- P2 (relay-controlled input on phones): `rust/hollow_core/src/node/fetch.rs` frame parsing (runs in
  the NSE and the Android isolate), `push_enrich.rs` inputs; the sidecar's `parseToken` (Node,
  a JS fuzzer); `verify_signed_device_list` (`device_list.cpp`), `door_room` proofs.
- P3 (own or local input): `snapshot_codec.h` decode, `ReportsState::load_from_file`,
  `LicenseState::load_from_file`.

## Requirements

| ID | Requirement | Evidence | Test |
|---|---|---|---|
| R-RP-01 | An authenticated socket registers, replaces or deletes a push token, push prefs or the offline opt-in only for its own authenticated peer id. | `ws_handler.cpp:1365`, `:1375`, `:1591`, `:1609`; key binding `:313-317` | no test (matrix `relay:A-11`, `A-13`, `A-14`: none) |
| R-RP-02 | A guest socket cannot register a token, set prefs, deposit a direct or get TURN credentials. | `ws_handler.cpp:1363`, `:1567`, `:1953`, `:3034`, `:2833` | `test_relay_live.cpp` "a guest's direct (0x04) is dropped", "its JSON direct too", "no TURN credentials for a guest" |
| R-RP-03 | A fetch socket is never listed in members, presence, discovery or `check_peers`, and never displaces the device's full socket. | `ws_handler.cpp:741-754`, `:675`, `:2780`; `peer_sockets` only for full sockets `:415-441` | `test_relay_live.cpp` "a fetch login leaves the device's full socket in place", "never its fetch socket" |
| R-RP-04 | No relay, sidecar or forwarder log line carries a peer id, room, token, endpoint, address or push routing. | `ws_handler.cpp:457`, `:1236`; `snapshot.cpp:282-288`; `index.js:199`, `:203`; `unifiedpush.js:116-125` | `the_headless_forwarder_opens_no_log_file`; relay and sidecar: no test |
| R-RP-05 | Everything the relay keeps across a restart rides the fd store as a memfd; the report counter is the relay's only file. | `snapshot.cpp:262`, `:279`; `reports.cpp:66-85` | `test_snapshot_codec.cpp`; `check-host.sh` Disk section |
| R-RP-06 | No frame from an unauthenticated socket is parsed past 16 KiB, and no client frame's exception reaches uSockets. | `auth_frame.h:40-57`; `ws_handler.cpp:3004-3009`, `:3017-3021`, `:3047-3082` | `test_auth_frame.cpp` |
| R-RP-07 | NOT MET. No single client frame can exhaust the relay's stack: nesting depth is bounded before any recursive walk. | violated at `ws_handler.cpp:700` (C-RP-01) | no test |
| R-RP-08 | With `PUSH_TOKEN` set, the sidecar refuses unauthenticated callers in constant time and logs nothing about them. | `index.js:18-24`, `:79-86` | no test |
| R-RP-09 | The sidecar posts UnifiedPush only to `https` URLs without credentials whose host resolves, at connect time, to a public address (loopback, RFC1918, CGNAT, link-local incl. 169.254.169.254, ULA, multicast and documentation ranges refused, IP literals too), with a 5 s timeout. | `unifiedpush.js:25-35`, `:49-65`, `:89-93`, `:105-112` | no automated test (manual, `reports/shipped/relay-and-sync/UNIFIEDPUSH_PLAN.md` "What was verified") |
| R-RP-10 | A wake to FCM or APNs carries no message content, and the iOS alert text is fixed. | `index.js:107-115`, `:182` | no test |
| R-RP-11 | UnifiedPush wakes are encrypted to the device's own key set; the app drops what does not decrypt and never registers a distributor without keys. | `unifiedpush.js:105-108`; `unified_push_service.dart:75-84`, `:161-170` | no test |
| R-RP-12 | A push fetch joins only the DM room of an accepted, unblocked friend or a server we are a member of. | `node/fetch.rs:72-85` | `a_channel_wake_for_a_server_we_do_not_hold_joins_nothing`, `a_dm_wake_from_a_stranger_joins_nothing`, `a_dm_wake_names_only_ourselves_or_a_friend` |
| R-RP-13 | An empty wake from someone we do not know shows no banner naming anyone (Android; iOS deferred to K3). | `push_notification_service.dart:532-545`; `api/network.rs:2552-2565` | `authz_an_empty_wake_names_only_a_sender_we_know` |
| R-RP-14 | The NSE logs only timings, footprint and lengths, never decrypted text. | `NotificationService.swift:113-114`, `:193-194` | no test |
| R-RP-15 | A channel copy or wake comes only from a socket that sees the room. | `ws_handler.cpp:1887-1893` | `test_relay_live.cpp` "door rooms (D1): a hidden socket leaves no channel copy"; `authz_a_socket_the_room_hides_leaves_no_channel_copy` |
| R-RP-16 | DM wake-ups to one device are at most one per 10 s and 30 per hour, channel wakes within their debounces; over budget only the wake is skipped, never the deposit. | `ws_handler.cpp:1289-1312`, `:1815-1838` | no test (matrix: "the push budget and mute in the handler: none") |
| R-RP-17 | TURN credentials go only to authenticated non-guest sockets, expire within an hour, and coturn relays to no loopback, private, link-local or metadata address. | `ws_handler.cpp:2833-2847`; `coturn-start.sh:57-62` | `test_relay_live.cpp` "no TURN credentials for a guest", "a member gets them"; coturn: none |
| R-RP-18 | Each relay-box service runs as its own non-sudo account in a sandbox, with secrets only in root-only `EnvironmentFile`/`LoadCredential`, no core dumps, and EPERM for denied syscalls. | `hollow-relay.service`, `hollow-push.service`, `hollow-forwarder.service`, `coturn-sandbox.conf` | `check-host.sh` (on the box) |
| R-RP-19 | NOT MET. A wiped device (duress, remote destroy, roster erase) keeps no friend names, avatars or push timeline, and stops being woken for the destroyed identity. | violated (C-RP-02) | no test |
| R-RP-20 | NOT MET. While App Lock is engaged, no notification shows a name, avatar or message text. | violated (C-RP-04) | no test |
| R-RP-21 | NOT MET. The relay box keeps no user record on disk other than the report counter. | violated by `forwarder.db` (C-RP-07) | no test |
| R-RP-22 | NOT MET (SUSPECTED). Hollow's iOS data and push hints never enter a device backup. | no exclusion anywhere (C-RP-03) | no test |
| R-RP-23 | The relay holds only the push filters it needs: no server or channel at the default level. | not met today (C-RP-06) | no test |
| R-RP-24 | The relay restart handoff writes the snapshot before the listen socket closes, restores it before listening, and discards an unreadable or oversized one. | `main.cpp:91`, `:217`; `snapshot.cpp:291-325` | `test_snapshot_codec.cpp` ("a v7 snapshot decodes under this reader" and the others) |

## Could not check

- The official box's `/etc/turnserver.conf` (peer lock, CLI, log file) and whether kdump is
  installed there: not in the repo, and this pass does not log into production.
- iOS backup inclusion of the App Group and Documents containers (C-RP-03): needs a device or
  simulator.
- `web-push` 3.6.7 internals (agent use, no redirects): the library source is not in the tree;
  relied on its documented API and the UnifiedPush plan's manual verification.
- The exact stack depth that kills the relay (C-RP-01): not run, per the no-run rule.
- Whether the OS lock screen already hides previews by default on each platform (C-RP-04): the
  claim is about App Lock, so it holds either way when the phone itself is unlocked.
