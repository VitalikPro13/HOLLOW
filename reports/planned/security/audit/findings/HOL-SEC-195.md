# HOL-SEC-195: A leave during the screen share picker left a live share for the next room

```
ID:          HOL-SEC-195                 Status: Fixed in 0.14
                                          (f0805308, 2026-11-05)
Severity:    Low                         (Impact M: our screen is captured with no room
                                          to stop it, and a voice room we join later is
                                          told we share and is served the capture on a
                                          Watch, a room the person never chose to show
                                          their screen to; the share controls there do
                                          say we share, and the OS capture indicator
                                          stays on; Exploitability L: a leave, kick or
                                          channel delete has to land while the capture
                                          picker is up, which nobody else can see)
Category:    State not restored / Consent (a share outlives the choice that started it)
Component:   lib/src/core/providers/voice_channel_provider.dart (startScreenShare,
             _armVoiceRedirect, onLocalJoined), lib/src/core/providers/call_provider.dart
             (startScreenShare), lib/src/core/services/desktop_capture_support.dart
             (ShareCapture)
Boundary:    TB-2 (peer and peer), TB-3 (server members)
Traces to:   C-21 (participants only); #38 (a share streams only to a watcher who asked);
             HOL-SEC-191 follow-up (the same start, later awaits)
Attacker:    none needed; a server moderator's kick or channel delete can land in the window
Found:       2026-11-05 (hostile review of the t14-left leftovers batch, finding 1)
Affected:    every release with voice channel screen share, read in 0.9.4-beta,
             0.10.0-beta, 0.12.0-beta, 0.12.2+1-beta and main 8350841b (0.13.0); the
             DM call share has the same window but sends nothing after it
Fix commit:  f0805308 (0.14, 2026-11-05)
Disclosure:  advisory with the 0.14 GHSAs
```

## Description

A voice channel share minted its session, then awaited the capture picker (the Android
consent dialog, the iOS broadcast sheet, the Wayland portal) and the preview while the
app stayed usable. The share was not live yet, so a stop did nothing, and a leave, a
kick or a channel delete in that window found no capture to close. The start then
resumed: it kept the capture, set the share live on a state with no room, and the next
room the person joined inherited it. Late joiners there were told we share and a Watch
was served, though the person had picked the screen for another room. A stop and a new
share started while an older share's voice redirect was still arming left the older
redirect armed.

A DM call share had the same window: a call that ended while the picker was up got its
capture kept, running with no call to end it, and announced to the old call's peer.

## Fix

The start holds the capture and preview in locals until its last await and checks after
each await that its session is still the current one, that we are still in the room and
not leaving (`_openShare`, `_shareStartLost`); a lost session closes both and returns
quietly. A stop while the picker is up drops the session, so the start closes what it
opens. A second start while one is at its picker is refused. The Windows voice redirect
arms one at a time and takes back its own redirect when its session ended
(`_armVoiceRedirect(session)`). A join into another room drops any share left over and
any start still at its picker (`_dropShareFromElsewhere`), so a share never crosses
rooms. The DM call share does the same per call (`_dmShareGen`, `_dmShareStarting`): a
hang-up or stop during the picker closes the capture it opened.

## Residual risk

While the picker is up the person sees no share control, so a share they gave up on is
cancelled only by leaving or by the picker returning. The DM call's per-watch redirect
arm (`_sendDmScreenOffer`) is not serialized like the voice channel's; a stop during it
ends in its catch, which disarms.

## Test

`test/vc_leave_teardown_test.dart` group "a share that starts while the room changes
(HOL-SEC-195)": "a leave during the picker leaves no share for the next room", "a kick
during the picker leaves no share", "a picker that returns mid-leave leaves no share",
"a stop during the picker cancels the share", "a second start while the picker is up is
refused", "a join from outside any room never inherits a share", "a re-share during an
old arm leaves only its own redirect". `test/dm_share_start_test.dart`: "a call that ends
during the picker leaves no capture running", "a stop during the picker cancels the
share", "a second start while the picker is up is refused".
