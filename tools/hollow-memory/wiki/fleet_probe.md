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
| `friend_dm` / `server_invite_message` | 29s / 33s |

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
   `server_invite_message` (create, invite, join, channel message both ways, delete, ~33s).
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

## Honest scope

The fleet proves the app DOES the thing. It does not prove the thing FEELS right, and it does not
replace Vitalik using Hollow. What it replaces is the part where he has to be the test harness.
