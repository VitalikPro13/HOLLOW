# Hollow Performance Optimization Report

**Date:** 2026-05-07
**Flutter:** 3.41.4 | **Platform:** Windows 10 (Skia + ANGLE → DirectX 11)
**Before:** ~14% CPU on tab switch, 231 MB RAM, Intel UHD GPU at 50%
**After:** ~2-3% CPU stable, 150 MB RAM, RTX 4060 handling rendering

---

## GPU Fix (DONE)

**NvOptimusEnablement + AmdPowerXpressRequestHighPerformance** exports added to
`windows/runner/main.cpp`. Forces the discrete GPU (RTX 4060) instead of integrated
Intel UHD. Safe fallback — symbols are ignored on machines without a discrete GPU.

---

## Quick Wins — All 5 DONE

### 1. profileProvider .select() — Tier 1, Item 1 (DONE)
- **22 of 45 call sites** converted from `ref.watch(profileProvider)` to
  `ref.watch(profileProvider.select((p) => p[peerId]))`.
- Added `displayNameForPeer()` and `serverDisplayNameForPeer()` helpers to
  `profile_provider.dart`.
- ~50% reduction in profile-triggered rebuilds.

### 2. Cached colorFromId() / nameColorFromId() — Tier 2, Item 10 (DONE)
- Created `lib/src/core/color_utils.dart` with static `Map` cache.
- Eliminated 4 duplicate `_colorFromId()` implementations across server_strip,
  bottom_bar, server_folder_popup, and hollow_avatar.
- HSLColor computed once per ID, never again.

### 3. serverMemberNamesProvider — Tier 1, Item 5 (DONE)
- Created memoized `serverMemberNamesProvider` in `server_provider.dart`.
- Computed once per server when members/profiles/nicknames change, not per message bubble.

### 4. Message text LRU cache — Tier 1, Item 4 (DONE)
- Rewrote `message_text_parser.dart`: split into tokenizer (cacheable) + renderer (cheap).
- 200-entry LRU cache keyed by (text + memberNames hash).
- New messages parse once; scrolling back hits cache instantly.

### 5. jsonDecode() cached in sidebar — Tier 1, Item 3 (DONE)
- `channel_sidebar.dart` now caches parsed JSON in `_parsedLayout` state field.
- Only re-parses when the JSON string actually changes.

---

## Medium Effort — All 4 DONE

### 6. Shell provider watch split — Tier 1, Item 2 (DONE)
- Moved `localNicknameProvider` from `ref.watch()` to `ref.listenManual()` (side effect only).
- Extracted `backgroundProvider` into `_ShellScaffold` ConsumerWidget.
- Main build reduced from 14 to 12 provider watches.

### 7. sortedFriendsProvider — Tier 2, Item 7 (DONE)
- Created `sortedFriendsProvider` and `pendingFriendCountProvider` in `friends_provider.dart`.
- O(n log n) sort + displayNameFor calls computed once, shared across all consumers.

### 8. dmUnreadBadgeProvider — Tier 2, Item 8 (DONE)
- Created `dmUnreadBadgeProvider` in `unread_provider.dart`.
- Replaced manual O(n) DM unread loops in both `bottom_bar.dart` and `server_strip.dart`.

### 9. peersProvider + unreadProvider .select() — Tier 1, Item 1 ext. (DONE)
- 3 peersProvider sites converted to `.select((p) => p.keys.toSet())` (user_bar, home_dashboard, member_panel).
- 3 unreadProvider sites converted to `.select()` for specific DM/channel counts (chat_pane, channel_chat_pane, home_dashboard).

---

## Larger Effort — All 3 DONE

### 10. BackdropFilter optimization — Tier 2, Item 6 (DONE)
- Reduced blur sigma 12 → 8 (~44% cheaper, visually similar).
- Replaced `AnimatedOpacity(Duration.zero)` with `FadeTransition` (no independent ticker).
- Added `RepaintBoundary` around blur layer.
- Reduced dialog BoxShadow blurRadius 24 → 16.
- Updated shader warmup to match sigma 8.

### 11. Event dispatch consolidation — Tier 2, Item 9 (DONE)
- Extracted `_refreshServerState()` helper in `event_provider.dart`.
- Reused from both `NetworkEvent_ServerUpdated` and `NetworkEvent_RoleChanged` (was 7 lines × 2 = 14 lines, now 1 call each).
- Investigation confirmed Riverpod already coalesces invalidations within the same synchronous frame — no batching framework needed.

### 12. Animation per-frame efficiency — Full audit (DONE)
Six animation inefficiencies fixed:

| Fix | File | What changed |
|-----|------|-------------|
| Dialog blur ticker | hollow_dialog.dart | FadeTransition replaces AnimatedOpacity(Duration.zero) |
| Ambient Paint cache | ambient_background.dart | Paint objects cached as fields, fade colors precomputed |
| Shimmer CustomPaint | selection_shimmer.dart | _ShimmerPainter with cached Paint replaces DecoratedBox |
| Status dot painter | status_dot.dart | _PulseDotPainter with Paint.maskFilter replaces BoxDecoration |
| Toggle ColorTween | hollow_toggle.dart | ColorTween cached in didChangeDependencies, const BoxShadow |
| Waveform Paint+repaint | voice_recorder_bar.dart | Static cached Paint, fixed shouldRepaint, added RepaintBoundary |

---

## Remaining Items (NOT done — diminishing returns)

### 23 profileProvider full-map watches
These are in list builders (friends_bar, chat_pane, channel_chat_pane, archive views)
where multiple peerIds are iterated. Converting them requires extracting each list item
into its own ConsumerWidget with a per-item .select(). This is a significant structural
refactor per file with moderate gain — the 22 single-peerId sites we already fixed cover
the worst cases. The remaining sites only rebuild when their parent list rebuilds anyway
(which is the correct behavior for a list showing multiple profiles).

**Verdict:** Not worth doing unless profiling shows these specific list rebuilds as a bottleneck.

### Tier 3 items from original audit
- **ref.listen inside build()** in chat panes — re-registers listeners per rebuild. Low
  frequency (only when chat view rebuilds), so low impact.
- **Duplicate ref.watch calls** in channel_chat_pane — watches same provider twice in one
  build. Tiny overhead (Riverpod deduplicates internally).
- **localNicknameProvider in member tiles** — any nickname change rebuilds all member tiles.
  Rare event (user manually sets nicknames), not worth optimizing.
- **Text field shake fractional pixels** — only happens during the shake animation (rare),
  not worth a fix.

**Verdict:** All Tier 3 items have negligible real-world impact at 2-3% CPU. Leave them.

---

## Final Results

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| CPU (idle) | 3-5% | ~2% | ~60% reduction |
| CPU (tab switching) | 14%+ | ~3% | ~80% reduction |
| RAM (active) | 231 MB | 150 MB | ~35% reduction |
| GPU | Intel UHD at 50% | RTX 4060 at ~30% | Discrete GPU enabled |
| Frame rate | ~141 FPS | 144 FPS (target) | Hitting vsync target |
| Jank rate | 0.7% | ~0% | Eliminated |

**Total changes:** 17 optimization tasks across ~40 files, zero compile errors introduced.
