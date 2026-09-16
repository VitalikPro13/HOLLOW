# Reports

Design documents, audits and plans, one folder per status and one subfolder per area of the app.

- `planned/` is work that is designed but not built. When it ships, `git mv` it to `shipped/` and fix the references (`grep -r "reports/planned/<name>"` across the repo, `tools/hollow-memory/wiki`, the memory directory and `~/.claude/skills`).
- `shipped/` is work that is built. The document stays as the record of the design and the decisions; the status line at its top says what remains, if anything.
- `reference/` is living material that is regenerated or kept current rather than finished: the feature matrix, the UI navigation map, the harness coverage map, the audio stack parameter extract.

Areas: `multi-device`, `relay-and-sync`, `security`, `performance`, `voice-and-media`, `profile-and-assets`, `shop`, `ui-and-accessibility`, `testing-and-tooling`. Add an area only when two or more documents need it.

## Planned

| Document | Area | What it is |
|---|---|---|
| `planned/relay-and-sync/MULTI_RELAY_CLIENT_PLAN.md` | relay-and-sync | One client holding sockets to several relays, servers and friendships bound to the relay they live on, no relay-to-relay protocol. Designed 2026-09-12. |
| `planned/voice-and-media/MEDIA_VIEWER_ALBUMS_SUBTITLES_PLAN.md` | voice-and-media | True fullscreen on every platform, one media viewer for images and video, Telegram-style albums with a signed album id, and subtitles with a cue editor. Designed 2026-09-14. |
| `planned/ui-and-accessibility/HOLLOW_DESIGN_LANGUAGE_PLAN.md` | ui-and-accessibility | The research digest, the Hollow design language (tokens, components, usage rules, the forbidden tells), its enforcement, and the screen-by-screen redesign program for desktop and mobile. Designed 2026-09-14, starts after the media plan. |

## Shipped

| Document | Area | What it is |
|---|---|---|
| `shipped/multi-device/MULTI_DEVICE_SYNC_PLAN.md` | multi-device | The original epic design (2026-06-09): one master identity, many devices. |
| `shipped/multi-device/MULTI_DEVICE_STEP4_LINK_DESIGN.md` | multi-device | Device linking and snapshot sync design (2026-06-15). |
| `shipped/multi-device/MULTI_DEVICE_IMPLEMENTATION_TRACKER.md` | multi-device | Execution tracker for every step; epic complete 2026-06-20. |
| `shipped/relay-and-sync/LARGE_SERVER_SCALING_2026.md` | relay-and-sync | Why a 50k-member server keeps MLS; tiers 1 to 3 built, tier 4 (relay sharding) is the infra plan. |
| `shipped/relay-and-sync/PENDING_JOINS_ASYNC_FRIENDING.md` | relay-and-sync | Requests that outlive both sessions: async friending and parked server joins (2026-08-27 to 29). |
| `shipped/relay-and-sync/ANTI_CENSORSHIP_TRANSPORT_2026.md` | relay-and-sync | VLESS + REALITY transport decision; desktop shipped 2026-07-05, mobile deferred. |
| `shipped/security/DEPENDENCY_SECURITY_AUDIT_2026-06.md` | security | Crate and package audit against advisories, June 2026. |
| `shipped/security/SECURITY_AUDIT_2026_09.md` | security | Internal white-box audit of the app, relay and shop backend at commit e0be717. |
| `shipped/performance/QA_REPORT.md` | performance | May 2026 five-domain quality audit and the tiered fix list. |
| `shipped/performance/PERFORMANCE_REPORT.md` | performance | Windows GPU and CPU optimisation pass, May 2026. |
| `shipped/performance/backend_report.md` | performance | Rust backend hot-path audit, May 2026 (the `MessageStore::open` finding). |
| `shipped/performance/PERFORMANCE_AUDIT_2026_07.md` | performance | July 2026 audit and the same-day fix pass, with the deviations recorded. |
| `shipped/voice-and-media/MEDIA_FORWARDING_PLAN.md` | voice-and-media | Resolution capping, originator attribution, SFrame packet forwarders; phase 3 built 2026-08-08. |
| `shipped/voice-and-media/FLUTTER_WEBRTC_152_REBASE_SPEC.md` | voice-and-media | The fork rebase from 1.4.1 to 1.5.2 and the three adopt-upstream decisions. |
| `shipped/voice-and-media/CONFERENCES_PLAN.md` | voice-and-media | Zoom-style rooms with a waiting room; admission is the MLS add. |
| `shipped/voice-and-media/linux_reporter_fixes.md` | voice-and-media | Linux call fixes from a reporter's logs, 2026-09-08. |
| `shipped/profile-and-assets/ASSET_RAIL_PLAN.md` | profile-and-assets | Server banners, GIF picker, stickers; all phases done 2026-07-30. |
| `shipped/profile-and-assets/PROFILE_SHOWCASE_BOARD.md` | profile-and-assets | The self-curated showcase board and why there is no rich presence. |
| `shipped/profile-and-assets/GAME_CARD_DIALOG_PLAN.md` | profile-and-assets | The game card, landed minimal after two same-day redesigns. |
| `shipped/shop/ARTIST_SHOP_DESIGN.md` | shop | The artist shop and support credentials, the living design with every locked decision. |
| `shipped/shop/REDEEM_PHASE2.md` | shop | Support credentials redeem flow, built 2026-09-02 (the Creem rail it reads through is gone since 2026-09-16). |
| `planned/shop/KOFI_SHOP_PLAN.md` | shop | The shop on Ko-fi: artists sell on their own Ko-fi, the shop mints codes on the webhook. Built 2026-09-16, awaiting deploy and a live test order. |
| `shipped/ui-and-accessibility/ACCESSIBILITY_IMPLEMENTATION_PLAN.md` | ui-and-accessibility | Reduce motion, contrast, semantics, keyboard focus, larger text; all code phases done. |
| `shipped/ui-and-accessibility/PUSH_NOTIFICATION_UX_PLAN.md` | ui-and-accessibility | Making the push notification fast and correct on first appearance. |
| `shipped/testing-and-tooling/MULTINODE_TEST_HARNESS_HANDOFF.md` | testing-and-tooling | The in-process multi-node harness, rungs 1 to 3 and the ring-2 control plane. |
| `shipped/testing-and-tooling/SONAR_CLEANUP_EPIC.md` | testing-and-tooling | SonarQube Cloud go-live and the backlog close-out, closed 2026-07-15. |

## Reference

| Document | What it is |
|---|---|
| `reference/FEATURE_MATRIX.md` | Every feature, desktop against mobile, the matrix the fleet and UI probes verify against. |
| `reference/UI_NAVIGATION_MAP.md` | Generated by `scripts/ui_nav_map.ps1`; the probe target for every screen. Never hand-edit. |
| `reference/HARNESS_COVERAGE_MAP.md` | What the multi-node harness can and cannot verify, by ring. |
| `reference/audio_stack_properties.txt` | Every parameter of the voice chain, extracted from source for a sound engineer. |
