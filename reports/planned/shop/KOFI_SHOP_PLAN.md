# Hollow Shop on Ko-fi

Design and build plan, 2026-09-16. Status: BUILT the same day (848 shop tests green, driven locally end to end), NOT YET DEPLOYED; section 10 is what is left. Replaces the Creem merchant-of-record rail with the code model Vitalik chose on 2026-09-14: the artist sells on their own Ko-fi shop and keeps 100 percent, Hollow receives the artist's Ko-fi webhook, mints a one-time code and mails it to the buyer. Hollow takes no money, holds no payment rail, needs no KYC and no VAT position.

Shop code lives in the private `anonlisten-sites` repo under `shop/`. The app side is untouched except for two strings.

## 1. What changes, in one paragraph

Creem created the product, ran the checkout, minted license keys, paid the split and sent refund webhooks. Now the artist does the product and the checkout on Ko-fi, Ko-fi pays the artist directly, and the shop keeps three jobs: the catalog (unchanged), the code (minted by the shop on the artist's Ko-fi webhook, delivered by email, burned on redeem) and the badge (the blind-signed support credential, unchanged). No split, no percentage, no payout address, no rail adapter.

## 2. The artist's journey

1. **Sign in** to the dashboard as today (email code).
2. **Settings > Your Ko-fi.** Paste the verification token from Ko-fi's webhooks page. The shop then shows the webhook URL to paste back into Ko-fi. Optionally a "forward a copy to" URL for an artist whose one Ko-fi webhook slot is already taken. The card shows when Ko-fi last reached the shop and what happened (matched an order, token mismatch, unknown item), so a test order proves the wiring.
3. **Submit a piece** as today, minus the split percentage. Price is the price the artist will put on Ko-fi.
4. **The keeper approves** as today: the encoder runs, the pack is built, the issuing key is made. Status `approved`.
5. **Put it on Ko-fi.** The listing card now shows a panel with the title, the description and the price ready to copy, a download of the `.hollowpack` (the artist uploads it as the Ko-fi item's asset so Ko-fi delivers the files), and one field: paste the Ko-fi item link (`https://ko-fi.com/s/<code>`). Saving it puts the listing on the wall. The panel is refused until Settings > Your Ko-fi is done, because a sale before that would never reach the shop.
6. **Sales.** A buyer presses Buy on Ko-fi on the wall, pays on Ko-fi, Ko-fi delivers the files and posts the order to the shop, the shop mints one code per unit and emails the buyer the code, a `hollow://redeem/` link and a 30-day download link for the pack.
7. **Discounts** are the artist's: the sale controls stay on the dashboard and the artist mirrors the price on Ko-fi by hand. The shop shows what the artist told it and says the charge happens on Ko-fi.

## 3. The buyer's journey

Wall and item page unchanged, except the Buy button is a link that opens the Ko-fi item in a new tab, labelled with the price the artist declared and the words "on Ko-fi". After paying, the buyer gets Ko-fi's own thank-you and receipt (with the files, if the artist attached them) and, within a minute, the shop's email with the code. Redeeming in the app is unchanged: `hollow://redeem/<code>` or the Redeem dialog, lookup then blind-signed redeem, pack download as the courtesy.

`/thanks` becomes a plain page ("Your code is on its way to the email you gave Ko-fi"), usable as the item's optional "redirect buyer to a URL" asset. No signature, no key on it.

## 4. The webhook

`POST /api/kofi/<hook>` where `<hook>` is a 32-byte random secret the shop minted for the artist (base64url, 43 chars). Ko-fi posts `application/x-www-form-urlencoded` with one field `data` holding JSON (sample: `drafts/kofi_example.txt` in the app repo).

Order of business, and it matters:

1. Content-length cap (64 KB) before the body is read. Missing or oversized: 413.
2. Parse the form, parse `data`. Not JSON: 400.
3. Artist by `HMAC(hook)` (the same host HMAC key that tags email addresses). Unknown: 404, no detail.
4. `verification_token` compared in constant time against the artist's stored `HMAC(token)`. Mismatch: 401, and the artist's card records `token mismatch` so they can see it. A missing token on the artist row is a 401 too (there is no "token not set yet" acceptance; that would be the bypass).
5. Idempotency: `recordWebhookEvent('kofi:' + message_id, type, scrubbed)`. Seen before: 200 `{duplicate: true}` and nothing else. Scrubbed means `message_id, type, timestamp, kofi_transaction_id, amount, currency, shop_items[{direct_link_code, quantity}]` and NOTHING else. Never email, name, message, url, shipping, discord fields.
6. `type !== 'Shop Order'`: 200 `{outcome: 'not a shop order'}`. The event row is still recorded (so a retry is a duplicate) but a donation or membership payload is scrubbed to its spine like everything else.
7. For each `shop_items[]` entry: `listingByKofiCode(artistId, direct_link_code)`. The listing must belong to THIS artist and be `live` or `paused` (a paused piece can still be bought through a stale Ko-fi page; the buyer paid, they get their code). Unknown code: noted in the outcome, nothing minted. `quantity` clamped to 1..10.
8. Mint `quantity` codes per matched item, in ONE transaction with `sold += quantity`. Code format: `HOLLOW-XXXXX-XXXXX-XXXXX-XXXXX`, X from Crockford base32 (no I, L, O, U), 100 bits of entropy, from `randomBytes`. Stored as SHA-256 only (`redeem_codes`). The plaintext exists in memory for the length of the mail.
9. Mail the buyer (`email` from the payload) ONE message: every matched item with its title, its codes (each as text and as a `hollow://redeem/` link), its 30-day pack download link, the item page link, and three lines on what to do. The address is used for this send and discarded.
10. If the send fails: the codes stay minted, and the whole mail (address plus codes) is sealed under the host AES-GCM key into `order_mail_pending` for a retry. The keeper's overview shows the count with a Send again button; any admin page load retries rows older than five minutes (best effort, at most three tries an hour). On success the row is deleted. Ko-fi still gets a 200: retrying the webhook would re-deliver a duplicate, not fix the mail.
11. Forward: when the artist set a forward URL, POST the ORIGINAL form body to it after our answer is decided, 10 s timeout, best effort, never awaited by the response. https only, hostname not an IP literal and not localhost.
12. Answer 200 `{received: true, duplicate: false, outcome}`; outcome names counts, never a person or a code.

The artist's row records `kofi_last_at` and `kofi_last_outcome` (one of `order`, `not a shop order`, `token mismatch`, `unknown item`, `duplicate`) on every delivery, so the Settings card can say "Ko-fi reached the shop at 14:02 (order matched)". Nothing personal in it.

Refunds: Ko-fi sends no refund webhook. A refunded order keeps its code unless the keeper refuses it on the listing page (per code row, by hash). The art has no DRM anyway.

## 5. Redeem, adjusted

`redeem.js` keeps its shape and the M4 order; the rail is gone:

- `gate`: shape, buckets, `isKeyRefused`, `isKeyBurned` (unchanged).
- `resolveListing`: `db.listingIdForCode(sha)` from `redeem_codes` instead of `rail.validateKey`. Unknown: 404 `unknown`.
- `redeemOnce`: sign first in memory (unchanged), then `burnKey` is the ONLY lock (the rail's activation is gone), then `incrementRedeemed`, pack token as today.
- Rate buckets unchanged.

`CODE_SHAPE` stays `[A-Za-z0-9_-]{8,128}`; the new code fits it and the app's `valid_redeem_code` gate (`[A-Za-z0-9_-]{8,128}`, `api/shop.rs`) without any app change.

## 6. Database, migration 13

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

`keys_burned`, `keys_refused`, `webhook_events`, `redeem_tokens` stay and keep their meaning. `creem_*`, `split_enabled`, `hollow_pct`, `thanks_shown` stay in the schema (shipped migrations are never edited) and are written by nobody: new listings get `hollow_pct = 0`.

`live` means `status = 'live' AND kofi_code IS NOT NULL`. Publishing (artist save of the link, keeper Publish) requires `approved` plus a code; clearing the link drops a live listing back to `approved`.

## 7. Contract for the coders

DB helpers (db.js), exact names:

- `artistKofiState(artistId) -> { hasToken, hookEnc: string|null, forwardUrl: string|null, lastAt: string|null, lastOutcome: string|null }`
- `setArtistKofiToken(artistId, tokenHmac|null)`, `setArtistKofiHook(artistId, hookHmac, hookEnc)`, `clearArtistKofi(artistId)` (all six columns null), `setArtistKofiForward(artistId, url|null)`, `noteKofiDelivery(artistId, outcome)`
- `artistIdByKofiHook(hookHmac) -> number|null`, `artistKofiTokenHmac(artistId) -> string|null`
- `setListingKofiCode(listingId, code|null) -> boolean` (unique violation = false), `listingByKofiCode(artistId, code) -> AdminListing|null`
- `mintCodes(entries: {codeSha, listingId, artistId, eventId}[])` in one transaction with `sold += n` per listing; `listingIdForCode(codeSha) -> number|null`; `codesForListing(listingId) -> {code_sha256, minted_at, burned: boolean, refused: boolean}[]`; `codeCountsForListing(listingId) -> {minted, burned, refused}`
- `putPendingOrderMail(eventId, artistId, payloadEnc)`, `listPendingOrderMail() -> rows`, `notePendingOrderMailTry(eventId, error)`, `deletePendingOrderMail(eventId)`, `countPendingOrderMail()`
- `putPackLink(tokenSha, listingId, expiresAt)`, `listingForPackLink(tokenSha, nowIso) -> number|null`, `sweepPackLinks(nowIso)`
- `publishListing(listingId) -> boolean` (approved + code -> live), `unpublishListing(listingId)` (live -> approved)
- Removed: `getListingByProductId`, `incrementSoldByProductId`, `setListingProduct`, `setListingSplit`, `setArtistStore`, `artistCreemEmailEnc`, `setArtistCreemEmailByArtist`, `saleStateBySlug`, `markThanksShown`, `clearSplit`, every `creem_*` field on the returned shapes, `awaiting_invite` in the overview counts.

`lib/server/kofi.js` exports: `parseKofiBody(rawForm) -> {ok, event}|{ok:false, status, message}`, `scrubKofiEvent(event)`, `newHook() -> {hook, hookHmac, hookEnc}`, `hookUrl(origin, hook)`, `parseKofiItemLink(text) -> code|null` (accepts `https://ko-fi.com/s/<code>`, `ko-fi.com/s/<code>`, bare code; code = `[a-z0-9]{4,32}` lowercase), `kofiItemUrl(code)`, `newRedeemCode()`, `ingestKofiEvent({db, config, artistId, event, rawBody}) -> {status, body}`, `sendOrderMail`, `retryPendingOrderMail({db, config})`, `forwardCopy(url, rawBody)`.

Routes: `POST /api/kofi/[hook]`, `GET /download/[token]` (the 30-day pack link; `download` attribute, `no-store`).

Env: `CREEM_MODE`, `CREEM_API_KEY`, `CREEM_WEBHOOK_SECRET`, `CREEM_API_BASE` gone. `SHOP_MODE=test|live` replaces the mode (live refuses `SMTP_DEV_SINK`; `hooks.server.js` prints it). `ARTIST_EMAIL_HMAC_KEY` and `ARTIST_EMAIL_ENC_KEY` are ALWAYS required now (the Ko-fi secrets are sealed under them; a shop without them cannot receive an order). `ARTIST_LOGIN_ENABLED` keeps gating only the login door.

`approveAndList` returns `{ ok, listingId, steps, stopped }` (no `splitDone`, no product step). `blockedBecause(listing)`: submitted -> "Approve the submission first."; no `kofi_code` -> "The Ko-fi item link is not set. The artist pastes it on their listings page, or set it below."; else null.

Mail templates (mail.js): `orderMail({items: [{title, url, codes: string[], packUrl}]})` new; `listingStatusMail` copy: `approved` says "put it on Ko-fi" (the panel on the listings page), `live` says "on the wall, sold on your Ko-fi"; `invite` state removed.

## 8. What goes

`rail/` (all three files), `buy.js`, `webhooks.js`, `split_check.js`, `sale_sync.js`, `fees.js`, `routes/api/webhooks/creem`, `routes/api/cron/split-check`, the `?/buy` action, the Creem checklist and product/split buttons on the admin listing page, the payout card on artist settings, the Creem address form on admin artists, the percentage sliders on submit and both bundle makers, the invite mail, `scripts/creem_stub.mjs`, `scripts/replay-webhook.mjs` (replaced by `scripts/kofi_send.mjs`), the Creem branch of `scripts/e2e_redeem_prep.mjs`.

## 9. Testing

- `npm test`: webhook parse/verify/idempotency/scrub, code minting and format, redeem against `redeem_codes`, item link parsing, settings actions, publish rules.
- Local drive: `.env` with `SMTP_DEV_SINK=mail.jsonl`; sign in as a seeded artist, set a token, copy the hook URL; `node scripts/kofi_send.mjs --hook <url> --token <token> --code <kofi item code> [--qty 2]` posts the sample order; the buyer mail lands in `.data/mail.jsonl`; redeem the code in the app against the local shop.
- Live: Vitalik makes a real Ko-fi item at the minimum price, buys it, reads the mail, redeems.

## 10. Deploy

Same pipeline (`npm run archive`, Hostinger deploy). Host `.env`: remove the four `CREEM_*` lines, add `SHOP_MODE=live`. Delete the hPanel cron for `/api/cron/split-check`. Legal pages (terms, privacy, refunds, artist terms) rewritten for the new roles and passed through Sepia before Vitalik reads them.
