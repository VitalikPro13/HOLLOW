//! `hollowpack` — the artist shop's local pack tool
//! (`cargo build --release --features packtool --bin hollowpack`).
//!
//! Approval is a manual step Vitalik runs (ARTIST_SHOP_DESIGN §13.14): this is
//! the binary that turns an artist's submitted source art into the processed
//! WebPs, their hashes, and the `.hollowpack` that gets attached to the Creem
//! product. The site then links the listing to those hashes.
//!
//! It runs the APP's encoders, not a copy of them, because the buyer's client
//! recomputes the SHA-256 of the bytes on import and phase 2 binds a support
//! credential to that hash. Identity is the hash, so a second encoder would be
//! a second identity.
//!
//! **Why the feature gate.** Cargo builds every `[[bin]]` whose
//! `required-features` are satisfied, and cargokit runs a plain `cargo build`
//! for every app platform. `packtool` is passed by nothing but a developer's
//! own command line, so this target simply does not exist in an app build.
//! (Unlike `hollow-forwarder` it needs no stub: an unsatisfied
//! `required-features` skips the target outright.)
//!
//! Subcommands:
//!   pack     encode sources, write pack.json + files/<hash>.webp into a zip
//!   inspect  re-verify a pack the way the app's importer does
//!   process  encode one source and print what it produced (the design sheet)

use std::path::{Path, PathBuf};

use hollow_core::hollowpack::{
    self, PackInput, ProcessedFile, RoleHint,
};

const USAGE: &str = "\
hollowpack — build and check Hollow artist shop packs

USAGE:
  hollowpack pack --file <kind>=<path> [--file ...] --title <t>
                  --artist-name <n> --artist-slug <s> [--artist-url <u>]
                  [--license <text or @file>] [--item-id <16 hex>]
                  --out <x.hollowpack> [--emit-entry <entry.json>]

  hollowpack inspect <x.hollowpack>

  hollowpack process --kind <frame|avatar|banner> <in> --out-dir <dir>

<kind> is frame, avatar or banner. Still versus animated is decided from the
bytes, never from the file extension.
";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("pack") => cmd_pack(&args[1..]),
        Some("inspect") => cmd_inspect(&args[1..]),
        Some("process") => cmd_process(&args[1..]),
        Some("--help") | Some("-h") | Some("help") | None => {
            print!("{USAGE}");
            return;
        }
        Some(other) => Err(format!("unknown subcommand {other}\n\n{USAGE}")),
    };
    if let Err(e) = result {
        eprintln!("hollowpack: {e}");
        std::process::exit(1);
    }
}

// ── Argument handling ─────────────────────────────────────────────────
//
// Hand-parsed, the same way `hollow-forwarder` does it: this is a two-person
// tool and a CLI dependency would ride into the app crate's lockfile for it.

/// Pull the value that follows `--flag`, erroring when it is missing.
fn need_value(args: &[String], i: &mut usize, flag: &str) -> Result<String, String> {
    *i += 1;
    args.get(*i)
        .cloned()
        .ok_or_else(|| format!("{flag} needs a value"))
}

fn require(value: Option<String>, flag: &str) -> Result<String, String> {
    value.filter(|v| !v.trim().is_empty()).ok_or_else(|| format!("{flag} is required"))
}

/// `--license` takes literal text, or `@path` to read it from a file. Licence
/// text is a paragraph, and a paragraph on a command line is a quoting trap.
fn read_license(value: &str) -> Result<String, String> {
    match value.strip_prefix('@') {
        Some(path) => std::fs::read_to_string(path)
            .map(|s| s.trim_end().to_string())
            .map_err(|e| format!("failed to read the licence file {path}: {e}")),
        None => Ok(value.to_string()),
    }
}

// ── pack ──────────────────────────────────────────────────────────────

fn cmd_pack(args: &[String]) -> Result<(), String> {
    let mut sources: Vec<(RoleHint, PathBuf)> = Vec::new();
    let mut title = None;
    let mut artist_name = None;
    let mut artist_slug = None;
    let mut artist_url = String::new();
    let mut license = String::new();
    let mut item_id: Option<String> = None;
    let mut out: Option<String> = None;
    let mut emit_entry: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--file" => {
                let raw = need_value(args, &mut i, "--file")?;
                let (kind, path) = raw
                    .split_once('=')
                    .ok_or_else(|| format!("--file wants <kind>=<path>, got {raw}"))?;
                sources.push((RoleHint::parse(kind)?, PathBuf::from(path)));
            }
            "--title" => title = Some(need_value(args, &mut i, "--title")?),
            "--artist-name" => artist_name = Some(need_value(args, &mut i, "--artist-name")?),
            "--artist-slug" => artist_slug = Some(need_value(args, &mut i, "--artist-slug")?),
            "--artist-url" => artist_url = need_value(args, &mut i, "--artist-url")?,
            "--license" => license = read_license(&need_value(args, &mut i, "--license")?)?,
            "--item-id" => item_id = Some(need_value(args, &mut i, "--item-id")?),
            "--out" => out = Some(need_value(args, &mut i, "--out")?),
            "--emit-entry" => emit_entry = Some(need_value(args, &mut i, "--emit-entry")?),
            "--help" | "-h" => {
                print!("{USAGE}");
                return Ok(());
            }
            other => return Err(format!("unknown arg {other}")),
        }
        i += 1;
    }

    if sources.is_empty() {
        return Err("pack needs at least one --file <kind>=<path>".into());
    }
    let title = require(title, "--title")?;
    let artist_name = require(artist_name, "--artist-name")?;
    let artist_slug = require(artist_slug, "--artist-slug")?;
    let out = require(out, "--out")?;
    if let Some(id) = &item_id
        && (id.len() != 16 || !id.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')))
    {
        return Err("--item-id has to be 16 lowercase hex characters".into());
    }

    let mut files: Vec<ProcessedFile> = Vec::new();
    let mut kinds: Vec<String> = Vec::new();
    for (hint, path) in &sources {
        let raw = std::fs::read(path)
            .map_err(|e| format!("failed to read {}: {e}", path.display()))?;
        let produced = hollowpack::process_source(*hint, &raw)
            .map_err(|e| format!("{}: {e}", path.display()))?;
        for f in &produced {
            println!(
                "encoded {} -> {} {} {}x{} {} bytes{}",
                path.display(),
                f.role.as_str(),
                &f.hash[..16],
                f.w,
                f.h,
                f.bytes.len(),
                if f.animated { " animated" } else { "" }
            );
        }
        files.extend(produced);
        let k = hint.as_str().to_string();
        if !kinds.contains(&k) {
            kinds.push(k);
        }
    }

    let (zip_bytes, manifest) = hollowpack::build_pack(&PackInput {
        title,
        artist_name,
        artist_slug,
        artist_url,
        license,
        item_id,
        kinds,
        files,
    })?;

    // Verify what we just wrote, through the importer's own path. A pack that
    // cannot be imported is not a pack, and finding that out here costs
    // nothing while finding it out from a buyer costs a refund.
    hollowpack::verify_pack(&zip_bytes)
        .map_err(|e| format!("the pack we just built does not verify: {e}"))?;

    write_out(&out, &zip_bytes)?;
    println!(
        "wrote {out} ({} bytes, item {}, {} files)",
        zip_bytes.len(),
        manifest.item.id,
        manifest.files.len()
    );

    if let Some(entry_path) = emit_entry {
        let entry = hollowpack::catalog_entry(&manifest);
        let json = serde_json::to_vec_pretty(&entry)
            .map_err(|e| format!("failed to write the catalog entry: {e}"))?;
        write_out(&entry_path, &json)?;
        println!("wrote {entry_path}");
    }
    Ok(())
}

fn write_out(path: &str, bytes: &[u8]) -> Result<(), String> {
    if let Some(parent) = Path::new(path).parent()
        && !parent.as_os_str().is_empty()
    {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create {}: {e}", parent.display()))?;
    }
    std::fs::write(path, bytes).map_err(|e| format!("failed to write {path}: {e}"))
}

// ── inspect ───────────────────────────────────────────────────────────

fn cmd_inspect(args: &[String]) -> Result<(), String> {
    let mut path: Option<String> = None;
    for a in args {
        match a.as_str() {
            "--help" | "-h" => {
                print!("{USAGE}");
                return Ok(());
            }
            other if other.starts_with("--") => return Err(format!("unknown arg {other}")),
            other => {
                if path.is_some() {
                    return Err("inspect takes one pack".into());
                }
                path = Some(other.to_string());
            }
        }
    }
    let path = require(path, "a pack path")?;

    // The same call the app's importer makes. Every hash and every dimension
    // in the printout below came out of the BYTES, not out of the manifest,
    // and a disagreement between the two is what makes this exit non-zero.
    let verified = hollowpack::verify_pack_file(&path)?;
    let m = &verified.manifest;

    println!("pack     {path}");
    println!("format   {} v{}", m.format, m.version);
    println!("item     {} {:?}", m.item.id, m.item.title);
    println!("kinds    {}", m.item.kinds.join(", "));
    println!(
        "artist   {} ({}){}",
        m.artist.name,
        m.artist.slug,
        if m.artist.url.is_empty() {
            String::new()
        } else {
            format!(" {}", m.artist.url)
        }
    );
    if !m.license.is_empty() {
        println!("licence  {}", m.license);
    }
    println!("files    {}", verified.files.len());
    for f in &verified.files {
        println!(
            "  {:<13} {} {:>4}x{:<4} {:>8} bytes {}",
            f.role.as_str(),
            f.hash,
            f.w,
            f.h,
            f.bytes.len(),
            if f.animated { "animated" } else { "still" }
        );
    }
    println!("verified: every hash and dimension recomputed from the bytes");
    Ok(())
}

// ── process ───────────────────────────────────────────────────────────

fn cmd_process(args: &[String]) -> Result<(), String> {
    let mut kind: Option<RoleHint> = None;
    let mut input: Option<String> = None;
    let mut out_dir: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--kind" => kind = Some(RoleHint::parse(&need_value(args, &mut i, "--kind")?)?),
            "--in" => input = Some(need_value(args, &mut i, "--in")?),
            "--out-dir" => out_dir = Some(need_value(args, &mut i, "--out-dir")?),
            "--help" | "-h" => {
                print!("{USAGE}");
                return Ok(());
            }
            other if other.starts_with("--") => return Err(format!("unknown arg {other}")),
            other => {
                if input.is_some() {
                    return Err("process takes one input file".into());
                }
                input = Some(other.to_string());
            }
        }
        i += 1;
    }

    let kind = kind.ok_or("--kind is required")?;
    let input = require(input, "an input file")?;
    let out_dir = require(out_dir, "--out-dir")?;
    std::fs::create_dir_all(&out_dir)
        .map_err(|e| format!("failed to create {out_dir}: {e}"))?;

    let raw = std::fs::read(&input).map_err(|e| format!("failed to read {input}: {e}"))?;
    let produced = hollowpack::process_source(kind, &raw).map_err(|e| format!("{input}: {e}"))?;

    for f in &produced {
        let path = Path::new(&out_dir).join(format!("{}.webp", f.hash));
        std::fs::write(&path, &f.bytes)
            .map_err(|e| format!("failed to write {}: {e}", path.display()))?;
        let line = serde_json::json!({
            "source": input,
            "role": f.role.as_str(),
            "hash": f.hash,
            "bytes": f.bytes.len(),
            "w": f.w,
            "h": f.h,
            "animated": f.animated,
            "path": path.to_string_lossy(),
        });
        println!("{line}");
    }
    Ok(())
}
