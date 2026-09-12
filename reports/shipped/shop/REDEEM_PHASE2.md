# Redeem phase 2: support credentials, built 2026-09-02

Fable 5.1, hands on, no agents (Vitalik's call for this unit). Design: `reports/ARTIST_SHOP_DESIGN.md` sections 5, 12.6, 13.23, the audit's M4 gate. Code map: wiki `support_credentials.md`; gates: wiki `security_write_gates.md` section 9; memory `project_support_credentials_phase2`. Both repos UNCOMMITTED, nothing deployed, the live shop untouched.

## What exists now, in the order a buyer meets it

1. The thank-you page's **Redeem in Hollow** button (`hollow://redeem/<code>`) or the Shop tab's new **Redeem a code** button opens the redeem dialog. A code that arrives by link is KEPT first (phase 1's table), so closing the dialog loses nothing; kept codes in Settings > Profile > Art you own now carry a **Redeem** button each.
2. **Look up**: one anonymous call, `POST /api/redeem/lookup {code}`. The dialog shows the title, the artist, the kinds, and the 13.23 warning when this identity already supports the item ("keep the code and gift it instead, or redeem it anyway"). Refused (refunded), burned, unknown and "listed before marks existed" each come back as one sentence; nothing burns.
3. **Redeem**: Rust verifies the shop's key chain against the ROOT KEY PINNED IN THE APP before anything is spent, blinds a message binding OUR MASTER peer id to the item (RFC 9474, RSABSSA-SHA384-PSS-Deterministic, RSA-3072), `POST /api/redeem {code, blinded}`. The shop checks its refused and burned tables, signs the blinded message in memory with the listing's sealed key, activates the Creem key (the second lock), burns it in its own table, and answers with the blind signature and a one-shot pack token. Rust unblinds, verifies the finished entry exactly as any viewer will, stores it (`support_creds_own`), rewrites and announces the profile field, THEN fetches the pack (`GET /api/redeem/pack/<token>`) through the one import door (`import_hollowpack_bytes`). A pack that fails to arrive is a sentence in the outcome, never a lost mark (the Creem email has the same pack).
4. The **Imported** dialog with the Wear buttons, exactly as a hand-imported pack.
5. **The mark**: on the profile card, a "Supported <artist>" chip in the band under the banner, next to the avatar (design 5.6, always on, lit only while the vouched art is worn: frame id, animated avatar or banner hash, or the hash of the still avatar). **Next to the name** (chat rows, member panel, DM list), a 14 px sparkles glyph, OPT-IN through the new "Show the mark next to my name" toggle under Settings > Profile > Support marks, off by default. Zero layout cost: a shrunk box when off.
6. Viewers verify offline: every entry carries the whole chain, the receive-side sanitizer walks it against the pinned root and THIS profile's master id, drops what fails in silence, dedups by item, caps at 3 item + 1 supporter, re-serializes. A transplanted credential (minted for another identity) fails the last link.

## Decisions taken (Vitalik can veto any of them)

1. **Three key tiers, not two.** Design 5.2 said the offline root signs issuing keys; approval is server-side now, so the per-listing key is minted on the host. The root stays OFFLINE by signing ONE shop issuer key (`SUPPORT_ISSUER_SK/PK/SIG` in the host env); the issuer signs each listing's RSA key at approval. The entry carries `issuer` + `issuer_sig` so the app pins only the root. Rotating the issuer never touches the app.
2. **One credential per listing, bundles included.** `item` = SHA-256 over the listing's file hashes sorted ascending as raw bytes; the entry carries `parts`; the mark lights when ANY part is worn. This answers "a bundle credential must vouch for every file" with one entry inside the inline cap.
3. **Two round trips, no auth, no cookies.** Deviation from the brief: the LOOKUP reads the rail (`validateKey`) to find the listing, because a code maps to a product only at Creem; the shop stores no key-to-listing map at purchase (that would be a new fact about a sale). Nothing burns at lookup.
4. **The RSA code is one crate on both sides:** `blind-rsa-signatures = "=0.17.2"` in hollow_core (`node/support_rsa.rs`) and in the `hollowpack` binary through a `#[path]` include (hollow_art 0.3.0: `keygen`, `blind-sign` with the secret on STDIN). Ed25519 stays in Node (`support_keys.js`); dalek's `verify_strict` accepts Node's signatures (proven by the local end-to-end run below, and by the lookup chain the app verified).
5. **Message bytes** exactly as 5.3, pinned by a KAT. Two small deviations from the 5.5 sketch, both deliberate: the issuer's key signature is domain-tagged (`hollow-support-key/v1` before `t||item||period||key`, so one signature can never be presented as another), and keys ride as PKCS#1 DER (422 bytes) rather than SPKI.
6. **Profile field** `support_creds: Option<String>`, every established rule followed (`avatar_anim` was the precedent): absent = preserve, `""` = clear, `#[serde(default)]`, one receive-side validator, rides the light announce and the light loads, NOT in `profile_signing_payload`, replicates to siblings with the profile (harness-proven), in the `.hollow` backup (the backup snapshots the database).
7. **`badge` on the entry** is the holder's next-to-name choice, unsigned, carried through the sanitizer; new credentials inherit the `support_badge` setting.
8. **Redeem dialog** does lookup -> duplicate warning -> redeem -> Imported dialog; the FFI is two calls (`redeem_lookup`, `redeem_code`) so the warning is a real confirmation.
9. **Catalog and approval:** `approveAndList` makes the issuing key as its own step (non-fatal: a host without the issuer lists anyway and the outcome says so; a code redeemed before the key exists answers "no key yet" and is NOT spent); the listing page has a **Support mark** card with "Make the issuing key" / "Sign the key again" (files changed since); `/api/catalog.json` carries `item, parts, key, key_sig, issuer, issuer_sig`; the app reads `item` as `ShopListing.credential_item`.
10. **No per-IP rate limit on the shop.** It is built to never read an IP (README, `ADDRESS_HEADER` never set), so the buckets are per code hash (10 per 15 min) and shop-wide (300 per 15 min), in memory like the login buckets. Guessing a 25-character Creem key is not what they stop; a script turning the shop into a Creem-API cannon is.
11. **A stand-in Creem for local runs:** `CREEM_API_BASE` points the rail elsewhere in TEST mode only (a startup refusal in live). Added for the end-to-end run; the shop tests never needed it.
12. **13.23's cryptographic claim is corrected:** PSS salts every signature, so a second redemption of one item mints DIFFERENT bytes for the same claim. The "no x2" outcome holds anyway: the sanitizer keeps one entry per item.

## Keys and environment

- Root: `C:\Users\Jabun\.hollow-release\support_root.key` (64-hex seed, OFFLINE, signs issuer keys only). Public key pinned: `b4fa9abcc8bd5aebfe5a2cb50eff6faba14dc3524463ebadf6b125e780aebc25` (`rust/hollow_core/src/node/support_creds.rs` `ROOT_PUBLIC_KEY_HEX`, `shop/src/lib/server/support_keys.js`). A unit test proves the constant parses and is not the test root.
- Issuer: `C:\Users\Jabun\.hollow-release\support_issuer.key`. Host env (also in the shop's local `.env` now, documented in `.env.example`):
  - `SUPPORT_ISSUER_SK=<the 64-hex seed: in the shop's local `.env` and in the issuer key file; never in a tracked file>`
  - `SUPPORT_ISSUER_PK=vQeKwGqkERXxIk+GtdHAuatLx6bi74Jc2j2tDTC8J0E=`
  - `SUPPORT_ISSUER_SIG=Mf5VXFU9HCWosXMa3LI/bdI9TTqRptAYeFOfMcuOG/zF1lQRDsNJPxVDlx19ey2PCpfAIK53GobcVaXIGffYCg==`
  - `env.js` verifies the three against the pinned root at startup and refuses a mismatch with one line.
- Minting: `node scripts/support_keys.mjs root --out <file>` / `issuer --root <file> --out <file>` / `show --root <file>`; a file is never overwritten.

## Files changed

**HOLLOW (Rust)**
- NEW `rust/hollow_core/src/node/support_rsa.rs`, `node/support_creds.rs` (messages, entry, `verify_chain`/`verify_entry`, `keep_verified`, `sanitize_incoming_support_creds`, `blind_request`/`finish_request`, test minting under a fixed test root).
- `node/types.rs` (`support_creds` on `NodeCommand::UpdateProfile`, `HavenMessage::ProfileUpdate`, `MessageEnvelope::ProfileUpdate`), `node/social.rs` (own update carries the stored value; `save_incoming_profile` sanitizes; `profile_request_for` sends it), `node/swarm.rs` (4 sites), `node/mod.rs`, `storage/messages.rs` (column + migration, `save_profile` COALESCE, the 4 loads, `support_creds_own` table + methods), `api/storage.rs` (`UserProfile.support_creds`), `api/network.rs` (`update_profile(support_creds)`, `import_hollowpack_bytes`), `api/shop.rs` (`redeem_lookup`, `redeem_code`, `list_own_support_creds`, `support_badge_enabled`, `set_support_badge`, `credential_item` on the catalog, POST + bounded read helpers), `Cargo.toml`/`Cargo.lock` (`blind-rsa-signatures =0.17.2`), `frb_generated.rs` (codegen), `node/test_harness.rs` (4 literal fixes + the replication test, de-slept).
- `rust/hollow_art`: `Cargo.toml` 0.3.0 (+ the crate, `base64`), `src/node/mod.rs` (the include), `src/main.rs` (`keygen`, `blind-sign`, usage).

**HOLLOW (Dart)**
- Codegen: `lib/src/rust/api/{network,shop,storage}.dart`, `frb_generated*.dart`.
- NEW `lib/src/core/providers/support_marks_provider.dart`, `lib/src/ui/components/support_glyph.dart`; rewritten `lib/src/ui/shop/redeem_code_dialog.dart`.
- `providers/profile_provider.dart` (`supportCreds` through `updateMyProfile` and the two copies), `providers/event_provider.dart` (guest copy), `providers/shop_provider.dart` (exports + `ownSupportCredsProvider`, `supportBadgeProvider`), `providers/owned_art_provider.dart` (`digestOfBytes` shared), `ui/shop/shop_dashboard.dart` (Redeem a code), `ui/shop/owned_art_panel.dart` (Redeem per kept code, Support marks section + toggle), `ui/components/profile_card_body.dart` (chips in the corner band), `ui/chat/message_bubble.dart`, `ui/shell/member_panel.dart`, `ui/sidebar/peer_card.dart` (the glyph), 4 test fixtures (`supportCreds: ''`, `credentialItem: ''`).
- NEW `scripts/probe_scenarios/redeem_phase2.json`.
- Wiki: NEW `tools/hollow-memory/wiki/support_credentials.md`; `security_write_gates.md` section 9 (the `support_creds` ingest, the redeem writes, the owed `import_hollowpack` row); `hollowpack.md` (0.3.0).

**anonlisten-sites/shop**
- NEW `src/lib/server/support_keys.js` (+test), `issuing_key.js` (+test), `redeem.js` (+test), `small_body.js` (+test), `src/params/redeemtoken.js`, `src/routes/api/redeem/{lookup/,pack/[token=redeemtoken]/}+server.js` and `api/redeem/+server.js`, `scripts/support_keys.mjs`, `scripts/e2e_redeem_prep.mjs` (local tooling only).
- `db.js` (migration 9: `listings.issuing_pub/issuing_key_sig/issuing_item/issuing_secret_enc`, `redeem_tokens`; `credential` on `PublicListing`, `issuing_item` on `AdminListing`; key + token methods), `env.js` (`supportIssuer`, `creemApiBase`), `app.js` (`getRedeem`, the base override), `approve.js` (the issuing-key step), `packtool.js` (`runToolWithInput`), `routes/api/catalog.json` (`credentialFieldsOf`), `routes/admin/listing/[id]` (load `issuingKey`, action `makeIssuingKey`, the Support mark card), `routes/(shop)/thanks/+page.svelte` (the "what happens now" bullets), `.env.example`, `.env` (the issuer, local).

## Tests run (all output pasted from the runs)

- hollow_core `cargo check` + `cargo clippy --lib`: clean for the new files (the crate's pre-existing unused-import warnings unchanged). hollow_art `cargo clippy --release`: clean after one `never_loop` fix.
- `cargo nextest run --lib support_cred` (10): message KAT, domain separation, item hash, mint-verify-transplant, two redemptions one claim, every chain link, sanitizer (preserve/clear/drop/dedup/cap), encode round trip, pinned root parses, **and the harness test `support_credential_replicates_and_transplant_is_dropped`** (A announces a real entry plus a transplant; B keeps the real one under A's MASTER and re-verifies it offline; A's sibling device holds it; an untouched update preserves; `""` clears). Plus `blind_sign_through_the_hollowpack_binary_round_trips` (blinds in-process, signs through the built `hollowpack.exe`, finalizes, verifies; fails for a wrong master).
- Full suite `cargo nextest run --lib`: **729 run, 728 passed, 1 failed** on the first run: `harness_fixed_sleep_budget_does_not_grow` (my test had 3.7 s of fixed sleeps). De-slept to `wait_until` conditions; rerun of the two: **2 passed**. No other test touched.
- Shop `npx vitest run`: **37 files, 533 tests passed** (35 new: `support_keys` 7, `small_body` 3, `issuing_key` 5, `redeem` 11 covering lookup order, refused before the rail, unknown/rail-down/orphan product, nokey, the chain verifying, the per-code pause, the burn + count + one-shot token + second redeem 409 without a rail call, malformed blinded 400, refunded 403, rail-down-at-activation burns nothing, "limit reached" burns, signer failure spends nothing, token expiry; plus the existing suites untouched). `npm run build`: clean.
- `flutter analyze`: no errors in `lib/` (the pre-existing package and test infos unchanged); the 5 test fixtures updated. Widget tests for the touched files: see below.

## Local end-to-end run, as driven (the real app, the real shop code, a stand-in Creem)

Setup: the shop's dev server on `localhost:3000` with `CREEM_API_BASE=http://localhost:9999` pointing its rail at a 60-line stub (`shop/scripts/creem_stub.mjs`, dev only: one key `E2EAA-BBBBB-CCCCC-DDDDD-EEEEE` for `prod_e2e_frame`, validate answers it, activate burns it once); `scripts/e2e_redeem_prep.mjs 1 prod_e2e_frame` built listing 1's pack from its processed file with the 0.3.0 binary (`--processed`, hash unchanged), linked the product, made and signed the issuing key (`366e7247…3865`). `curl` proved the endpoints first: lookup `ok` with the full chain, an unknown code `404 unknown`, the catalog carrying `item/parts/key/key_sig/issuer/issuer_sig` for that one listing and nothing for the keyless ones. Then `scripts/ui_probe.ps1 -Scenario redeem_phase2` (the real app, debug, `HOLLOW_SHOP_ORIGIN=http://localhost:3000`, a COPY of the real data directory) and `redeem_phase2_marks -ReuseData`. Every step passed on the second attempt (the first stopped at step 29 because `text:` targets are exact; the scenario now names the whole sentence). Screenshots in `build/ui_probe/`, all read:

- `redeem-01-shop`: the Shop tab with the new **Redeem a code** button beside Import a pack.
- `redeem-03-found`: the dialog after Look up: "Sample frame", "by Sample Artist  frame", the one-time sentence about the mark living in the profile, the Redeem button.
- `redeem-04-imported`: after Redeem: the toast "Support mark saved for Sample frame" and the Imported dialog with the frame's preview and **Wear frame**. The stub's log shows the M4 order from the shop's side: validate (lookup), validate (redeem), activate ONCE; the second lookup of the burned code made NO rail call (answered from `keys_burned`).
- `redeem-05-worn`: Wear frame applied; `redeem-06-burned`: the second Look up answers "This code has already been redeemed." in red under the field.
- `redeem-07-settings-marks` / `redeem-08-badge-on`: Settings > Profile: the Sample frame row reads **Worn**, the new **SUPPORT MARKS** section lists "Sample frame  by Sample Artist" with the sparkles glyph, and the toggle "Show the mark next to my name in chats and member lists" flips on (one profile save).
- `redeem-09-chat-row`: after the toggle, the member panel's "AnonListen" row carries the glyph (`expect_count semantics:Supports an artist` = 1). The chat ROW did not on that run: the server chat draws its header in `channel_message_bubble.dart`, not `message_bubble.dart` (the DM bubble); the glyph is now on both, and the marks half was driven a third time (result below).
- `redeem-10-profile-card`: the card with the avatar wearing the frame and, in the band under the banner beside the Twitch chip, the **"Supported Sample Artist"** chip.

Chat row, fourth run (`redeem-09-chat-row.png`, read): both of my message groups in `#general` carry the sparkles glyph right after "AnonListen", and so does the member panel's Owner row; `wait_for semantics:Supports an artist` holds. (The third run counted zero because `-ReuseData` keeps the toggle's state and the scenario's tap flipped it OFF again; the fourth flipped it back. The scenarios now check presence, not a count.) The profile card chip held on every run.

Local state left behind, dev only: the shop's `.data/shop.db` has listing 1 with an issuing key, `creem_product_id = prod_e2e_frame`, its pack under `.data/packs/1/`, one `keys_burned` row and one spent `redeem_tokens` row; the probe's data COPY (`%TEMP%\hollow_ui_probe_data`) holds the credential and the worn frame. The live data directory was never touched.

`flutter test test/` (the whole widget suite): **718 passed**. `dart analyze` on every Dart file touched after the full analyze: no issues.

## Host steps still owed (main's or Vitalik's call; nothing deployed by this unit)

1. Cross-build `hollowpack` 0.3.0 (`cargo zigbuild --release --target x86_64-unknown-linux-musl` in `rust/hollow_art`; `cargo-zigbuild.exe` is under the Python 3.12 Store package's `Scripts` dir) and install it at `~/domains/anonlisten.com/shop/data/bin/hollowpack` (keep 0.2.0 beside it as before).
2. Add the three `SUPPORT_ISSUER_*` lines to the host environment file. Back up the live DB first (`shop.db.pre-credentials`); migration 9 runs itself on the next start.
3. Redeploy the shop (`scripts/make-archive.mjs` + the Hostinger build); smoke `POST /api/redeem/lookup` with a junk code (expect 404 `unknown`) and `/api/catalog.json`.
4. On `/admin/listing/<id>` press **Make the issuing key** for every existing TEST listing (approval does it for new ones).
5. One real redeem from the app against the live shop with a real TEST checkout's key (the `hollow://redeem` link on `/thanks`), then wipe the sample catalog before the first artist as planned.

## Open for Vitalik's eye

- The glyph: `LucideIcons.sparkles` in `accentText`, 12 px in a 14 px box, tooltip "Supports an artist on the Hollow Shop"; the card chip says "Supported <artist>" (or "Supported the artist" when the pack is not in this install's library). A real design pass is expected (5.6 says so).
- The dialog copy, the thanks-page bullets, the Support mark card wording on the listing page, the Support marks section in Settings.
- Decision 1 (the issuer tier), decision 3 (lookup reads the rail), decision 10 (no per-IP buckets).
- A supporter credential (phase 3) will need the monthly key and the claim-secret flow; the message, entry, sanitizer and cap already accept `t = 2`.

## Proposed one-liners for main

- CLAUDE.md, under `.hollowpack` + Shop client: `- **CRITICAL: support credentials (phase 2):** blind-signed (RFC 9474) entries ride the profile as `support_creds`, verified OFFLINE against the ROOT PINNED in `node/support_creds.rs`; `sanitize_incoming_support_creds` is the ONE validator (chain + THIS master); redeem verifies the chain BEFORE spending, stores BEFORE fetching the pack; shop M4 order (refused, burned, sign, activate, burn); one credential per listing (`item` = sha256 of sorted parts). wiki `support_credentials`.`
- MEMORY.md, in "Project strategy & decisions" after the Bundles line: `- [Creds](project_support_credentials_phase2.md)—root PINNED, issuer in env, one per listing, lookup reads the rail, no per-IP; host steps owed`
