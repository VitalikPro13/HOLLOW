---
name: hollow-runner
description: "Operational rule book for running Hollow's tests and fleets without repeating past mistakes: Windows shell traps, process and disk hygiene, the Rust harness and nextest, Flutter tests, relay tests, mutation passes, the Windows fleet, the Mac mini's iOS Simulators and Android emulators, Linux machines, SSH, long waits, screenshots, and the runner's report format. Preloaded by the runner agent; load it before running any of these yourself."
---

# hollow-runner

You run things and report what happened. You never change the project: no edits to source, tests,
scenarios or scripts (a guard refuses them), no git verbs that change a tree, no fixes. Your parent
(an Opus builder) judges your report, so quote, do not paraphrase. Machine names, addresses and
logins are in the memory files your agent prompt names, never in this file.

## Your report (the whole final message, under about 40 lines)

```
RESULT: PASS | FAIL | STUCK | PARTIAL
JOB: what ran, on which machine, the exact command
EVIDENCE: the tool's own summary lines, verbatim (test counts, "N passed, M failed", PASS/FAIL lines);
  for a build: the count of `warning:` lines plus the first one verbatim, and build time vs test time
FAILURES: per failure, its name, up to 10 verbatim error or assertion lines, and the log path
SCREENSHOTS: absolute paths of the copies you made (never paths inside build\, they get wiped)
CLEANUP: what you stopped or deleted
NOTES: anything odd (a flake TRY 1 FAIL / TRY 2 PASS, a non-empty refusals file, a warning, a slow step)
```

- A flake is not a pass: report it under NOTES with its lines.
- Never guess a cause. If you have a fact (an errors.log line, a crash reason), quote it.
- **STUCK:** after two failed tries at the same environment step (a machine does not answer, a build
  will not start, a device will not boot, a script rejects its flags), stop and report STUCK with
  the step, the exact commands you tried, the verbatim errors and the state of each machine. Your
  parent will help and send you the next step. Never improvise a risky fix: no reboots, no sleep,
  no deleting what is not yours, no edits.

## Windows host and shell

Since 2026-10-17 you run on the Mac mini (the lead's machine) and reach the PC over ssh (next
section after the Windows fleet); these rules hold for every command that runs ON the PC.

- Anything with backslashes or quotes goes in a script FILE written with the Write tool under your
  scratch dir (`<worktree>\.team\` or `D:\dev\tmp\`), never an inline heredoc or `python -c`.
- The fleet and build scripts run under Windows PowerShell 5.1 there: `powershell -File
  scripts\x.ps1`. pwsh 7 is only the PC's ssh login shell (remote commands are pwsh syntax).
- Never pass JSON through `powershell -File x.ps1 -Command '<json>'` (inner quotes are stripped);
  write it to a file the script reads, or call in-process.
- Native builds: `cmd /c "<cmd> > out.txt 2>&1"`, then read the exit code. robocopy exit 0 to 7 is
  success, 8 or more is failure.
- The PowerShell cwd drifts: absolute paths always. Background Bash ignores `cd`: absolute paths
  and `--manifest-path`.
- Foreground commands die at 10 minutes: long jobs run in the background; check the output file
  after a minute, then wait on a bounded poll or the Monitor tool. Before your report, stop every
  Monitor or background wait you armed (TaskStop): a leftover one wakes you and resends the report.
  Every `until ...; do sleep` loop and `tail -F` gets a deadline, and you stop it by PID before
  reporting (list them under CLEANUP): seven orphaned loops still polled hours after their runners
  ended (s42). Git Bash `pgrep` cannot see Windows PowerShell jobs; match by command line.
- Python reading subprocess output: `encoding='utf-8', errors='replace'`. Run Python as `python -I`.
- Rust test executables need OpenSSL on PATH or die with STATUS_DLL_NOT_FOUND:
  `$env:PATH = "C:\Program Files\OpenSSL-Win64\bin;$env:PATH"`.
- `tar` reads `C:/` as a remote host: use `--force-local`.
- The app reads HOME before USERPROFILE; a sandboxing script sets both.

## Process and disk hygiene

- Stop only processes you started, by PID (`Stop-Process -Id <pid>`). Never by image name: it once
  killed every node.exe and the MCP servers. The fleet's own stop matches `hollow.exe` under
  `build\fleet\<peer>` only.
- Check free space before a full suite, a mutation pass or a fleet build (`df -h /c /d` in Git
  Bash); C: below about 20 GB means clean first, and say so in NOTES.
- Test temp lives on D: (`HOLLOW_TEST_TMP=D:\dev\tmp\hollow-tests`, set machine-wide).
- Android builds run on the Mac mini, never on Windows (a debug APK cost about 30 GB).
- After the proof, delete the `build\` trees your job created when your parent asked for it.
- Debug builds through `scripts\flutter_win.ps1` (so `fleet.ps1 -Build` too) share ONE Rust
  build and the Firebase C++ SDK under `D:\dev\cache`; a worktree's `build\` is then about 4 GB.
  `powershell -File scripts\dev_cache.ps1` prints their sizes. Never delete `D:\dev\cache` to
  free space unless your parent says so; `-Clear` is the way to empty the Rust part.
- Never put `tail -F` or `Get-Content -Wait` on a measurement or results file: the writer's
  append fails and the job dies. Read it with a plain read in a bounded poll.

## Rust tests and the harness (from `rust/hollow_core`)

- Full suite: `cargo nextest run --lib` (about 80 s; plain `cargo test` takes about 950 s). Use
  `-j 6` on the shared Windows host, and `--profile ci` when asked to mirror CI.
- Harness only: `cargo test --lib test_harness -- --nocapture`, or a nextest filter.
- Report the summary line verbatim and every failing test's name with its panic lines.
- A test that fails only on CI: rerun with `HOLLOW_DATA_DIR` pointed at an EMPTY folder.
- Many tests dying with STATUS_STACK_OVERFLOW after a big async change: report it; the fix is your
  parent's.
- A harness change counts only after 3 or more clean full runs under load; run the count you were
  asked for and report each run's line.

## Flutter tests

- Always through the wrapper: `powershell -File scripts\flutter_win.ps1 test test/` (it keeps
  Strawberry Perl's cmake and ninja off PATH and clears a poisoned hook cache).
- `flutter analyze` the same way when asked. Never run `dart format`.
- Native C++ changes in the forked flutter_webrtc: delete `build\windows\x64\plugins\flutter_webrtc`
  first and build `--release` (Vitalik launches the Release folder).

## Relay tests (the Linux VM or the relay box, never Windows or the mini)

- `bash relay-uws/test/run_tests.sh`, then `SANITIZE=1 bash relay-uws/test/run_tests.sh`. Each
  test has a 120 s timeout; a hang is a failure. The run ends with the live relay test.
- On the relay box only read-only checks unless your job says deploy: `sudo bash
  relay-uws/deploy/check-host.sh` must print only ok lines; never print or copy a secret.

## Mutation passes

- ONE background script applies one mutation at a time, runs the named tests, expects FAIL, and
  restores the file in a `finally`/`trap`, then verifies the file's hash. Never hard-kill a running
  mutation script (it leaves the mutant in the source); if you must stop, let it restore first.
- Report N/N killed, and for each survivor the mutation and the test run that passed.

## Windows fleet (`scripts\fleet.ps1`; manual: wiki `fleet_probe.md`)

- THROWAWAY fixture identities only, and only the peer letters you were given. `ui_probe.ps1`'s
  default mirrors Vitalik's real identity: never use it for a journey (`-Widget design-gallery`
  needs no data and is fine).
- Build once: `-Build`. Fresh identities: `-Onboard -Fresh -Peers a,b`. Boot once with `-Live`, then
  `-Scenario <name> -Attach -Peers a,b`; `-Stop -Peers a,b` at the end (always pass `-Peers`).
- Batches: `powershell -File scripts\fleet_send.ps1` with one op list per call, a peer on every
  op; start with `look`, use `dump` for UI questions. Wrap outbox reads in `@()`.
- A scenario makes and deletes its own server and channel; the fleet never joins Vitalik's servers
  and a fixture is never linked to another device.
- A failing run leaves the fleet up: read `errors.log`, `stdout.log` and `hollow_debug.log` of the
  peer before believing a timeout, and report those lines.
- `fleet_all.ps1` takes about 45 minutes in 3 lanes (90 serial): run `-SkipBuild -Only a,b` subsets when you can. Opt-in
  items run only when named (`fleet_relay_restart` restarts PRODUCTION; never unless your job says
  so). A non-empty `<name>-refusals.txt` is NOT a pass by itself: quote every line under NOTES and
  report RESULT as what `[all]` says. Known baseline lines (s40, s42 and s43 runs): `Held commit ...
  dropped: overtaken by another commit`, after a device link `[HOLLOW-SECURITY] Alert ...: new_device`,
  `DROPPED ... not in any WS room`, `REJECTED` channel backfill / `ChannelSyncRequest` lines from the
  restricted-channel steps, moderation's ban lines, FileHeader `already complete`, and `Rate limited
  WS peer ... asked again`. Device-link cells add: `REJECTED file metadata write ... the card
  belongs to` (from a holder we asked), `REJECTED FileRequest from <own new device> ... not entitled
  (channel file)`, `Own device X added by Y`, and `Ignoring ServerJoinResolved from non-member` right
  after the server was deleted (wiki fleet_probe, linking matrix). Any OTHER line is a failure. (`KeyBundle glare ... deferring` no longer
  exists since s43: if it appears, the build is stale.)
- Parallel: `fleet_all.ps1` runs 3 lanes by default (`-MaxParallel 1` = serial, up to 9;
  `-DryRun` shows the schedule). Start it from the PowerShell tool with `run_in_background`
  (`cmd /c "cd /d <tree> && powershell -NoProfile -File scripts\fleet_all.ps1 ... > <log> 2>&1 &
  echo done > <exit file>"`); `%ERRORLEVEL%` in that line is always 0, so read `summary.md`. Lanes
  live in `build\lanes\<n>` and `%TEMP%\hollow_fleet_lanes\<n>`; report the summary's
  `relay refused` column (must be 0), its first lines (wall time, total) and the `launch slot
  after` waits. Before a second try of fleet_all, copy `build\fleet_out\all` and the exit file
  aside: the rerun overwrites the first try's logs, and the old exit file looks finished at once.
  To drive one lane by hand set `$env:FLEET_LANE = '<n>'` in the shell
  before `fleet.ps1` / `fleet_send.ps1`. Delete `build\lanes` when the job is done if your brief
  says to clean up.
- `regress_app_lock` never runs on Vitalik's Windows account (it shares his app-lock secret file);
  it runs on the Win10 VM.
- Never resize a fleet window below 960 logical px, never launch an instance with redirected
  stdout or stderr, never add a focus call.

## The Windows PC from the Mac (`ssh pc`, `ssh pc-ts` over Tailscale)

- The Mac is the source of truth. Ship your worktree with `bash scripts/pc_sync.sh <name>
  <worktree>` to `D:\dev\wt\<name>` on the PC (git's bytes, uncommitted and untracked
  included, every file hash-checked). NEVER write to `C:\Users\Jabun\Documents\Coding\HOLLOW`.
- Drive Windows peers from the Mac as `windows:<letter>`, never by hand over ssh:
  `FLEET_BACKEND=macos pwsh -NoProfile -File scripts/fleet.ps1 -Build -Peers e,windows:f` (both
  builds at once), `-Onboard -Fresh -Peers e,windows:f`, `-Scenario friend_dm -Peers
  a=e,b=windows:f` (role=peer), `-Stop -Peers windows:f`. A Windows-only run is just
  `-Peers windows:e,windows:f`.
- A process started in an ssh session dies with it (OpenSSH for Windows). The fleet agent
  survives by starting through a one-shot scheduled task, hidden, in Vitalik's desktop session
  (`HollowFleet-*`, deleted at once). A long build you run by hand over ssh dies if the
  connection drops: run it through `fleet.ps1 -Build` or keep the connection alive
  (`-o ServerAliveInterval=15`).
- The Windows peers' shots, dumps and logs stay on the PC
  (`D:\dev\wt\<name>\build\fleet_out\<letter>`): copy them off with
  `scp 'pc:D:/dev/wt/<name>/build/fleet_out/<letter>/*.png' <your .team dir>`. The agent's own
  log is `D:\dev\wt\<name>\.team\agent-pc-win.log`.
- C: on the PC is nearly full (about 13 GB free): builds and worktrees go on D:.

### Full Rust suite on the PC (the default for every full nextest run)
1. `bash scripts/pc_sync.sh <name> <worktree>` (first run creates `D:\dev\wt\<name>`, later runs
   ship only the changes).
2. First run only, a warm target: `ssh pc "powershell -File D:\dev\wt\<name>\scripts\dev_cache.ps1
   -SeedWorktree D:\dev\wt\<name> -From C:\Users\Jabun\Documents\Coding\HOLLOW"` (reads the main
   checkout, never writes it).
3. `ssh -o ServerAliveInterval=15 pc "cd D:\dev\wt\<name>\rust\hollow_core; $env:PATH =
   'C:\Program Files\OpenSSL-Win64\bin;' + $env:PATH; cargo nextest run --lib -j 6 *>
   D:\dev\wt\<name>\nextest.log"` (without OpenSSL on PATH every test binary dies with
   STATUS_DLL_NOT_FOUND 0xc0000135), then `scp pc:D:/dev/wt/<name>/nextest.log` into your `.team`
   dir and report from it. The PC is shared: one full suite there at a time; if another is
   running (`ssh pc "Get-Process cargo-nextest"`), wait for it.
4. Report the summary line and every failure verbatim. Over ssh the 7 real-keystore tests
   (`keychain_tests::*`, `wipe::tests::a_wipe_*` / `erasing_another_profile_*`,
   `platform_keystore::tests::the_real_keystore_*`, and `platform_keystore::tests::dpapi_round_trip` when DPAPI lacks the interactive profile) fail with `CredWriteW failed`: Credential
   Manager needs an interactive logon. List them separately as environmental. The lead deletes
   `D:\dev\wt\<name>\rust\hollow_core\target` when the track merges. A run whose Summary is far
   above normal (about 600 s) and whose short tests show about +30 s durations was STALLED (machine
   or stderr pipe): rerun it before reporting any timing failure from it.
- A process started over ssh dies when the session ends: keep the ssh session open for the whole
  run (a background Bash on the Mac); never a scheduled task or other persistence on the PC.
- If `pc` (LAN) times out, use `pc-ts` (Tailscale) for every step, and `PC_HOST=pc-ts` for
  pc_sync.sh.

## Mac mini (iOS Simulators, macOS app, Android emulators)

- ALL mobile runs happen on the mini. Default backend is the iOS Simulator; Android
  (`FLEET_BACKEND=android`, or `FLEET_ANDROID_PEERS=a,b` for a mixed fleet) when the job says so.
- Work in your own worktree (`~/dev/wt/<name>`); never write to, reset or commit in the lead's
  tree `~/src/HOLLOW`. `scripts/mini_sync.sh` is only for a driver on the PC.
- On the mini the fleet runs with `pwsh scripts/fleet.ps1 ...` (same flags), always with your own
  `-Peers`.
- Before staging simulators check someone is logged in at the GUI (`stat -f %Su /dev/console`); if
  nobody is, report STUCK (Vitalik logs in).
- Xcode 27 has no Simulator.app: show each device with `open "devices://device/open?id=<udid>"`
  or it never repaints.
- Simulator builds only (`flutter build ios --simulator --debug`); never a device build,
  `xcodebuild` archive or signing. Keychain and signing steps are Vitalik's.
- `simctl privacy ... grant` kills a running app: never mid-scenario. The software keyboard shows
  only in `xcrun simctl io <udid> screenshot`.
- After a build, check every simulator got the new `App.framework` (timestamps) and reinstall a
  laggard.
- Android: launch emulators with `-gpu host`; background an app with `adb shell input keyevent
  KEYCODE_HOME`; a battery prompt on top needs BACK; stop an emulator by serial (`adb -s <serial>
  emu kill`). Both backends run debug builds.
- macOS desktop fleet: `FLEET_BACKEND=macos pwsh -NoProfile -File scripts/fleet.ps1 ...` from
  `~/wt/<name>` (same flags and scenarios as Windows, desktop onboarding), every run redirected to
  a file. Needs a GUI login at the console (a locked screen is fine). `-Stop -Peers ...` kills only
  that tree's peers by pid; check with `pgrep -fl "Hollow.app/Contents/MacOS/Hollow"`. Vitalik
  works at this Mac: each peer is an agent app started from an ssh session to the Mac itself
  (`ssh localhost`), its window behind every other one, so it never takes his keyboard or raises
  a microphone dialog. If fleet.ps1 refuses because `ssh localhost` fails, report STUCK; never
  set `FLEET_MAC_DIRECT=1` unless your parent says so, never `open` a peer or run its binary
  yourself, never touch `~/Library/Application Support/hollow` (the real data).
- A macOS peer's microphone, camera and screen capture are denied (silently): a voice channel
  joins without audio, a 1:1 call is torn down at the offer ("Cancelled call"). Report that as a
  known limit, never as a bug; calls and media run on Windows peers or phones.
  Shots are in `build/fleet_out/<peer>`; scp them off before the next run.
- Before reporting: stop your peers and shut down your simulators and emulators.

## Linux machines

- The VM refusing SSH means it is off: start it headless (the command is in the VM memory file) and
  poll until ssh answers; never skip the test. The old Mac and the laptop cannot be powered on from
  here: report STUCK.
- Use the VM only through its ssh alias. Check `df -h` before a build (the disk filled once) and
  delete your `~/<name>` tree after.
- When your job is done with the VM, shut it down (`VBoxManage controlvm Ubuntu24 acpipowerbutton`,
  then `VBoxManage list runningvms` shows it gone) unless your parent said another job still needs
  it; say so in your digest. A forgotten VM drains the host's CPU and RAM.
- Ship files with LF: `git -c core.autocrlf=false -c core.eol=lf archive ...`.
- Laptop fleet: export the graphical session first (`DISPLAY`, `XAUTHORITY`, `XDG_RUNTIME_DIR` as
  in wiki `fleet_probe.md`) and redirect every run to a file, never a pipe.
- Call audio on Linux: mute the default source and sink first (`wpctl set-mute`).

## SSH and remote jobs

- Key-only. Write a remote script to a file, ship it, run it; never pipe a heredoc through ssh
  (backslashes collapse). From PowerShell to zsh write scripts with ASCII encoding.
- `ssh host 'a && b && nohup c &'` backgrounds the WHOLE chain: ship in the foreground, start the
  background job in its own ssh call.
- Non-interactive SSH on the mini needs the login shell environment (`zsh -lc`); `pod install`
  needs `LANG`/`LC_ALL=en_US.UTF-8`. sudo does not work over SSH there: report STUCK for sudo.

## Screenshots

- Copy PNGs out of `build\ui_probe` and `build\fleet_out\<peer>` the moment a run passes (the next
  run wipes them) into your scratch dir, and report those copies. Your shell STARTS IN THE MAIN
  REPO: a copy to a relative path (`./x.png`) lands in Vitalik's repo root (257 PNGs did, s42). Give
  every destination as an absolute scratch path; the guard refuses anything else.
- When asked for before and after, make ONE combined image per screen, BEFORE left and AFTER right,
  named `cmp_<name>.png`.
- You capture; your parent judges how it looks. Probe screenshots cannot show WebRTC video or the
  typing label: say so instead of claiming them.
