//! `.hollowpack`, the artist shop's art container.
//!
//! A pack is a ZIP holding `pack.json` plus processed WebP files, and the files are
//! the SAME bytes the app itself would produce, because Hollow identifies art by the
//! SHA-256 of the PROCESSED bytes and a support credential binds to that hash.
//!
//! Two rules follow and neither is negotiable: the pack TOOL runs the app's own
//! encoders, never a lookalike, and the app's IMPORTER never re-encodes, because a
//! lossy WebP through the encoder twice is a different file with a different hash and
//! would orphan the credential naming the first. So this module owns the format, the
//! encode step and the verification step, and the `hollowpack` CLI and
//! `api::network::import_hollowpack` both call the same `verify_pack`.
//!
//! Everything in a pack is attacker-controlled, so nothing in the manifest is trusted:
//! the hash is RECOMPUTED, the dimensions are re-derived from the decoded image, the
//! entry read is the one the recomputed hash names (a manifest path is never joined
//! onto a directory), and the frame authoring gate is re-applied so a hand-built pack
//! cannot smuggle an opaque frame past the picker.
//!
//! `ext` is reserved for a later phase: no keys and no signatures live here yet.

use std::io::Read;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::node::image_convert;

/// The `format` string every pack carries. Checked on read.
pub const FORMAT: &str = "hollowpack";
/// The format version this build writes, and the newest it will read.
pub const VERSION: u32 = 1;

/// The manifest's name inside the ZIP.
pub const MANIFEST_NAME: &str = "pack.json";

// ── Untrusted-input caps ──────────────────────────────────────────────
//
// An import is a file the user was handed by a website, so every one of these is a
// refusal bound rather than a warning: far above what a real pack needs (2 MB for the
// biggest legal asset) and far below what would hurt.

/// Most files one pack may carry. A listing is at most an avatar pair, a
/// banner pair and a frame; 8 leaves room without leaving room for a dump.
pub const MAX_FILES: usize = 8;
/// Largest single file inside a pack.
pub const MAX_FILE_BYTES: usize = 4 * 1024 * 1024;
/// Largest total of every file inside a pack, decompressed.
pub const MAX_TOTAL_BYTES: usize = 16 * 1024 * 1024;
/// Largest `.hollowpack` container we will even open.
pub const MAX_PACK_BYTES: u64 = 20 * 1024 * 1024;
/// Largest `pack.json`. A manifest is a few hundred bytes of text.
pub const MAX_MANIFEST_BYTES: usize = 64 * 1024;

// ── Roles ─────────────────────────────────────────────────────────────

/// What one file in a pack IS, which decides its encoder, its ceiling and
/// where it lands in the app.
///
/// The animated profile kinds ship as a PAIR: the animation rides the asset rail and
/// the still rides the pushed profile blob, so a pack carrying only the animation
/// would leave old clients and the guest thumb with no face.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Role {
    /// Still avatar, `process_avatar_image` (512 square ceiling).
    Avatar,
    /// Animated avatar, the animated half of `process_user_avatar_anim`.
    AvatarAnim,
    /// The still companion of [`Role::AvatarAnim`].
    AvatarStill,
    /// Still banner, `process_banner_image` (2.5:1, 1200x480 ceiling).
    Banner,
    /// Animated banner, the animated half of `process_user_banner_anim`.
    BannerAnim,
    /// The still companion of [`Role::BannerAnim`].
    BannerStill,
    /// Avatar frame, `process_avatar_frame` (square, at most 512x512, still or
    /// animated). Carries the see-through-centre gate.
    Frame,
}

impl Role {
    /// The wire spelling, which is also the sort key.
    pub fn as_str(self) -> &'static str {
        match self {
            Role::Avatar => "avatar",
            Role::AvatarAnim => "avatar_anim",
            Role::AvatarStill => "avatar_still",
            Role::Banner => "banner",
            Role::BannerAnim => "banner_anim",
            Role::BannerStill => "banner_still",
            Role::Frame => "frame",
        }
    }

    /// Parse a wire role. An unknown role is a refusal, not a skip: a pack whose files
    /// we do not understand is not a pack we can promise anything about.
    pub fn parse(s: &str) -> Result<Role, String> {
        match s {
            "avatar" => Ok(Role::Avatar),
            "avatar_anim" => Ok(Role::AvatarAnim),
            "avatar_still" => Ok(Role::AvatarStill),
            "banner" => Ok(Role::Banner),
            "banner_anim" => Ok(Role::BannerAnim),
            "banner_still" => Ok(Role::BannerStill),
            "frame" => Ok(Role::Frame),
            other => Err(format!("The pack lists a file role this version does not know: {other}")),
        }
    }

    /// The `emote_blobs.kind` the bytes are cached under; a pack never invents a rail.
    pub fn asset_kind(self) -> &'static str {
        match self {
            Role::Frame => "frame",
            _ => "profile",
        }
    }

    /// True when this role's bytes MUST animate. [`Role::Frame`] is absent on
    /// purpose: a frame is legal either way and the bytes decide.
    fn must_animate(self) -> Option<bool> {
        match self {
            Role::AvatarAnim | Role::BannerAnim => Some(true),
            Role::Avatar | Role::AvatarStill | Role::Banner | Role::BannerStill => Some(false),
            Role::Frame => None,
        }
    }
}

/// What the artist tells the tool their source is. The tool decides still versus
/// animated from the BYTES, never from this and never from the file extension: an
/// extension branch silently flattens the APNG that Steam serves animated art as.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RoleHint {
    Frame,
    Avatar,
    Banner,
}

impl RoleHint {
    pub fn as_str(self) -> &'static str {
        match self {
            RoleHint::Frame => "frame",
            RoleHint::Avatar => "avatar",
            RoleHint::Banner => "banner",
        }
    }

    pub fn parse(s: &str) -> Result<RoleHint, String> {
        match s {
            "frame" => Ok(RoleHint::Frame),
            "avatar" => Ok(RoleHint::Avatar),
            "banner" => Ok(RoleHint::Banner),
            other => Err(format!("Unknown kind {other}. Use frame, avatar or banner.")),
        }
    }
}

// ── The manifest ──────────────────────────────────────────────────────

/// `pack.json`. Every optional field defaults, unknown fields are ignored,
/// and `format` plus `version` are checked before anything else is read.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PackManifest {
    #[serde(default)]
    pub format: String,
    #[serde(default)]
    pub version: u32,
    #[serde(default)]
    pub item: PackItemMeta,
    #[serde(default)]
    pub artist: PackArtist,
    #[serde(default)]
    pub license: String,
    #[serde(default)]
    pub files: Vec<PackFile>,
    /// Reserved for phase 2 (issuing key, catalog signature). Carried through
    /// untouched so a pack written by a later tool still reads here.
    #[serde(default)]
    pub ext: serde_json::Value,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PackItemMeta {
    /// 16 hex chars. Content-addressed by default (see [`default_item_id`]).
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub title: String,
    /// The source kinds this listing covers: `frame`, `avatar`, `banner`.
    #[serde(default)]
    pub kinds: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PackArtist {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub slug: String,
    #[serde(default)]
    pub url: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PackFile {
    #[serde(default)]
    pub role: String,
    /// Always `files/<sha256>.webp`. Never joined onto a path on the reading
    /// side: the entry read is the one the RECOMPUTED hash names.
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub sha256: String,
    #[serde(default)]
    pub bytes: u64,
    #[serde(default)]
    pub w: u32,
    #[serde(default)]
    pub h: u32,
    #[serde(default)]
    pub animated: bool,
}

// ── Encoding (the tool side) ──────────────────────────────────────────

/// One processed file, straight out of the app's own encoder.
#[derive(Debug, Clone)]
pub struct ProcessedFile {
    pub role: Role,
    pub bytes: Vec<u8>,
    /// SHA-256 of `bytes`, hex. This IS the art's identity.
    pub hash: String,
    pub w: u32,
    pub h: u32,
    pub animated: bool,
}

impl ProcessedFile {
    /// The entry name this file takes inside the ZIP.
    pub fn zip_path(&self) -> String {
        format!("files/{}.webp", self.hash)
    }
}

/// SHA-256 of `bytes`, lowercase hex.
pub fn hash_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

/// Run the app's encoder for `hint` over a raw source and return every file the app
/// would have produced.
///
/// Animation is decided from the BYTES, so an APNG or animated WebP takes the
/// animated path exactly as a GIF does, and an animated avatar or banner yields the
/// `(animated, still)` PAIR both halves of the rendering need.
pub fn process_source(hint: RoleHint, raw: &[u8]) -> Result<Vec<ProcessedFile>, String> {
    let animated = image_convert::is_animated_image(raw);
    let out = match (hint, animated) {
        (RoleHint::Frame, _) => {
            // The frame encoder branches on the bytes itself and reports what
            // it produced, so there is nothing to decide here.
            let (bytes, _anim) = image_convert::process_avatar_frame(raw)?;
            vec![(Role::Frame, bytes)]
        }
        (RoleHint::Avatar, false) => {
            vec![(Role::Avatar, image_convert::process_avatar_image(raw)?)]
        }
        (RoleHint::Avatar, true) => {
            let (anim, still) = image_convert::process_user_avatar_anim(raw)?;
            vec![(Role::AvatarAnim, anim), (Role::AvatarStill, still)]
        }
        (RoleHint::Banner, false) => {
            vec![(Role::Banner, image_convert::process_banner_image(raw)?)]
        }
        (RoleHint::Banner, true) => {
            let (anim, still) = image_convert::process_user_banner_anim(raw)?;
            vec![(Role::BannerAnim, anim), (Role::BannerStill, still)]
        }
    };

    out.into_iter()
        .map(|(role, bytes)| {
            let (w, h, animated) = blob_shape(&bytes)?;
            Ok(ProcessedFile {
                role,
                hash: hash_hex(&bytes),
                bytes,
                w,
                h,
                animated,
            })
        })
        .collect()
}

/// An already-processed file, taken AS-IS: checked against its role's ceiling, its
/// animation expectation and (for a frame) the see-through-centre gate, hashed, and
/// never re-encoded.
///
/// A bundle is a pack whose files were processed for OTHER packs, and its buyer has to
/// own the same hash as the buyer of the single item, so the bytes are carried through
/// untouched. These are exactly the checks [`verify_pack`] runs, by calling this.
pub fn processed_from_bytes(role: Role, bytes: Vec<u8>) -> Result<ProcessedFile, String> {
    // Bounded before anything decodes it: the caller may be handing us a file
    // off disk that nothing in this process produced.
    if bytes.len() > MAX_FILE_BYTES {
        return Err(format!(
            "The {} file in this pack is over the {} MB limit",
            role.as_str(),
            MAX_FILE_BYTES / (1024 * 1024)
        ));
    }
    let (w, h, animated) = blob_shape(&bytes)?;
    check_role_shape(role, w, h, animated)?;
    if role == Role::Frame {
        image_convert::validate_frame_centre(&bytes)?;
    }
    Ok(ProcessedFile {
        role,
        hash: hash_hex(&bytes),
        bytes,
        w,
        h,
        animated,
    })
}

/// The default `item.id`: the first 16 hex characters of the SHA-256 over every file
/// hash, sorted and newline-joined. Content-addressed on purpose, so the same art
/// re-packed on another machine is recognisably the same listing.
pub fn default_item_id(files: &[ProcessedFile]) -> String {
    let mut hashes: Vec<&str> = files.iter().map(|f| f.hash.as_str()).collect();
    hashes.sort_unstable();
    let joined = hashes.join("\n");
    hash_hex(joined.as_bytes())[..16].to_string()
}

/// Everything the tool needs to write a pack.
#[derive(Debug, Clone, Default)]
pub struct PackInput {
    pub title: String,
    pub artist_name: String,
    pub artist_slug: String,
    pub artist_url: String,
    pub license: String,
    /// `None` = content-address it (see [`default_item_id`]).
    pub item_id: Option<String>,
    /// Source kinds, in the order the artist passed them.
    pub kinds: Vec<String>,
    pub files: Vec<ProcessedFile>,
}

/// Build the `.hollowpack` bytes plus the manifest that went into them.
///
/// Files are ordered by role then hash, so the same inputs always produce the
/// same manifest regardless of the order they were passed on the command line.
pub fn build_pack(input: &PackInput) -> Result<(Vec<u8>, PackManifest), String> {
    use std::io::Write;

    if input.files.is_empty() {
        return Err("A pack needs at least one file".into());
    }
    if input.files.len() > MAX_FILES {
        return Err(format!("A pack carries at most {MAX_FILES} files"));
    }

    let mut files = input.files.clone();
    files.sort_by(|a, b| {
        a.role
            .as_str()
            .cmp(b.role.as_str())
            .then_with(|| a.hash.cmp(&b.hash))
    });

    // Two files with the same bytes would collide on one ZIP entry and leave
    // the manifest describing an entry that is not there twice.
    for pair in files.windows(2) {
        if pair[0].hash == pair[1].hash {
            return Err(format!(
                "Two files in this pack are byte identical ({}). Each file has to be distinct art.",
                pair[0].hash
            ));
        }
    }

    // An authoring rule, deliberately NOT a verification rule, so packs already in the
    // world keep verifying. A role is a SLOT in the app, so two files in one slot would
    // leave the importer picking.
    for pair in files.windows(2) {
        if pair[0].role == pair[1].role {
            return Err(format!(
                "A pack carries one file per role, and two {} files were given. Two avatars are two packs, not one.",
                pair[0].role.as_str()
            ));
        }
    }

    let mut kinds = input.kinds.clone();
    kinds.dedup();

    let manifest = PackManifest {
        format: FORMAT.to_string(),
        version: VERSION,
        item: PackItemMeta {
            id: match &input.item_id {
                Some(id) => id.clone(),
                None => default_item_id(&files),
            },
            title: input.title.clone(),
            kinds,
        },
        artist: PackArtist {
            name: input.artist_name.clone(),
            slug: input.artist_slug.clone(),
            url: input.artist_url.clone(),
        },
        license: input.license.clone(),
        files: files
            .iter()
            .map(|f| PackFile {
                role: f.role.as_str().to_string(),
                path: f.zip_path(),
                sha256: f.hash.clone(),
                bytes: f.bytes.len() as u64,
                w: f.w,
                h: f.h,
                animated: f.animated,
            })
            .collect(),
        ext: serde_json::json!({}),
    };

    let manifest_json = serde_json::to_vec_pretty(&manifest)
        .map_err(|e| format!("Failed to write the manifest: {e}"))?;

    let mut buf = Vec::new();
    {
        let mut zip = zip::ZipWriter::new(std::io::Cursor::new(&mut buf));
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        zip.start_file(MANIFEST_NAME, options)
            .map_err(|e| format!("Failed to start the manifest entry: {e}"))?;
        zip.write_all(&manifest_json)
            .map_err(|e| format!("Failed to write the manifest: {e}"))?;
        for f in &files {
            zip.start_file(f.zip_path(), options)
                .map_err(|e| format!("Failed to start a file entry: {e}"))?;
            zip.write_all(&f.bytes)
                .map_err(|e| format!("Failed to write a file entry: {e}"))?;
        }
        zip.finish()
            .map_err(|e| format!("Failed to finish the pack: {e}"))?;
    }

    Ok((buf, manifest))
}

/// The catalog entry the website ingests: the same item, artist and file
/// facts as the manifest, without the container.
pub fn catalog_entry(manifest: &PackManifest) -> serde_json::Value {
    serde_json::json!({
        "format": FORMAT,
        "version": VERSION,
        "item": manifest.item,
        "artist": manifest.artist,
        "license": manifest.license,
        "files": manifest.files.iter().map(|f| serde_json::json!({
            "role": f.role,
            "sha256": f.sha256,
            "bytes": f.bytes,
            "w": f.w,
            "h": f.h,
            "animated": f.animated,
        })).collect::<Vec<_>>(),
    })
}

// ── Verification (the importer side, and `inspect`) ───────────────────

/// One file that survived [`verify_pack`], with the values RECOMPUTED from
/// the bytes rather than read out of the manifest.
#[derive(Debug, Clone)]
pub struct VerifiedFile {
    pub role: Role,
    pub hash: String,
    pub bytes: Vec<u8>,
    pub w: u32,
    pub h: u32,
    pub animated: bool,
}

/// A pack that verified whole. Partial success does not exist here: a pack
/// with one bad file is refused entirely, because the credential in phase 2
/// binds the ITEM and half an item is not the thing that was bought.
#[derive(Debug, Clone)]
pub struct VerifiedPack {
    pub manifest: PackManifest,
    pub files: Vec<VerifiedFile>,
}

/// Read `pack.json` out of a pack without touching a single art byte.
pub fn read_manifest(zip_bytes: &[u8]) -> Result<PackManifest, String> {
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(zip_bytes))
        .map_err(|e| format!("That file is not a valid art pack: {e}"))?;
    read_manifest_from(&mut archive)
}

fn read_manifest_from<R: Read + std::io::Seek>(
    archive: &mut zip::ZipArchive<R>,
) -> Result<PackManifest, String> {
    let entry = archive
        .by_name(MANIFEST_NAME)
        .map_err(|_| "The pack is missing its manifest".to_string())?;
    if entry.size() > MAX_MANIFEST_BYTES as u64 {
        return Err("The pack manifest is too large to be real".into());
    }
    let mut raw = String::new();
    entry
        .take(MAX_MANIFEST_BYTES as u64 + 1)
        .read_to_string(&mut raw)
        .map_err(|e| format!("Failed to read the pack manifest: {e}"))?;
    if raw.len() > MAX_MANIFEST_BYTES {
        return Err("The pack manifest is too large to be real".into());
    }

    let manifest: PackManifest = serde_json::from_str(&raw)
        .map_err(|e| format!("Failed to parse the pack manifest: {e}"))?;
    if manifest.format != FORMAT {
        return Err("That file is not a Hollow art pack".into());
    }
    if manifest.version == 0 || manifest.version > VERSION {
        return Err("That pack was made by a newer version of Hollow".into());
    }
    Ok(manifest)
}

/// Read a pack from disk and verify it whole. Bounded before it is opened,
/// so a huge file is refused rather than read.
pub fn verify_pack_file(path: &str) -> Result<VerifiedPack, String> {
    let meta = std::fs::metadata(path).map_err(|e| format!("Failed to open the pack: {e}"))?;
    if meta.len() > MAX_PACK_BYTES {
        return Err(format!(
            "That pack is too large to open (over {} MB)",
            MAX_PACK_BYTES / (1024 * 1024)
        ));
    }
    let bytes = std::fs::read(path).map_err(|e| format!("Failed to read the pack: {e}"))?;
    verify_pack(&bytes)
}

/// THE trust boundary for pack bytes: `hollowpack inspect` and the app's importer both
/// call this and nothing else, so the tool checks exactly what the app checks.
///
/// For every file the entry is the one the manifest's hash NAMES (never a path from
/// the manifest), it is read under the per-file and total caps, the SHA-256 is
/// RECOMPUTED and must match, the WebP is decoded so dimensions and the animation
/// flag come from the pixels, the role's ceiling is enforced, and a frame has the
/// see-through-centre gate re-applied. Nothing is written anywhere.
pub fn verify_pack(zip_bytes: &[u8]) -> Result<VerifiedPack, String> {
    if zip_bytes.len() as u64 > MAX_PACK_BYTES {
        return Err(format!(
            "That pack is too large to open (over {} MB)",
            MAX_PACK_BYTES / (1024 * 1024)
        ));
    }
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(zip_bytes))
        .map_err(|e| format!("That file is not a valid art pack: {e}"))?;
    let manifest = read_manifest_from(&mut archive)?;

    if manifest.files.is_empty() {
        return Err("The pack carries no files".into());
    }
    if manifest.files.len() > MAX_FILES {
        return Err(format!(
            "The pack lists {} files, and a pack carries at most {MAX_FILES}",
            manifest.files.len()
        ));
    }

    let mut files: Vec<VerifiedFile> = Vec::with_capacity(manifest.files.len());
    let mut total: usize = 0;

    for entry in &manifest.files {
        let role = Role::parse(&entry.role)?;

        if !is_hash_hex(&entry.sha256) {
            return Err("The pack names a file with a malformed hash".into());
        }
        // The hash names the entry, so an attacker-supplied path is never used for
        // anything and there is no traversal surface at all.
        let name = format!("files/{}.webp", entry.sha256);
        if !entry.path.is_empty() && entry.path != name {
            return Err(format!(
                "The pack lists {} at a path that does not match its hash",
                entry.role
            ));
        }
        if files.iter().any(|f| f.hash == entry.sha256) {
            return Err("The pack lists the same file twice".into());
        }

        let bytes = {
            let zf = archive
                .by_name(&name)
                .map_err(|_| format!("The pack is missing the file it lists as {}", entry.role))?;
            if zf.size() > MAX_FILE_BYTES as u64 {
                return Err(format!(
                    "The {} file in this pack is over the {} MB limit",
                    entry.role,
                    MAX_FILE_BYTES / (1024 * 1024)
                ));
            }
            let mut buf = Vec::new();
            zf.take(MAX_FILE_BYTES as u64 + 1)
                .read_to_end(&mut buf)
                .map_err(|e| format!("Failed to read the {} file: {e}", entry.role))?;
            buf
        };
        if bytes.len() > MAX_FILE_BYTES {
            return Err(format!(
                "The {} file in this pack is over the {} MB limit",
                entry.role,
                MAX_FILE_BYTES / (1024 * 1024)
            ));
        }
        total = total.saturating_add(bytes.len());
        if total > MAX_TOTAL_BYTES {
            return Err(format!(
                "The pack holds more than {} MB of art",
                MAX_TOTAL_BYTES / (1024 * 1024)
            ));
        }

        // The bytes ARE the identity, so this is the check the whole format
        // rests on. A mismatch refuses the pack, never just the file.
        let actual = hash_hex(&bytes);
        if actual != entry.sha256 {
            return Err(format!(
                "The {} file does not match the hash the pack claims for it",
                entry.role
            ));
        }
        if entry.bytes != 0 && entry.bytes != bytes.len() as u64 {
            return Err(format!(
                "The {} file is not the size the pack claims for it",
                entry.role
            ));
        }

        // The decode, the ceiling and the frame gate are ONE body shared with the bundle
        // maker, so already-processed art is checked exactly as art inside a pack is.
        let file = processed_from_bytes(role, bytes)?;
        if (entry.w != 0 || entry.h != 0) && (entry.w != file.w || entry.h != file.h) {
            return Err(format!(
                "The {} file is {}x{}, not the size the pack claims for it",
                entry.role, file.w, file.h
            ));
        }
        if entry.animated != file.animated {
            return Err(format!(
                "The pack is wrong about whether its {} file animates",
                entry.role
            ));
        }

        files.push(VerifiedFile {
            role: file.role,
            hash: actual,
            bytes: file.bytes,
            w: file.w,
            h: file.h,
            animated: file.animated,
        });
    }

    Ok(VerifiedPack { manifest, files })
}

/// 64 lowercase hex characters, the shape every content address in Hollow
/// takes.
fn is_hash_hex(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// `(width, height, animated)` of an encoded blob, read from the PIXELS. Everything a
/// pack may carry is a WebP, so a GIF or APNG smuggled in under a WebP role is refused
/// here rather than decoded.
fn blob_shape(data: &[u8]) -> Result<(u32, u32, bool), String> {
    if data.len() < 16 || &data[0..4] != b"RIFF" || &data[8..12] != b"WEBP" {
        return Err("A file in this pack is not a WebP image".into());
    }
    // SHOP-2: the ceiling used to be checked on the DECODED image, so a file under the
    // byte cap declaring a 16384x16384 canvas cost about a gigabyte of RGBA before
    // anyone said no. Read the canvas out of the header and refuse it undecoded.
    let (hdr_w, hdr_h) = image_convert::webp_header_dimensions(data)
        .ok_or("A file in this pack has an unreadable WebP header")?;
    if hdr_w > image_convert::MAX_DECODE_DIM || hdr_h > image_convert::MAX_DECODE_DIM {
        return Err("A file in this pack is too large to decode safely".into());
    }
    if image_convert::is_animated_webp(data) {
        let decoder = webp_animation::Decoder::new(data)
            .map_err(|e| format!("Failed to decode an animated file in this pack: {e}"))?;
        let first = decoder
            .into_iter()
            .next()
            .ok_or("An animated file in this pack has no frames")?;
        let (w, h) = first.dimensions();
        if w == 0 || h == 0 {
            return Err("A file in this pack has zero dimensions".into());
        }
        return Ok((w, h, true));
    }
    let (w, h) = image_convert::get_image_dimensions(data)
        .map_err(|e| format!("Failed to decode a file in this pack: {e}"))?;
    if w == 0 || h == 0 {
        return Err("A file in this pack has zero dimensions".into());
    }
    Ok((w, h, false))
}

/// The role's ceiling and animation expectation, re-checked against what the pixels
/// actually are. These are the bounds the encoders produce, so anything that fails
/// was not built by the tool.
fn check_role_shape(role: Role, w: u32, h: u32, animated: bool) -> Result<(), String> {
    if let Some(expected) = role.must_animate()
        && animated != expected
    {
        return Err(if expected {
            format!("The {} file in this pack does not animate", role.as_str())
        } else {
            format!("The {} file in this pack has to be a still", role.as_str())
        });
    }
    match role {
        // A ceiling, not an exact size, which is what keeps every 128x128 frame and every
        // pack built before the ceiling moved valid by construction.
        Role::Frame => {
            if w != h {
                return Err("The frame file has to be square".into());
            }
            if w > image_convert::FRAME_DIM {
                return Err(format!(
                    "The frame file is {w}x{h}, over the {}px frame ceiling",
                    image_convert::FRAME_DIM
                ));
            }
        }
        Role::Avatar | Role::AvatarAnim | Role::AvatarStill => {
            if w != h {
                return Err(format!("The {} file has to be square", role.as_str()));
            }
            if w > image_convert::AVATAR_DIM {
                return Err(format!(
                    "The {} file is {w}x{h}, over the {}px avatar ceiling",
                    role.as_str(),
                    image_convert::AVATAR_DIM
                ));
            }
        }
        Role::Banner | Role::BannerAnim | Role::BannerStill => {
            let max_h = image_convert::BANNER_H;
            if w > image_convert::BANNER_W || h > max_h {
                return Err(format!(
                    "The {} file is {w}x{h}, over the {}x{max_h} banner ceiling",
                    role.as_str(),
                    image_convert::BANNER_W
                ));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── Fixtures, built in memory ─────────────────────────────────────
    //
    // Never committed binaries: a fixture that cannot animate cannot catch an encoder
    // that flattens animation, and one nobody can read cannot be adjusted.

    /// A ring: opaque at the edges, fully transparent through the middle.
    /// This is what a legal avatar frame looks like.
    pub(super) fn ring_png(size: u32) -> Vec<u8> {
        let mut img = image::RgbaImage::new(size, size);
        let c = size as f32 / 2.0;
        let inner = size as f32 * 0.34;
        for (x, y, px) in img.enumerate_pixels_mut() {
            let dx = x as f32 + 0.5 - c;
            let dy = y as f32 + 0.5 - c;
            let d = (dx * dx + dy * dy).sqrt();
            *px = if d > inner {
                image::Rgba([200, 60, 90, 255])
            } else {
                image::Rgba([0, 0, 0, 0])
            };
        }
        encode_png(&img)
    }

    /// A solid square. Legal as an avatar, and refused as a frame.
    pub(super) fn solid_png(w: u32, h: u32) -> Vec<u8> {
        let mut img = image::RgbaImage::new(w, h);
        for (x, y, px) in img.enumerate_pixels_mut() {
            *px = image::Rgba([(x % 256) as u8, (y % 256) as u8, 140, 255]);
        }
        encode_png(&img)
    }

    fn encode_png(img: &image::RgbaImage) -> Vec<u8> {
        let mut out = Vec::new();
        img.write_to(
            &mut std::io::Cursor::new(&mut out),
            image::ImageFormat::Png,
        )
        .expect("encode png fixture");
        out
    }

    /// A two-frame animated GIF, so the animated encoders have something real
    /// to chew on.
    pub(super) fn anim_gif(w: u32, h: u32) -> Vec<u8> {
        let mut out = Vec::new();
        {
            let mut enc = image::codecs::gif::GifEncoder::new(&mut out);
            enc.set_repeat(image::codecs::gif::Repeat::Infinite)
                .expect("gif repeat");
            for step in 0..2u32 {
                let mut img = image::RgbaImage::new(w, h);
                for (x, y, px) in img.enumerate_pixels_mut() {
                    let v = ((x + y + step * 90) % 256) as u8;
                    *px = image::Rgba([v, 255 - v, 90, 255]);
                }
                enc.encode_frame(image::Frame::from_parts(
                    img,
                    0,
                    0,
                    image::Delay::from_numer_denom_ms(100, 1),
                ))
                .expect("gif frame");
            }
        }
        out
    }

    // ── (a0) the decode ceiling (SHOP-2) ──────────────────────────────

    /// The header reader has to agree with the encoders on all three WebP
    /// chunk shapes, because a wrong answer here either lets a bomb through
    /// or refuses real art.
    #[test]
    fn webp_header_dimensions_reads_vp8_vp8l_vp8x() {
        use crate::node::webp_anim::{self, AnimParams};

        // VP8 and VP8L stills through the crate's own encoder, at a non-square size so a
        // width/height swap shows. Fully OPAQUE on purpose: libwebp wraps anything with
        // alpha in a VP8X container, and these are the two simple chunk shapes.
        let (w, h) = (200u32, 120u32);
        let rgba: Vec<u8> = (0..(w * h))
            .flat_map(|_| [180u8, 140, 90, 255])
            .collect();

        let lossy = webp_anim::encode_still(&rgba, w, h, &AnimParams::default())
            .expect("lossy still");
        assert_eq!(&lossy[12..16], b"VP8 ", "the lossy encoder emits a VP8 chunk");
        assert_eq!(
            image_convert::webp_header_dimensions(&lossy),
            Some((w, h)),
            "VP8 header dimensions",
        );

        let lossless = webp_anim::encode_still(
            &rgba,
            w,
            h,
            &AnimParams { lossless: true, ..Default::default() },
        )
        .expect("lossless still");
        assert_eq!(
            &lossless[12..16],
            b"VP8L",
            "the lossless encoder emits a VP8L chunk",
        );
        assert_eq!(
            image_convert::webp_header_dimensions(&lossless),
            Some((w, h)),
            "VP8L header dimensions",
        );

        // VP8X (extended, the container every animation uses).
        let frames: Vec<(image::RgbaImage, i32)> = (0..2)
            .map(|i| (image::RgbaImage::new(w, h), i * 100))
            .collect();
        let anim = webp_anim::encode_animation(&frames, (w, h), &AnimParams::default())
            .expect("animation");
        assert_eq!(&anim[12..16], b"VP8X", "an animation is an extended WebP");
        assert_eq!(
            image_convert::webp_header_dimensions(&anim),
            Some((w, h)),
            "VP8X canvas dimensions",
        );

        // Not a WebP, and a WebP whose first chunk is nothing we know.
        assert_eq!(image_convert::webp_header_dimensions(b"not a webp at all"), None);
        let mut junk = anim.clone();
        junk[12..16].copy_from_slice(b"XXXX");
        assert_eq!(image_convert::webp_header_dimensions(&junk), None);
    }

    /// SHOP-2 regression: the ceiling used to be checked on the DECODED image, so a small
    /// file declaring a huge canvas cost about a gigabyte of RGBA. The refusal now happens
    /// on the header, which means it also has to be fast.
    #[test]
    fn blob_shape_rejects_oversized_canvas_before_decode() {
        // A hand-built VP8X header claiming 16384x16384 followed by nothing usable:
        // reaching the decoder would allocate a gigabyte or fail slowly.
        let mut bomb = Vec::with_capacity(4096);
        bomb.extend_from_slice(b"RIFF");
        bomb.extend_from_slice(&0u32.to_le_bytes()); // size, unread by us
        bomb.extend_from_slice(b"WEBP");
        bomb.extend_from_slice(b"VP8X");
        bomb.extend_from_slice(&10u32.to_le_bytes()); // VP8X payload length
        bomb.push(0x10); // flags: alpha
        bomb.extend_from_slice(&[0, 0, 0]); // reserved
        let dim_minus_one = 16384u32 - 1;
        bomb.extend_from_slice(&dim_minus_one.to_le_bytes()[0..3]); // width-1
        bomb.extend_from_slice(&dim_minus_one.to_le_bytes()[0..3]); // height-1
        bomb.extend_from_slice(&[0xAB; 2048]); // garbage where the frames go

        assert_eq!(
            image_convert::webp_header_dimensions(&bomb),
            Some((16384, 16384)),
            "the header check reads the claimed canvas",
        );

        let start = std::time::Instant::now();
        let err = blob_shape(&bomb).expect_err("a 16384x16384 canvas must be refused");
        let elapsed = start.elapsed();
        assert!(err.contains("too large to decode safely"), "got: {err}");
        assert!(
            elapsed < std::time::Duration::from_millis(100),
            "the refusal has to happen on the header, not after a decode: took {elapsed:?}",
        );

        // A WebP container whose first chunk we cannot read a size out of is
        // refused too, rather than handed to a decoder to find out.
        let mut unreadable = Vec::new();
        unreadable.extend_from_slice(b"RIFF");
        unreadable.extend_from_slice(&0u32.to_le_bytes());
        unreadable.extend_from_slice(b"WEBP");
        unreadable.extend_from_slice(b"ZZZZ");
        unreadable.extend_from_slice(&[0u8; 64]);
        let err = blob_shape(&unreadable).expect_err("an unreadable header must be refused");
        assert!(err.contains("unreadable WebP header"), "got: {err}");

        // And real art still passes, header check and all.
        let real = image_convert::process_avatar_frame(&ring_png(224)).expect("frame");
        let (w, h, _) = blob_shape(&real.0).expect("a real frame still passes");
        assert!(w <= image_convert::MAX_DECODE_DIM && h <= image_convert::MAX_DECODE_DIM);
    }

    // ── (a) encoder determinism ───────────────────────────────────────

    #[test]
    fn the_encoders_are_deterministic() {
        // The whole format rests on this: the shop encodes once, the buyer's
        // client hashes the bytes, and a credential binds that hash. An
        // encoder that varied run to run would break every one of those.
        let frame_src = ring_png(224);
        let a = image_convert::process_avatar_frame(&frame_src).expect("frame a");
        let b = image_convert::process_avatar_frame(&frame_src).expect("frame b");
        assert_eq!(a.0, b.0, "the frame encoder is not deterministic");

        let still_src = solid_png(400, 400);
        assert_eq!(
            image_convert::process_avatar_image(&still_src).expect("avatar a"),
            image_convert::process_avatar_image(&still_src).expect("avatar b"),
            "the still avatar encoder is not deterministic"
        );

        let banner_src = solid_png(1200, 500);
        assert_eq!(
            image_convert::process_banner_image(&banner_src).expect("banner a"),
            image_convert::process_banner_image(&banner_src).expect("banner b"),
            "the still banner encoder is not deterministic"
        );

        let gif = anim_gif(200, 200);
        assert_eq!(
            image_convert::process_user_avatar_anim(&gif).expect("avatar anim a"),
            image_convert::process_user_avatar_anim(&gif).expect("avatar anim b"),
            "the animated avatar encoder is not deterministic"
        );

        let wide = anim_gif(360, 120);
        assert_eq!(
            image_convert::process_user_banner_anim(&wide).expect("banner anim a"),
            image_convert::process_user_banner_anim(&wide).expect("banner anim b"),
            "the animated banner encoder is not deterministic"
        );
    }

    #[test]
    fn an_animated_source_expands_to_the_pair() {
        let files = process_source(RoleHint::Avatar, &anim_gif(200, 200)).expect("avatar pair");
        assert_eq!(files.len(), 2, "an animated avatar ships as a pair");
        assert_eq!(files[0].role, Role::AvatarAnim);
        assert!(files[0].animated);
        assert_eq!(files[1].role, Role::AvatarStill);
        assert!(!files[1].animated, "the companion is a still");

        let still = process_source(RoleHint::Avatar, &solid_png(400, 400)).expect("avatar still");
        assert_eq!(still.len(), 1);
        assert_eq!(still[0].role, Role::Avatar);
    }

    // ── (a2) passthrough, the bundle maker ────────────────────────────

    #[test]
    fn passthrough_keeps_the_hash_and_the_bytes() {
        // A bundle is built from files processed for OTHER listings, and its buyer must end
        // up owning the same hash, so passthrough may check anything and change nothing.
        let mut original = process_source(RoleHint::Avatar, &anim_gif(200, 200)).expect("pair");
        original.extend(process_source(RoleHint::Frame, &ring_png(224)).expect("frame"));
        assert_eq!(original.len(), 3, "an animated avatar pair plus a frame");

        let mut passed: Vec<ProcessedFile> = Vec::with_capacity(original.len());
        for f in &original {
            let again = processed_from_bytes(f.role, f.bytes.clone())
                .unwrap_or_else(|e| panic!("{} must pass through: {e}", f.role.as_str()));
            assert_eq!(again.role, f.role);
            assert_eq!(again.hash, f.hash, "passthrough minted a different hash");
            assert_eq!((again.w, again.h), (f.w, f.h));
            assert_eq!(again.animated, f.animated);
            assert_eq!(again.bytes, f.bytes, "passthrough changed the bytes");
            passed.push(again);
        }

        // The bundle itself: two existing listings in one pack.
        let (zip_bytes, manifest) = build_pack(&PackInput {
            title: "Dusk bundle".into(),
            artist_name: "Sample Artist".into(),
            artist_slug: "sample".into(),
            artist_url: "https://example.invalid/sample".into(),
            license: "Plain text licence.".into(),
            item_id: None,
            kinds: vec!["avatar".into(), "frame".into()],
            files: passed.clone(),
        })
        .expect("a bundle of processed files must build");

        let verified = verify_pack(&zip_bytes).expect("a bundle must verify");
        assert_eq!(verified.files.len(), original.len());

        let mut want: Vec<&str> = original.iter().map(|f| f.hash.as_str()).collect();
        want.sort_unstable();
        let mut got: Vec<&str> = verified.files.iter().map(|f| f.hash.as_str()).collect();
        got.sort_unstable();
        assert_eq!(got, want, "the bundle carries the ORIGINAL hashes");

        for f in &verified.files {
            let src = original
                .iter()
                .find(|o| o.hash == f.hash)
                .expect("every verified file is one of the originals");
            assert_eq!(f.bytes, src.bytes, "byte identical, end to end");
        }

        assert_eq!(manifest.item.id, default_item_id(&passed));
        assert_eq!(
            manifest.item.id,
            default_item_id(&original),
            "the same art, so the same content-addressed item id"
        );
    }

    #[test]
    fn passthrough_refuses_what_the_encoder_never_made() {
        // Not a WebP at all. Passthrough is a trust boundary, not a copy.
        let err = processed_from_bytes(Role::Avatar, solid_png(400, 400))
            .expect_err("a PNG is not a processed file");
        assert!(err.contains("not a WebP"), "got: {err}");

        // A still under an animated role.
        let still = image_convert::process_avatar_image(&solid_png(400, 400)).expect("avatar");
        let err = processed_from_bytes(Role::AvatarAnim, still.clone())
            .expect_err("an avatar_anim that does not animate must be refused");
        assert!(err.contains("does not animate"), "got: {err}");

        // Square, inside the frame ceiling, and opaque through the middle: only
        // the centre gate can catch this one.
        let err = processed_from_bytes(Role::Frame, still)
            .expect_err("an opaque centre must be refused");
        assert!(err.contains("transparent"), "got: {err}");

        // Over the per-file cap, refused before anything tries to decode it.
        let err = processed_from_bytes(Role::Avatar, vec![0u8; MAX_FILE_BYTES + 1])
            .expect_err("an oversize file must be refused");
        assert!(err.contains("limit"), "got: {err}");
    }

    #[test]
    fn a_pack_carries_one_file_per_role() {
        let mut files = process_source(RoleHint::Avatar, &solid_png(400, 400)).expect("avatar a");
        files.extend(process_source(RoleHint::Avatar, &solid_png(320, 320)).expect("avatar b"));
        assert_eq!(files.len(), 2);
        assert_ne!(files[0].hash, files[1].hash, "distinct art, distinct hashes");

        let err = build_pack(&PackInput {
            title: "Two faces".into(),
            artist_name: "Sample Artist".into(),
            artist_slug: "sample".into(),
            artist_url: String::new(),
            license: String::new(),
            item_id: None,
            kinds: vec!["avatar".into()],
            files,
        })
        .expect_err("two avatars in one pack must be refused");
        assert_eq!(
            err,
            "A pack carries one file per role, and two avatar files were given. \
             Two avatars are two packs, not one."
        );
    }

    // ── (b) pack then inspect ─────────────────────────────────────────

    pub(super) fn sample_pack() -> (Vec<u8>, PackManifest) {
        let mut files = process_source(RoleHint::Frame, &ring_png(224)).expect("frame");
        files.extend(process_source(RoleHint::Avatar, &solid_png(400, 400)).expect("avatar"));
        build_pack(&PackInput {
            title: "Ring of dusk".into(),
            artist_name: "Sample Artist".into(),
            artist_slug: "sample".into(),
            artist_url: "https://example.invalid/sample".into(),
            license: "Plain text licence. No DRM, you own the files.".into(),
            item_id: None,
            kinds: vec!["frame".into(), "avatar".into()],
            files,
        })
        .expect("build pack")
    }

    #[test]
    fn a_packed_pack_verifies_and_its_hashes_are_the_bytes() {
        let (zip_bytes, manifest) = sample_pack();
        let verified = verify_pack(&zip_bytes).expect("verify");

        assert_eq!(verified.files.len(), manifest.files.len());
        assert_eq!(verified.manifest.item.title, "Ring of dusk");
        assert_eq!(verified.manifest.artist.slug, "sample");
        assert_eq!(manifest.item.id.len(), 16, "item ids are 16 hex chars");

        for (claimed, actual) in manifest.files.iter().zip(verified.files.iter()) {
            assert_eq!(claimed.sha256, actual.hash, "the manifest hash is the bytes");
            assert_eq!(claimed.sha256, hash_hex(&actual.bytes));
            assert_eq!(claimed.w, actual.w);
            assert_eq!(claimed.h, actual.h);
            assert_eq!(claimed.animated, actual.animated);
            assert_eq!(claimed.path, format!("files/{}.webp", actual.hash));
        }

        // Ordered by role then hash, whatever order they were passed in.
        let roles: Vec<&str> = manifest.files.iter().map(|f| f.role.as_str()).collect();
        let mut sorted = roles.clone();
        sorted.sort_unstable();
        assert_eq!(roles, sorted);
    }

    #[test]
    fn the_item_id_is_content_addressed() {
        let files = process_source(RoleHint::Frame, &ring_png(224)).expect("frame");
        let a = default_item_id(&files);
        let mut reordered = files.clone();
        reordered.reverse();
        assert_eq!(a, default_item_id(&reordered), "order does not change it");

        let other = process_source(RoleHint::Avatar, &solid_png(400, 400)).expect("avatar");
        assert_ne!(a, default_item_id(&other), "different art, different id");
    }

    // ── (c) a flipped byte ────────────────────────────────────────────

    /// Rebuild a pack's ZIP with one entry's bytes replaced. The manifest is
    /// left exactly as it was, which is precisely the tamper the hash check
    /// exists to catch.
    pub(super) fn repack_with(
        zip_bytes: &[u8],
        swap: impl Fn(&str, Vec<u8>) -> Vec<u8>,
    ) -> Vec<u8> {
        use std::io::Write;
        let mut src = zip::ZipArchive::new(std::io::Cursor::new(zip_bytes)).expect("open");
        let names: Vec<String> = src.file_names().map(|n| n.to_string()).collect();
        let mut out = Vec::new();
        {
            let mut zip = zip::ZipWriter::new(std::io::Cursor::new(&mut out));
            let options = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            for name in names {
                let mut buf = Vec::new();
                src.by_name(&name)
                    .expect("entry")
                    .read_to_end(&mut buf)
                    .expect("read");
                let buf = swap(&name, buf);
                zip.start_file(&name, options).expect("start");
                zip.write_all(&buf).expect("write");
            }
            zip.finish().expect("finish");
        }
        out
    }

    #[test]
    fn one_flipped_byte_refuses_the_pack() {
        let (zip_bytes, _) = sample_pack();
        let tampered = repack_with(&zip_bytes, |name, mut buf| {
            if name.starts_with("files/") {
                // Flip a bit deep in the pixel data, past the header.
                let i = buf.len() - 3;
                buf[i] ^= 0x01;
            }
            buf
        });
        let err = verify_pack(&tampered).expect_err("a tampered file must be refused");
        assert!(
            err.contains("does not match the hash"),
            "the error has to name the hash mismatch, got: {err}"
        );
    }

    #[test]
    fn a_manifest_that_lies_about_the_size_is_refused() {
        let (zip_bytes, _) = sample_pack();
        let tampered = repack_with(&zip_bytes, |name, buf| {
            if name != MANIFEST_NAME {
                return buf;
            }
            let mut m: PackManifest = serde_json::from_slice(&buf).expect("parse");
            m.files[0].w = 4096;
            serde_json::to_vec(&m).expect("write")
        });
        let err = verify_pack(&tampered).expect_err("a lying manifest must be refused");
        assert!(err.contains("not the size"), "got: {err}");
    }

    // ── (d) an opaque frame ───────────────────────────────────────────

    #[test]
    fn an_opaque_centre_is_refused_at_authoring_and_at_import() {
        // Authoring: the encoder refuses outright.
        let err = image_convert::process_avatar_frame(&solid_png(224, 224))
            .expect_err("a solid square is not a frame");
        assert!(err.contains("transparent"), "got: {err}");

        // Import: a hand-built pack that skipped the encoder is refused too.
        // The frame slot is filled with a legally SIZED but opaque 128x128
        // WebP, so only the centre gate can catch it.
        let opaque = image_convert::process_still_avatar(&solid_png(300, 300), 128)
            .expect("encode an opaque 128 square");
        let hash = hash_hex(&opaque);
        let (w, h, animated) = blob_shape(&opaque).expect("shape");
        assert_eq!((w, h), (128, 128));

        let manifest = PackManifest {
            format: FORMAT.into(),
            version: VERSION,
            item: PackItemMeta {
                id: "0123456789abcdef".into(),
                title: "Smuggled".into(),
                kinds: vec!["frame".into()],
            },
            artist: PackArtist::default(),
            license: String::new(),
            files: vec![PackFile {
                role: "frame".into(),
                path: format!("files/{hash}.webp"),
                sha256: hash.clone(),
                bytes: opaque.len() as u64,
                w,
                h,
                animated,
            }],
            ext: serde_json::json!({}),
        };
        let zip_bytes = raw_pack(&manifest, &[(hash, opaque)]);

        let err = verify_pack(&zip_bytes).expect_err("an opaque frame must be refused");
        assert!(
            err.contains("transparent"),
            "the centre gate has to be the refusal, got: {err}"
        );
    }

    /// The frame ceiling is "square, at most 512x512" rather than exactly 128x128, and
    /// the point of a ceiling is that every frame and pack already in the world stays
    /// valid.
    #[test]
    fn a_128_frame_still_encodes_and_verifies_at_128() {
        let files = process_source(RoleHint::Frame, &ring_png(128)).expect("frame");
        assert_eq!(files.len(), 1);
        assert_eq!(
            (files[0].w, files[0].h),
            (128, 128),
            "a 128 source must not be upscaled to the new ceiling"
        );

        let (zip_bytes, manifest) = build_pack(&PackInput {
            title: "Legacy ring".into(),
            artist_name: "Sample Artist".into(),
            artist_slug: "sample".into(),
            artist_url: "https://example.invalid/sample".into(),
            license: "Plain text licence.".into(),
            item_id: None,
            kinds: vec!["frame".into()],
            files,
        })
        .expect("build pack");
        assert_eq!(manifest.files[0].w, 128);

        let verified = verify_pack(&zip_bytes).expect("a 128x128 frame pack must still verify");
        assert_eq!((verified.files[0].w, verified.files[0].h), (128, 128));

        // The shape check is a ceiling in both directions that matter: over it
        // is refused, and non-square is refused.
        assert!(check_role_shape(Role::Frame, 128, 128, false).is_ok());
        assert!(check_role_shape(Role::Frame, image_convert::FRAME_DIM, image_convert::FRAME_DIM, false).is_ok());
        let err = check_role_shape(Role::Frame, image_convert::FRAME_DIM + 1, image_convert::FRAME_DIM + 1, false)
            .expect_err("over the ceiling must be refused");
        assert!(err.contains("ceiling"), "got: {err}");
        let err = check_role_shape(Role::Frame, 128, 96, false).expect_err("non-square is refused");
        assert!(err.contains("square"), "got: {err}");
    }

    /// Write a pack from a manifest and raw entries, bypassing [`build_pack`]
    /// entirely. This is how a hostile pack would be built, so it is how the
    /// hostile cases are tested.
    pub(super) fn raw_pack(manifest: &PackManifest, entries: &[(String, Vec<u8>)]) -> Vec<u8> {
        use std::io::Write;
        let mut out = Vec::new();
        {
            let mut zip = zip::ZipWriter::new(std::io::Cursor::new(&mut out));
            let options = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            zip.start_file(MANIFEST_NAME, options).expect("start");
            zip.write_all(&serde_json::to_vec(manifest).expect("json"))
                .expect("write");
            for (hash, bytes) in entries {
                zip.start_file(format!("files/{hash}.webp"), options)
                    .expect("start");
                zip.write_all(bytes).expect("write");
            }
            zip.finish().expect("finish");
        }
        out
    }

    // ── (e) too many files, and too many bytes ────────────────────────

    #[test]
    fn a_pack_with_too_many_files_is_refused() {
        let mut manifest = PackManifest {
            format: FORMAT.into(),
            version: VERSION,
            ..Default::default()
        };
        let mut entries = Vec::new();
        for i in 0..(MAX_FILES + 1) {
            let png = solid_png(200 + i as u32, 200 + i as u32);
            let bytes = image_convert::process_avatar_image(&png).expect("avatar");
            let hash = hash_hex(&bytes);
            manifest.files.push(PackFile {
                role: "avatar".into(),
                path: format!("files/{hash}.webp"),
                sha256: hash.clone(),
                bytes: bytes.len() as u64,
                w: image_convert::AVATAR_DIM,
                h: image_convert::AVATAR_DIM,
                animated: false,
            });
            entries.push((hash, bytes));
        }
        let zip_bytes = raw_pack(&manifest, &entries);
        let err = verify_pack(&zip_bytes).expect_err("too many files must be refused");
        assert!(err.contains("at most"), "got: {err}");
    }

    #[test]
    fn an_oversize_file_is_refused_before_it_is_decoded() {
        // A single entry that decompresses past the per-file cap. The bytes
        // are incompressible noise so the ZIP cannot hide the size, and the
        // refusal has to land on the cap rather than on "not a WebP".
        let mut big = vec![0u8; MAX_FILE_BYTES + 4096];
        let mut seed = 0x9E3779B9u32;
        for b in big.iter_mut() {
            seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
            *b = (seed >> 24) as u8;
        }
        let hash = hash_hex(&big);
        let manifest = PackManifest {
            format: FORMAT.into(),
            version: VERSION,
            files: vec![PackFile {
                role: "avatar".into(),
                path: format!("files/{hash}.webp"),
                sha256: hash.clone(),
                bytes: big.len() as u64,
                w: image_convert::AVATAR_DIM,
                h: image_convert::AVATAR_DIM,
                animated: false,
            }],
            ..Default::default()
        };
        let zip_bytes = raw_pack(&manifest, &[(hash, big)]);
        let err = verify_pack(&zip_bytes).expect_err("an oversize file must be refused");
        assert!(err.contains("limit"), "got: {err}");
    }

    #[test]
    fn an_unknown_role_and_a_mismatched_path_are_both_refused() {
        let bytes = image_convert::process_avatar_image(&solid_png(400, 400)).expect("avatar");
        let hash = hash_hex(&bytes);

        let mut manifest = PackManifest {
            format: FORMAT.into(),
            version: VERSION,
            files: vec![PackFile {
                role: "wallpaper".into(),
                path: format!("files/{hash}.webp"),
                sha256: hash.clone(),
                bytes: bytes.len() as u64,
                w: image_convert::AVATAR_DIM,
                h: image_convert::AVATAR_DIM,
                animated: false,
            }],
            ..Default::default()
        };
        let zip_bytes = raw_pack(&manifest, &[(hash.clone(), bytes.clone())]);
        let err = verify_pack(&zip_bytes).expect_err("an unknown role must be refused");
        assert!(err.contains("role this version does not know"), "got: {err}");

        // A path pointing somewhere other than the hash is refused, and it is
        // never joined onto anything on the way to that refusal.
        manifest.files[0].role = "avatar".into();
        manifest.files[0].path = "../../../etc/passwd".into();
        let zip_bytes = raw_pack(&manifest, &[(hash, bytes)]);
        let err = verify_pack(&zip_bytes).expect_err("a mismatched path must be refused");
        assert!(err.contains("does not match its hash"), "got: {err}");
    }

    #[test]
    fn a_foreign_format_and_a_future_version_are_both_refused() {
        let (zip_bytes, _) = sample_pack();

        let foreign = repack_with(&zip_bytes, |name, buf| {
            if name != MANIFEST_NAME {
                return buf;
            }
            let mut m: PackManifest = serde_json::from_slice(&buf).expect("parse");
            m.format = "stickerpack".into();
            serde_json::to_vec(&m).expect("json")
        });
        assert!(
            verify_pack(&foreign)
                .expect_err("a foreign format must be refused")
                .contains("not a Hollow art pack")
        );

        let future = repack_with(&zip_bytes, |name, buf| {
            if name != MANIFEST_NAME {
                return buf;
            }
            let mut m: PackManifest = serde_json::from_slice(&buf).expect("parse");
            m.version = VERSION + 1;
            serde_json::to_vec(&m).expect("json")
        });
        assert!(
            verify_pack(&future)
                .expect_err("a future version must be refused")
                .contains("newer version")
        );
    }

    #[test]
    fn unknown_manifest_fields_are_ignored() {
        // Phase 2 adds an issuing key and a catalog signature under `ext`. An
        // older client has to keep reading those packs, so the parse is
        // tolerant of anything it does not recognise.
        let (zip_bytes, _) = sample_pack();
        let extended = repack_with(&zip_bytes, |name, buf| {
            if name != MANIFEST_NAME {
                return buf;
            }
            let mut v: serde_json::Value = serde_json::from_slice(&buf).expect("parse");
            v["ext"]["issuer_pk"] = serde_json::json!("not a real key");
            v["something_from_the_future"] = serde_json::json!({ "nested": true });
            v["files"][0]["future_field"] = serde_json::json!(7);
            serde_json::to_vec(&v).expect("json")
        });
        let verified = verify_pack(&extended).expect("unknown fields must not break the read");
        assert_eq!(verified.manifest.ext["issuer_pk"], "not a real key");
    }

    // -- (f) the importer, end to end --------------------------------
    //
    // These drive `api::network::import_hollowpack` against a real in-memory SQLCipher
    // store, so they cover the rail write and the provenance row too. No node runs.

    /// Install a fresh in-memory store and hold the lock that serializes
    /// every test which swaps the process-global slot.
    fn fresh_store() -> std::sync::MutexGuard<'static, ()> {
        let lock = crate::api::storage::store_test_lock();
        crate::api::storage::set_test_store(
            crate::storage::MessageStore::open(":memory:", &"ab".repeat(32))
                .expect("open in-memory store"),
        );
        lock
    }

    /// Run `body` against the store the api functions actually read.
    fn with_installed_store<T>(body: impl FnOnce(&crate::storage::MessageStore) -> T) -> T {
        let guard = crate::api::storage::get_store()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        body(guard.as_ref().expect("store installed"))
    }

    /// Write bytes to a throwaway file. The returned dir owns it, so dropping
    /// the dir deletes the pack.
    fn temp_pack(bytes: &[u8]) -> (tempfile::TempDir, String) {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("item.hollowpack");
        std::fs::write(&path, bytes).expect("write pack");
        let as_str = path.to_string_lossy().to_string();
        (dir, as_str)
    }

    #[test]
    fn importing_puts_the_bytes_on_the_rail_and_records_who_made_them() {
        let _lock = fresh_store();

        let (zip_bytes, manifest) = sample_pack();
        let (_dir, path) = temp_pack(&zip_bytes);

        let imported =
            crate::api::network::import_hollowpack(path).expect("a good pack must import");

        assert_eq!(imported.item_id, manifest.item.id);
        assert_eq!(imported.title, "Ring of dusk");
        assert_eq!(imported.artist_name, "Sample Artist");
        assert_eq!(imported.files.len(), manifest.files.len());

        with_installed_store(|ms| {
            for f in &imported.files {
                // On the rail, byte for byte. A re-encode here would be a
                // different hash and a dead credential.
                let stored = ms
                    .load_emote_blob(&f.hash)
                    .expect("read blob")
                    .expect("the blob has to be on the rail");
                assert_eq!(hash_hex(&stored), f.hash, "the rail holds the exact bytes");
                assert_eq!(stored.len() as u64, f.bytes);
            }

            let owned = ms.list_owned_art().expect("list owned art");
            assert_eq!(owned.len(), imported.files.len());
            for row in &owned {
                assert_eq!(row.2, manifest.item.id, "item id");
                assert_eq!(row.3, "Ring of dusk", "title");
                assert_eq!(row.4, "Sample Artist", "artist name");
                assert_eq!(row.5, "sample", "artist slug");
                assert!(row.7.contains("No DRM"), "the licence text is kept");
                assert!(row.8 > 0, "imported_at is stamped");
            }
            assert!(
                owned.iter().any(|r| r.1 == "frame"),
                "the frame role is recorded"
            );
        });

        // The FFI listing is the same set.
        let listed = crate::api::network::list_owned_art().expect("list");
        assert_eq!(listed.len(), imported.files.len());

        // Re-importing the same order owns the art once, not twice.
        let (_dir2, path2) = temp_pack(&zip_bytes);
        crate::api::network::import_hollowpack(path2).expect("a second import is idempotent");
        assert_eq!(
            crate::api::network::list_owned_art().expect("list").len(),
            imported.files.len(),
            "re-importing must not duplicate rows"
        );
    }

    #[test]
    fn the_importer_refuses_a_tampered_pack_and_stores_nothing() {
        let _lock = fresh_store();

        let (zip_bytes, _) = sample_pack();
        let tampered = repack_with(&zip_bytes, |name, mut buf| {
            if name.starts_with("files/") {
                let i = buf.len() - 3;
                buf[i] ^= 0x01;
            }
            buf
        });
        let (_dir, path) = temp_pack(&tampered);

        let err = crate::api::network::import_hollowpack(path)
            .expect_err("a tampered pack must be refused");
        assert!(err.contains("does not match the hash"), "got: {err}");

        // Refused WHOLE: not one file of a two-file pack landed.
        with_installed_store(|ms| {
            assert!(
                ms.list_owned_art().expect("list").is_empty(),
                "a refused pack must leave nothing behind"
            );
            assert!(
                ms.list_asset_blobs_by_kind("frame").expect("list").is_empty(),
                "a refused pack must put nothing on the rail"
            );
            assert!(
                ms.list_asset_blobs_by_kind("profile")
                    .expect("list")
                    .is_empty()
            );
        });
    }

    #[test]
    fn the_importer_refuses_a_pack_with_too_many_files() {
        let _lock = fresh_store();

        // Same shape as the unit case, driven through the FFI so the caps are
        // proven where a real import would hit them.
        let mut manifest = PackManifest {
            format: FORMAT.into(),
            version: VERSION,
            ..Default::default()
        };
        let mut entries = Vec::new();
        for i in 0..(MAX_FILES + 1) {
            let png = solid_png(200 + i as u32, 200 + i as u32);
            let bytes = image_convert::process_avatar_image(&png).expect("avatar");
            let hash = hash_hex(&bytes);
            manifest.files.push(PackFile {
                role: "avatar".into(),
                path: format!("files/{hash}.webp"),
                sha256: hash.clone(),
                bytes: bytes.len() as u64,
                w: image_convert::AVATAR_DIM,
                h: image_convert::AVATAR_DIM,
                animated: false,
            });
            entries.push((hash, bytes));
        }
        let (_dir, path) = temp_pack(&raw_pack(&manifest, &entries));
        let err = crate::api::network::import_hollowpack(path)
            .expect_err("too many files must be refused");
        assert!(err.contains("at most"), "got: {err}");

        with_installed_store(|ms| {
            assert!(ms.list_owned_art().expect("list").is_empty());
        });
    }

    #[test]
    fn the_importer_refuses_a_frame_whose_middle_is_opaque() {
        let _lock = fresh_store();

        let opaque = image_convert::process_still_avatar(&solid_png(300, 300), 128)
            .expect("encode an opaque 128 square");
        let hash = hash_hex(&opaque);
        let (w, h, animated) = blob_shape(&opaque).expect("shape");

        let manifest = PackManifest {
            format: FORMAT.into(),
            version: VERSION,
            item: PackItemMeta {
                id: "0123456789abcdef".into(),
                title: "Smuggled".into(),
                kinds: vec!["frame".into()],
            },
            files: vec![PackFile {
                role: "frame".into(),
                path: format!("files/{hash}.webp"),
                sha256: hash.clone(),
                bytes: opaque.len() as u64,
                w,
                h,
                animated,
            }],
            ..Default::default()
        };
        let (_dir, path) = temp_pack(&raw_pack(&manifest, &[(hash, opaque)]));

        let err = crate::api::network::import_hollowpack(path)
            .expect_err("an opaque frame must be refused at import too");
        assert!(err.contains("transparent"), "got: {err}");

        with_installed_store(|ms| {
            assert!(ms.list_owned_art().expect("list").is_empty());
        });
    }

    #[test]
    fn a_still_role_carrying_an_animation_is_refused() {
        let gif = anim_gif(200, 200);
        let (anim, _still) = image_convert::process_user_avatar_anim(&gif).expect("avatar anim");
        let hash = hash_hex(&anim);
        let (w, h, animated) = blob_shape(&anim).expect("shape");
        assert!(animated);

        let manifest = PackManifest {
            format: FORMAT.into(),
            version: VERSION,
            files: vec![PackFile {
                // Claiming the still role for animated bytes.
                role: "avatar_still".into(),
                path: format!("files/{hash}.webp"),
                sha256: hash.clone(),
                bytes: anim.len() as u64,
                w,
                h,
                animated: true,
            }],
            ..Default::default()
        };
        let zip_bytes = raw_pack(&manifest, &[(hash, anim)]);
        let err = verify_pack(&zip_bytes).expect_err("a still role must not animate");
        assert!(err.contains("has to be a still"), "got: {err}");
    }
}
