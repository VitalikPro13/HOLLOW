# Hollow Artist Shop and Support Credentials

Design document, 2026-08-28. Status: DESIGN, nothing built. Decisions marked LOCKED were made by Vitalik in the 2026-08-28 session; everything else is a proposal.

## 1. What this is

A storefront where independent artists sell profile art for Hollow (avatars, avatar frames, banners, static and animated), Hollow takes a small cut, and a buyer can prove "I supported this artist" on their profile without the shop, the relay, or anyone else ever learning which Hollow identity bought what.

It is not a decoration system. Hollow already lets everyone upload their own frames, avatars and animated banners for free, and that stays. The shop sells art, never capability. This keeps HOLLOW_PLAN section 18 intact: nothing that makes Hollow work is behind a paywall.

Three principles, in priority order:

1. **Privacy.** The shop never learns a Hollow identity. The relay never learns about a purchase. A purchase looks, to Hollow, like a file the user imported.
2. **Artists first.** LOCKED: default split 95/5 (artist/Hollow), artist-adjustable in either direction, applied to net revenue after payment-processor fees and taxes. Per-sale attribution, no pooled revenue (LOCKED: the pool model from the old voice project is dropped).
3. **No DRM.** LOCKED. Buying means you own the files and can use them anywhere. The only thing a copy cannot reproduce is the support credential (section 5), and that is the point of it.

## 2. Precedents

- **itch.io open revenue share.** Creators choose itch's cut, default 10 percent, allowed 0 to 100. Fees are deducted before the share. This is the same model with a more generous default, and it has run for a decade, so the split needs no argument.
- **Privacy Pass / RFC 9474 (RSA blind signatures).** The issuer signs a message it cannot read; the holder unblinds and gets a normal signature. Used for "prove you are entitled without saying who you are". Section 5 is this applied to purchases.
- **Discord Shop** (the thing to be different from): licensed art sold by the platform, entitlements server-side, nothing owned, nothing goes to independent artists.
- **Hollow multi-device link codes**: a short one-shot bearer code that unlocks something for whoever holds it. The shop's redemption codes are the same idea.

## 3. Roles and flows

### 3.1 Artist

1. Applies with a portfolio. Curation is manual (section 7).
2. Onboards through **Stripe Connect Express** (LOCKED: Stripe is the payment rail). Stripe performs KYC, holds payout details, issues tax forms, and pays out. Hollow never holds artist banking data.
3. Uploads items through the artist dashboard on the website. Every upload is processed by the **same encoders the app uses** (`image_convert::process_avatar_frame`, `process_user_avatar_anim`, `process_user_banner_anim`, `process_still`), shipped as a small CLI built from `hollow_core`. This is not cosmetic: the credential (section 5) binds the hash of the PROCESSED bytes, and the buyer's client recomputes that hash on import. libwebp is deterministic, so processed-once-on-the-server and processed-again-on-import land on the same hash (the same property the animated-avatar migration relies on).
4. Sets price (floor: LOCKED $4.99; bundles encouraged, $9.99 and up at the artist's discretion) and split (default 95/5, any value allowed).
5. Sees sales counts and payouts in the dashboard. Never sees buyers.

### 3.2 Buyer

1. Browses in Hollow (desktop, or any non-store build; see section 8) or on the website.
2. "Buy" opens the item page **in the system browser**. Checkout is Stripe Checkout as a guest: email plus payment, no shop account (LOCKED: one-time purchases, no accounts).
3. The order page shows the downloads (a `.hollowpack`, section 6.3) and one **redemption code per item** (plus gift codes if bought as gifts). The same is emailed as the receipt.
4. Imports the pack in Hollow (drag and drop, or the pickers). The art now works exactly like self-made art. This is the end of the mandatory path; everything below is optional.
5. Redeems the code inside Hollow to mint a support credential (section 5). The shop signs blind; it learns that *a* code was redeemed, not by whom.

### 3.3 Gifting

A gift is just a code you did not redeem yourself.

- At checkout, "buy as gift" issues a code that is not tied to the buyer's own redemption. The giver sends it to the recipient over a Hollow DM (end-to-end encrypted) or any channel they like, and the recipient redeems it in their own client.
- **Gift button (the nicer flow, same guarantees).** The giver's client can run the redemption *on behalf of* the recipient, because blinding needs only the recipient's master peer id, which is public: build `(recipient_master_id || item_hash)`, blind it with a fresh random factor, redeem the code, unblind, and send the finished credential plus the pack to the recipient over a DM (a dedicated `HavenMessage::SupportGift` carrying the credential JSON; files go over the normal file transfer). The recipient's client verifies the credential, shows "X gifted you <item> by <artist>, accept?", and only on accept stores and publishes it. The credential is bound to the recipient's identity, so it is useless to the giver or anyone in between. The shop still sees only "a code was redeemed" from the IP that already bought it. The relay sees a DM like any other.
- The blinding factor is ephemeral: whichever client runs a redemption holds it for the seconds between blind and unblind, then discards it. No server holds any blind state, and no server holds credentials at all; they live in the holder's profile and replicate to their own devices through the master-keyed profile sync.
- The shop never sees either identity; the giver never sends anyone's peer ID anywhere.
- **Rejected:** a "redeem to peer ID" form on the website. It would hand the store a table of orders (with emails behind them) mapped to Hollow identities, which is exactly the registry Hollow has refused to keep so far. Codes give gifting for free without it.
- Unsolicited "gifts" cannot pin anything on anyone: a credential renders only if the recipient's own client redeems the code and publishes the result.

### 3.4 Supporter subscription

Monthly support of Hollow itself, rendered as a "Supporter" mark. Same credential machinery, one credential per calendar month (section 5.4). Not part of the first release; designed now so the shop does not have to be reopened for it.

### 3.5 Refunds and chargebacks

- Refund on request while the code is unredeemed (the store can see redeemed-or-not without knowing by whom).
- After redemption, the sale is final; if a chargeback lands anyway, Hollow eats it. A credential is cosmetic; there is no revocation list in the first version, and none is needed for the threat this creates.

## 4. Privacy model

What each party learns:

| Party | Learns | Never learns |
|---|---|---|
| Stripe | email, payment instrument, item, price | anything about Hollow |
| Shop server | order (email, item, codes issued), redemption events (code burned, a blinded blob signed) | which peer redeemed; the peer IDs behind any order |
| Relay | nothing new (a credential rides the profile like any other field) | that a purchase happened |
| Viewers of a profile | that this identity holds a valid credential for item X / for month M | the order, the price, the email |

Residual, stated honestly: the shop server sees the **IP address** of the redemption request, as any HTTPS endpoint does. The blind signature prevents the *database* from linking identities to orders; it does not stop a malicious operator who correlates redemption-time IPs with the relay's in-RAM IP-to-peer mapping. Mitigations, in the order they should be applied: the redemption endpoint keeps **no request logs and no IP logs** (the same discipline as the relay, and written into the Privacy Policy); the client may add a random delay of minutes between purchase and redemption; a future option is redeeming over a proxy. This is the same residual the relay itself has and it is documented rather than hidden.

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
4. The shop checks the code (exists, unredeemed, maps to this item's key), signs the blinded message with that key, burns the code, returns the blind signature. It stores: code -> redeemed at time T. Nothing else.
5. The client unblinds, verifies the signature locally against the issuing key, and stores the credential in its own DB under the master identity.

Stealing a credential is useless: it is a signature over *another* peer id, so it fails verification on any other profile.

### 5.4 Supporter credentials

One issuing key per calendar month, published in advance. A subscription issues a **claim secret** once (shown on the order page and in the receipt). Each month the client, holding the claim secret, asks the shop for that month's redemption code, then blind-redeems it exactly as above. The shop links claim secret to subscription (and so to an email); it still never sees the peer. Viewers treat a credential for the current month or the previous one as active ("Supporter"); older ones are simply not rendered. Streaks and "supporter since" are deliberately out of scope for the first version (they would need the issuer to sign something it can see).

### 5.5 What rides the profile

A new profile field `support_creds: Option<String>` (JSON array), following the established profile-field rules: absent on the wire means PRESERVE, `""` means clear, `#[serde(default)]` on every persisted struct, receive-side sanitizer as the single validator, and it is NOT part of `profile_signing_payload` (a credential already binds the master peer id itself, so it cannot be transplanted; adding it to the signed payload would break the signature against every shipped client for no gain, the same reasoning as `avatar_frame`).

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
3. For item credentials, the mark renders only when `item` equals a hash the profile is currently using (frame, avatar animation, banner animation, or avatar still). A credential for art you are not wearing shows nothing; there is no trophy case in the first version.

Invalid entries are ignored, never displayed, never an error.

### 5.6 Rendering

Consistent with the frame rules (issue #54): zero layout cost, never on voice or call surfaces. Frames already render on chat rows (animated on row hover), so the marks may too. Two placements, chosen by the holder in Settings:

- **Profile card** (always on): a small mark next to the art it vouches for, hover text "Supported <artist>" (the artist name comes from the pack manifest the viewer may not have; fall back to "Supported the artist" when unknown). "Supporter" is a second small mark on the card.
- **Next to the name** (opt-in, off by default): a fixed-size 12 to 14 px glyph after the display name on chat rows and the member list, the way a Twitch sub badge sits next to a chatter. Fixed box, cached, no per-row work beyond painting an icon, so the chat list stays at zero layout cost.

The glyphs themselves need a real design pass driven in the app (`feedback_verify_ui_by_driving`): monochrome, tinted with `accentText`, no colour that competes with roles.

## 6. Money

### 6.1 Rail

LOCKED: **Stripe Connect Express**, Hollow as the platform. Stripe Checkout for buyers (guest). Stripe Tax so VAT and sales tax are charged where the buyer lives (digital goods are taxed at the buyer's location; the EU OSS scheme and equivalents apply). Artists receive transfers to their connected account; Hollow's cut is the application fee.

### 6.2 Split arithmetic (LOCKED)

`net = price - processor fees - taxes collected`; `artist = net * artist_share`; `hollow = net - artist`. Default `artist_share = 0.95`, artist-adjustable from 0 to 1. The dashboard shows the artist the projected payout per sale before they publish.

Price floor $4.99 (LOCKED). At that floor Stripe's fixed fee is about 6 percent of the price, which is why the floor exists; below it, fees eat the artist's share.

### 6.3 Pack format

`.hollowpack` = a zip: `pack.json` (artist, item id, item title, license text, list of files with their expected hashes) plus the processed WebP files at the app's native sizes (frame 128x128, avatar 184 ceiling, banner 600x200 ceiling). The client **hashes the bytes itself**; the manifest's hashes are a convenience for the UI, never trusted. Identity is the hash, exactly like stickers.

### 6.4 Other rails

- PayPal or manual payout for artists who cannot use Stripe in their country: possible later as a monthly manual process; it moves compliance work onto Hollow and is not in the first version.
- Crypto: not in the first version. It does not fit the merchant-of-record tax flow, adds a second money pipeline, and volatility makes artist payouts unpredictable. If ever, a self-hosted BTCPay Server for *donations to Hollow* only, never for artist sales.

## 7. Curation and content policy (LOCKED)

- Artists' own original work only. No third-party IP without written permission on file. Fan art of licensed characters is not sold here (this is what Discord pays licensors for).
- PG-13 in the first version. NSFW comes later and follows the existing NSFW server model (`Atlas.adult_18` marker, opt-in surfaces), designed as its own phase.
- Manual approval per item. A takedown process (DMCA-style) with a contact address. Repeat infringement ends the artist relationship.
- Hollow is the merchant and hosts the files, so Hollow is responsible for what is listed. Curation is not optional.

## 8. Mobile store policy (LOCKED direction)

Apple's guideline 3.1.1 requires in-app purchase for digital goods used in the app and bans buttons or links that steer to other purchase mechanisms; it also bans apps unlocking content with their own license keys. Google's Play policy is similar in spirit. The US and EU carve-outs exist and change yearly; the design must not depend on them.

So, for any build distributed through an app store:

- **No shop UI.** No gallery, no prices, no "buy on the website", no redeem dialog. The safest sentence is no sentence.
- **Rendering only.** Credentials and purchased art are ordinary profile data and render everywhere. A credential minted on desktop reaches the phone through the normal master-keyed profile sync, so the phone shows the mark without ever having unlocked anything.
- Sideloaded Android builds and desktop get the full shop: gallery, "Buy" opening the browser, "Redeem code", "Import pack".

This removes the Fortnite shape entirely: nothing is bought or unlocked inside a store build.

## 9. Components

Website / store (`!hollow-website` or a sibling SvelteKit app):
- Catalog (static, signed by the root key), item pages, artist pages.
- Stripe Checkout, order page with downloads and codes, receipt email.
- Artist dashboard: Connect onboarding, upload (runs the `hollow_core` encoder CLI), price/split, sales.
- Redemption API: `POST /redeem`, `POST /supporter/claim`. No request logging, no IP logging.
- Issuing-key management: per-item and per-month RSA keys, catalog signing with the offline root key.

Client:
- Rust: `node/support_creds.rs` (message building, blinding via the `blind-rsa-signatures` crate, verification), the profile field through `storage/messages.rs` (migration + COALESCE preserve), `types.rs` (all three ProfileUpdate variants), `social.rs` sanitizer, FFI `redeem_support_code`, `import_hollowpack`, `list_support_creds`.
- Dart: Shop tab (desktop and sideload only), item page with "Buy" (external browser), "Redeem code" dialog, pack import (drag and drop + picker), credential marks on the profile card, settings row listing held credentials.
- Pinned root public key in the client with a rotation path (a new root signs a statement under the old one).

## 10. Phasing

1. **Store without credentials.** Catalog, Stripe Connect, checkout, downloads, `.hollowpack` import. Artists get paid; buyers get art. No new wire fields. Proves the money side.
2. **Item credentials.** Issuing keys, redemption API, client redemption, profile field, marks. The first thing a copy cannot reproduce.
3. **Gifting UX and supporter subscription.** Gift codes at checkout, claim secrets, monthly credentials.
4. **Later:** NSFW phase under the server model, PayPal fallback for artists, credential collections beyond the inline cap, streaks.

## 11. Open questions

- Legal entity and merchant of record: Hollow as platform means VAT registration in the EU OSS scheme and equivalents; confirm before phase 1 goes live.
- Root key custody: hardware token or an offline machine; who holds the backup.
- Whether the artist name should be inside the credential (signed public metadata) so "Supported <artist>" never depends on the viewer holding the pack. It costs the issuer seeing the artist, which it already knows, so it is cheap; decide with the metadata-mode question in 5.2.
- Client-side delay before redemption (section 4): default on with a random 1 to 15 minutes, or off with a note.
- Whether store builds should show a neutral "Art from Hollow artists" gallery with no prices at all, or nothing. The design says nothing until a lawyer says otherwise.
