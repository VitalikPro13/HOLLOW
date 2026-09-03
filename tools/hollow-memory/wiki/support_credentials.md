# Support credentials — the artist shop's phase 2

Built 2026-09-02 (design record: `reports/ARTIST_SHOP_DESIGN.md` sections 5, 12.6, 13.23; build notes `reports/REDEEM_PHASE2.md`; memory `project_support_credentials_phase2`). A buyer redeems a Creem license key inside Hollow and gets a **support credential**: a blind signature (RFC 9474, RSABSSA-SHA384-PSS-Deterministic over RSA-3072) over a message binding their MASTER peer id to the item they bought. The shop signs it without seeing the identity; the credential rides the profile as `support_creds`; any viewer verifies it OFFLINE against one root key pinned in the app and lights a mark next to the art it vouches for, while that art is worn.

## The chain (design 5.2, amended for server-side approval)

```
root (Ed25519, OFFLINE; pub pinned in node/support_creds.rs ROOT_PUBLIC_KEY_HEX
      and shop/src/lib/server/support_keys.js)
  signs  issuer  (Ed25519; secret in the shop host's env SUPPORT_ISSUER_SK,
                  pub SUPPORT_ISSUER_PK, root sig SUPPORT_ISSUER_SIG)
  signs  key     (RSA-3072 per LISTING, made at approval by `hollowpack keygen`;
                  secret sealed in listings.issuing_secret_enc, pub in issuing_pub,
                  issuer sig in issuing_key_sig, for issuing_item)
  signs  sig     (blind, over the credential message for THIS profile's master)
```

Every entry carries the whole chain, so a viewer needs nothing but the pinned root. Root keys: `anonlisten-sites/shop/scripts/support_keys.mjs root|issuer|show`; the seeds live OUTSIDE both repos (`C:\Users\Jabun\.hollow-release\support_root.key`, `support_issuer.key`, beside the manifest signing key). Rotating the issuer = a new `issuer` run under the same root and three new env values; the app never changes.

## Messages (byte exact, `node/support_creds.rs` + `support_keys.js`)

- Credential: `"hollow-support-cred/v1" || t:u8 || len(master):u16 BE || master utf8 || item:32 || period:u32 BE`. `t` 1 = item, 2 = supporter (phase 3, not issued yet). Pinned by `credential_message_bytes_are_pinned`.
- Issuer: `"hollow-support-issuer/v1" || issuer_pk:32`, signed by the root.
- Key: `"hollow-support-key/v1" || t || item:32 || period BE || key PKCS#1 DER`, signed by the issuer.
- **`item`** = SHA-256 over the listing's file hashes sorted ascending, concatenated as raw 32-byte values; the entry carries that sorted list as `parts`. ONE credential per listing, bundles included: a viewer recomputes `item` from `parts`; the mark is a BADGE and renders whether or not any of `parts` is worn (Vitalik, 2026-09-02; `parts` still says exactly which bytes were bought).

## The entry (the `support_creds` profile field, JSON array)

`{ t, item (64 hex), period, parts [64 hex], key (b64 PKCS#1 DER), key_sig, issuer (b64 32), issuer_sig, sig (b64 384), badge }`, about 1.4 KB. `badge` is the HOLDER's display choice (mark next to the name), unsigned. Cap: 3 item + 1 supporter entries inline (`MAX_ITEM_CREDS`); extras dropped. Raw field over 16 KB = ABSENT (preserve).

Profile-field rules, all followed (`avatar_anim` is the precedent): wire `Option<String>` with `#[serde(default)]` on `HavenMessage::ProfileUpdate` and `MessageEnvelope::ProfileUpdate` (absent = PRESERVE, `""` = clear), `NodeCommand::UpdateProfile.support_creds`, `StoredProfile.support_creds` (migration `user_profiles.support_creds TEXT NOT NULL DEFAULT ''`, COALESCE in `save_profile`), rides the LIGHT announce and the light loads (renderers need it), **NOT** in `profile_signing_payload` (an entry already binds the master; adding it would break the signature against shipped clients, same reasoning as `avatar_frame`). `UserProfile.support_creds` on the FFI.

## Gates

- **Receive:** `support_creds::sanitize_incoming_support_creds(raw, master)` inside `social::save_incoming_profile` is the ONE validator: every entry verified through the whole chain and the blind signature over the RESOLVED master, invalid ones dropped in silence, deduped by item, capped, and the survivors RE-SERIALIZED so the row holds exactly what verified. Both ingest paths (MLS envelope, plaintext) pass the raw value. A transplanted entry (minted for another identity) fails the last link. `security_write_gates.md` §9.
- **Redeem (client, `api/shop.rs`):** the chain is verified (`verify_chain`) BEFORE the code is spent; after `finish_request` the assembled entry is verified again exactly as a viewer will; the credential is stored (`support_creds_own`) and republished BEFORE the pack is fetched, so a network failure after the burn costs a download (also in the Creem email), never the mark.
- **Shop (`redeem.js`, the audit's M4 gate):** `isKeyRefused`, then `isKeyBurned`, BEFORE `activateKey`; sign in memory first (secret unsealed for one `blind-sign` call, handed on STDIN); `activateKey` (the second lock; "limit reached" burns locally too); `burnKey` (a false = a lost race = 409) + `incrementRedeemed`; then a one-shot pack token. Stores only key SHA-256 + time and token SHA-256 + listing. Rate buckets per code hash (10/15 min) + shop-wide (300/15 min), never per IP (the shop reads none).

## Endpoints (shop, all anonymous, small JSON bodies capped at 8 KB)

- `POST /api/redeem/lookup {code}` → 200 `{status:"ok", listing:{slug,title,url,kinds,artist,item,parts,key,key_sig,issuer,issuer_sig}}` or `{status: refused|burned|unknown|nokey, message}` with 403/409/404/409. Reads the rail (`validateKey`) to find the listing; burns nothing.
- `POST /api/redeem {code, blinded (b64, 384 bytes)}` → 200 `{blind_sig, pack_token, listing:{slug,title}}`, else `{status, message}`.
- `GET /api/redeem/pack/<48 hex>` → the `.hollowpack` once (`content-disposition: attachment`), 404 after.
- `/api/catalog.json` gains per listing `item, parts, key, key_sig, issuer, issuer_sig` once the listing has a key signed for its current files (`credentialFieldsOf`); the app reads `item` as `ShopListing.credential_item`.

## Code map

- Rust: `node/support_rsa.rs` (the ONE RFC 9474 variant + keygen/blind/sign/finalize/verify; `#[path]`-included by `rust/hollow_art` too), `node/support_creds.rs` (messages, entry, `verify_chain`/`verify_entry`, `keep_verified`, sanitizer, `blind_request`/`finish_request`, test minting under a fixed TEST root), `api/shop.rs` (`redeem_lookup`, `redeem_code`, `list_own_support_creds`, `support_badge_enabled`, `set_support_badge`, `credential_item`), `api/network.rs` (`import_hollowpack_bytes`), `storage/messages.rs` (`support_creds` column, `support_creds_own` table). Tests: `cargo nextest run --lib support_cred` (10 incl. the harness replication test and the binary interop test, which skips when `rust/hollow_art/target/release/hollowpack` is not built).
- CLI (`hollowpack` 0.3.0): `keygen` (one JSON line `{secret_b64, public_b64, bits}`), `blind-sign --blinded <b64>` (secret on stdin, prints `{blind_sig_b64}`).
- Shop: `support_keys.js` (Ed25519 + messages + `loadIssuer`), `issuing_key.js` (`ensureIssuingKey` at approval and from the listing page's "Make the issuing key"; `credentialFieldsOf`), `redeem.js` (`createRedeemService`), `small_body.js`, routes under `api/redeem/`, `params/redeemtoken.js`, `db.js` migration 9, `env.js` `supportIssuer`, `app.js` `getRedeem`. Tests: `support_keys`, `issuing_key`, `redeem`, `small_body` (35).
- Dart: `support_marks_provider.dart` (`supportMarksProvider(peerId)` = every credential the profile carries, `supportMarkInfosProvider` = the same with artist and title attached (own redeem records by exact item, then the catalog by exact item, then the library by an exact file set), `supportBadgeVisibleProvider`), `components/support_glyph.dart` (`SupportNameGlyph` on chat rows, member panel, DM list; `SupportMarksChip`, ONE chip per profile in the card's corner band: compact = icon + x2/x3, full = the sentence, hover lists every piece), `shop/redeem_code_dialog.dart` (lookup → duplicate warning → redeem → Imported dialog), Redeem buttons on the Shop tab and on kept codes, "Support marks" section with the badge toggle in `owned_art_panel.dart`.

## Things a maintainer should know

- PSS salts every signature, so two redemptions of one item mint two different byte strings for one claim; the sanitizer keeps one per item (13.23's "x2 cannot exist" holds by dedup, not by byte identity).
- A listing approved before the issuer key was set answers `nokey` at lookup and the code is NOT spent; the keeper presses "Make the issuing key" on the listing page. A re-approval that changes the files leaves the key and re-signs it (`resigned`).
- Store builds render marks (they are profile data) but have no redeem surface: the deep link and the buttons sit behind `shopAvailableProvider`.
- Supporter credentials (t = 2) are phase 3: the message, the entry and the sanitizer already accept them; nothing issues or renders them.

## Amendments after the first live redeem (Vitalik, 2026-09-02)

- **A mark is a badge.** Every credential renders, worn or not; the inline cap (3 + 1) is the only bound. The design's "no trophy case" rule (5.5 rule 3) is gone.
- **One chip per profile**, never one per credential: the compact card would run into the avatar's overhang. Compact = icon alone plus a count; full = "Supported <artist>" / "Supported <artist> x2" / "Supported N artists"; hover lists "artist: title" per piece.
- **The name glyph is ON by default.** `support_badge` absent reads as on (`badge_on`); only an explicit "0" switches it off. Since 2026-09-03 `set_support_badge` only saves the setting and republishes: the `badge` flag is stamped from the setting onto EVERY published entry at publish time (`published_creds_json`), so the toggle works from any linked device.
- **Dead codes are forgotten at lookup.** `redeem_lookup` calls `forget_redeem_code` when the shop answers burned, refused or unknown (`lookup_status_is_dead`); `nokey`, `paused` and `rail` are not dead. Kept codes are masked in Settings with an eye to reveal.
- **The shop builds a missing pack at redeem** (`redeem.js` `ensurePack`): a listing approved before packs were built at approval (or whose pack left the disk) gets one from its own processed files through the encoder's passthrough, BEFORE anything is spent; failure is quiet (the credential is the deliverable, the pack the courtesy, and the buyer's Creem download carries it too).
- **The shop burns locally ONLY on Creem's measured "Activation limit reached" text.** Any other 4xx from `activateKey` answers `rail_refused` and burns nothing (a burn with no credential handed out would be unrecoverable).
- **Owned means bought.** The Shop tab's Owned chip and the item dialog's hidden Buy follow `ownCredentialItemsProvider` (item hashes this identity holds a credential for) against the catalog's `credential_item`, never the library: a pack can be handed to a friend, a credential cannot. The library only decides Wear it, and only when ONE imported pack covers EVERY file of the listing (a bundle's pack covers its singles; two single packs do not make the set wearable from its card). Beside Wear it, Buy is the outline button.

## Holder controls and the sibling union (2026-09-03)

Settings > Profile > Support marks (`_SupportMarksSection` in `owned_art_panel.dart`, shared by the desktop `profile_section.dart` and the mobile settings tab; writes go through `SupportMarksFfi`/`supportMarksFfiProvider` because top-level FFI functions cannot be overridden in Riverpod) carries three controls:

- **The glyph toggle** (above).
- **Hide my support marks** (`support_marks_hidden` / `set_support_marks_hidden`, local setting `support_hidden`, NEVER on the wire). Hidden publishes the explicit clear `""` and writes `""` onto our own profile row, so every receiver drops the entries and a hidden holder is indistinguishable from someone who never bought anything; the `support_creds_own` records are untouched. On the way INTO hiding the current union is saved to the local `support_creds_shelf` setting (only when not already hidden, so a repeated hide cannot flatten it); unhiding publishes table ∪ shelf ∪ row and clears the shelf, so hide and unhide round-trip from a device with an empty table.
- **Remove** per credential (`remove_own_support_cred(item)`, a `.danger` dialog): deletes the table row, appends the item to the local `support_creds_removed` tombstone list (cleared again by a fresh redeem of the same item), republishes. Irreversible: the code is spent, the shop signs no second credential for it; the files stay in the library and Owned leaves the Shop tab.

**The publish rule.** `support_creds_own` is a PER-DEVICE table and does not replicate; before 2026-09-03 every device republished from its own table, so a linked sibling that never redeemed (or redeemed one item) wiped the master's marks for everyone on any toggle or redeem. Now `published_creds_json` publishes `keep_verified(table ∪ shelf ∪ our own profile row)`, deduplicated by item with the table winning, minus tombstones, with the glyph flag stamped from the setting. The row is what a sibling's announce wrote onto this device, so a device that minted nothing still republishes what the master holds; `keep_verified` drops a row entry signed for another master, which keeps a transplanted row harmless. `list_own_support_creds` returns the same union (row-only entries carry no names and `redeemed_at` 0). Residual edge, documented in the code: a mark removed on a device that did not mint it comes back if the minting device republishes later; a replicating table is a later unit. Tests: 17 in `api::shop::tests` (`hidden_marks_publish_a_clear_and_keep_the_records`, `sibling_with_an_empty_table_republishes_the_masters_marks`, `hide_and_unhide_round_trip_from_a_device_with_an_empty_table`, `hiding_twice_keeps_the_shelf`, `remove_from_a_device_that_did_not_mint_it_sticks_on_that_device`, `a_row_entry_for_another_master_never_rides_the_announce`, `badge_setting_applies_to_every_published_entry`, ...), the harness `support_credential_replicates_and_transplant_is_dropped` (proves `""` clears on a peer and the field reaches a sibling), 5 widget tests in `test/widget/support_marks_section_test.dart`.

## The two Twitch types, and the field signature (2026-09-03)

Same chain, same blind signature, a different verifier at the top: instead of a
Creem licence key the shop validates a Twitch OAuth access token and signs what
Twitch itself reported.

- **`T_TWITCH_OWNER = 3`** — "this identity holds this Twitch account".
  `parts = [twitch_user_id, login_lowercase]`,
  `item = SHA-256("hollow-twitch-owner/v1" || 0x00 || user_id || 0x00 || login)`.
  KAT: user_id `12345`, login `somestreamer` ->
  `be924c37092c5b6014256f49f62220f379f7aec5390b587ecc41b8c55d55ab1b`. Cap 1 on
  the profile. The purple chip draws from this and from nothing else.
- **`T_TWITCH_FOLLOW = 4`** — "this identity follows this channel, at least this
  long, at this tier". `parts = [broadcaster_id, age_bucket_days, tier]`,
  `item = SHA-256("hollow-twitch-follow/v1" || 0x00 || broadcaster || 0x00 || bucket || 0x00 || tier)`.
  KATs: `67890`/`30`/`0` -> `a36cd1c6f03bf61bd6d2c522860aeeb037fb9862038713ffb711b1380fca5e2a`;
  `67890`/`365`/`2000` -> `fd9d50532a17342be7e94d6ad75736be284f2200ebcd6c36b86a27ea9a89476b`.
  Buckets `[0,1,3,7,14,30,60,90,180,365]` (the verifier picks the largest at or
  below the real follow age), tiers `"0"`, `"1000"`, `"2000"`, `"3000"`. Cap 0:
  `keep_verified` drops it in BOTH directions, so a follow credential never
  rides a profile. It is presented at join time only.
- **Shapes** are enforced on both sides: a login is `[a-z0-9_]{4,25}` already
  lowercased (one spelling per account), an id is 1..20 decimal digits, a bucket
  and a tier must be on the grid, spelled canonically.
- **`period` means TIME for the first time.** `period = floor(unix / 86400 / 90)`,
  REQUIRED non-zero for `t` 3 and 4, and a verifier accepts `now_period` or
  `now_period - 1` (one window of grace). KAT: unix `1786000000` -> `229`. An
  entry two windows old fails `verify_entry` even though its chain and its
  signature are perfect. `verify_chain_at` / `verify_entry_at` /
  `keep_verified_at` take the window explicitly so a test can stand elsewhere.
- **Shop endpoints** (same origin as redeem, token never stored or logged):
  `POST /api/twitch/key {kind:"owner"|"follow", token, broadcaster_id?}` answers
  `{t, item, parts, period, key, key_sig, issuer, issuer_sig}`;
  `POST /api/twitch/verify {kind, token, broadcaster_id?, item, period, blinded}`
  re-derives the facts from live Twitch and answers `{blind_sig}`, or 409
  `{status:"mismatch"}` when they differ from the request. Status words:
  `token` (401), `not_following` (404), `slow` (429), `rail` (503), `mismatch`
  (409); the app words each one itself.
- **Client:** `api/shop.rs` holds `TwitchVerifier` (two closures, not a trait —
  the bridge would generate a Dart class for a trait), `mint_twitch_credential`
  (chain verified against the PINNED root BEFORE anything is blinded),
  `verify_twitch_owner_with` and `forget_twitch_owner_creds`. `api/twitch.rs`
  holds the token half: `twitch_verify_owner`, `twitch_verify_follow`,
  `twitch_maintain_owner_credential` (silent re-verify at start-up, 24 h
  cooldown, only when the stored entry has slipped out of the current window),
  and `twitch_disconnect`, which drops the credential and republishes BEFORE it
  wipes the token.
- **Hiding** filters by type: "Hide my support marks" hides `t` 1 and 2 only, so
  a verified Twitch account keeps publishing while the shop marks are held back.
  With no Twitch entry the published field is still the bare `""`, so hiding
  stays indistinguishable from never having bought anything.
- **The join gate** is `twitch::validate_follow_credential`, offline against the
  pinned root; the old JSON proof is refused with `OLD_PROOF_SENTENCE`. Because
  the credential names no Twitch account, the `~join` ring copy carries it and
  the rung-1 strip is lifted. See `security_write_gates.md`.
- **Rendering:** `twitchLoginProvider(peerId)` (`support_marks_provider.dart`)
  is the ONE source for the chip on every surface; it reads `parts[1]` off a
  `t = 3` entry and re-checks the window so an expired mark stops showing at
  once rather than at the holder's next announce. `twitch_username` and the
  member-level `TwitchUsernameChanged` op stay on the wire for old clients and
  are rendered by nothing.

## The field signature `support_creds_sig` (2026-09-03)

The hole this closes: `support_creds` is outside `profile_signing_payload`
(each entry binds the identity by itself), which covers forgery and misses
DENIAL — on the plaintext `ProfileUpdate` fallback a relay rewrites the field to
`""` in flight, the profile signature still verifies, and `Some("")` is the
holder's explicit clear on every receiver.

- **Message:** `"hollow-support-creds-sig/v1" || len(peer):u16 BE || master ||
  updated_at:i64 BE || field`, Ed25519 under the MASTER key
  (`support_creds::support_creds_sig_message`,
  `crypto_handler::sign_support_creds` / `verify_support_creds_sig`).
- **Wire:** `support_creds_sig: Option<String>`, `#[serde(default,
  skip_serializing_if = "Option::is_none")]`, on the two structs that carry
  `support_creds` (`HavenMessage::ProfileUpdate` and the MLS `srv_profile`
  `MessageEnvelope::ProfileUpdate`). Sent whenever the field is `Some`,
  including `Some("")`. Verified with the profile's own `profile_pk`, which is
  re-derived to the master.
- **Pin:** `user_profiles.support_creds_signed` (INTEGER, default 0, set only
  forwards, only after a successful save). A valid signature applies the field
  and sets the pin; no valid signature from a PINNED master REJECTS the field
  (treated as absent, preserve, logged once); no valid signature from a master
  that has never signed takes the legacy path, so every shipped client keeps
  working.
- **Freshness:** the field is ignored when the announce's `updated_at` is
  strictly older than the stored row's, signature or not — `save_profile`
  tolerates 24 hours of backdating, so a replayed genuine older announce would
  otherwise clear the marks.
- One function decides all of it: `social::gated_support_creds`, called from
  `save_incoming_profile` ahead of the entry validator.

