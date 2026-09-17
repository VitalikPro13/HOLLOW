# Hollow Artist Shop, Support Credentials and the Ko-fi Rail

The living record of the shop: what it is, how support credentials work, and how the money rail arrived at Ko-fi. It merges the original design (2026-08-28) with the Ko-fi build plan (2026-09-16), which replaced it wholesale on the money side.

Status, 2026-09-17:

- **Built and deployed.** The app client, `.hollowpack`, blind-signed support credentials and the Twitch credential all shipped. The shop server runs the Ko-fi code model (deployed 2026-09-16, build `01a0ab72`); a live test order is still outstanding.
- **Hidden in the app** since 2026-09-05: `shopAvailableProvider` is the store verdict AND a persisted `shop_unlocked` flag, default off, turned on by an easter egg in Settings. Support marks keep rendering regardless.
- The rail changed twice. Stripe Connect was the 2026-08-28 design; Creem replaced it; Creem rejected the merchant account on 2026-09-03, final, no appeal. Section 6 is what runs now.

Decisions marked LOCKED were made by Vitalik.

## 1. What this is

A storefront where independent artists sell profile art for Hollow (avatars, avatar frames, banners, static and animated), and a buyer can prove "I supported this artist" on their profile without the shop, the relay, or anyone else ever learning which Hollow identity bought what.

It is not a decoration system. Hollow already lets everyone upload their own frames, avatars and animated banners for free, and that stays. The shop sells art, never capability. This keeps HOLLOW_PLAN section 18 intact: nothing that makes Hollow work is behind a paywall.

Three principles, in priority order:

1. **Privacy.** The shop never learns a Hollow identity. The relay never learns about a purchase. A purchase looks, to Hollow, like a file the user imported.
2. **Artists first.** Since 2026-09-14 this is absolute: the artist sells on their own Ko-fi and keeps everything (section 6). The old 95/5 split is gone with the rail it needed.
3. **No DRM.** LOCKED. Buying means you own the files and can use them anywhere. The only thing a copy cannot reproduce is the support credential (section 5), and that is the point of it.

## 2. Precedents

- **itch.io open revenue share.** Creators choose itch's cut, default 10 percent, allowed 0 to 100. The shop ended up further along that line: the artist keeps all of it.
- **Privacy Pass / RFC 9474 (RSA blind signatures).** The issuer signs a message it cannot read; the holder unblinds and gets a normal signature. Used for "prove you are entitled without saying who you are". Section 5 is this applied to purchases.
- **Discord Shop** (the thing to be different from): licensed art sold by the platform, entitlements server-side, nothing owned, nothing goes to independent artists.
- **Hollow multi-device link codes**: a short one-shot bearer code that unlocks something for whoever holds it. The shop's redemption codes are the same idea.

## 3. Roles and flows

### 3.1 Artist

1. Applies with a portfolio. Curation is manual (section 7).
2. **Signs in** to the dashboard with an email code. Hollow holds no banking data and no payout address, because it is never in the payment path.
3. **Connects their Ko-fi** in Settings > Your Ko-fi: paste the verification token from Ko-fi's webhooks page, and the shop shows the per-artist webhook URL to paste back into Ko-fi. Optionally a "forward a copy to" URL, for an artist whose one Ko-fi webhook slot is already taken. The card shows when Ko-fi last reached the shop and what happened (order matched, token mismatch, unknown item), so a test order proves the wiring.
4. **Submits a piece.** Every upload is processed by the **same encoders the app uses** (`image_convert::process_avatar_frame`, `process_user_avatar_anim`, `process_user_banner_anim`, `process_still`), shipped as a small CLI built from `hollow_core`. This is not cosmetic: the credential (section 5) binds the hash of the PROCESSED bytes, and the buyer's client recomputes that hash on import. libwebp is deterministic, so processed-once-on-the-server and processed-again-on-import land on the same hash (the property the animated-avatar migration relies on too).
5. **The keeper approves**: the encoder runs, the pack is built, the issuing key is made, status `approved`.
6. **Puts it on Ko-fi.** The listing card then shows a panel with the title, the description and the price ready to copy, a download of the `.hollowpack` to attach as the Ko-fi item's asset, and one field for the Ko-fi item link (`https://ko-fi.com/s/<code>`). Saving that link is what publishes the listing to the wall. The panel is refused until the Ko-fi token is set, because a sale before that would never reach the shop.
7. **Sales.** Ko-fi pays the artist directly. Sale counts appear on the dashboard. The artist never sees buyers.
8. **Discounts** are the artist's: the sale controls live on the dashboard (price floor $4.99, a sale runs 1 to 30 days) as local writes, and the artist mirrors the number on Ko-fi by hand. The artist agreement makes the two prices equal by rule.

### 3.2 Buyer

1. Browses in Hollow (desktop, or any non-store build; see section 8) or on the website.
2. "Buy" opens the artist's Ko-fi item in a browser tab, labelled with the price the artist declared and the words "on Ko-fi". Payment, receipt and file delivery are Ko-fi's.
3. Within a minute the shop sends one email per order: every item with its title, one `HOLLOW-` code per unit (as text and as a `hollow://redeem/` link), a 30-day pack download link and the item page link. `/thanks` is a plain page saying the code is on its way, usable as the item's optional redirect URL.
4. Imports the pack in Hollow (drag and drop, or the pickers). The art now works exactly like self-made art. This is the end of the mandatory path; everything below is optional.
5. Redeems the code inside Hollow to mint a support credential (section 5). The shop signs blind: it learns that *a* code was burned, never by whom.

### 3.3 Gifting

A gift is just a code you did not redeem yourself.

- Every code is a bearer token, so a gift is a code the buyer passes on instead of redeeming. The giver sends it over a Hollow DM (end-to-end encrypted) or any channel they like, and the recipient redeems it in their own client.
- **Gift button (the nicer flow, same guarantees, designed and not built).** The giver's client can run the redemption *on behalf of* the recipient, because blinding needs only the recipient's master peer id, which is public: build `(recipient_master_id || item_hash)`, blind it with a fresh random factor, redeem the code, unblind, and send the finished credential plus the pack to the recipient over a DM (a dedicated `HavenMessage::SupportGift` carrying the credential JSON; files go over the normal file transfer). The recipient's client verifies the credential, shows "X gifted you <item> by <artist>, accept?", and only on accept stores and publishes it. The credential is bound to the recipient's identity, so it is useless to the giver or anyone in between.
- The blinding factor is ephemeral: whichever client runs a redemption holds it for the seconds between blind and unblind, then discards it. No server holds any blind state, and no server holds credentials at all; they live in the holder's profile and replicate to their own devices through the master-keyed profile sync.
- The shop never sees either identity; the giver never sends anyone's peer id anywhere.
- **Rejected:** a "redeem to peer ID" form on the website. It would hand the store a table of orders (with emails behind them) mapped to Hollow identities, which is exactly the registry Hollow has refused to keep so far. Codes give gifting for free without it.
- Unsolicited "gifts" cannot pin anything on anyone: a credential renders only if the recipient's own client redeems the code and publishes the result.

### 3.4 Supporter subscription

Monthly support of Hollow itself, rendered as a "Supporter" mark. Same credential machinery, one credential per calendar month (section 5.4). Designed, not built, and it now needs a rail of its own, since Hollow takes no money through Ko-fi.

### 3.5 Refunds and chargebacks

Ko-fi sends no refund webhook, and a refund is between the buyer and the artist. A refunded order keeps its code unless the keeper refuses that code on the listing page (per code row, by hash). The art has no DRM anyway, and a credential is cosmetic.

## 4. Privacy model

What each party learns:

| Party | Learns | Never learns |
|---|---|---|
| Ko-fi | the buyer's email, payment instrument, item, price | anything about Hollow |
| Shop server | the scrubbed webhook event (ids, amount, item code, quantity), the buyer's email for exactly one send and then discarded, and that a code was burned at time T | which peer redeemed; the peer ids behind any order; everything the scrubber drops (name, message, url, shipping, discord fields) |
| Relay | nothing new (a credential rides the profile like any other field) | that a purchase happened |
| Viewers of a profile | that this identity holds a valid credential for item X / for month M | the order, the price, the email |

Residual, stated honestly: the shop server sees the **IP address** of the redemption request, as any HTTPS endpoint does. The blind signature prevents the *database* from linking identities to orders; it does not stop a malicious operator who correlates redemption-time IPs with the relay's in-RAM IP-to-peer mapping. Mitigations, in the order they should be applied: the redemption endpoint keeps **no request logs and no IP logs** (the same discipline as the relay, and written into the Privacy Policy); the client may add a random delay of minutes between purchase and redemption; a future option is redeeming over a proxy. This is the same residual the relay itself has, and it is documented rather than hidden.

The downloads come from the website, never through the relay. The credential is the only artifact that touches Hollow, and it carries no order data.

## 5. Support credentials (the core mechanism)

### 5.1 Goal

A viewer of a profile can verify, offline, with one pinned public key, that the identity shown bought item X (or supports Hollow in month M), and the issuer cannot map credentials back to purchases.

### 5.2 Keys

- **Root key:** one Ed25519 keypair, kept offline. Its public key is pinned in the client. It signs *issuing keys*, never credentials.
- **Issuing keys:** one RSA-3072 keypair per item (generated at listing time, about a second each) and one per calendar month for the supporter credential (generated ahead of time). The public halves are published on the website as a signed catalog and are also embedded in every credential, so a viewer never needs to fetch anything to verify.

Why a key per item: RFC 9474 signatures are *fully* blind. If one key signed everything, a $4.99 code could be redeemed into a credential for a $49.99 bundle, because the issuer cannot see which item hash is inside the blinded message. With a key per item, the code selects the key, and the key can only ever produce credentials for that item. (Alternative, if the `blind-rsa-signatures` crate's public-metadata mode is adopted: one key with the item hash as public metadata. Fewer keys, same guarantee. Either works; per-item keys rely on nothing beyond the RFC.)

### 5.3 Message and redemption

Message (byte string, domain separated):

```
"hollow-support-cred/v1" || type:u8 || len(master_peer_id):u16 || master_peer_id || item_hash:32 bytes || period:u32
```

`type` = 1 item, 2 supporter. `item_hash` = SHA-256 of the processed art bytes (zeros for supporter). `period` = months since 2026-01 for supporter (zero for items). `master_peer_id` is the buyer's MASTER identity, never a device id (the profile is master-keyed, credentials sync to siblings with it).

Redemption, inside the client:

1. Build the message with the local master peer id and the item hash from the pack manifest (recomputed from the bytes, never trusted from the manifest).
2. Blind it (RSABSSA-SHA384-PSS-Deterministic, RFC 9474) under the item's issuing public key.
3. `POST /redeem { code, blinded }` to the shop. No auth, no cookies, no identity.
4. The shop checks the code (exists, unburned, maps to this item's key), signs the blinded message with that key, burns the code, returns the blind signature. It stores: code -> burned at time T. Nothing else.
5. The client unblinds, verifies the signature locally against the issuing key, and stores the credential in its own DB under the master identity.

Stealing a credential is useless: it is a signature over *another* peer id, so it fails verification on any other profile.

### 5.4 Supporter credentials

One issuing key per calendar month, published in advance. A subscription issues a **claim secret** once (shown on the order page and in the receipt). Each month the client, holding the claim secret, asks the shop for that month's redemption code, then blind-redeems it exactly as above. The shop links claim secret to subscription (and so to an email); it still never sees the peer. Viewers treat a credential for the current month or the previous one as active ("Supporter"); older ones are simply not rendered. Streaks and "supporter since" are deliberately out of scope for the first version (they would need the issuer to sign something it can see).

### 5.5 What rides the profile

A profile field `support_creds: Option<String>` (JSON array), following the established profile-field rules: absent on the wire means PRESERVE, `""` means clear, `#[serde(default)]` on every persisted struct, receive-side sanitizer as the single validator, and it is NOT part of `profile_signing_payload` (a credential already binds the master peer id itself, so it cannot be transplanted; adding it to the signed payload would break the signature against every shipped client for no gain, the same reasoning as `avatar_frame`).

Each entry is self-contained so viewers verify without any fetch:

```
{ "t": 1, "item": "<64 hex>", "period": 0,
  "key": "<b64 RSA-3072 public key>",
  "key_sig": "<b64 Ed25519 root signature over t || item || period || key>",
  "sig": "<b64 blind signature>" }
```

About 1.2 KB each. Cap: 3 item credentials plus 1 supporter credential inline on the light announce (a few KB, alongside the showcase board). If people want to show more, the array moves to the asset rail as a hash-pulled blob like every other large profile attachment; the inline cap is the first version.

Viewer-side verification, on every profile ingest and again at render:

1. `key_sig` verifies under the pinned root public key.
2. `sig` verifies under `key` over the message rebuilt from THIS profile's master peer id and the entry's item/period.
3. ~~For item credentials, the mark renders only when `item` equals a hash the profile is currently using. A credential for art you are not wearing shows nothing; there is no trophy case in the first version.~~ **AMENDED by Vitalik 2026-09-02 after the first live redeem: the mark is a BADGE and renders whether or not the art is worn** ("to still show that you did buy stuff but just don't wear it right now"). Every credential the profile carries is a mark; the inline cap (3 items + 1 supporter) is what bounds it.

Invalid entries are ignored, never displayed, never an error.

### 5.6 Rendering

Consistent with the frame rules (issue #54): zero layout cost, never on voice or call surfaces. Frames already render on chat rows (animated on row hover), so the marks may too. Two placements, chosen by the holder in Settings:

- **Profile card** (always on): ONE chip for every credential the profile carries (Vitalik 2026-09-02: never one per credential, the card would overfill), in the band under the banner before the Twitch chip. The compact 300 px card shows the icon alone, plus "x2"/"x3" when there is more than one; the full profile spells it out ("Supported <artist>", "Supported <artist> x2", "Supported 3 artists"); the hover lists every piece as "artist: title", the names from the pack manifest when this install imported it, else from the shop's catalog when there is a shop here, else "a piece by the artist". "Supporter" is a second small mark on the card.
- **Next to the name** (ON by default since 2026-09-02, the holder can switch it off): a fixed-size 12 to 14 px glyph after the display name on chat rows and the member list, the way a Twitch sub badge sits next to a chatter. Fixed box, cached, no per-row work beyond painting an icon, so the chat list stays at zero layout cost.

The glyphs themselves need a real design pass driven in the app (`feedback_verify_ui_by_driving`): monochrome, tinted with `accentText`, no colour that competes with roles.

## 6. The Ko-fi rail (LOCKED 2026-09-14, built 2026-09-16)

### 6.1 The model

The artist sells on their **own Ko-fi shop** and keeps 100 percent of what Ko-fi pays out. Hollow takes no cut, holds no payment rail, needs no KYC and has no VAT position. The shop keeps three jobs: the catalog (unchanged), the code (minted on the artist's Ko-fi webhook, mailed to the buyer, burned on redeem) and the badge (the blind-signed credential, unchanged).

There is no split and no percentage anywhere. `hollow_pct` stays in the schema at 0, because shipped migrations are never edited.

### 6.2 Why not the other rails

- **Stripe Connect** was the original design (default 95/5, Hollow as merchant of record, Stripe Tax for VAT). It makes Hollow a marketplace, with KYC, tax registration and payouts to run.
- **Creem** replaced it as a merchant of record and then rejected the account on 2026-09-03, final. Vitalik's reading is their prohibited-list line on marketplaces and merchant-funded payouts, which also rules out the researched alternatives.
- **Crypto** stays out: it does not fit a merchant-of-record tax flow, adds a second money pipeline, and volatility makes artist payouts unpredictable. If ever, a self-hosted BTCPay Server for *donations to Hollow* only, never for artist sales.

Ko-fi sidesteps all of it by keeping Hollow out of the payment path entirely.

### 6.3 Pack format

`.hollowpack` = a zip: `pack.json` (artist, item id, item title, license text, list of files with their expected hashes) plus the processed WebP files at the app's native sizes (frame 128x128, avatar 184 ceiling, banner 600x200 ceiling). The client **hashes the bytes itself**; the manifest's hashes are a convenience for the UI, never trusted. Identity is the hash, exactly like stickers.

## 7. Curation and content policy (LOCKED)

- Artists' own original work only. No third-party IP without written permission on file. Fan art of licensed characters is not sold here (this is what Discord pays licensors for).
- PG-13 in the first version. NSFW comes later and follows the existing NSFW server model (`Atlas.adult_18` marker, opt-in surfaces), designed as its own phase.
- **No AI-generated assets (LOCKED, Vitalik 2026-08-29).** Human-made work only. The artist declares human authorship in the artist agreement; a listing found to be AI-generated is removed and the artist relationship ends. Enforced by the declaration, curation by eye and takedown, never by a detector (they misfire and would accuse real artists).
- Manual approval per item. A takedown process (DMCA-style) with a contact address. Repeat infringement ends the artist relationship.
- Hollow hosts the files and vouches for a listing with a credential, so Hollow answers for what is listed even though the sale happens on Ko-fi. Curation is not optional.

## 8. Mobile store policy (LOCKED direction)

Apple's guideline 3.1.1 requires in-app purchase for digital goods used in the app and bans buttons or links that steer to other purchase mechanisms; it also bans apps unlocking content with their own license keys. Google's Play policy is similar in spirit. The US and EU carve-outs exist and change yearly; the design must not depend on them.

So, for any build distributed through an app store:

- **No shop UI.** No gallery, no prices, no "buy on the website", no redeem dialog. The safest sentence is no sentence.
- **Rendering only.** Credentials and purchased art are ordinary profile data and render everywhere. A credential minted on desktop reaches the phone through the normal master-keyed profile sync, so the phone shows the mark without ever having unlocked anything.
- Sideloaded Android builds and desktop get the full shop: gallery, "Buy" opening the browser, "Redeem code", "Import pack".

This removes the Fortnite shape entirely: nothing is bought or unlocked inside a store build. Since 2026-09-05 the shop is hidden even there, behind the unlock flag described in the status block.

## 9. Components

Shop server (private repo `anonlisten-sites`, under `shop/`):
- Catalog (static, signed by the root key), item pages, artist pages. "Buy" links out to Ko-fi.
- Artist dashboard: email-code login, Ko-fi settings, submit, price and sale controls, the "On Ko-fi" panel, sales.
- `POST /api/kofi/<hook>` (section 10.1), `GET /download/<token>` (the 30-day pack link), `POST /redeem`, the keeper's admin pages.
- Issuing-key management: per-item and per-month RSA keys, catalog signing with the offline root key.

Client:
- Rust: `node/support_creds.rs` (message building, blinding via the `blind-rsa-signatures` crate, verification), the profile field through `storage/messages.rs` (migration + COALESCE preserve), `types.rs` (all three ProfileUpdate variants), `social.rs` sanitizer, FFI `redeem_support_code`, `import_hollowpack`, `list_support_creds`.
- Dart: Shop tab (desktop and sideload only, behind the unlock flag), item page with "Buy" (external browser), "Redeem code" dialog, pack import (drag and drop + picker), credential marks on the profile card, settings row listing held credentials.
- Pinned root public key in the client with a rotation path (a new root signs a statement under the old one).

## 10. The Ko-fi build (2026-09-16)

Built by four Opus agents under Fable, 848 shop tests, driven locally end to end (token, link, fake order, mail, download, lookup, disconnect), then deployed. The app side changed by two strings.

### 10.1 The webhook

`POST /api/kofi/<hook>` where `<hook>` is a 32-byte random secret the shop minted for the artist (base64url, 43 chars). Ko-fi posts `application/x-www-form-urlencoded` with one field `data` holding JSON.

Order of business, and it matters:

1. Content-length cap (64 KB) before the body is read. Missing or oversized: 413.
2. Parse the form, parse `data`. Not JSON: 400.
3. Artist by `HMAC(hook)` (the same host HMAC key that tags email addresses). Unknown: 404, no detail.
4. `verification_token` compared in constant time against the artist's stored `HMAC(token)`. Mismatch: 401, and the artist's card records `token mismatch` so they can see it. A missing token on the artist row is a 401 too; there is no "token not set yet" acceptance, because that would be the bypass.
5. Idempotency: `recordWebhookEvent('kofi:' + message_id, type, scrubbed)`. Seen before: 200 `{duplicate: true}` and nothing else. Scrubbed means `message_id, type, timestamp, kofi_transaction_id, amount, currency, shop_items[{direct_link_code, quantity}]` and NOTHING else. Never email, name, message, url, shipping or discord fields.
6. `type !== 'Shop Order'`: 200 `{outcome: 'not a shop order'}`. The event row is still recorded, so a retry is a duplicate.
7. For each `shop_items[]` entry: `listingByKofiCode(artistId, direct_link_code)`. The listing must belong to THIS artist and be `live` or `paused` (a paused piece can still be bought through a stale Ko-fi page; the buyer paid, so they get their code). Unknown code: noted in the outcome, nothing minted. `quantity` clamped to 1..10.
8. Mint `quantity` codes per matched item, in ONE transaction with `sold += quantity`. Format `HOLLOW-XXXXX-XXXXX-XXXXX-XXXXX`, X from Crockford base32 (no I, L, O, U), 100 bits of entropy from `randomBytes`. Stored as SHA-256 only (`redeem_codes`); the plaintext exists in memory for the length of the mail.
9. Mail the buyer ONE message: every matched item with its title, its codes (each as text and as a `hollow://redeem/` link), its 30-day pack download link, the item page link, and three lines on what to do. The address is used for this send and discarded.
10. If the send fails, the codes stay minted and the whole mail (address plus codes) is sealed under the host AES-GCM key into `order_mail_pending` for a retry. The keeper's overview shows the count with a Send again button; any admin page load retries rows older than five minutes, at most three tries an hour. Ko-fi still gets a 200, because retrying the webhook would re-deliver a duplicate rather than fix the mail.
11. Forward: when the artist set a forward URL, POST the ORIGINAL form body to it after our answer is decided, 10 s timeout, best effort, never awaited by the response. https only, hostname not an IP literal and not localhost.
12. Answer 200 `{received: true, duplicate: false, outcome}`. The outcome names counts, never a person or a code.

The artist's row records `kofi_last_at` and `kofi_last_outcome` (one of `order`, `not a shop order`, `token mismatch`, `unknown item`, `duplicate`) on every delivery, so the Settings card can say "Ko-fi reached the shop at 14:02 (order matched)". Nothing personal in it.

### 10.2 Redeem

`redeem.js` keeps its shape and the audit's M4 order; the rail is gone:

- `gate`: shape, buckets, `isKeyRefused`, `isKeyBurned` (unchanged).
- `resolveListing`: `db.listingIdForCode(sha)` from `redeem_codes` instead of a rail lookup. Unknown: 404 `unknown`.
- `redeemOnce`: sign first in memory (unchanged), then `burnKey` as the ONLY lock (the rail's activation is gone), then `incrementRedeemed`, then the pack token as today.
- Rate buckets unchanged.

`CODE_SHAPE` stays `[A-Za-z0-9_-]{8,128}`; the new code fits it and the app's `valid_redeem_code` gate (`api/shop.rs`) with no app change.

### 10.3 Database, migration 13

```sql
ALTER TABLE artists ADD COLUMN kofi_token_hmac TEXT;
ALTER TABLE artists ADD COLUMN kofi_hook_hmac TEXT;
ALTER TABLE artists ADD COLUMN kofi_hook_enc TEXT;
ALTER TABLE artists ADD COLUMN kofi_forward_url TEXT;
ALTER TABLE artists ADD COLUMN kofi_last_at TEXT;
ALTER TABLE artists ADD COLUMN kofi_last_outcome TEXT;
CREATE UNIQUE INDEX artists_kofi_hook_idx ON artists(kofi_hook_hmac);

ALTER TABLE listings ADD COLUMN kofi_code TEXT;
CREATE UNIQUE INDEX listings_kofi_code_idx ON listings(kofi_code);

CREATE TABLE redeem_codes (
  code_sha256 TEXT PRIMARY KEY,
  listing_id INTEGER NOT NULL REFERENCES listings(id),
  artist_id INTEGER NOT NULL REFERENCES artists(id),
  event_id TEXT NOT NULL,
  minted_at TEXT NOT NULL
);
CREATE INDEX redeem_codes_listing_idx ON redeem_codes(listing_id);
CREATE INDEX redeem_codes_event_idx ON redeem_codes(event_id);

CREATE TABLE order_mail_pending (
  event_id TEXT PRIMARY KEY,
  artist_id INTEGER NOT NULL,
  payload_enc TEXT NOT NULL,
  tries INTEGER NOT NULL DEFAULT 0,
  last_try_at TEXT,
  last_error TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL
);

CREATE TABLE pack_links (
  token_sha256 TEXT PRIMARY KEY,
  listing_id INTEGER NOT NULL REFERENCES listings(id),
  expires_at TEXT NOT NULL
);
```

`keys_burned`, `keys_refused`, `webhook_events` and `redeem_tokens` stay and keep their meaning. `creem_*`, `split_enabled`, `hollow_pct` and `thanks_shown` stay in the schema and are written by nobody; new listings get `hollow_pct = 0`.

`live` means `status = 'live' AND kofi_code IS NOT NULL`. Publishing (artist save of the link, keeper Publish) requires `approved` plus a code; clearing the link drops a live listing back to `approved`.

### 10.4 Module contract

`lib/server/kofi.js` exports `parseKofiBody`, `scrubKofiEvent`, `newHook`, `hookUrl`, `parseKofiItemLink` (accepts `https://ko-fi.com/s/<code>`, `ko-fi.com/s/<code>` or a bare lowercase `[a-z0-9]{4,32}` code), `kofiItemUrl`, `newRedeemCode`, `ingestKofiEvent`, `sendOrderMail`, `retryPendingOrderMail`, `forwardCopy`.

`db.js` gained `artistKofiState`, `setArtistKofiToken`, `setArtistKofiHook`, `clearArtistKofi`, `setArtistKofiForward`, `noteKofiDelivery`, `artistIdByKofiHook`, `artistKofiTokenHmac`, `setListingKofiCode`, `listingByKofiCode`, `mintCodes`, `listingIdForCode`, `codesForListing`, `codeCountsForListing`, the `order_mail_pending` helpers, the `pack_links` helpers, `publishListing` and `unpublishListing`. It lost every Creem-shaped helper (`getListingByProductId`, `incrementSoldByProductId`, `setListingProduct`, `setListingSplit`, `setArtistStore`, `artistCreemEmailEnc`, `setArtistCreemEmailByArtist`, `saleStateBySlug`, `markThanksShown`, `clearSplit`) and `awaiting_invite` from the overview counts.

Deleted with the rail: `rail/`, `buy.js`, `webhooks.js`, `split_check.js`, `sale_sync.js`, `fees.js`, the Creem webhook and split-check routes, the `?/buy` action, the Creem checklist and the product and split buttons, the payout card, the Creem address form, the percentage sliders, the invite mail, `scripts/creem_stub.mjs` and `scripts/replay-webhook.mjs` (replaced by `scripts/kofi_send.mjs`).

Env: the four `CREEM_*` variables are gone; `SHOP_MODE=test|live` replaces the mode (live refuses `SMTP_DEV_SINK`). `ARTIST_EMAIL_HMAC_KEY` and `ARTIST_EMAIL_ENC_KEY` are now ALWAYS required, because the Ko-fi secrets are sealed under them: a shop without them cannot receive an order. `ARTIST_LOGIN_ENABLED` keeps gating only the login door.

### 10.5 Testing

`npm test` covers webhook parse, verify, idempotency and scrub, code minting and format, redeem against `redeem_codes`, item link parsing, settings actions and publish rules. The local drive uses `SMTP_DEV_SINK=mail.jsonl` plus `node scripts/kofi_send.mjs --hook <url> --token <token> --code <kofi item code> [--qty 2]`, with the buyer mail landing in `.data/mail.jsonl` and the code redeemed in the app against the local shop.

## 11. What is left

- A real Ko-fi test order by Vitalik, end to end: buy, read the mail, redeem in the app.
- Legal pages (terms, privacy, refunds, artist terms) rewritten for the Ko-fi roles and passed through Sepia before Vitalik reads them.
- `scripts/probe_scenarios/shop_tab.json` names sample listings the live catalog no longer serves; its two target strings need refreshing.
- The supporter subscription (section 3.4) needs a rail of its own.
- Root key custody: hardware token or an offline machine, and who holds the backup.
- Whether the artist name belongs inside the credential as signed public metadata, so "Supported <artist>" never depends on the viewer holding the pack. It costs the issuer seeing the artist, which it already knows.
- Later: the NSFW phase under the server model, credential collections beyond the inline cap, streaks.
