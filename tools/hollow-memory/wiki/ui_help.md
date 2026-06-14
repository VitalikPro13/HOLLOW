# Help — In-App Resource Center (Guides)

The in-app Help is a **resource-center** pattern (search + collapsible categories + in-place
lesson reading), NOT a course/modal. Industry-standard shape (Intercom/Userpilot style): a
persistent affordance opens a slide-out panel with search at the top and collapsed category
sections. Content ships **bundled in the app** (`assets/help/`), loaded locally, no network.

## Files

- `assets/help/manifest.json` — all Help content (7 modules, 28 lessons). Edited per app release.
- `assets/help/media/` — small inline screenshots (icon/control shots). `.gitkeep` placeholder; most lessons are text-only.
- `lib/src/ui/guides/guides_models.dart` — `GuidesManifest → GuidesModule → GuidesLesson → GuidesSection`. A lesson is ONE scrollable page of `sections` (each = optional `media` asset path + markdown `text`). All have `fromJson`.
- `lib/src/core/providers/help_manifest_provider.dart` — `helpManifestProvider` (`FutureProvider<GuidesManifest>`) loads `assets/help/manifest.json` via `rootBundle` + `jsonDecode`. Cached by Riverpod; `ref.invalidate` retries on error.
- `lib/src/core/providers/help_panel_provider.dart` — `helpPanelOpenProvider` (`StateProvider<bool>`, default false).
- `lib/src/ui/guides/help_panel.dart` — all the UI (slider, panel chrome, resource center, lesson view).

## Entry points

- **Desktop:** circled-`?` (`LucideIcons.circleHelp`) on the RIGHT of `FriendsBar` (`friends_bar.dart`), symmetric with Add Friend on the left. Icon turns `hollow.accent` when the panel is open. `onTap` toggles `helpPanelOpenProvider`.
- **Mobile:** a "Help" `_SettingsNavTile` (circleHelp icon) at the top of `mobile_settings_tab.dart`, pushes `const HelpResourceCenter()` full-screen via the shared `_SettingsSubPage` chrome.

## Widgets (help_panel.dart)

- `HelpPanelSlider` — right-edge slide-in (ClipRect + Align centerRight widthFactor + fade, mirrors `_MemberPanelSlider`). Inserted into both shell layouts. Wraps `_HelpPanelChrome`.
- `_HelpPanelChrome` — fixed-width (`kHelpPanelWidth` = 340) panel with a left border; holds `HelpResourceCenter` with an `onClose` that sets the provider false.
- `HelpResourceCenter` (`ConsumerStatefulWidget`, shared desktop + mobile) — watches `helpManifestProvider` (`.when` loading/error/data). Header (`?` + "Help" + optional X) → search field (live filter by title) → body. Body shows `_SearchResults` when querying, else a `ListView` of `_CategorySection` (first module expanded once via `_seededExpansion`). Opening a lesson sets `_openLesson` and swaps the whole body to `HelpLessonView`. `onClose` null on mobile (route has its own back chrome).
- `_CategorySection` — collapsible module header (title + subtitle + `AnimatedRotation` chevron) revealing inset `_LessonRow`s.
- `_LessonRow` — id badge (mono, accent) + title; `subtle` pressable.
- `HelpLessonView` (shared) — ONE scrollable page: header (back arrow → `onBack` returns to list) + `ListView.separated` of `_SectionView`. NO paging/dots/arrows (deliberately removed).
- `_SectionView` → optional `_InlineImage` (small, 48px, bordered) + `HelpMarkdown`.
- `HelpMarkdown` — `MarkdownBody` with Hollow styleSheet (reuses the news-post markdown style; code spans use `HollowTypography.mono` accent).
- `_HelpError` — honest error state + "Try again" (`ref.invalidate(helpManifestProvider)`).

## Content / voice conventions (manifest.json)

- Voice: competent and calm, lightly human, first-person, honest. **No em-dashes** (they read as AI). No personal anecdotes. Tech named AND translated in one breath (e.g. "MLS (RFC 9420, a modern protocol for encrypting large groups)"). Written in Vitalik's voice; he authors/edits the content.
- A lesson = sections on one scroll. Most sections text-only; a few reference `assets/help/media/*` for a small icon/control shot.
- Modules: m0 Welcome, m1 Identity & data, m2 Getting started, m3 Talking to people, m4 Running a server, m5 Storage/vault/data, m6 Living with a serverless network (the honest trade-offs, ends the set on candor).

## Notes

- Adding/editing lessons = edit `assets/help/manifest.json` (+ drop images in `assets/help/media/`) and ship in a release. No CDN, no fetch.
- Superseded earlier centered-course-modal design (`guides_screen.dart`/`lesson_viewer.dart`, both deleted) and a CDN-fetch plan (dropped for bundled assets).
- `recoveryPoolProvider` / vault recovery: a recovery pool reconstructs a DEAD/DISBANDED server's erasure-coded files by pooling ex-members' shards (Archive → Vault Files), NOT personal account recovery. Lesson 1.4 documents this correctly.
