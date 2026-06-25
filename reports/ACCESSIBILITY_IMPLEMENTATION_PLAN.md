# HOLLOW — Accessibility Implementation Plan

**Status:** Phase 1 + Phase 2 (2.1–2.6) IMPLEMENTED; Phase 3 not started. Authored 2026-06-24, updated 2026-06-25.

> **Progress (2026-06-25):** **Phase 1** (1.1 Reduce Motion, 1.2 Contrast, 1.3 Differentiate Without Color, 1.4 Accessibility settings shell, 1.5 Reduce Transparency) — all implemented. **Phase 2** (VoiceOver/Voice Control): 2.1 semantics foundation ✅, 2.2 icon-only labels ✅, 2.3 avatar alt text ✅, 2.4 inline content ✅, 2.5 custom-painted widgets ✅, **2.6 keyboard focus ✅ (NEW 2026-06-25)**. **Phase 2 is now code-complete.** **Phase 3 (Larger Text) not started.** All 66 widget/unit tests pass + `flutter analyze` clean (no new issues). **CI guards:** `test/contrast_test.dart` (1.2), `test/widget/semantics_foundation_test.dart` (2.1, 12 tests, proves no double-fire), `test/a11y_label_guard_test.dart` (2.2 — static scan that fails the build on any unlabeled icon-only `HollowPressable`/`HollowButton` AND raw `GestureDetector`/`InkWell`), `test/widget/focus_traversal_test.dart` (2.6, 9 tests — Tab focuses, Enter/Space activate once, disabled stays out), and `test/focus_ring_guard_test.dart` (2.6 — static guard that fails the build if any of the 3 core components drops its `HollowFocusRing` wiring or the `focusRing` token is removed). Per-section state marked inline with ✅.
>
> **What 2.6 built (the chokepoint, 2026-06-25):** a new `lib/src/ui/components/hollow_focus_ring.dart` (`HollowFocusRing`) wraps a child in a `FocusableActionDetector` → the control enters the Tab/arrow focus chain, Enter/Space/NumpadEnter activate it (local `Shortcuts`→`ActivateIntent`→`CallbackAction` mirroring the host's tap, fires **once** — no double-fire with the existing `GestureDetector`+`Semantics(onTap:)`), and an accent **outline + soft glow** ring paints **only on keyboard/assistive-tech focus** (`onShowFocusHighlight`, never on mouse hover/press). The ring is a negative-inset `Stack` sibling (`Clip.none`) so it never changes layout; it fades via `HollowDurations.fast` (snaps under reduce-motion). New design token **`HollowTheme.focusRing`** = `ensureContrast(accent, background, 3.0)` (WCAG non-text min; light theme reuses `accentTextLight`) threaded through all 4 factories + `copyWith` + `lerp`. The three core components (`hollow_pressable`/`hollow_button`/`hollow_toggle`) each wrap their content in one `HollowFocusRing` → all ~645 call sites became keyboard-operable from 3 edits. Shell Tab order: a `FocusTraversalGroup(ReadingOrderTraversalPolicy())` wraps the desktop body in `hollow_shell.dart` and the mobile `Scaffold` in `mobile_shell.dart` (reading order follows the visual panel layout). **Still gated on Vitalik's real desktop keyboard sweep** (Tab through every surface; confirm order is sane + ring is visible on each) before the VoiceOver/Voice Control App Store box is checked.
>
> **First device pass (Vitalik, TalkBack on Android, 2026-06-24):** core flow works — labels read, reduce-motion works, dark theme good. **Two fixes applied from it:** (1) mobile nav "+" button was unlabeled (a raw `GestureDetector` the guard didn't yet scan) → labeled "New conversation" + **guard extended to cover raw GestureDetector/InkWell**; (2) nav badges read "5, Chats" (meaningless number) → now "Chats, 5 unread" + selected state (WCAG 4.1.2 — label must convey purpose, not just glyph). **Next device pass (Vitalik, NEXT SESSION before 2.6):** sweep all labeled surfaces by ear for (a) controls reading as bare/unnamed, (b) rows announcing a name twice (MergeSemantics over-merge), (c) labels that read the glyph but not the meaning. Anything found → fix the control, and if it's a pattern, teach the guard. THEN do 2.6 keyboard focus. The App Store VoiceOver/Voice Control box stays UNCHECKED until this ear-sweep + an iOS VoiceOver pass confirm it sounds right.
**Target:** Legitimately claim all 7 applicable App Store Connect accessibility features (everything except Captions and Audio Descriptions, which are N/A — Hollow ships no authored media content).
**Scope decisions (locked with Vitalik):**
- **Everything, claimable for real** — no box checked that we can't honestly back.
- **Full desktop + mobile, shared-code-first.** `HollowPressable`/`HollowButton`/`HollowToggle`/theme/animations are platform-agnostic; fixing them once lands on Windows/macOS/Linux/Android/iOS simultaneously. Platform-specific bits (iOS text-scale cap, OS-flag hooks) are called out per target.
- **Reduce Motion = OR semantics**, surfaced as a tri-state **Auto / On / Off** control (default Auto = follow OS). Effective reduce-motion = `OS Reduce-Motion flag OR in-app override`.
- A dedicated **Accessibility** settings section is added to both shells (desktop side-rail category + mobile nav tile).

> This plan is the authoritative checklist. It is derived from a 5-agent read-only audit of the live codebase (2026-06-24). All file:line anchors below were verified at that time — re-confirm before editing, the tree moves fast.

---

## The 7 features and current honest status

| Feature | Status today | Claimable after |
|---|---|---|
| Dark Interface | ✅ Already real | (already) — optionally add System/Auto mode |
| Reduced Motion | ✅ Phase 1.1 done — OS flag + tri-state Auto/On/Off, bypass swept | ready to claim |
| Sufficient Contrast | ✅ Phase 1.2 done — tertiary token, accentText auto-brighten, light theme reworked, CI guard | ready to claim |
| Differentiate Without Color | ✅ Phase 1.3 done — StatusDot shape cue (filled/ring) on all ~30 sites | ready to claim |
| Larger Text | 🟡 mobile capped at 1.3×; fixed-height bars clip; header overflows | Phase 3 (not started) |
| VoiceOver | ✅ Phase 2.1–2.6 done — semantics foundation, labels, alt text, painted-widget handling, keyboard focus | device ear-sweep (Vitalik), then claim |
| Voice Control | ✅ Phase 2 done — controls are actionable semantic nodes + keyboard/numbered-overlay reachable | device pass (Vitalik), then claim |

---

## Architecture decisions (read before implementing anything)

### A. The semantics chokepoint — `HollowPressable` / `HollowButton` / `HollowToggle`
Nearly every interactive element funnels through these three custom widgets, each currently a raw `GestureDetector` with **no `Semantics`** (`hollow_pressable.dart:173`, `hollow_button.dart:226`, `hollow_toggle.dart:82`). Wrapping their gesture handler in `Semantics(button: true, onTap: …, enabled: isInteractive, label: semanticLabel)` exposes the **bulk** of the UI to both VoiceOver and Voice Control in one edit each. This is the single highest-leverage change in the entire plan.

- Add an optional `String? semanticLabel` field to all three.
- `HollowPressable`: wrap `inner` (built at `:134`) in `Semantics(button: true, label: widget.semanticLabel, enabled: isInteractive, child: …)`. Keep the `GestureDetector` for the actual gesture; `Semantics(onTap:)` should mirror `widget.onTap` so Voice Control can invoke it.
- `HollowButton`: it has a `child` that is almost always `Text`, so once `button: true` is set the text supplies the name automatically — `semanticLabel` only needed for icon-only buttons.
- `HollowToggle`: use `Semantics(toggled: value, button: true, label: …)` so switches announce on/off state.
- **`MergeSemantics`**: where a control is `[Icon + Text]` (e.g. nav tabs, member rows), wrap in `MergeSemantics` so VoiceOver reads it as one node instead of two.

### B. Tooltips DO NOT help accessibility
`HollowTooltip` (`hollow_tooltip.dart:16,34`) is a custom `OverlayEntry`, **not** Flutter's `Tooltip`. It contributes **nothing** to the semantics tree, and only appears on desktop hover. The 69–175 existing tooltip strings are still **useful as a copy source** for authoring `semanticLabel` values (they're already human-readable: "Mute", "Settings", "Invite people", "Disconnect"), but they must be passed explicitly as `semanticLabel:` — they will never auto-surface. **Do not assume any control is labeled just because it has a tooltip.**

### C. Reduce-motion single source of truth
Today there are **two** hand-synced flags: `HollowDurations.animationsDisabled` (`hollow_curves.dart:23`, gates duration getters) and `SharedTickers.instance.disabled` (`shared_tickers.dart:66`, gates repeating tickers), kept in sync manually in 3 files. Replace with one reactive source:

```
effectiveReduceMotion = (inAppOverride == On)
                        || (inAppOverride == Auto && MediaQuery.disableAnimations)
```

- New `reduceMotionProvider` (tri-state enum `Auto/On/Off`, persisted) in `settings_provider.dart`.
- A top-level listener on `WidgetsBinding.instance.platformDispatcher.onAccessibilityFeaturesChanged` (fires at runtime when the user flips OS Reduce Motion) that recomputes `effectiveReduceMotion` and pushes it to **both** statics + calls `SharedTickers.pause()/resume()`.
- Fix the **start-order bug**: `SharedTickers.start()` runs in `main.dart:246` before the DB opens, so decorative tickers spin on the login screen regardless of setting. The OS flag (`platformDispatcher.accessibilityFeatures.disableAnimations`) is available *immediately* at startup (no DB needed) — seed `effectiveReduceMotion` from it before `SharedTickers.start()`, then refine with the persisted override after unlock (`hollow_shell.dart:766-779`).

### D. Larger Text = layout robustness, NOT a scaling engine
Confirmed: no global UI-scale system exists, and we are **not** building one (the Wholesome Story `AdaptiveScaleProvider` approach is explicitly rejected — it *dampens* accessibility scaling and creates a per-widget maintenance tax). Flutter's `textScaler` already scales `Text` correctly via the theme tokens. The work is:
1. Raise/gate the mobile `withClampedTextScaling` cap (`app.dart:84`).
2. Convert fixed-height chrome bars to min-height/intrinsic sizing.
3. Add `Expanded`/`Flexible` + `overflow` to names in tight rows.

### E. Optional global knob: "UI density / text size" setting (product feature, separate from a11y)
Out of scope for the *claimable* work but noted here so it's not lost: a user-facing Small/Default/Large control implemented as a **single root-level `textScaler` multiplier** fed into `MediaQuery` (NOT per-widget `.scaled()`). If built, it doubles as extra "Larger Text" headroom. Decide later; the large-text layout fixes (Phase 3) are a prerequisite either way.

---

## PHASE 1 — Cheap, honest wins (Reduce Motion + Contrast + Color-only) — ✅ IMPLEMENTED 2026-06-24

> These have no dependency on the labeling pass and immediately make 3 features claimable. Land first.

> **What was actually built (deltas from the plan below):**
> - **Reduce-motion single source of truth** lives in a new standalone `lib/src/core/reduce_motion.dart` (`ReduceMotionController` singleton, not folded into a provider — it must run before the DB opens). It owns both legacy statics + the ticker, seeds from the OS flag in `main()` before `SharedTickers.start()`, and listens to `onAccessibilityFeaturesChanged` for live OS-flag changes. Tri-state `reduceMotionProvider` (migrates the old `disable_animations` bool) drives it.
> - **Mobile route transitions** were consolidated into a shared `lib/src/ui/mobile/mobile_page_route.dart` (`hollowMobileRoute()` + `HollowRouteTransition` enum); all 8 custom `PageRouteBuilder` sites migrated.
> - **Contrast** added `lib/src/theme/contrast.dart` (WCAG math + `ensureContrast` auto-adjust) and two theme tokens: `accentText` (accent auto-brightened/darkened for foreground use — default teal unchanged at 8.22:1, only custom dark hues lift) and `textTertiary` (faded-metadata, ≥4.5:1). Light theme got dedicated darker accent/error/success/warning variants. CI guard: `test/contrast_test.dart` (verifies tokens + 8 custom hues both themes).
> - **StatusDot** gained `filled` (solid disc=online, hollow ring=offline) + `semanticLabel` + a `.offline()` ctor. **The audit's ~5-site list was incomplete — a direct grep found ~30.** All genuine person-presence dots fixed (incl. the audit-missed DM left profile panel `chat_pane.dart:3798` and Home Recent Conversations `home_dashboard.dart:767`). Inventory saved in memory `project_accessibility_status_dot_inventory`.
> - Tests: `test/helpers/test_app.dart` now mocks `reduceMotionProvider` (→ `on`) instead of `disableAnimationsProvider`.
>
> **Known deferred (Vitalik: "still some stuff to fix later"):** accent-as-foreground was fixed at the measured-failure sites (links, mentions, active nav, sync status); the ~70 other `accent`-using files are fills/borders/icons where default teal already passes and were not blanket-swept. The continuous-animation bypass sweep covered the listed continuous/large-area sites; a few low-severity one-shot `Animated*` transitions still animate (acceptable). GIF reduce-motion shows the static first frame.

### 1.1 ✅ Reduce Motion — wire the OS flag (the headline gap)
- [ ] Add `ReduceMotionMode { auto, on, off }` enum + `reduceMotionProvider` (persisted key `reduce_motion_mode`, default `auto`) in `lib/src/core/providers/settings_provider.dart`. **Migrate** the existing `disable_animations` bool: if it was `true`, seed the new key to `on`; else `auto`.
- [ ] Build the single reactive source (decision C). Create a small `ReduceMotionController` (or fold into an existing app-init path) that:
  - reads `platformDispatcher.accessibilityFeatures.disableAnimations` at startup (before `SharedTickers.start()` in `main.dart:243-246`),
  - listens to `onAccessibilityFeaturesChanged`,
  - combines with `reduceMotionProvider`,
  - writes `HollowDurations.animationsDisabled` AND `SharedTickers.instance.disabled` + pause/resume.
- [ ] Replace the 3 hand-synced write sites to call the controller instead of setting flags directly: `user_settings_dialog.dart:693-703`, `mobile_settings_tab.dart:1740-1750`, `hollow_shell.dart:766-779`.
- [ ] **Sweep the bypass surface** (the static is a cascade hub, not a complete chokepoint). Fix the looping/continuous animations that ignore the flag:
  - [ ] `channel_chat_pane.dart:2543-2554` — spinner: hardcoded `1500ms` + unconditional `..repeat()`. Guard with effective flag (mirror the *correct* pattern at `member_panel.dart:237-243`).
  - [ ] `voice_recorder_bar.dart:57-60` — pulse `..repeat(reverse:true)`, no guard.
  - [ ] `recording_indicator.dart:51-54` — pulse `..repeat(reverse:true)`, no guard.
  - [ ] `speaking_border.dart:28-93` — hardcoded `300ms`, no guard.
  - [ ] `home_dashboard.dart:1482-1485` — 7s progress, no guard.
  - [ ] `animated_gif_image.dart:42,95` — independent `Ticker` for GIF playback. **Decision needed:** GIF playback is arguably *content*, not decorative motion. Recommended: respect reduce-motion by showing the **static first frame** (the widget already has `_StaticFirstFrame`) when effective flag is on. Low priority.
  - [ ] Mobile route transitions — `PageRouteBuilder`/`SlideTransition` sites (`mobile_chats_tab.dart:168-174,234-240`, `mobile_chat_route.dart:2555-2559`, `mobile_voice_channel_pill.dart:61-67`, `mobile_incoming_call.dart:235-240`, `mobile_call_video_view.dart:482-487`, `mobile_notification_banner.dart:204`) and the `MaterialPageRoute` defaults: when reduce-motion is on, use a no-transition / fade route. Consider a shared `hollowPageRoute()` helper so this is one fix, not N.
  - [ ] Decorative tickers already gated via `SharedTickers` (ambient/shimmer/pulse/typingDots) — verify `pause()` is actually called on the new effective flag, not just `disabled=true` (setting `disabled` alone does not stop a running ticker — `shared_tickers.dart:77,141`).
- [ ] **Audit pass:** grep `..repeat(` and `AnimationController(` in `lib/src/ui/` after the sweep; every continuous animation must consult the effective flag. (~109 implicit `Animated*` + ~172 `Duration()` literals exist — most are one-shot and low motion-severity; prioritize continuous/large-area motion. Full table in the audit appendix.)

### 1.2 ✅ Sufficient Contrast — fix the measured failures
Source palette: `lib/src/theme/hollow_colors.dart`; theme mapping: `lib/src/theme/hollow_theme.dart`.

- [ ] **Critical — faded message metadata.** Timestamps + "(edited)" use `textSecondary.withValues(alpha:0.5)` → **2.37:1**. Sites: `channel_message_bubble.dart:176-181, 285-291` (and the DM-bubble equivalents in `message_bubble.dart`). Raise to full-alpha `textSecondary` (5.7:1) or a new dedicated `textTertiary` token that still clears 4.5:1 on all dark surfaces.
- [ ] **Major — char counter** `textSecondary.withValues(alpha:0.4)` → **1.93:1** at `hollow_text_field.dart:256-259`. Raise alpha or use the new tertiary token.
- [ ] **Major — hue-shifted accent collapse.** `accentFromHue(hue) = HSLColor(hue, 0.85, 0.37)` (`accent_color_provider.dart:15-16`) pins lightness at 0.37, so blue/purple/red hues fall to **1.5–2.96:1** when accent is used as *foreground* (links, mention text, active nav label/icon, "Syncing…" status). Two-part fix:
  - Clamp/raise lightness for low-luminance hues (compute relative luminance, bump L until the accent clears ~3:1 on `background`), OR
  - Restrict accent-as-foreground: where accent is text/icon on a dark bg, use a luminance-guaranteed variant; keep raw accent only for fills (which pair with dark `textOnAccent`, already 8.22:1).
- [ ] **Critical — entire LIGHT theme.** `.light()` reuses dark accent/success/warning on near-white surfaces: accent-on-white **2.33:1**, warning **1.67:1**, success **2.54:1**, plus filled-button foreground. Define light-theme-specific darker accent/semantic colors (or darken-on-light at the theme layer). Sites: `hollow_colors.dart:36-49`, `hollow_theme.dart:71-89`. Verify `hollow_button.dart` filled-foreground + disabled-label on light theme (flagged un-read in audit).
- [ ] **Minor — reply-preview strip / empty-state icons** at `alpha:0.3` (1.6–1.9:1): `channel_message_bubble.dart:93-94`, `channel_sidebar.dart:685`, `mobile_chats_tab.dart:318`, `friends_bar.dart:518,693`. Bump alpha; these are affordance hints.
- [ ] **Minor — white-on-error badge** 3.76:1 (fails body, passes UI/large): acceptable for short counts but consider a darker error or larger weight. Sites: `server_strip.dart:619-628`, `channel_sidebar.dart:960-976`.
- [ ] Add a **dev-time contrast assertion** helper (optional but recommended): a test that computes WCAG ratios for every token pairing in `hollow_colors.dart` and fails CI below threshold, so regressions can't silently ship. (Mirrors the audit's luminance math.)

### 1.3 ✅ Differentiate Without Color Alone — add non-color cues
- [ ] **Critical — StatusDot presence is color-only.** `status_dot.dart` is a solid circle whose only variable is `color`; online vs offline = green vs grey, identical shape (the pulse is motion/color, disabled offline). Add a **shape/icon cue**: e.g. offline = hollow ring (border only, no fill) or a small inner glyph; online = filled. Apply at all overlay sites: `peer_card.dart:79`, `member_panel.dart:636-642`, `mobile_chats_tab.dart:553-557`, `friends_bar.dart:568-573,1255-1259`, `user_bar.dart:188-191`. (The Friends-Manager rows already add "Online/Offline" text — `friends_bar.dart:593-601,773-781` — those pass; it's the avatar overlays that fail.)
- [ ] **Major — DM unread dot** is a bare accent circle with no count (`peer_card.dart:142-152`). The row already bolds the name (secondary cue), but make the indicator itself consistent with the rest of the app (count badge) or add a glyph.
- [ ] **Minor — speaking dot** raw `Colors.teal` circle, color-only + bypasses theme tokens (`channel_sidebar.dart:1408-1432`). Add a ring/waveform cue and use the theme token. Transient, so low priority.
- [ ] Everything else in this category already passes (unread/mention count badges, connection status icon+word, links underlined, mentions `@`+pill, selected server pill-bar, role text labels) — see audit Part B for the pass list; **do not** spend effort re-doing those.

### 1.4 ✅ Build the Accessibility settings section (shell for everything)
- [ ] **Desktop** (`user_settings_dialog.dart`): add `_SettingsCategory.accessibility` to the enum (`:119-131`, place after `appearance`), with icon (`:134`), label "Accessibility" (`:148`), search terms (`:165` — "accessibility contrast motion transparency text size voice screen reader reduce"), and an `_accessibilityCards(...)` builder wired into dispatch (`:579`, model on `_appearanceCards` `:619`).
- [ ] **Mobile** (`mobile_settings_tab.dart`): add a `_SettingsNavTile` (`:140-210`, after Appearance) pushing a new `_AccessibilityTab` modeled on `_AppearanceTab`.
- [ ] Section contents (built incrementally as phases land):
  - **Reduce Motion** — tri-state Auto/On/Off (Phase 1.1). Re-home/alias the existing "Disable Animations" toggle here; leave a redirect or remove it from Appearance.
  - **Reduce Transparency** — toggle (Phase 1.5).
  - **High Contrast** — toggle (optional stretch; would select a higher-contrast token set).
  - **Text Size** — Auto/Large or a small slider (Phase 3; ties to the text-cap decision).
  - **Color-blind friendly** — note/toggle if a palette variant is added (stretch).
  - Copy/labels follow `feedback_vitalik_writing_voice` (calm, first-person, honest, no em-dashes).

### 1.5 ✅ Reduce Transparency (low-effort, centralized)
- [ ] Blur is narrow: essentially one site governs all dialog glass — `hollow_dialog.dart:41-42` (`ImageFilter.blur(8,8)`). Add a `reduceTransparencyProvider` (persisted) that, when on, sets sigma to 0 (and skips the blur animation). Also gate the opt-in background-image panel opacity (`app.dart:34-52`) to fully opaque when on. `shader_warmup.dart:194-202` is warmup-only (no user surface) — leave it, or skip warming the blur shader when reduce-transparency defaults on.

---

## PHASE 2 — VoiceOver + Voice Control (the labeling pass)

> The big-leverage foundation (3 component edits) is small; the long tail (authoring labels for ~hundreds of icon-only controls) is the real work. Both features become claimable together because Voice Control rides on the same semantics.

### 2.1 Foundation — make the 3 core components accessible (decision A)
- [ ] `hollow_pressable.dart`: add `semanticLabel`, wrap `inner` in `Semantics(button: true, label: semanticLabel, enabled: isInteractive, onTap: isInteractive ? onTap : null, child: …)`.
- [ ] `hollow_button.dart`: add `semanticLabel`, wrap in `Semantics(button: true, enabled: isInteractive, label: semanticLabel, child: …)` (text child auto-names when label null).
- [ ] `hollow_toggle.dart`: wrap in `Semantics(button: true, toggled: value, label: semanticLabel, child: …)`.
- [ ] Verify no double-tap / double-announce regressions (raw `GestureDetector` under `Semantics(onTap:)` can double up — test with VoiceOver/TalkBack on a few controls before mass rollout).

### 2.2 Author labels for icon-only controls (the long tail)
Work through by surface. Where a `HollowTooltip` string already exists, reuse its text. Where none exists (most of these), author a clear label.
- [ ] **Composer** (no tooltips today): Send `chat_pane.dart:1841`, Attach `:1791`, Voice record `:1802`, Cancel reply `:1672`; channel twins `channel_chat_pane.dart:2228,2322`.
- [ ] **Message action bar** (`message_action_bar.dart:506-599`, no tooltips): Download, Copy, Copy image, React, Reply, Verify/proof, Pin, Edit, Delete.
- [ ] **Voice UI desktop** (`voice_channel_pane.dart:1180-1261`, tooltips exist → reuse): Mute, Deafen, Camera, Screen share, Disconnect. Same for `active_call_bar.dart:189-301`.
- [ ] **Voice UI mobile** (`mobile_voice_channel_route.dart:404-481`, `MobileControlButton`, no labels): Mute, Deafen, Speaker, Camera, Flip, Leave. Add `semanticLabel` to `MobileControlButton` itself (`mobile_voice_avatars.dart:203-242`).
- [ ] **Server strip** (`server_strip.dart`): Share, Archive, Create server, per-server icons (reuse `tooltip: name`).
- [ ] **Channel sidebar header** (`channel_sidebar.dart:223-267,436`): Invite, Storage, Server settings, Add channel, collapse.
- [ ] **User bar** (`user_bar.dart:209-237`): Settings, Recovery phrase, Downloads.
- [ ] **Public-channel globe** (`channels_tab.dart:785-794`): Critical — a security-relevant toggle whose state is only conveyed by accent color. Label it AND announce state (e.g. "Make channel public, currently private").
- [ ] **Window controls** (`window_title_bar.dart:182,200,259`): Minimize, Maximize, Close. Add label to `_WindowButton`.
- [ ] **Dialog/route close & back buttons** (pattern across app): `channel_chat_pane.dart:332,2093,2148`, `file_attachment_widget.dart:470`, etc.
- [ ] **Brand-icon social buttons** (`user_settings_dialog.dart:5163-5208`, tooltips exist), `member_panel.dart:674` Twitch.

### 2.3 Images / avatars — alt text
- [ ] `HollowAvatar` (`hollow_avatar.dart:20-99`): add an optional label (peer display name) → `Semantics(label: …, image: true)`. It currently exposes nothing — a SR user gets no name on any avatar. Thread the name from call sites (user_bar, message rows, voice tiles, profile cards).
- [ ] Message image attachments (`message_bubble.dart:114`, `channel_message_bubble.dart:129`, `chat_pane.dart:1641,1701`, `file_attachment_widget.dart`): label with caption/filename, or `excludeFromSemantics: true` if purely decorative.
- [ ] `AnimatedGifImage`/`GifFileImage` (`animated_gif_image.dart:114-141`): add `semanticLabel` or exclude.
- [ ] Distinguish **decorative** (banners `chat_pane.dart:3762` → `ExcludeSemantics`) from **informative** (avatars, attachments → labeled).

### 2.4 Inline interactive content (`WidgetSpan` + `GestureDetector`)
- [ ] `message_text_parser.dart`: tappable **URLs** (`:264-281`) and **spoilers** (`:319-324`) are built as `WidgetSpan`+`GestureDetector` and are invisible/unactionable to SR. Wrap the inner widget in `Semantics(link: true, label: url, onTap: …)` / `Semantics(button: true, label: "Reveal spoiler")`. Mentions (`:283-300`) — add `Semantics(label: "@username")`.
- [ ] `ProfileTapTarget` (`profile_tap.dart:73-89`) — wraps avatars/usernames app-wide in a bare `GestureDetector` opening a profile card. Add `Semantics(button: true, label: "Open {name}'s profile")`.

### 2.5 Custom-painted state widgets — ✅ DONE 2026-06-24
- [x] `StatusDot` — already has `Semantics(label: "Online"/"Offline")` from Phase 1.3 (shape cue + label). Nothing further needed.
- [x] `speaking_border.dart` — when `isSpeaking`, wraps the child in `Semantics(label: 'Speaking', container: true)` which MERGES with the wrapped avatar's existing name → SR reads "Alice, Speaking". No call-site plumbing needed (the avatar inside already names the person). Silent passthrough when not speaking.
- [x] Waveforms → `ExcludeSemantics`: `voice_recorder_bar` (live amplitude — non-informative to SR; recording state is carried by the timer + labeled Discard/Send) and `ringtone_clip_editor` drag-scrub surface (the accessible path is the labeled Start/End nudge fields). **Decision:** waveforms are NOT given text labels — live amplitude / drag-scrub convey nothing a SR can act on, so excluding them is more honest than announcing a meaningless region.
- [x] Other decorative `CustomPaint` (shimmer, ambient, tree connectors, crop grid, annotation canvas) — **left as-is**: a childless `CustomPaint` with no `SemanticsProperties` already contributes NOTHING to the semantics tree, so wrapping them in `ExcludeSemantics` would be a no-op. Verified, not skipped.

### 2.6 Focus traversal + keyboard — ✅ DONE 2026-06-25
> **Implemented as a single chokepoint** (mirrors the 2.1 semantics foundation): one new wrapper widget that the three core components each use, so the whole app became keyboard-operable from 3 edits instead of touching 645 call sites. Decision recap: VoiceOver + Voice Control were already served by labels + `Semantics(onTap:)`; 2.6 adds the **keyboard** path (Tab focus + Enter/Space) + the visible focus indicator + Voice-Control numbered-overlay landing.
- [x] **`HollowFocusRing`** (`lib/src/ui/components/hollow_focus_ring.dart`) — wraps a child in `FocusableActionDetector`: joins the Tab/arrow focus chain, maps Enter/Space/NumpadEnter → `ActivateIntent` → `onActivate` (mirrors the host's tap; fires **once**), and paints an accent **outline + soft glow** ring **only on keyboard focus** (`onShowFocusHighlight`, never on mouse). The ring is drawn by a **`CustomPaint` `foregroundPainter` wrapping the child directly** → it paints at the child's **EXACT rendered size/position**, immune to ancestor stretch (a `SizedBox(width:∞)` around a `MainAxisSize.min` button), with the stroke + blurred glow kept **inset** (within the control's box) so no bleed onto neighbours/panel edges. Opacity is driven by an `AnimationController` (a `CustomPaint` can't sit under `AnimatedOpacity` without changing size); fade duration collapses to zero under reduce-motion. `enabled:false`/`onActivate:null` drops the control out of the focus chain entirely. *(Two device-feedback iterations 2026-06-25: first an inset redesign to stop neighbour bleed, then the **CustomPaint rewrite** because a `Positioned.fill` Stack ring filled the *stretched* box — so on `SizedBox(width:∞)` buttons like "Edit Nickname"/"Edit Profile" the ring was larger + off-centre than the visible button. CustomPaint paints the child's own box → ring always hugs the control. CI-locked by two geometry tests in `focus_traversal_test.dart`: ring size == `AnimatedContainer` size, content-width AND stretched.)*
- [x] **Focus-ring design token** — `HollowTheme.focusRing` = `Contrast.ensureContrast(accent, background, targetRatio: 3.0)` (WCAG non-text-contrast min; survives every custom accent hue; light theme reuses `accentTextLight`). Threaded through all 4 factories + `copyWith` + `lerp`. (NOT faded by `withPanelOpacity` — the ring stays fully visible over a background image.)
- [x] **Wired into the 3 core components** — `hollow_pressable.dart` (all interactive instances, incl. `semanticButton:false` rows — they're keyboard-reachable now), `hollow_button.dart`, `hollow_toggle.dart`. Ring hugs each control's own corner radius. Composes with the existing `Semantics`/`GestureDetector` (no double-fire — proven by `physical tap fires once` + the new `Enter/Space fires once` tests).
- [x] **`FocusTraversalGroup(ReadingOrderTraversalPolicy())`** around the desktop shell body (`hollow_shell.dart`, just before `_ShellScaffold`) and the mobile `Scaffold` (`mobile_shell.dart`) → Tab order follows the visual layout left-to-right/top-to-bottom (server strip → channel list → chat → member panel) with no manual ordering. Dialogs/routes pushed above trap their own focus.
- [x] **CI:** `test/widget/focus_traversal_test.dart` (9 tests — Tab focuses each component, Enter & Space activate once, disabled/non-interactive stay out, token is non-transparent) + `test/focus_ring_guard_test.dart` (static guard — fails the build if any core component drops `HollowFocusRing` or the `focusRing` token is removed). Updated `semantics_foundation_test.dart`'s 5 strict matchers to expect the new (correct) `isFocusable`/`hasFocusAction` flags.
- [ ] **App-level `Shortcuts`/`Actions` for common actions** (send, navigate channels) — NOT done; explicitly lower priority and out of scope for the claimable work. Chat-input shortcuts (Enter-to-send, Ctrl+B/I/E etc.) already exist in `chat_input_shortcuts.dart`. A global navigation-shortcuts layer can be a later product polish.
- [ ] **Device keyboard sweep (Vitalik)** — Tab through every desktop surface: confirm (a) focus reaches each control in a sane order, (b) the ring is visible on each (not clipped/hidden in tight rows like the composer/action bars), (c) Enter/Space do the right thing. This is the gate before the VoiceOver/Voice Control App Store box is checked.

#### 2.6 device-feedback fixes (round 2, 2026-06-25 — from Vitalik's first desktop keyboard pass)
- [x] **Ring no longer bleeds onto neighbours, AND now hugs the control exactly** — two iterations: (1) redrawn INSET to stop the friends-bar/profile-card edge bleed; (2) **rewritten as a `CustomPaint` `foregroundPainter`** (see `HollowFocusRing` note above) because the inset version still used a `Positioned.fill` Stack that filled the *stretched* box → the "Edit Nickname"/"Edit Profile" buttons (wrapped in `SizedBox(width:∞)`) got a ring larger + off-centre than the visible button. The painter draws at the child's own rendered size, so the ring is always concentric and content-sized. Verified paint-only (not layout) + CI-locked by `focus_traversal_test.dart` geometry tests.
- [x] **Ring clears when the user switches to the mouse** — new `_PointerFocusDismisser` in `app.dart` wraps the app body: on any pointer-down WHILE the focus highlight is in keyboard (`traditional`) mode, it unfocuses the primary node → every `HollowFocusRing` collapses. (Flutter keeps `traditional` highlight after a *desktop mouse* click, so a ring left on the last Tab-focused control would otherwise linger. Text fields still focus — their own tap-up fires after this.)
- [x] **Tab stays inside the open settings pane** — the user-settings dialog's content `Expanded` and the category rail each got their own `FocusTraversalGroup(ReadingOrderTraversalPolicy())`, so Tab no longer walks from a setting's controls back up into the category list. (`user_settings_dialog.dart`.)
- [x] **Raw-`GestureDetector` controls made keyboard-focusable (high-traffic ones):** server strip `_ServerIcon` (the **Home** button + every server/Share/Archive/Create icon — Vitalik's "Home tab isn't getting selected"), Dock-mode `_BottomServerIcon` (`bottom_bar.dart`), **Image Quality** pills + accent **color swatches** (`user_settings_dialog.dart`) — each wrapped in `HollowFocusRing`. The **Audio Quality + device dropdowns** are Material `DropdownButton`s, already keyboard-focusable natively (they just show Material's highlight, not the Hollow ring — acceptable).
- [ ] **Remaining raw-`GestureDetector`/`InkWell` tappables NOT yet focus-wrapped (enumerated 2026-06-25, awaiting Vitalik's priority call):** these are text-labelled selectable rows/cards/chips (so they ARE mouse-operable + screen-reader-labelled; they just don't join the Tab chain). Medium-traffic: screen-share tabs/source tiles (`screen_share_dialog.dart:351/383/448`), channel-type cards (`create_channel_dialog.dart:120`, `channels_tab.dart:924`), relay-server row (`user_settings_dialog.dart:1187`), notification preset rows (`notifications_tab.dart:204`), members expand row (`members_tab.dart:487`), label colour swatch + self-label chip (`labels_tab.dart:120/235`), storage row (`storage_section.dart:400` — the only `InkWell`), welcome-dialog rows (`welcome_dialog.dart:237/311`), device-link row (`device_link_dialog.dart:419`). Low-traffic / inline message affordances: reply-jump (`message_bubble.dart:135`, `channel_message_bubble.dart:150`), image-open (`file_attachment_widget.dart:223`), video play (`video_message_bubble.dart`), home-dashboard badges (`home_dashboard.dart:272/1302/1352`), plus the mobile-route rows. Window min/max/close (`window_title_bar.dart`) **deliberately NOT** added to the Tab chain (non-standard UX; already screen-reader-labelled + OS-operable). **`server_settings_panel.dart` focus-trapping** also deferred (different layout from the user-settings dialog — revisit if reported).

#### 2.6 device-feedback fixes (round 3, 2026-06-25)
- [x] **Focus ring now visible on accent-FILLED controls** — an accent-only ring vanished when it sat on an accent fill (the teal Home "H" button, an ON `HollowToggle`'s accent track, filled "Save Profile"). The `_FocusRingPainter` now draws the accent ring **outlined on both edges by a contrasting `casing` stroke** (`hollow.background` — near-black on dark, near-white on light): a 3.5px casing stroke with the 2px accent stroke centred on top, so the casing peeks ~0.75px either side. Reads on any background — a plain dark/light surface OR an accent fill. Still fully inset (no neighbour bleed) and still hugs the control box (geometry tests unaffected).
- [x] **Annotate button (title bar) now theme-aware** — `annotation_toggle_button.dart` hardcoded `Color(0xFFFFFFFF)` for the pencil icon + label + hover bg → invisible white-on-white on the light theme. Now defaults to `HollowTheme.textSecondary` (icon/label) + `elevated` (hover), so it's legible on both themes (and consistent with the min/max/close icons, which already use `textSecondary`).

---

## PHASE 3 — Larger Text (layout hardening)

> Make the UI survive OS text scaling up to 200%. Decision D: fix layouts, don't build a scaling engine.

### 3.1 The text-scale cap decision
- [ ] `app.dart:84` clamps **mobile** to `withClampedTextScaling(0.8, 1.3)` — a user who sets 200% silently gets 130%. Options:
  - **(Recommended)** Raise the max to a value the fixed layouts can actually survive after 3.2/3.3 (e.g. 1.6–2.0), OR gate the clamp behind the new **Text Size** Accessibility setting (Auto = honor full OS up to a safe max).
  - Do NOT keep it at 1.3× silently — that's the dishonest state. If a hard cap remains for layout safety, document it and prefer the highest survivable value.
- [ ] Desktop has **no** clamp (full OS scaling already flows) — so desktop is the harder test surface and must be fixed regardless.

### 3.2 Convert fixed-height chrome bars to flexible height (Critical clips)
Replace `Container(height: N)` wrapping text with `ConstrainedBox(minHeight: N)` / intrinsic height / padding-driven sizing:
- [ ] `channel_chat_pane.dart:1306` header `height:48` (Critical — and see 3.3, the name overflows horizontally too).
- [ ] `chat_pane.dart:4066` typing bar `height:24` (Critical — clips ~1.6×).
- [ ] `user_bar.dart:119-120` desktop user panel `height:52` (two text lines, Critical, desktop uncapped).
- [ ] `bottom_bar.dart:90-91` Dock bar `height:59`.
- [ ] `member_panel.dart:399-400` header `height:48`; `channel_sidebar.dart:200-202` header `height:48`.
- [ ] `mobile_chat_route.dart:1958-1959` header `height:52`; `friends_bar.dart:52-53` `height:44`; `mobile_nav.dart:22` / `mobile_nav_bar.dart:38-39` nav `height:56`.
- [ ] Settings/dialog bands: `server_settings_panel.dart:141,193,234`; `hollow_shell.dart:1230,2546,2585`; `window_title_bar.dart` title; dialog headers (`welcome_dialog.dart:163`, `license_key_dialog.dart:122`, `device_link_dialog.dart:260`, `message_proof_dialog.dart:584`); `user_settings_dialog.dart:1230,4238,4449,5335`; archive viewers (`mobile_*archive*:52`).
- [ ] **Do NOT touch** the confirmed-safe fixed heights: reply rails (text-free dividers `message_bubble.dart:74-80`), avatars/images, `status_dot` size, badge containers (already min-width/padding), `reaction_bar` (Wrap). See audit §2 "Not at risk" list.

### 3.3 Add overflow protection to names in tight rows (Critical horizontal overflow)
- [ ] **The worst one:** `channel_chat_pane.dart:1313-1334` channel header — name `Text` (`:1317-1323`) has no `Flexible`/`overflow`/`maxLines` in a `Row` with a `Spacer()` + 4 action icons → guaranteed RenderFlex overflow at large scale. Copy the **good** DM-header pattern (`chat_pane.dart:856-919`: name in `Expanded` + `overflow: ellipsis`, padding-driven height).
- [ ] Message sender-name + timestamp rows: `message_bubble.dart:244-269`, `channel_message_bubble.dart:266-294` — wrap name in `Flexible` + `overflow: ellipsis`; this is the core chat surface.
- [ ] Spot-check sidebar/member rows (mostly already `Expanded`+ellipsis — low risk, verify only).

### 3.4 Verify typography tokens stay scale-friendly
- [ ] No action expected — `hollow_typography.dart` styles are plain `TextStyle` consumed via `HollowTheme.of`; they scale correctly. Just confirm no future change wraps text in a scaler-defeating widget. The 628 `fontSize:` literals (mostly `.copyWith(fontSize:)` off a token) still scale via `textScaler` — leave them; not a breakage source.

### 3.5 Buttons/touch targets
- [ ] `HollowButton`/`HollowPressable` impose **no** fixed height (size is child/padding-driven) — safe. Minor: button `icon` is a fixed `SizedBox(16,16)` (`hollow_button.dart:177`) that won't grow with scaled label (cosmetic only). Optionally scale the icon with `textScaler` for polish.

---

## Testing & validation

- [x] **Semantics foundation widget test** (`test/widget/semantics_foundation_test.dart`, 12 tests, Phase 2.1): asserts `HollowPressable`/`HollowButton`/`HollowToggle` expose the right role (button/toggled), enabled state, and label — AND that a `GestureDetector` under `Semantics(onTap:)` does **not** double-fire (physical tap once, assistive-tech activation once). Headless; stands in for the device pass on the foundation *mechanics* only (not announced label text).
- [x] **A11y label CI guard** (`test/a11y_label_guard_test.dart`, Phase 2.2): static source scan of `lib/src/ui` that **fails the build** if an icon-only `HollowPressable`/`HollowButton` (child is a bare Icon/glyph, no Text) has no `semanticLabel`. This is the machine that keeps future controls labeled — the foundation widget test can't see the real tree, this can. Prints `file:line` + the icon for each offender. Escape hatch: `// a11y-ignore: <reason>` on the control's line. Text-child controls are auto-named and intentionally not flagged. **When it fails, add the label — do not suppress.** (Found 28 sweep-missed controls on first run; all labeled.)
- [x] **Keyboard focus widget test** (`test/widget/focus_traversal_test.dart`, Phase 2.6, 9 tests): pumps each of the 3 components, sends `Tab` (proving it's IN the focus chain), then `Enter`/`Space` and asserts the callback fired **exactly once** (no stacking of GestureDetector + Semantics(onTap) + ActivateAction). Also asserts disabled/non-interactive controls stay OUT of the chain, and the `focusRing` token is non-transparent. Headless; stands in for the device keyboard pass on the foundation mechanics (per-surface Tab-order is still Vitalik's sweep).
- [x] **Keyboard focus CI guard** (`test/focus_ring_guard_test.dart`, Phase 2.6): static source scan that **fails the build** if `hollow_pressable`/`hollow_button`/`hollow_toggle` stops importing+using `HollowFocusRing` (the centralised wiring all 645 call sites depend on), or if `HollowTheme` loses the `focusRing` token. Cheap tripwire for the chokepoint — a dropped wrapper would silently kill keyboard access app-wide with no per-call-site test noticing.
- [ ] **Widget tests:** the harness (`test/helpers/test_app.dart`, `pumpHollowMobile()`) already mocks `disableAnimationsProvider` — extend to cover `reduceMotionProvider` tri-state. Add golden/structure tests at 1.0× / 1.5× / 2.0× `textScaler` for the chat surfaces fixed in Phase 3 (assert no RenderFlex overflow).
- [x] **Contrast CI check** (1.2.x): token-pairing luminance test fails below 4.5:1 body / 3:1 UI. (`test/contrast_test.dart`.)
- [ ] **Manual VoiceOver/TalkBack pass** (Vitalik, on real devices) — the audit can't verify announced names; a real screen-reader sweep of the labeled surfaces is required before claiming VoiceOver/Voice Control. (Per `feedback_no_ios_build_command` + `feedback_vitalik_tests_*`: Vitalik runs the iOS/device verification; Claude can't.)
- [ ] **OS Reduce-Motion runtime test:** toggle the OS setting while the app is open; confirm `onAccessibilityFeaturesChanged` stops motion live (not just on restart).
- [ ] **App Store Connect:** only check a box after its phase is implemented AND device-verified. A false claim is worse than an empty one (Apple spot-checks; this was the original motivation).

---

## Suggested landing order (each independently shippable)

1. ✅ **Phase 1.1 Reduce Motion** + **1.4 Accessibility section shell** → claim Reduced Motion. (Highest honesty-per-effort.) — DONE 2026-06-24
2. ✅ **Phase 1.2 Contrast** + **1.3 Color-only** → claim Sufficient Contrast + Differentiate Without Color. — DONE 2026-06-24
3. ✅ **Phase 1.5 Reduce Transparency** (bonus, cheap). — DONE 2026-06-24
4. ✅ **Phase 2.1 foundation** + **2.2–2.4 labels** + **2.5 painted widgets** + **2.6 keyboard focus** — ALL DONE (2.1–2.5 on 2026-06-24, 2.6 on 2026-06-25). **Phase 2 is code-complete.** **Remaining before checking the VoiceOver + Voice Control box:** the **device VoiceOver/TalkBack ear-sweep + desktop keyboard sweep** (Vitalik) — see the device-pass notes at the top + the 2.6 keyboard-sweep checkbox.
5. ⬜ **Phase 3 large-text** layout hardening → raise the cap → device-verify → claim Larger Text.

> **Phase 2.1–2.4 landed 2026-06-24.** Foundation: `HollowPressable`/`HollowButton`/`HollowToggle` wrap their gesture in `Semantics` (+`MergeSemantics` so each control is one SR node) with new `semanticLabel` (and `semanticButton` on Pressable) params; `HollowAvatar` gained `semanticLabel` (announces "name, image" or `ExcludeSemantics` when null). ~230 labels added across ~60 files via a parallel sweep, then a **CI guard** (`test/a11y_label_guard_test.dart`) caught 28 sweep-missed controls (all fixed). The guard now enforces labeling for all future icon-only controls.
>
> **LESSON (cost us a recovery):** several sweep agents ran `dart format`, which reflows entire files due to a `dart_style` version mismatch with HEAD (committed code is NOT format-clean), burying real changes in thousands of churn lines and once even reverting the foundation. **Do NOT run `dart format` on existing files in this repo during a labeling/edit pass** — hand-match the surrounding indentation; only format brand-new files. If a labeling diff shows deletions ≫ additions, formatting leaked in — revert and re-apply by hand.
>
> **NEXT (Phase 3):** Phase 2 is code-complete (2.1–2.6). What remains for Phase 2 is purely Vitalik's device verification (VoiceOver/TalkBack ear-sweep + desktop keyboard sweep) before the App Store box is checked. Then start Phase 3 (Larger Text — layout hardening, raise the mobile 1.3× cap). Heed the 1.3 lesson: audit site-lists are incomplete — the guard + a fresh grep are the real surface, not the bullet lists.

Dark Interface is already claimable now.

---

## Audit source

Full 5-agent audit findings (file:line evidence, contrast-ratio tables, animation inventory, severity rollups) were produced 2026-06-24 and summarized into this plan. Key surprising findings preserved above: the mobile 1.3× text cap (`app.dart:84`), the hue-shift contrast collapse (`accent_color_provider.dart:15`), the two-flag reduce-motion split, and the GIF-ticker bypass. Re-run a targeted audit before each phase if the tree has moved significantly.
