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
- **The name glyph is ON by default.** `support_badge` absent reads as on (`badge_on`); only an explicit "0" switches it off. `set_support_badge` rewrites the `badge` flag on every own entry and republishes.
- **Dead codes are forgotten at lookup.** `redeem_lookup` calls `forget_redeem_code` when the shop answers burned, refused or unknown (`lookup_status_is_dead`); `nokey`, `paused` and `rail` are not dead. Kept codes are masked in Settings with an eye to reveal.
- **The shop builds a missing pack at redeem** (`redeem.js` `ensurePack`): a listing approved before packs were built at approval (or whose pack left the disk) gets one from its own processed files through the encoder's passthrough, BEFORE anything is spent; failure is quiet (the credential is the deliverable, the pack the courtesy, and the buyer's Creem download carries it too).
- **The shop burns locally ONLY on Creem's measured "Activation limit reached" text.** Any other 4xx from `activateKey` answers `rail_refused` and burns nothing (a burn with no credential handed out would be unrecoverable).
- **Owned means bought.** The Shop tab's Owned chip and the item dialog's hidden Buy follow `ownCredentialItemsProvider` (item hashes this identity holds a credential for) against the catalog's `credential_item`, never the library: a pack can be handed to a friend, a credential cannot. The library only decides Wear it, and only when ONE imported pack covers EVERY file of the listing (a bundle's pack covers its singles; two single packs do not make the set wearable from its card). Beside Wear it, Buy is the outline button.
