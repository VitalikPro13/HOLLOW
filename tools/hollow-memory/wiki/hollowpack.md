# .hollowpack — the artist shop's art container

Built 2026-08-29 for the artist shop (design record: `reports/ARTIST_SHOP_DESIGN.md`; memory `project_hollowpack_format`, `project_artist_shop_design`). Phase 1 = the store sells DRM-free art; phase 2 binds a blind-signed support credential to the art's hash.

## Format (v1)

A ZIP: `pack.json` + `files/<sha256>.webp`. Manifest fields: `format: "hollowpack"`, `version: 1`, `item {id, title, kinds}`, `artist {name, slug, url}`, `license`, `files [{role, path, sha256, bytes, w, h, animated}]`, `ext {}` (reserved for the phase-2 issuing key and catalog signature). Roles (ceilings per the 2026-09-01 encoder bump, memory `project_encoder_ceilings_bump`): `frame` (square, at most 512, animated or still -- a CEILING since the bump, so older exactly-128 packs stay valid), `avatar` (still-only, 512 ceiling), `avatar_anim` + `avatar_still` (the pair `process_user_avatar_anim` returns), `banner` (still-only, 2.5:1, 1200x480 ceiling), `banner_anim` + `banner_still`. Animated vs still is decided from BYTES (`is_animated_image`), never the extension. `item.id` defaults to the first 16 hex of sha256 over the sorted file hashes (content-addressed).

**Identity is the hash of the PROCESSED bytes.** The pack is produced only by the app's own encoders (`process_avatar_frame`, `process_avatar_image`, `process_user_avatar_anim`, `process_banner_image`, `process_user_banner_anim`) so a pack made by the tool and art the app processes itself land on the same hash (libwebp is deterministic). A lossy WebP re-encoded is a different hash, so **the importer never re-encodes**.

## Code

- `rust/hollow_core/src/hollowpack.rs`: format structs (`#[serde(default)]` on every optional field, unknown fields ignored, `format`/`version` checked), `process_source`, `build_pack`, `catalog_entry`, `read_manifest`, `verify_pack` / `verify_pack_file` (the ONE trust boundary; see `security_write_gates.md` §2).
- `rust/hollow_core/src/bin/hollowpack.rs`: the CLI, `pack` / `inspect` / `process`. Cargo feature `packtool` with `required-features`, so cargokit app builds never compile it (`cargo run --features packtool --bin hollowpack -- process --kind frame in.png --out-dir out/`). `--emit-entry` writes the catalog entry JSON the shop ingests.
- FFI `import_hollowpack(path) -> HollowpackImport` and `list_owned_art()` in `api/network.rs`: verify, then store bytes AS-IS on the asset rail (kind `frame` for frames, kind `profile` for every avatar/banner role, stills included) and record `owned_art(hash, role, item_id, title, artist_name, artist_slug, artist_url, license, imported_at)` in `storage/messages.rs`. Importing does NOT wear anything; "wear it" is a later step that reads the still back off the rail and sets the profile the way the pickers do.
- `image_convert::validate_frame_centre` re-applies the see-through-centre gate to already-encoded frame bytes.

## Verification (import and `inspect` are the same call)

Caps first (8 files, 4 MB each, 16 MB total, 20 MB zip, 64 KB manifest; the biggest legal single asset is a 2 MB animated avatar or banner), then per file: recomputed sha256 must match, the WebP must decode, dimensions within the role's ceiling (frame: square and at most 512), animated roles animate and still roles do not, frames pass the centre gate. A manifest that disagrees with the bytes about size, dims or animation is REFUSED, never silently corrected. Nothing is written by a manifest-supplied name. 17 unit tests (`cargo nextest run --lib hollowpack`).

## Not yet built

Dart import UI (drag-drop + pickers), the "wear it" step, the native Shop tab (desktop + sideloaded Android only; store builds show nothing), the `hollow://redeem/<key>` handler and `node/support_creds.rs` (phase 2). The shop server lives in the private `anonlisten-sites` repo (`shop/`).
