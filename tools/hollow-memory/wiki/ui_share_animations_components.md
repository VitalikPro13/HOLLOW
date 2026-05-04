# Share UI, Animations, and Reusable Components

## ShareDashboard

File: `lib/src/ui/share/share_dashboard.dart`

Top-level Share tab view. `ConsumerStatefulWidget` that displays the full share management interface with two sub-tabs.

### State

- `_subTab` (`_ShareSubTab`) — enum with values `myShares` and `serverFiles`. Controls which sub-tab content is displayed.
- On `initState`, fires `ref.read(shareTabProvider.notifier).loadAll()` via `Future.microtask`.

### Data Flow

- Watches `shareTabProvider` which returns `List<ShareItemState>`.
- Splits shares into two lists:
  - `userShares` — items where `contextType == null` (user's personal shares).
  - `serverFileShares` — items where `serverId != null` (files sent in server channels).

### Layout

Container with `hollow.background` color, Column with header + Expanded content area.

### Header (`_buildHeader`)

Row containing:
- "Share" heading text.
- Two `_SubTabPill` widgets for sub-tab switching, showing counts in parentheses when > 0.
- Right-aligned action buttons (only visible on "My Shares" tab):
  - "Share a File" — `HollowButton.ghost` with `LucideIcons.filePlus`, calls `_pickFile()`.
  - "Paste Link" — `HollowButton.filled` with `LucideIcons.link`, calls `_showPasteDialog()`.

### My Shares Tab (`_buildMyShares`)

- Empty state: centered icon (`LucideIcons.share2`), title "No shares yet", subtitle.
- Non-empty: ListView with padding `HollowSpacing.lg`, sections for:
  - "Downloading" — items where `state == 'downloading' || state == 'failed'`.
  - "Seeding" — items where `state == 'completed'`.
- Each item rendered as `ShareCard(item: item)`.

### Server Files Tab (`_buildServerFiles`)

- Empty state: `LucideIcons.server`, "No server files", subtitle about large files.
- Groups items by `serverId` using a `Map<String, List<ShareItemState>>`.
- Reads `serverListProvider` to resolve server names via `_serverName()`.
- Each group has a section header with server name + count, then `ShareCard` per item.

### Actions

- `_pickFile()` — opens `FilePicker.platform.pickFiles()`, calls `share_api.shareCreateFromFile(sourcePath:)`.
- `_showPasteDialog()` — opens `showHollowDialog` with `PasteLinkDialog`.

### _SubTabPill

Private `StatelessWidget`. Pill-shaped sub-tab button using `HollowPressable`. When `isSelected`:
- Background: `hollow.accent` at 15% alpha.
- Border: `hollow.accent` at 30% alpha.
- Text: accent color, `FontWeight.w600`.

When not selected: transparent background, `hollow.border` border, `hollow.textSecondary` text.


## ShareCard

File: `lib/src/ui/share/share_card.dart`

`ConsumerWidget` displaying a single share item inside a `HollowCard`. Takes `ShareItemState item` as required parameter.

### Layout

`HollowCard` with `HollowSpacing.lg` padding. Column with header + conditional body based on `item.state`.

### Header (`_buildHeader`)

Row: file icon (`LucideIcons.file`) + file name (ellipsized, colored red on failure) + formatted size.

### Download Body (`_buildDownloadBody`, state == 'downloading')

- `LinearProgressIndicator` with `chunksHave / chunksTotal` progress.
- Status row: chunk count, seeder/leecher counts, download speed in accent color.
- Cancel button: calls `share_api.shareCancel(rootHash:)`.

### Seeding Body (`_buildSeedingBody`, state == 'completed')

- Upload stats: bytes uploaded, seeder/leecher counts.
- Action row:
  - "Copy Link" — copies `item.shareLink` to clipboard, shows success toast.
  - "Show" — opens parent directory in `explorer.exe` (only if `diskPath` is non-null).
  - "Remove" — danger button, opens `_confirmRemove` dialog.
  - "Seeding" toggle — `HollowToggle` calling `share_api.shareSetSeeding(rootHash:, seeding:)`.

### Failed Body (`_buildFailedBody`, state == 'failed')

- Error text in `hollow.error` color.
- "Retry" button (if `shareLink` is non-empty): calls `share_api.shareOpenLink(link:)`.
- "Remove" danger button.

### Remove Confirmation (`_confirmRemove`)

Opens `showHollowDialog` with `HollowDialog` asking to confirm removal. On confirm: calls `share_api.shareRemove(rootHash:, deleteFile: false)` and `shareTabProvider.notifier.removeShare(rootHash)`.

### Static Utility Methods

- `formatSize(int bytes)` — B / KB / MB / GB with appropriate precision.
- `formatSpeed(int bytesPerSec)` — same format, appended with "/s" by callers.


## PasteLinkDialog

File: `lib/src/ui/share/paste_link_dialog.dart`

`ConsumerStatefulWidget` implementing a three-state dialog for opening share links.

### Dialog States (`_DialogState` enum)

- `input` — text field for pasting link.
- `loading` — spinner with countdown timer, waiting for seeders.
- `confirm` — shows file details and download button.

### State Fields

- `_controller` — `TextEditingController` for link input.
- `_state` — current dialog state.
- `_errorText` — validation error.
- `_rootHash`, `_shareLink` — decoded share info.
- `_fileName`, `_totalSize`, `_chunkCount` — manifest details from seeders.
- `_loadingStartMs` — timestamp for 10-second timeout.
- `_countdownTimer` — `Timer.periodic(1s)` to update countdown display.
- Optional `initialLink` constructor param — auto-submits on mount via `addPostFrameCallback`.

### Input State

- `HollowTextField` with hint "hollow://share/...", autofocus.
- Cancel + Open buttons.
- `_onOpen()`: validates non-empty, calls `share_api.shareDecodeLink(link:)`, checks for duplicates in `shareTabProvider`, transitions to loading state, calls `share_api.shareOpenLink(link:)`.

### Loading State

- Watches `shareTabProvider` for `pendingManifests[_rootHash]`.
- When manifest arrives: cancels countdown, transitions to confirm state, populates file info.
- 10-second timeout: cleans up, returns to input state with "No seeders found" error.
- Shows `CircularProgressIndicator` (24x24, strokeWidth 2) + "Looking for seeders... {remaining}s".

### Confirm State

- File name, formatted size + chunk count.
- Download path display: reads `shareDownloadPathProvider`, defaults to "Default Shares folder".
- "Change" button: calls `FilePicker.platform.getDirectoryPath()`.
- Cancel + Download buttons.
- `_onDownload()`: calls `shareTabProvider.notifier.startDownload()` then `share_api.shareStartDownload(rootHash:, saveDir:, link:, sequential: false)`.

### Cleanup

`_cleanup()` clears pending manifest and calls `share_api.shareCancel(rootHash:)`.


## DownloadManagerPopup

File: `lib/src/ui/components/download_manager_popup.dart`

Overlay-based download queue and progress popup. 613 lines total.

### Entry Point: `showDownloadManagerPopup()`

Top-level function. Takes `context`, `anchor` (Offset), `anchorBottom` (bool). Creates an `OverlayEntry` with `_DownloadManagerOverlay`, inserts into overlay. Dismiss callback removes + disposes the entry.

### _DownloadManagerOverlay

`ConsumerStatefulWidget` with `SingleTickerProviderStateMixin`.

**Animation:** Scale 0.92 to 1.0 (`easeOutCubic`) + fade 0.0 to 1.0 (`easeOut`), 180ms duration. Respects `HollowDurations.animationsDisabled`. Dismiss reverses animation then calls `onDismiss`.

**Data sources:**
- `downloadManagerEntriesProvider` — `List<DownloadManagerEntry>` for saved files and rebalance ops.
- `shareTabProvider` — filtered through `downloadingShares()` utility, further filtered to `contextType == null`.

**Layout constants:** `cardWidth = 340`, `maxHeight = 420`.

**Positioning logic:**
- Horizontal: anchored at `widget.anchor.dx`, clamped to 8px from edges.
- Vertical: if `anchorBottom`, card bottom sits at anchor Y; otherwise top sits at anchor Y.

**Structure:**
- Stack with dismiss barrier (full-screen `GestureDetector`) + positioned animated card.
- Card: `FadeTransition` + `ScaleTransition` (alignment `Alignment.bottomCenter`).
- Card decoration: surface at 96% alpha, `radiusLg` corners, accent border at 15% alpha, heavy shadow (35% black, 28px blur).

**Header:** Download icon + "Downloads" text + "Clear" button (calls `downloadManagerStateProvider.notifier.clearAll()`). Clear button only visible when entries exist.

**Empty state:** Inbox icon at 40% alpha + "Nothing here yet" + subtitle.

**Entry list:** `ListView.separated` with `shrinkWrap: true`. Combined list: share download tiles first, then regular entries. Separator: 1px border line at 30% alpha.

Item routing: share items render as `_ShareDownloadTile`; rebalance entries as `_RebalanceTile`; saved files as `_SavedFileTile`.

### _SavedFileTile

`ConsumerWidget` for completed file downloads.

**Thumbnail:** 40x40 `ClipRRect`. Shows `Image.file` for images/videos (with play icon overlay for video), or `_fileIconFallback` (film/image/file icon on `hollow.elevated` background).

**Content:** File display name (12px, w500) + saved path (mono, 9px, 70% alpha).

**Tap action:** `_revealInFolder()` — platform-specific:
- **Windows:** `Process.start('explorer.exe', ['/select,$path'])` then a PowerShell script that uses P/Invoke to call `SetForegroundWindow` with input queue attachment to bypass the foreground lock. Uses synthetic Alt keypress technique.
- **macOS:** `Process.run('open', ['-R', path])`.
- **Linux:** Opens parent directory via `launchUrl(Uri.file(parent))`.

On error: shows error toast "Could not open folder".

### _ShareDownloadTile

`StatelessWidget` for active share downloads.

**Layout:** Row with 40x40 indicator + file details.

**Indicator states:**
- Completed: green checkmark on `success` at 12% alpha background.
- In-progress: `CircularProgressIndicator` (32x32, strokeWidth 2.5) with percentage text (8px, w600) centered inside.
- Failed: progress ring in `hollow.error` color.

**Details:** File name + status line:
- Completed: formatted total size in success color.
- Failed: error message in error color.
- Downloading: "X/Y chunks  ·  speed/s" in secondary text.

### _RebalanceTile

`StatelessWidget` for vault shard rebalance operations.

**Layout:** 40x40 colored icon box (shuffle icon) + display name + status text. Active entries use accent color; completed use success color with checkmark icon.


## HollowCurves

File: `lib/src/ui/animations/hollow_curves.dart`

Abstract final class with static `Curve` constants for consistent animation curves across all Hollow UI.

| Name | Value | Usage |
|------|-------|-------|
| `enter` | `Curves.easeOutCubic` | Default enter curve, snappy with small overshoot |
| `exit` | `Curves.easeInCubic` | Default exit curve, smooth deceleration |
| `spring` | `Curves.elasticOut` | Interactive elements (buttons, cards) |
| `subtle` | `Curves.easeInOut` | Hover/focus transitions |

## HollowDurations

Same file. Abstract final class with static duration getters that return `Duration.zero` when `_disabled` is true (set via `animationsDisabled` setter). Used throughout all animated components.

| Name | Duration | Usage |
|------|----------|-------|
| `fast` | 150ms | Hover, focus, status changes |
| `normal` | 250ms | Panels, dialogs |
| `slow` | 400ms | Page changes, layout shifts |

All duration getters check `_disabled` flag and return `Duration.zero` when true. Components also check `HollowDurations.animationsDisabled` directly for `AnimationController` durations.


## FadeSlideTransition

File: `lib/src/ui/animations/hollow_transitions.dart`

`StatefulWidget` with `SingleTickerProviderStateMixin`. Combines opacity fade + slide-up for message bubbles and list items.

**Parameters:**
- `child` — widget to animate.
- `duration` — defaults to `HollowDurations.normal` (250ms).
- `beginOffset` — defaults to `Offset(0, 0.1)` (10% slide from below).

**Animation:** Single `AnimationController` drives both `_opacity` (CurvedAnimation with `HollowCurves.enter`) and `_offset` (Tween from `beginOffset` to `Offset.zero`, same curve). Auto-forwards on init.

**Build:** `FadeTransition` wrapping `SlideTransition`.


## ScaleFadeTransition

Same file. `StatefulWidget` for dialog and popup entrances.

**Parameters:**
- `child` — widget to animate.
- `duration` — defaults to `HollowDurations.normal` (250ms).

**Animation:** Scale 0.95 to 1.0 + opacity fade, both using `HollowCurves.enter`. Auto-forwards on init.

**Build:** `FadeTransition` wrapping `ScaleTransition`.


## AmbientBackground

File: `lib/src/ui/animations/ambient_background.dart`

`ConsumerWidget` that renders two slow-drifting radial gradient blobs behind the chat area.

**Parameters:**
- `color1`, `color2` — blob colors (typically teal + purple/blue).
- `opacity` — defaults to 0.04 (very subtle).
- `child` — content rendered beneath blobs.

**Background check:** Watches `backgroundProvider.hasBackground`. If a custom background image is set, skips blobs entirely and returns `child` directly.

**Animation:** Uses `SharedTickers.instance.ambient` (`ValueNotifier<double>`, ~15fps, 45-second cycle). The `ValueListenableBuilder` computes figure-8 positions:
- Blob 1: `x1 = 0.5 + 0.25 * sin(t)`, `y1 = 0.5 + 0.15 * sin(2t)`.
- Blob 2: `x2 = 0.5 - 0.2 * sin(t + 0.7pi)`, `y2 = 0.5 - 0.2 * sin(2t + pi)`.

**Rendering:** `RepaintBoundary` wrapping Stack: child (passed as `ValueListenableBuilder.child` for caching) + `Positioned.fill` with `IgnorePointer` + `CustomPaint`.

### _AmbientPainter

`CustomPainter`. Paints two radial gradient circles:
- Blob 1: radius = `width * 0.55`, 3-stop gradient `[color, color, transparent]` at stops `[0.0, 0.35, 1.0]`.
- Blob 2: radius = `width * 0.5`, same gradient pattern.

`shouldRepaint` returns true when center positions change.


## StartupRevealScope

File: `lib/src/ui/animations/startup_reveal.dart`

`InheritedWidget` that shares the master startup animation controller with the entire widget subtree.

**Properties:**
- `controller` — `AnimationController` for the startup sequence.
- `isComplete` — bool, when true all child lookups return null (skip animation).

**Static methods:**
- `of(BuildContext)` — returns `AnimationController?`. Returns null if scope not found or `isComplete` is true. Widgets should render fully when null.
- `interval(BuildContext, begin, end, {curve})` — creates a `CurvedAnimation` sub-interval of the master timeline for staggering child elements. Returns null when complete.

**Update notification:** Only notifies when `isComplete` changes.


## RevealClip

File: `lib/src/ui/animations/reveal_widgets.dart`

`StatelessWidget`. Reveals child by animating a clip from one edge ("carpet roll" effect).

**Parameters:**
- `animation` — `Animation<double>?`. When null, renders child directly (zero overhead).
- `axis` — `Axis.vertical` (top to bottom) or `Axis.horizontal` (left to right).
- `alignment` — defaults to `Alignment.topLeft`.

**Build:** `AnimatedBuilder` + `ClipRect` + `Align`. Sets `heightFactor` (vertical) or `widthFactor` (horizontal) to `animation.value`.


## TypewriterText

Same file. `StatelessWidget`. Reveals text character by character over an animation interval.

**Parameters:**
- `text` — full text string.
- `animation` — `Animation<double>?`. Null shows full text immediately.
- `style`, `overflow`, `maxLines` — standard text styling.

**Build:** `AnimatedBuilder` that computes `charCount = (value * text.length).round()` and shows `text.substring(0, charCount)`.


## LineDrawDivider

Same file. `StatelessWidget`. A divider that "draws" itself from one side to the other.

**Parameters:**
- `animation` — `Animation<double>?`. Null renders full width immediately.
- `height` — defaults to 1.
- `color` — defaults to `Theme.of(context).dividerColor`.
- `alignment` — defaults to `Alignment.centerLeft`.

**Build:** `AnimatedBuilder` + `FractionallySizedBox` with `widthFactor: animation.value`.


## StaggeredListItem

Same file. `StatelessWidget`. Per-item fade + slide entrance with stagger delay based on index.

**Parameters:**
- `parentAnimation` — `Animation<double>?`. Null renders child directly.
- `index` — item position in list.
- `totalItems` — total list length.
- `slideFrom` — defaults to `Offset(-0.3, 0)` (slide from left).

**Stagger calculation:**
- `itemDuration = 0.4` (each item animates over 40% of total timeline).
- `totalStagger = 0.6` (remaining 60% distributed as delays).
- `step = totalStagger / (totalItems - 1)`.
- Item interval: `[index * step, index * step + 0.4]`, clamped to `[0.0, 1.0]`.
- Curve: `Interval(begin, end, curve: Curves.easeOutCubic)`.

**Build:** `FadeTransition` + `SlideTransition` using the computed item animation.


## SelectionShimmer

File: `lib/src/ui/animations/selection_shimmer.dart`

`StatelessWidget`. A subtle transparent-to-highlight-to-transparent gradient that sweeps across the widget on a 4-second cycle.

**Parameters:**
- `child` — widget to overlay shimmer on.
- `highlightColor` — gradient peak color.
- `borderRadius` — optional clip radius.
- `vertical` — defaults to false. True for top-to-bottom sweep (voice channels), false for left-to-right.

**Animation:** Uses `SharedTickers.instance.shimmer` (4s cycle, `ValueNotifier<double>`). Sweep position: `value * 4.0 - 1.5` (range -1.5 to 2.5). Gradient alignment computed from position with 0.5 spread.

**Build:** `ValueListenableBuilder` + Stack: child (cached) + `Positioned.fill` with `IgnorePointer` + `ClipRRect` + `DecoratedBox` with `LinearGradient` (3 stops: transparent, highlight, transparent).


## SharedTickers

File: `lib/src/core/shared_tickers.dart`

Singleton (`SharedTickers.instance`) that centralizes all repeating animation tickers into a single `Ticker` + one ambient `Timer`. Implements `WidgetsBindingObserver` for lifecycle management.

**Shared ValueNotifiers (0.0 to 1.0 repeating):**

| Notifier | Cycle | Driven By | Used By |
|----------|-------|-----------|---------|
| `shimmer` | 4s linear | Main ticker | `SelectionShimmer`, divider glows |
| `pulse` | 6s ping-pong (3s each way) with easeInOut | Main ticker | `StatusDot` |
| `typingDots` | 1.2s linear | Main ticker | Typing indicator dots |
| `ambient` | 45s linear at ~15fps | Separate `Timer.periodic(67ms)` | `AmbientBackground` |

**Lifecycle:**
- `start()` — creates `Ticker` + ambient timer, registers as lifecycle observer. No-op if `disabled`.
- `pause()` — stops ticker, cancels ambient timer, stops ambient stopwatch.
- `resume()` — disposes old ticker, creates new one (Ticker cannot restart once stopped), restarts ambient timer.
- `didChangeAppLifecycleState` — pauses on `paused`/`hidden`/`detached`, resumes on `resumed`, keeps running on `inactive`.
- `disabled` flag — when true, `start()` and `resume()` are no-ops. All animation widgets stay frozen.


## HollowShaderWarmUp

File: `lib/src/ui/shader_warmup.dart`

Extends Flutter's `ShaderWarmUp` class. Executed in `main()` before `RustLib.init()` to pre-compile GPU shaders at startup, eliminating 20-200ms jank per first-use of each shader type.

**Canvas size:** 200x200.

**Primitives pre-compiled (13 categories):**
1. Solid filled rectangles (backgrounds, surfaces).
2. Rounded rectangles at radii 4/6/8/12/16/24 — filled, stroked, stroked with alpha.
3. Circles (avatars at 24px, status dots at 7px).
4. Linear gradients — vertical (server strip bg) + horizontal (shimmer).
5. Radial gradients — two blobs matching ambient background (teal + indigo).
6. Box shadows — large (dialog, 24px blur) + small (button hover, 8px blur).
7. Rounded rect clipping (avatar clips, RevealClip).
8. Rect clipping (width/height factor clips).
9. Lines (dividers, 1px stroke).
10. Text rendering — regular (14px) + bold (16px, w700).
11. Alpha compositing — `saveLayer` with 50% alpha + rounded rect fill.
12. BackdropFilter / `ImageFilter.blur` (glassmorphism dialogs, sigma 12).
13. Transform (scale + translate for ScaleTransition/SlideTransition).


## HollowPressable

File: `lib/src/ui/components/hollow_pressable.dart`

`StatefulWidget` with `SingleTickerProviderStateMixin`. Universal interactive widget replacing `InkWell` everywhere. No Material ripple.

**Parameters:**
- `child` — content widget.
- `onTap`, `onLongPress` — callbacks.
- `borderRadius`, `hoverColor`, `backgroundColor`, `padding` — visual config.
- `disabled` — disables interaction, shows at 40% opacity.
- `subtle` — list item mode: hover color change only, no press dim/scale.

**Animation (non-subtle):**
- `AnimationController`: 120ms forward, 200ms reverse.
- Scale: 1.0 to 0.98, forward curve `easeOutCubic`, reverse curve `HollowCurves.spring` (elasticOut for bounce-back).
- Opacity: 1.0 to 0.85, both curves `easeOutCubic`.
- Triggered by `Listener` pointer events (`onPointerDown` → forward, `onPointerUp`/`onPointerCancel` → reverse).

**Hover:**
- `MouseRegion` sets cursor to click when interactive.
- `_hovering` state triggers `AnimatedContainer` (duration `HollowDurations.fast`, curve `HollowCurves.subtle`):
  - Without `backgroundColor`: transitions to `effectiveHoverColor` (default `hollow.elevated`).
  - With `backgroundColor`: `Color.lerp(backgroundColor, Colors.white, 0.15)` + `BoxShadow` glow.

**Build hierarchy:** `MouseRegion` > `Listener` > `GestureDetector` > `AnimatedBuilder` (`FadeTransition` > `ScaleTransition`) > `AnimatedContainer`.


## HollowButton

File: `lib/src/ui/components/hollow_button.dart`

`StatefulWidget` with `SingleTickerProviderStateMixin`. Four-variant button with spring physics interactions.

**Variants (`HollowButtonVariant`):**

| Variant | Background | Text Color | Hover BG | Usage |
|---------|-----------|------------|----------|-------|
| `filled` | `hollow.accent` | `hollow.textOnAccent` | `hollow.accentHover` | Primary actions |
| `ghost` | transparent | `hollow.accent` | `hollow.accentMuted` | Secondary actions |
| `outline` | transparent + accent border | `hollow.accent` | `hollow.accentMuted` | Tertiary actions |
| `danger` | `hollow.error` | white | error at 85% | Destructive actions |

**Named constructors:** `HollowButton.filled()`, `.ghost()`, `.outline()`, `.danger()`.

**Parameters:** `onPressed`, `child`, `icon`, `variant`, `expand` (full width), `compact` (reduced padding).

**Animation:** Same pattern as `HollowPressable` — scale 1.0 to 0.98 + opacity 1.0 to 0.85, 120ms/200ms durations with spring reverse.

**Hover effects:**
- Non-ghost variants: `BoxShadow` glow (glowColor at 20% alpha, 8px blur).
- Outline variant: border alpha increases from 0.4 to 0.6 on hover.
- Disabled: opacity fixed at 0.4 via `AlwaysStoppedAnimation`.

**Content layout:** Row with optional 16x16 icon (in `IconTheme` with `fg` color) + `DefaultTextStyle` using `HollowTypography.label`.

**Padding:** compact = `HollowSpacing.md` horizontal / `HollowSpacing.sm` vertical; normal = `HollowSpacing.lg` / `HollowSpacing.sm + 2`.


## HollowTextField

File: `lib/src/ui/components/hollow_text_field.dart`

`StatefulWidget` with `SingleTickerProviderStateMixin`. Flat design text field with animated border and focus glow.

**Parameters:** `controller`, `hintText`, `onSubmitted`, `onChanged`, `isDense`, `style`, `prefixIcon`, `autofocus`, `errorText`, `obscureText`, `maxLines`, `minLines`, `focusNode`, `borderRadius`, `maxLength`, `showCounter`.

**Focus behavior:**
- Internal `FocusNode` created if none provided.
- `_isFocused` tracks focus state, triggers glow animation.
- Border color: error state → `hollow.error`; focused → `hollow.accent`; default → `hollow.border`.

**Error shake animation:**
- Triggered in `didUpdateWidget` when `errorText` transitions from null to non-null.
- `TweenSequence`: 0 → 3 → -3 → 2 → 0 over 300ms with `easeInOut`.
- Applied via `AnimatedBuilder` + `Transform.translate` on X axis.

**Focus glow:**
- `AnimatedContainer` (duration `HollowDurations.fast`, curve `HollowCurves.subtle`).
- When focused: `BoxShadow` with glow color (accent or error) at 15% alpha, 6px blur, 1px spread.

**Character counter:**
- Shown below field when `maxLength != null && showCounter` or `errorText != null`.
- Counter turns `hollow.warning` when at 80%+ of max length.

**TextField decoration:** `OutlineInputBorder` with configurable radius, filled with `hollow.elevated`, cursor in `hollow.accent`.


## HollowDialog (Widget) and showHollowDialog (Function)

File: `lib/src/ui/components/hollow_dialog.dart`

### showHollowDialog()

Top-level function wrapping `showGeneralDialog`. Returns `Future<T?>`.

**Parameters:** `context`, `builder` (WidgetBuilder), `barrierDismissible` (default true).

**Barrier:** `Colors.black` at 8% alpha. Label "Dismiss".

**Transition (duration: `HollowDurations.normal` = 250ms):**
- `CurvedAnimation`: forward `HollowCurves.enter` (easeOutCubic), reverse `Curves.easeIn`.
- `AnimatedBuilder` renders Stack:
  - Blur layer: `AnimatedOpacity` (opacity tied to animation.value, zero duration) wrapping `BackdropFilter` with `ImageFilter.blur(sigmaX: 12, sigmaY: 12)` on `SizedBox.expand`.
  - Dialog: `FadeTransition` + `ScaleTransition` (0.95 to 1.0).

### HollowDialog Widget

`StatelessWidget`. Dark-themed dialog container.

**Parameters:** `title` (String), `content` (Widget), `actions` (List<Widget>).

**Layout:** `Center` > `Padding(xl)` > `ConstrainedBox(maxWidth: 600, minWidth: 300)` > `Material(transparent)` > `Container`.

**Decoration:** `hollow.elevated` at 92% alpha, `radiusLg` corners, accent border at 15%, shadow (20% black, 24px blur).

**Content layout:** Column with title (if non-empty) + `HollowSpacing.lg` + content + `HollowSpacing.xl` + right-aligned action Row (if actions non-empty).

**Important:** Wraps content in `Material` so `Text` widgets have a material ancestor (avoids yellow debug underline).


## HollowTooltip

File: `lib/src/ui/components/hollow_tooltip.dart`

`StatefulWidget` with `SingleTickerProviderStateMixin`. Overlay-based tooltip replacing Material's `Tooltip`.

**Parameters:** `message` (String), `child` (Widget), `preferBelow` (default true).

**Hover timing:** 400ms delay via `Future.delayed` before showing. Tracks `_hovering` flag to prevent stale shows.

**Animation:** `AnimationController` at 100ms. Fade + slide (0.15 vertical offset to zero), both with `Curves.easeOut`.

**Dismiss (`_dismiss()`):**
- **Critical pattern:** Immediate overlay removal, no reverse animation. Prevents orphaned tooltips when parent rebuilds or leaves tree during hover (e.g., call bar buttons disappearing).
- Stops controller, resets to 0, removes + nulls `_entry`.
- Called on: hover exit, `deactivate()`, `dispose()`, message change (`didUpdateWidget`).

**Positioning (in OverlayEntry builder):**
- Tooltip width estimate: `message.length * 7.0 + padding`, clamped to screen bounds.
- Horizontal: centered on widget, clamped 8px from edges.
- Vertical: prefers below (`widget position + height + 6px gap`), flips above if would overflow. Estimated height: 28px.

**Visual:** `hollow.elevated` background, `radiusSm` corners, `hollow.border` border. Text in `HollowTypography.caption`, `hollow.textPrimary`.


## HollowToast

File: `lib/src/ui/components/hollow_toast.dart`

Static class + `_HollowToastWidget` `StatefulWidget`.

### HollowToast (static API)

- `show(context, message, {type, duration})` — shows a toast. Default duration 3 seconds.
- `_dismiss()` — removes current entry immediately.
- Only one toast visible at a time (`_currentEntry` static field). New toast replaces existing.

### Toast Types (`HollowToastType`)

| Type | Icon | Color |
|------|------|-------|
| `success` | `LucideIcons.checkCircle` | `hollow.success` |
| `error` | `LucideIcons.alertCircle` | `hollow.error` |
| `info` | `LucideIcons.info` | `hollow.accent` |

### _HollowToastWidget

`StatefulWidget` with `SingleTickerProviderStateMixin`.

**Animation:** `AnimationController` 200ms forward / 150ms reverse. Opacity with `easeOut` curve. Slide from `Offset(0, 0.3)` with `easeOutCubic`.

**Auto-dismiss:** `Future.delayed(duration)` then reverse animation, then remove entry.

**Position:** `Positioned` at bottom: 32, left/right: 0, centered. Max width 400px.

**Visual:** `hollow.elevated` background, `radiusMd` corners, `hollow.border` border. Row: colored icon (18px) + message text.


## HollowToggle

File: `lib/src/ui/components/hollow_toggle.dart`

`StatefulWidget` with `SingleTickerProviderStateMixin`. Toggle switch with spring physics.

**Parameters:** `value` (bool), `onChanged` (ValueChanged<bool>?).

**Dimensions:** Track: 36x20px pill. Thumb: 16px circle. 2px padding on each side.

**Animation:**
- `AnimationController` at 200ms, initial value matches `widget.value`.
- `CurvedAnimation` with `HollowCurves.spring` (elasticOut) for both forward and reverse.
- Thumb position: `2.0 + (value * 16.0)` (slides from left 2px to left 18px).
- Track color: `ColorTween` from `hollow.border` (off) to `hollow.accent` (on).

**Thumb shadow:** 2px blur, 15% black, offset (0, 1).

**Disabled state:** opacity 0.4 via `AlwaysStoppedAnimation`, cursor changes to `basic`.

**didUpdateWidget:** Forwards or reverses animation when `value` changes externally.


## HollowAvatar

File: `lib/src/ui/components/hollow_avatar.dart`

`ConsumerWidget`. User avatar with deterministic fallback. Auto-fetches avatar bytes from `avatarProvider` on mount.

**Parameters:** `peerId` (String), `size` (default 36), `imageBytes` (Uint8List?, explicit override), `animate` (default false).

**Avatar resolution order:**
1. If `imageBytes` is passed (non-null), use it directly (for archive data or explicit overrides).
2. Otherwise, read from `avatarProvider` cache. If not yet cached, schedules `loadAvatar(peerId)` via `Future.microtask`.

**With image:**
- `animate: true` — renders `AnimatedGifImage` (for GIF avatar support in profile cards, DM panel, settings).
- `animate: false` — renders `_StaticFirstFrame` (freezes GIF on first frame for list views).
- Wrapped in `ClipRRect` with `radiusMd` corners.

**Fallback (`_buildFallback`):**
- Color: `HSLColor.fromAHSL(1.0, peerId.hashCode % 360, 0.5, 0.45)`.
- Initials: first 2 characters of peerId, uppercased.
- Container: `radiusMd` corners, centered text at `size * 0.38` font size.

**IMPORTANT:** Do NOT pass `imageBytes: profiles[peerId]?.avatarBytes` — profileProvider loads light profiles without blobs. Avatar bytes are managed by `avatarProvider`.

### _StaticFirstFrame

Private `StatefulWidget`. Decodes only the first frame of an image using `ui.instantiateImageCodec` + `codec.getNextFrame()`. Properly disposes `ui.Image` and `codec`. Shows fallback on error, blank `SizedBox` while loading. `didUpdateWidget` re-decodes when `imageBytes` content changes (uses `listEquals` for content comparison, not identity).


## AnimatedGifImage

File: `lib/src/ui/components/animated_gif_image.dart`

`StatefulWidget` with `SingleTickerProviderStateMixin`. Renders animated GIFs from raw bytes with proper frame delay handling.

**Parameters:** `bytes` (Uint8List), `width`, `height`, `fit` (default `BoxFit.cover`), `errorWidget`.

**Browser-compatible delay:** Frame delays < 20ms are treated as 100ms (matching browser behavior where 0ms/10ms GIF delays play too fast).

**Decode flow:**
1. `ui.instantiateImageCodec(bytes)`.
2. Loop through all frames, collect `_GifFrame(image, duration)`.
3. Dispose codec.
4. If multi-frame: create `Ticker`, start animation.

**Tick logic (`_onTick`):** Tracks `_elapsed` and `_nextFrameAt`. When elapsed exceeds next frame time, advances `_currentFrame` (wrapping) and updates `_nextFrameAt`.

**Cleanup:** `_disposeFrames()` stops/disposes ticker, disposes all `ui.Image` instances.

**Build:** `RawImage` showing `_frames[_currentFrame].image`.

### GifFileImage

`StatefulWidget` wrapper. Loads bytes from disk path via `File(diskPath).readAsBytes()`, then renders via `AnimatedGifImage`. Re-loads when `diskPath` changes.


## HollowCard

File: `lib/src/ui/components/hollow_card.dart`

`StatelessWidget`. Simple elevated surface container.

**Parameters:** `child`, `padding` (default 16), `color` (default `hollow.elevated`).

**Build:** `Container` with specified padding, `radiusMd` corners, `hollow.border` border.


## StatusDot

File: `lib/src/ui/components/status_dot.dart`

`StatelessWidget`. Small colored circle for connection/encryption status.

**Parameters:** `color` (default `hollow.success`), `size` (default 8), `pulse` (default false).

**Named constructor:** `StatusDot.online({size, pulse})` — uses success color from theme.

**Non-pulse:** Simple `Container` with circle shape.

**Pulse mode:** Uses `SharedTickers.instance.pulse` (3s breathing, ping-pong 0 to 1 to 0 with easeInOut). `ValueListenableBuilder` wrapping Container with `BoxShadow`:
- Color: dot color at `0.4 * value` alpha.
- Blur: `3 * value`.
- Spread: `1.5 * value`.


## ConnectionProgress

File: `lib/src/ui/components/connection_progress.dart`

`StatelessWidget`. Simple two-state connection indicator.

**Enum `ConnectionStage`:** `offline`, `encrypted`.

**Encrypted:** Row with `LucideIcons.lock` (14px, success color) + "Encrypted" text in success color.

**Offline:** Row with `LucideIcons.wifiOff` (14px, secondary) + "Offline" text in secondary color.


## ActiveCallBar

File: `lib/src/ui/components/active_call_bar.dart`

`ConsumerStatefulWidget`. Floating draggable pill shown during active voice calls.

**State:** `_durationTimer` (1s periodic), `_duration` (Duration), `_dragOffset` (Offset for drag repositioning).

**Visibility conditions:**
- `callProvider` status must be `active` or `connecting`.
- Hidden when user is viewing the call peer's DM (inline call panel handles it).

**Duration tracking:** Starts 1-second `Timer.periodic` when call becomes active with `startedAt`. Formats as "MM:SS" with padded zeros and `FontFeature.tabularFigures()` for fixed-width digits.

**Layout:** `Positioned` at top: 80 (below title bar + friends bar), centered horizontally, wrapped in `Transform.translate(_dragOffset)`.

**Container:** Height 36, `radiusLg` corners, `hollow.elevated` background, green border (success at 30% alpha), drop shadow.

**Content Row:**
- Pulsing green `StatusDot`.
- Connecting state: "Connecting..." text.
- Active state: display name (w600) + formatted duration.
- Controls (all with `HollowTooltip` + `HollowPressable`):
  - Mute toggle — mic/micOff icons, error color when muted.
  - Video toggle — video/videoOff icons, accent when enabled.
  - Screen share indicator (desktop only) — monitorOff/monitor icons, accent when sharing. Only tappable to stop sharing.
  - End call — `LucideIcons.phoneOff`, error color.

**Drag:** `GestureDetector.onPanUpdate` accumulates delta into `_dragOffset`. `MouseRegion` shows move cursor.


## CallVideoView

File: `lib/src/ui/components/call_video_view.dart`

`ConsumerStatefulWidget`. Floating draggable video panel during active calls.

**Visibility:** Only shown when `callProvider.status == active` AND either local or remote video is enabled.

**Layout:** `Positioned` at `_position` (default Offset(20, 80)), draggable via `GestureDetector.onPanUpdate`.

**Container:** 320x240, `radiusLg` corners, elevated background, border, heavy shadow (30% black, 24px blur).

**Content Stack:**
- Remote video (full): `RTCVideoView(remoteRenderer)` with cover fit, wrapped in `RepaintBoundary`. Fallback when no remote video: centered `HollowAvatar` (64px) + display name + "Camera off" indicator.
- Local video (PiP): 96x72, positioned bottom-right (8px inset), `RTCVideoView(localRenderer, mirror: true)`, border + shadow, wrapped in `RepaintBoundary`.


## NotificationOverlay

File: `lib/src/ui/components/notification_overlay.dart`

`ConsumerWidget`. Bottom-right notification card stack showing up to 3 cards.

**Data:** Watches `systemNotificationProvider` which returns `List<NotificationCard>`.

**Layout:** Stack with `AnimatedPositioned` cards. Cards stacked vertically from bottom (newest at bottom, oldest at top). Card height ~100px + 4px gap. Positioned at right: `HollowSpacing.lg`, bottom: `HollowSpacing.lg + (cards.length - 1 - i) * (cardHeight + gap)`.

### _NotificationCardWidget

`ConsumerStatefulWidget` with `SingleTickerProviderStateMixin`.

**Animation:** Slide from right (`Offset(1.0, 0)` to zero) + fade, 250ms forward / 200ms reverse, `easeOutCubic`.

**Auto-dismiss:** 5-second timer. Hover pauses timer (cancels on `MouseRegion.onEnter`, restarts on `onExit`). Timer resets when new messages arrive (`didUpdateWidget` checks message count).

**Dismiss:** Reverse animation then remove card via `systemNotificationProvider.notifier.dismissCard(sourceKey)`.

**Tap navigation (`_onTap`):**
- DM notifications: sets `selectedPeerProvider`, clears server/channel/archive/share state, marks DM seen.
- Channel notifications: fetches channels + layout for server, sets all server/channel providers atomically (canonical batch pattern), updates `lastChannelPerServerProvider`.

**Card visual:** 320px wide, max height 260px. Elevated surface at 95% alpha, accent border at 20%, heavy shadow.

**Content:** Header (avatar + title + close button) + divider + message list.

### _MessageRow

`StatelessWidget`. For DMs: just the message text. For channels: sender name (bold) + message text. Both capped at 2 lines.


## DownloadIconButton

File: `lib/src/ui/components/download_icon_button.dart`

`ConsumerWidget`. Download manager icon with activity badge. Used in both UserBar (classic layout, iconSize 16) and BottomBar (dock layout, iconSize 18).

**Badge:** 7x7 accent-colored circle positioned top-right (-3, -3) when `activeTransferCountProvider > 0`.

**Tap:** Computes anchor position from `RenderBox.localToGlobal`, calls `showDownloadManagerPopup(anchor:, anchorBottom: true)`.

**Wrapping:** `HollowTooltip("Downloads")` > `HollowPressable` > `Stack` with icon + optional badge.


## ServerFolderPopup

File: `lib/src/ui/components/server_folder_popup.dart`

### ServerFolderIcon

`ConsumerWidget`. 2x2 mini-grid preview showing first 4 servers in a folder.

**Parameters:** `folder` (FolderStripItem), `size`.

**Cell rendering:** Uses `LayoutBuilder` for adaptive sizing. Each cell: `ClipRRect` with server avatar image or fallback (deterministic color from ID + initials). Empty cells: border at 30% alpha.

### showServerFolderPopup()

Top-level function. Creates `OverlayEntry` with `_FolderPopupOverlay`. Callbacks for server selection, dismiss, rename.

### _FolderPopupOverlay

`ConsumerStatefulWidget` with `SingleTickerProviderStateMixin`. Scale 0.92 to 1.0 + fade, 180ms.

**Layout constants:** `iconSize = 38`, `columns = 5`, `iconSpacing = 6`.

**Auto-dismiss:** If folder dissolved (not found in layout), dismisses via `addPostFrameCallback`.

**Positioning:** Dock mode anchors from bottom; classic mode from side. Clamped to screen bounds. Escape key dismisses via `Focus` widget.

**Content:** Header with folder name + pencil rename button + divider + `Wrap` grid of `_FolderServerItem` widgets.

### _FolderServerItem

`StatelessWidget`. Server icon (38px) with optional unread badge (red, top-right) and optional remove-from-folder button (X circle, top-left). Below: server name (9px caption).

### showFolderRenameDialog()

Opens `showHollowDialog` with `_FolderRenameDialog` — text field (maxLength 32, autofocus) + Cancel/Save buttons. Saves via `serverStripLayoutProvider.notifier.renameFolder(id, name)`.


## ProfileCardPopup

File: `lib/src/ui/components/profile_card_popup.dart`

### showProfileCardPopup()

Top-level function. Creates `OverlayEntry` with `_ProfileCardOverlay`. Accepts `peerId`, optional `nickname`, `role`, `twitchUsername`, `labels`, `anchor`, `anchorBottom`.

### _ProfileCardOverlay

`ConsumerStatefulWidget` with `SingleTickerProviderStateMixin`. Scale 0.92 to 1.0 + fade, 180ms, same pattern as download manager.

**Twitch resolution:** On init, if no Twitch username provided and viewing own profile, calls `twitchGetUsername()` FFI to resolve.

**Card width:** 280px. Positioned near anchor with screen edge clamping.

**Banner:** 80px tall. Shows `AnimatedGifImage` from `profile.bannerBytes` if available, otherwise gradient from `_bannerColorFromId(peerId)` (hue shifted +40 from avatar color).

**Content (overlaps banner via `Transform.translate(0, -32)`):**
- Avatar: 64px `HollowAvatar` with `animate: true`, bordered (3px surface color).
- Names: Local nickname or server nickname shown as primary (bold, 15px). Profile display name as secondary (11px caption). Falls back to truncated peer ID.
- Role badge: colored pill with capitalized role name. Colors: owner = warning, admin = purple (#A78BFA), moderator = warning/error blend, member = hidden.
- Labels: `Wrap` of colored pills from `List<LabelFfi>`. Color parsed from hex with `_parseLabelColor`.
- Twitch badge: purple pill (#9146FF) with Twitch icon + username. Tappable to open `twitch.tv/{username}`.
- Status: italic text if non-empty.
- Divider.
- About Me: section header "ABOUT ME" (9px, w700, 0.5 letter-spacing) + text (max 4 lines).
- Self actions: "Edit Profile" outline button opening `showUserSettingsDialog`.
- Non-self actions:
  - "Set Nickname" / "Edit Nickname" ghost button opening `showLocalNicknameDialog`.
  - `_FriendActionButton` — state-aware friend action.

**Peer ID footer:** Positioned at bottom via `Transform.translate(0, -28)`. Shows last 8 chars of peer ID in mono (8px, 35% alpha). Tap copies full peer ID to clipboard with success toast.

### _FriendActionButton

`ConsumerWidget`. Four states based on `friendsProvider[peerId]`:
- No entry: "Add Friend" outline button with userPlus icon.
- Pending incoming: "Accept Request" filled button with check icon.
- Pending outgoing: "Request Sent" disabled ghost button with clock icon.
- Accepted: "Friends" text with userCheck icon in success color.

### showLocalNicknameDialog()

Opens `showHollowDialog` with `_LocalNicknameDialog`. TextField (maxLength 32, hint "Nickname (leave empty to clear)"). Saves via `localNicknameProvider.notifier.setNickname(peerId, nickname)`.
