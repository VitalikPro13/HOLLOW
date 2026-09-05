# Fleet probe (driving N real Hollow instances against each other)

Source: `scripts/fleet.ps1` (scenarios), `scripts/fleet_send.ps1` (interactive),
`scripts/fleet_lib.ps1` (shared talk-to-an-instance code), `scripts/probe_scenarios/fleet/*.json`
Shares the runner with the single-peer probe: `integration_test/ui_probe_test.dart`,
`integration_test/probe/{probe_runner,probe_targets,probe_dump}.dart`
Design it came from: `tmp3.md` (2026-08-21). Built the same day.

## What it is

**Several real Hollow instances on this machine, each with its own identity and data directory,
all driven from one peer-tagged scenario.** Peer-to-peer behaviour is tested by watching it happen
instead of by Vitalik reproducing it and describing it.

```
powershell -File scripts/fleet.ps1 -Build                  # build + stage the copies
powershell -File scripts/fleet.ps1 -Onboard                # stamp the fixture identities
powershell -File scripts/fleet.ps1 -Live                   # boot and leave them up
powershell -File scripts/fleet.ps1 -Scenario friend_dm -Attach
powershell -File scripts/fleet.ps1 -Stop
powershell -File scripts/fleet_send.ps1 -Command '[{"peer":"a","op":"look"}]'
```

`pwsh` is NOT installed on this machine: use `powershell -File`. Both scripts are 5.1-compatible.

## The fast loop, and what each part of it costs

Measured, not estimated:

| step | cost |
|---|---|
| first build (cargokit + cmake + every plugin) | minutes, once |
| incremental build after a Dart change | 18s |
| restage both copies (robocopy, only what changed) | under 1s |
| boot to live-ready | 13s |
| one interactive command | ~1s |
| `friend_dm` / `server_invite_message` / `unread_line` | 29s / 33s / 2min |

So: **`-Live` ONCE, then `-Attach` for scenario runs and `fleet_send.ps1` for everything
else.** Booting restores the fixtures, which throws away whatever state you were looking at;
attaching costs nothing and keeps it. `-Attach` never stops the fleet, and neither does a FAILED
run - a failure is exactly when the screen is worth looking at, and attaching picks up from there
instead of replaying the twenty steps that already worked.

**A batch can mix peers, and should.** A round trip through the script is a second; a round trip
through whoever is reading the output is far more. "A sends, B waits for it, B shows me what it
has" belongs in ONE call:

```
powershell -File scripts/fleet_send.ps1 -Command '[
 {"peer":"a","op":"enter_text","target":"field","value":"hi"},
 {"peer":"a","op":"key","value":"enter"},
 {"peer":"b","op":"wait_for","target":"text:hi","timeout_ms":30000},
 {"peer":"b","op":"look"}]'
```

Steps run strictly in order, each waiting for its answer before the next is sent. Ten steps across
two instances, including a `capture`, measured at 14s.

## The gap it fills

The Rust multi-node harness (`node/test_harness.rs`) proves the OPS converge. The single-peer UI
probe proves one instance's widgets. Neither can answer "does the kicked member disappear from the
member panel", "does the receiver's chat show it without a refresh", "does the optimistic write
reconcile with the one that arrives". Every issue #61 bug lived in exactly that seam, and so did the
profile light-announce leak and the self-message unread pill.

**What it must not become:** a second multi-node harness. Two real apps plus the real relay is
half a minute per journey and inherently timing-sensitive. Convergence, MLS epochs, revocation and
anything needing five or more nodes stay in Rust, where a run is seconds and deterministic. If a
scenario starts looking like a protocol test, it belongs in the other harness.

## How N instances coexist (the thing that was thought impossible)

Session 2 recorded "two instances of the same exe cannot coexist". Half true, and the other half is
what makes this work.

1. **`SendAppLinkToInstance()` matches on the EXE PATH** (app_links 7.2.1,
   `windows/app_links_plugin_c_api.cpp`: `QueryFullProcessImageNameW` + `_wcsicmp` against our own).
   Two copies of `hollow.exe` in different folders do not match each other, so the second boots
   normally. Same-folder relaunches still forward, so deep links keep working exactly as they do.
2. **The Dart PID lock never runs.** `flutter build windows -t integration_test/ui_probe_test.dart`
   makes an exe whose entrypoint is the probe body, not `main()` — so `_acquireSingleInstanceLock()`
   is never called. (That matters: without portable/pinned mode the lock lives at
   `%APPDATA%\Hollow\hollow.lock`, which every instance would share.)
3. **Building once and COPYING** sidesteps the real obstacle, which was never the app: two
   concurrent `flutter drive` runs race on `build/windows` and one loses.

Copying also kills probe trap 2 (the stale cargo DLL): FRB resolves `ioDirectory` relative to the
CWD, and only `flutter drive` has a CWD at the repo root. A copy launched from its own folder loads
its own bundled DLL, like an install does.

## Layout

| what | where |
|---|---|
| staged exe per instance | `build/fleet/<peer>/` (~365 MB each, `-Build` re-stages) |
| artifacts per instance | `build/fleet_out/<peer>/` (results.jsonl, map-*.md, *.png, stdout.log, errors.log) |
| fixture identities | `%TEMP%\hollow_fleet\fixtures\<peer>` |
| the run's data dir | `%TEMP%\hollow_fleet\run\<peer>` (restored from the fixture each run) |

Fixtures hold real Ed25519 keys, so they live outside the repo where no `git add -A` reaches them.

## Fixture identities

Fresh identities have to walk the welcome flow, which doubles every run and puts the flakiest UI in
the app in front of every test. `-Onboard` walks it ONCE per peer and stamps the data directory:
create identity, dismiss the recovery phrase, wait for the node to actually connect, then set the
display name to `probe-<peer>`.

**The display name is not cosmetic.** Without one, every friend row, member panel entry and DM tab
reads `12D3KooW...` and nothing in a scenario can address any of them. With it, `text:probe-b` is a
real assertion.

`-Onboard` always starts from an EMPTY data directory (a restored fixture would leave the app in the
shell, and every onboarding step would fail looking for a screen already behind it), and it only
stamps a fixture if onboarding finished: a half-onboarded directory looks like a fixture and fails
every later run.

### When a stable identity is the bug (`-Fresh` / `-KeepIdentities`)

Stable identities are what makes a scenario cheap, and they are exactly wrong for the friend
journeys. The relay buffers a friend request against `inbox:{master}` and replays it, TTL-only, for
three days, so `fleet_friend_offline.ps1` and `fleet_friend_decline.ps1` run against a peer whose
mailbox still holds their own earlier runs: a `wait_for` passes on yesterday's request, and
"Incoming must be EMPTY" fails against a request nobody sent today.

* **`fleet.ps1 -Onboard -Fresh -Peers a,b`** deletes `%TEMP%\hollow_fleet\fixtures\<peer>` before
  onboarding, so the welcome flow mints a new mnemonic and a new master id, and the new identity's
  mailbox is empty. `-Onboard` alone already starts from an empty data dir and so already mints new
  keys; `-Fresh` throws the old fixture away first and makes the intent greppable. It is an error
  without `-Onboard`.
* **Both friend journeys default to fresh identities.** They call `Start-FreshFleet` in
  `fleet_lib.ps1` (stop, `-Onboard -Fresh`, `-Live`, then print each peer's new peer id), so they
  need no fleet up first and cost about a minute more. `-KeepIdentities` drives whatever fleet is
  already live instead, for iterating on the journey rather than the behaviour.

## Scenario format

A JSON object with `peers`, `steps` and `cleanup`; every step carries the `peer` that runs it
(`"all"` fans out sequentially). Ops and targets are the single-peer probe's, unchanged.

```json
{ "peer": "a", "op": "capture", "target": "type:SelectableText", "as": "INVITE" }
{ "peer": "b", "op": "enter_text", "target": "hint:Invite link or server ID", "value": "${INVITE}" }
{ "peer": "b", "op": "wait_for", "target": "server:fleet-probe", "timeout_ms": 90000 }
```

The orchestrator is a sequential loop: expand `${VAR}`, write the step to that peer's
`inbox.jsonl`, wait for the matching id in its `outbox.jsonl`, merge anything it captured, move on.
Steps for different peers could run concurrently later; do NOT start there, sequential is
debuggable.

**`cleanup` runs whatever happened**, and never stops on its own failures. Leaving a fleet server
alive is worse than a noisy log.

## Three ops the fleet needed

* **`wait_for`** — `target` (appears), `gone` (disappears), `count`, `timeout_ms` (default 15000).
  Polls every ~200ms and passes the moment it holds. A fixed `wait` is fine when one app talks to
  itself; put a relay round trip in the middle and it is a coin flip. **This op is the difference
  between a suite that gets trusted and one that gets ignored**, which is why it was built before
  the first scenario rather than after the fifth. `gone` means BECAME absent, so it proves a
  disappearance, not a permanent absence: for "never shows up", `wait` then `expect_no_text`.
* **`look`** — what is on screen, IN the answer: the open dialog, the menu rows, every addressable
  control and the visible text. `filter` narrows it, `max` caps it. `dump` is still the tool for a
  real diagnosis (it has the provider state and the layout outline) but most of the time the only
  question is "what do I click next", and answering that by writing a file and then reading and
  grepping it costs a whole extra round trip. Batch it after whatever changed the screen.
* **`capture`** — `as` plus one of `target` (the widget's text), `from: "provider"` + `key` (the
  dump's provider snapshot, e.g. `peerId`), or `from: "clipboard"`. Optional `regex` narrows it.
  The value comes back in the answer, and the orchestrator substitutes it into later steps on OTHER
  instances. That is how an invite link crosses from the app that generated it to the app that has
  to paste it.

Every string in a step is `${VAR}`-substituted before it runs — captured values first, then the
environment (so `${PEER}` resolves via `UI_PROBE_PEER`).

A fourth op joined them for issue #54: **`view`** — `width`/`height` (or `reset: true`) resizes the
FRAMEWORK viewport, which is what "the user maximized the window" looks like to every widget, and
is how the profile card's re-anchoring was reproduced. Deliberately NOT `window_manager`: driving
that against a window the probe never took through `main()`'s `setAsFrameless` dance kills the
process with no Dart error. Caveat learned the hard way: a resize can auto-collapse panels, so a
target's coordinates before and after are not comparable — re-resolve, do not cache.

## Rules that are not optional

- **The fleet talks only to servers the fleet creates.** These are real identities on the real
  relay writing real CRDT ops. A fleet peer joining one of Vitalik's servers pollutes his data and
  replicates it to his phone. Create it in `steps`, delete it in `cleanup`.
- **Put `${RUN}` in every message you send.** It is unique per run. The relay's availability cache
  holds undelivered traffic for three days and the fixture identities are STABLE across runs, so a
  `wait_for` on a fixed string can be satisfied by an EARLIER run's message — passing before the
  send it was waiting for.
- **Never widen an instance's window below 960 logical pixels.** Under 600 the app switches to the
  mobile shell, and a desktop scenario driving the mobile shell fails for a reason that looks like a
  bug. `Set-FleetWindows` tiles with that floor.
- **`Stop-Fleet` only kills processes under `build/fleet`.** Vitalik's real Hollow may well be open
  during a run; it has a different exe path and data directory and does not conflict with anything.

## Traps, each of which cost a run

1. **An instance that dies takes its reason with it.** An unhandled app exception ends the test
   body, the body IS the app, so the process exits — and in a fleet that looks like one instance
   that silently stops answering. Three things now catch it: the probe mirrors `debugPrint` into
   `<out>/stdout.log`, `FlutterError.onError` appends to `errors.log`, and both scripts check
   `HasExited` on every poll and print the log tails instead of timing out.
2. **NEVER launch an instance with `-RedirectStandardOutput`/`-RedirectStandardError`.** It looks
   like the obvious way to capture a dead instance's last words, and it flips `Start-Process` into
   inherit-handles mode: every instance then holds a duplicate of the launcher's stdout pipe, so
   `fleet.ps1 -Live | anything` never returns even though the script finished. Measured: 1s
   launching plain, 45s (the timeout) with redirection. That trap cost ten minutes a time, twice,
   before it was understood. The probe writes its own logs from inside instead — same information,
   no handle. (`nul.txt` is also not a usable filename: Windows reserves the NUL device, extension
   and all.)
3. **Annotation mode kills a probe instance dead.** The pencil in the title bar drives
   `windowManager.maximize/setBackgroundColor/setAlwaysOnTop` against a window that never went
   through `main()`'s `waitUntilReadyToShow` + `setAsFrameless`. No Dart exception, nothing in any
   log, process gone. It works in the real app. `windowManager.ensureInitialized()` is now called in
   `setUpAll` and does NOT fix it. Do not aim a scenario at it.
4. **Tapping a Text that is not a control silently does nothing and PASSES.** The delete-server
   confirmation has the words "Delete server" as its TITLE and as its button; index 0 is the title.
   `_requireHittable` cannot catch this one, because the title genuinely is hit-testable. When a
   confirm step appears to do nothing, count the matches first.
5. **`Get-Content` on a one-line file returns a bare string, and indexing a string gives a Char**
   (`[System.Char] does not contain a method named 'Trim'`). Every read of an outbox is wrapped in
   `@()`.
6. **The Accept button only exists on the INCOMING tab.** Waiting for it from the Friends tab is a
   30-second timeout that reads exactly like a delivery failure, while the provider dump says
   `pending (incoming)` the whole time. Read the dump before believing the timeout.

## What the dump adds for a fleet

`map-*.md` now carries, alongside the widget list: `identity` (this instance's peer id and whether
it loaded), `connection` (the overall connection provider, not node status), `friends` with status
and direction, and `dms` / `channelMessages` as per-conversation counts plus the last three bodies.
**One instance can never disagree with itself about these; two can, and that disagreement is the
whole bug class.** Counts rather than bodies on purpose: forty message bodies bury the one line that
matters.

## The ladder (from the design, section 6)

1. **Two peers, text.** ✅ `friend_dm` (request, accept, DM both ways, ~29s),
   `server_invite_message` (create, invite, join, channel message both ways, delete, ~33s),
   `unread_line` (the "new messages" line and its rail mark, ~2min).
2. **Two peers, moderation.** Kick and watch them vanish from the member panel AND lose the server;
   ban and watch a rejoin fail; mute and watch the composer refuse. Not built.
3. **Three or more, roles and visibility.** Restricted channels, access labels granted and revoked
   live, role badges. Per-channel MLS subgroups have a real UI surface here. Not built.
4. **Files and vault sharding.** The auto-download gate on the receiving side, storage dashboard
   numbers, shards distributed across N real peers and a restore. Not built.
5. **Media.** Joining a VC, participant rows, mute/deafen propagation: fine. **Screenshots cannot
   prove video** — platform views do not appear in them, so a WebRTC surface is black whether it
   works or not. The right signal is stats (`RTCVideoRenderer.videoValue` dimensions, `getStats`
   `framesDecoded` climbing), which needs a new `expect_stats` op. Start every instance MUTED: four
   live captures on one machine is a feedback loop. Not built.

## Trap 7 and 8, and when a journey is a SCRIPT (2026-08-27)

7. **A double-quoted PowerShell string eats `${RUN}` before `Expand-FleetVars` sees it.** It expands
   as a (nonexistent) PS variable, so the app is sent `"from a "` and the `wait_for` waits for a
   string nobody will ever send. Message literals in a hand-written driver must be SINGLE quoted;
   scenario JSON is immune.
8. **`enter_text` reports success into a composer that stays EMPTY.** Twice, both times on the send
   immediately after a peer RECONNECTED, where the burst (PeerJoined, key exchange, sync, profile
   updates) rebuilds the chat pane and the text lands on a controller about to be replaced. Neither
   `field` nor `hint:Message #general` helped. **TAP the composer first**, the way a user does. And
   make every send `wait_for` its OWN optimistic row before another peer waits on it, or a send that
   never happened is indistinguishable from a delivery failure and you debug the wrong app. The `ok`
   lied and `look` lied; the SCREENSHOT settled it in one glance.

**A journey where a peer has to LEAVE and COME BACK is a script, not a scenario JSON.**
`scripts/fleet_owner_offline.ps1` (owner-offline join, ~3 min, rung 2 of the ladder): `quit` has no
relaunch, so the owner could never return to delete its own server, which the cleanup rule requires.
Dot-source `fleet_lib.ps1`, set `$script:FleetVars` before it, and relaunch one peer by replicating
`Start-Peer` WITHOUT `Reset-PeerData` — a fixture restore would throw away the very server the
journey is about. Reset `$script:FleetConsumed[$peer]` when you wipe its outbox.

## fleet_pending_join.ps1 (pending server joins, 2026-08-29)

A pending server join that outlives BOTH sessions, across two REAL instances, proving the `~join` ring
path the Rust harness cannot: `node/test_harness.rs` proves the ops converge in one process; this
proves the app does it, in the widgets, over the real relay, with ZERO OVERLAP. a and b are never
online together until the last step, so every hop has to survive in the relay's availability rings and
be replayed on a room join. Another script rather than a scenario JSON, for the same reason as
`fleet_owner_offline.ps1`: `quit` has no relaunch, and this journey needs peers to leave and come back.

**Standard journey, 8 gates:** G1 a creates the server, `#general` is there, invite captured. G2 b sees
the "Joining server" toast (soft). G3 b shows the PENDING tile with nobody online. G4 b holds NO real
server yet (dump). G5 a returns ALONE and admits b from the ring (member panel grows to two, the gate
that proves the ring path works). G6 b returns ALONE, a long gone, to a REAL server with a channel list
(the buffered admission, snapshot, welcome, op log, has to reach it the same way; this is the return
leg). G7 a message each way once both are finally up (proves the MLS group actually formed rather than
the CRDT half landing on its own). G8 cleanup: a deletes the server it created.

**`-DeleteBeforeMessage` replaces G7 with a 9th-gate journey (G7d/G8d + cleanup = 9 gates)**, the case
that caught `feedback_mls_first_fallback_dead_targets`: a peer admitted through the ring holds the CRDT
half of the server and NO MLS leaf, since the leaf only forms on first co-presence, when its bootstrap
KeyPackage finally reaches somebody who can answer it. With the switch, a comes back and deletes the
server IMMEDIATELY, before any message can pull b's leaf into existence, and b has to lose the server
anyway, which only works if the plaintext `CrdtOpBroadcast` twin is sent unconditionally. Run 1 caught
the bug live: b logged `Received MlsChannelMessage for unknown group` and kept the server for good.

**Five relaunches total** across the two journeys (`Restart-Peer`, the same helper `fleet_owner_offline.ps1`
uses, relaunches ONE peer on its EXISTING data dir, no `Reset-PeerData`, since a fixture restore would
throw away the very server the journey is about) and `Stop-Peer` (kills the process, waits ~1.5s for the
SQLCipher WAL lock to release before the data dir is touched again).

**`Wait-ForConnected` helper:** "this peer is up and on the network" without depending on which screen
it booted into. Waits for EITHER `tooltip:Online` (the user bar's `connectionVisual()` label, which in
Dock mode lives only in the status dot's tooltip) OR `text:Connected` (the Home dashboard's own word),
never `text:Online` alone, because the member panel prints that word as a section divider and would
false-match for a peer that is actually offline. A peer that lands straight in a server view (which is
what a freshly-arrived server does, it self-selects) never shows either literal word on its OWN, and
waiting for the wrong one cost a whole run before this helper existed.

**The `$args` guard, and the trap it closes.** `powershell -File` does NOT reject an unknown or
not-yet-declared `-Switch`, it silently drops it into the script's `$args` array and binds the rest of
the parameters normally. Before `-DeleteBeforeMessage` was a declared `[switch]`, a mistyped or
not-yet-implemented flag ran the STANDARD 8-gate journey and reported a clean PASS for a journey nobody
actually asked to run, the kind of green that means nothing. The fix generalizes: `if ($args.Count -gt
0) { throw "unrecognised argument(s): ..." }` right after `param(...)`, before anything boots. Any fleet
script taking a new switch should add it to `param()` FIRST and let this guard catch the interim state,
rather than trust that PowerShell will reject a bad flag on its own: it will not.

`-Fresh` (via `Start-FreshFleet` in `fleet_lib.ps1`, `-Onboard -Fresh -Peers a,b`) deletes the fixture
identities before onboarding, same as the friend journeys: the relay's availability rings hold this
server's traffic for three days under a STABLE identity, so a reused fixture can be served an EARLIER
run's parked join or resolution.

## Honest scope

The fleet proves the app DOES the thing. It does not prove the thing FEELS right, and it does not
replace Vitalik using Hollow. What it replaces is the part where he has to be the test harness.

## What `unread_line` is actually for (2026-08-21)

Worth reading before writing the next scenario, because it is the clearest example of the
kind of thing ONLY this harness can answer.

The unread line's index maths and its read pointer both have widget tests, and both hand the
pointer in BY HAND. What no widget test can reach is the **moment** the pointer is captured:
`markDmSeen` runs from five places (the sidebar's selection callback before the pane exists,
the pane on load, the scroll handler, a context menu, a notification tap), any one of them can
clobber the entry pointer, and every one of them is only real when a message actually arrives
over the relay. So the journey is: a reads, a walks away, b sends, a returns — the line is
there and STAYS there three seconds later; a quiet return draws none.

Two things the scenario teaches about writing these:

- **`expect_count` on a semantics label only sees BUILT widgets.** After twenty more messages
  the line is far above the viewport, and a `ScrollablePositionedList` does not build an
  off-screen row, so asserting the line at the bottom of a long conversation fails for a
  correct app. That is not a bug in the test; it is the reason the rail carries the jump.
  Assert the rail mark, tap it, THEN assert the line.
- **A `HollowPressable` with a `semanticLabel` matches `semantics:X` TWICE.** Use
  `index: 0` to tap it and a unique `tooltip:` target to count it.

## The iOS Simulator backend: the same fleet on the Mac mini (2026-09-05)

The fleet runs on two iOS Simulators on Vitalik's Mac mini with the SAME three scripts, the same
op vocabulary, the same scenario format and the same send script. `fleet_lib.ps1` picks the
backend from `$IsMacOS` (absent under Windows PowerShell 5.1, so nothing changes there). pwsh 7
lives at `~/powershell/7/pwsh`, linked into `/opt/homebrew/bin`; every command below is run
over LAN SSH from Windows (`ssh jabun@192.168.18.2`, memory `reference_mac_ssh_build`).

```
pwsh scripts/fleet.ps1 -Build -Peers a,b                 # flutter build ios --simulator -t integration_test/ui_probe_test.dart, install into each
pwsh scripts/fleet.ps1 -Onboard -Fresh -Peers a,b        # the MOBILE welcome flow, stamps ~/hollow_fleet/fixtures/<peer>
pwsh scripts/fleet.ps1 -Live -Peers a,b                  # 15 s from fixtures
pwsh scripts/fleet.ps1 -Scenario mobile_friend_dm         # 38 s, 33 steps, both directions
pwsh scripts/fleet_send.ps1 -Command "$(cat /tmp/cmd.json)"   # peer-tagged batch, exactly as on Windows
pwsh scripts/fleet.ps1 -Stop
```

**What differs, and only this:**

- **One simulator per peer**, named `hollow-<peer>`, created on first use from the newest iOS
  runtime (`FLEET_SIM_DEVICE` picks the type, default iPhone 17 Pro). `Stop-Fleet` terminates
  the app in every `hollow-*` device and nothing else.
- **Everything the app writes lives in its own container.** An iOS app can write nowhere else,
  so the data directory is `<container>/Documents/hollow` and the probe output is
  `<container>/Documents/probe_out`; `build/fleet_out/<peer>` is a SYMLINK there, refreshed on
  every launch (the container UUID changes with every `simctl install`), so every reader of an
  out directory keeps its usual path. Fixtures are mirrored with rsync, not robocopy.
- **Configuration is a file, not the environment.** `Platform.environment` is EMPTY on iOS
  (zero variables, measured, while `ps eww` on the same process showed every `SIMCTL_CHILD_`
  value present). `Start-Peer` writes `<container>/Documents/probe.env` (KEY=VALUE lines) and
  the probe reads it in `setUpAll` through path_provider (`probe_env.dart`). The probe also
  calls `setDataDir` + `overrideHollowDataDir` itself for a file-sourced data dir, because the
  real app does that in `main()` and the probe never runs `main()`.
- **Simulator.app must be showing the devices** (`Start-SimDevice` opens it). A headless boot
  renders one frame and then produces none, and the probe's first `tester.pump` waits forever
  with an empty stack. That cost an hour to find; the VM service's `pause`+`getStack` on the
  isolate is what showed the idle loop.
- **The mobile onboarding walk** (`$onboardStepsMobile`): no `Connected` text anywhere, so the
  node coming up is `wait_for` on the `connection` PROVIDER; the Settings profile row is
  addressed by its subtitle (`text:Name, status, avatar & banner`); typing the name raises the
  software keyboard, which pushes `Save profile` off screen, so `scroll` first; `semantics:Back`
  instead of Escape.
- **Firebase.** The probe initialises Firebase on mobile the way `main()` does. Before that the
  push service's synchronous throw (`No Firebase App '[DEFAULT]'`) escaped `catchError` and
  marked a running, relay-connected node as `NodeStatus.error`; `node_provider.dart` now guards
  the push init with a try/catch too, because push is optional and the node is not.

**Runner improvements the mobile shell forced, all platform-neutral:**

- `wait_for` takes `provider` + `equals`/`matches` (polls the dump's provider snapshot).
- The dump reads `overallConnectionProvider` directly once the node and the relay-status
  notifier exist; it is derived, so nothing but a watching widget ever created it, and the
  mobile shell watches it only inside a chat.
- A target with no `index` and several matches picks the first one a finger can REACH. The
  mobile shell keeps every tab mounted (faded, ignoring pointers), so a friend's name exists once
  per tab within four pixels of itself, and tree order says nothing about which one shows. An
  explicit `index` stays literal.
- The tap guard accepts a hit on a box ABOVE the target when that box is on the target's own
  ancestor chain (a row whose label is not itself hit-testable). The failure text now also
  names the target's chain, so "a sibling under a common parent" and "an overlapping surface"
  read differently.
- `semantics:X` also matches a label that starts with `X,`: a badge turns the tab into
  `Friends, 1 friend request` and must not make it unaddressable.
- `UI_PROBE_TRACE=1` narrates the three boot awaits.

**Mobile scenario notes (`mobile_friend_dm.json`):** `Send Friend Request` (not `Send Request`),
`hint:Type a message...` + `semantics:Send` (Enter does not send), tap the composer before typing,
and the Chats list grows a row for a friend only once a message exists, so the receiver opens
the DM from Chats only after the sender has written. Everything else is the desktop journey.

**Desktop trap found while re-running `friend_dm` on Windows (2026-09-05):** `key escape` after
Send Request and the waits that follow reached nothing (focus had left the dialog), the Friends
dialog stayed open, and its barrier covered the DM tab at step 21. Escape from a focused field
works in isolation; a scenario cannot know where focus is by then. Dialogs are now closed by
their control, `tap type:_FriendsManager > semantics:Close` + `wait_for gone type:_FriendsManager`
(the Friends manager is a Material dialog, not a `HollowDialog`, so the `dialog` target does not see
it), and the scope is not optional: a bare `semantics:Close` matches the window title bar's close
button first in tree order, and that tap ends the process (it did). Predates the simulator work.
