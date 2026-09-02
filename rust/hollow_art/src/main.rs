//! `hollowpack` — the artist shop's pack tool
//! (`cargo build --release` in rust/hollow_art; the shop's Linux host gets
//! `cargo zigbuild --release --target x86_64-unknown-linux-musl`).
//!
//! This is the binary that turns an artist's submitted source art into the
//! processed WebPs, their hashes, the `.hollowpack` the app imports, and the
//! delivery zip the buyer downloads. The shop server runs it at approval; a
//! keeper can run it by hand for the same result.
//!
//! It runs the APP's encoders, not a copy of them, because the buyer's client
//! recomputes the SHA-256 of the bytes on import and phase 2 binds a support
//! credential to that hash. Identity is the hash, so a second encoder would be
//! a second identity. That is why this lives in hollow_art, which
//! `#[path]`-includes hollow_core's own encoder sources rather than shipping a
//! lookalike.
//!
//! Subcommands:
//!   pack     encode sources, write pack.json + files/<hash>.webp into a zip,
//!            and optionally the processed files, the catalog entry and the
//!            delivery zip (pack + originals + README)
//!   inspect  re-verify a pack the way the app's importer does
//!   process  encode one source and print what it produced (the design sheet)
//!   version  print the tool's version (also --version)

use std::path::{Path, PathBuf};

use hollow_art::hollowpack::{self, PackInput, ProcessedFile, RoleHint};

const USAGE: &str = "\
hollowpack — build and check Hollow artist shop packs

USAGE:
  hollowpack pack --file <kind>=<path> [--file ...] --title <t>
                  --artist-name <n> --artist-slug <s> [--artist-url <u>]
                  [--license <text or @file>] [--item-id <16 hex>]
                  --out <x.hollowpack> [--emit-entry <entry.json>]
                  [--emit-files <dir>]
                  [--original <path>]... [--readme <file>] [--delivery <x.zip>]

  hollowpack inspect <x.hollowpack>

  hollowpack process --kind <frame|avatar|banner> <in> --out-dir <dir>

  hollowpack version

<kind> is frame, avatar or banner. Still versus animated is decided from the
bytes, never from the file extension.

--emit-files writes every processed file as <dir>/<sha256>.webp.
--delivery writes the buyer's download: the pack at the root (named after
--out), each --original under originals/<basename>, and --readme as
README.txt.
";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("pack") => cmd_pack(&args[1..]),
        Some("inspect") => cmd_inspect(&args[1..]),
        Some("process") => cmd_process(&args[1..]),
        Some("version") | Some("--version") | Some("-V") => {
            println!("hollowpack {}", env!("CARGO_PKG_VERSION"));
            return;
        }
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
    let mut emit_files: Option<String> = None;
    let mut originals: Vec<PathBuf> = Vec::new();
    let mut readme: Option<String> = None;
    let mut delivery: Option<String> = None;

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
            "--emit-files" => emit_files = Some(need_value(args, &mut i, "--emit-files")?),
            "--original" => originals.push(PathBuf::from(need_value(args, &mut i, "--original")?)),
            "--readme" => readme = Some(need_value(args, &mut i, "--readme")?),
            "--delivery" => delivery = Some(need_value(args, &mut i, "--delivery")?),
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
    if (!originals.is_empty() || readme.is_some()) && delivery.is_none() {
        return Err("--original and --readme only mean something with --delivery".into());
    }
    // The delivery's entry names are checked BEFORE any encoding runs: a bad
    // original name is a one-second refusal, an encode is not.
    let original_names = delivery_names(&originals)?;

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

    let input = PackInput {
        title,
        artist_name,
        artist_slug,
        artist_url,
        license,
        item_id,
        kinds,
        files,
    };
    let (zip_bytes, manifest) = hollowpack::build_pack(&input)?;

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

    // The processed files on their own, named by hash: what a server stores
    // under /art/<sha256> without having to open the zip it just wrote.
    if let Some(dir) = emit_files {
        std::fs::create_dir_all(&dir).map_err(|e| format!("failed to create {dir}: {e}"))?;
        for f in &input.files {
            let path = Path::new(&dir).join(format!("{}.webp", f.hash));
            std::fs::write(&path, &f.bytes)
                .map_err(|e| format!("failed to write {}: {e}", path.display()))?;
            println!("wrote {} ({} {} bytes)", path.display(), f.role.as_str(), f.bytes.len());
        }
    }

    if let Some(delivery_path) = delivery {
        let pack_name = Path::new(&out)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .filter(|n| !n.is_empty())
            .ok_or_else(|| format!("--out {out} has no file name to put in the delivery"))?;
        let readme_bytes = match &readme {
            Some(path) => Some(
                std::fs::read(path).map_err(|e| format!("failed to read the readme {path}: {e}"))?,
            ),
            None => None,
        };
        let mut original_bytes: Vec<(String, Vec<u8>)> = Vec::with_capacity(originals.len());
        for (path, name) in originals.iter().zip(original_names) {
            let bytes = std::fs::read(path)
                .map_err(|e| format!("failed to read the original {}: {e}", path.display()))?;
            original_bytes.push((name, bytes));
        }
        let delivery_bytes =
            build_delivery(&pack_name, &zip_bytes, &original_bytes, readme_bytes.as_deref())?;
        write_out(&delivery_path, &delivery_bytes)?;
        println!(
            "wrote {delivery_path} ({} bytes, the pack, {} original{}{})",
            delivery_bytes.len(),
            original_bytes.len(),
            if original_bytes.len() == 1 { "" } else { "s" },
            if readme_bytes.is_some() { ", README.txt" } else { "" }
        );
    }
    Ok(())
}

/// The entry name each `--original` takes inside the delivery zip: its
/// basename and nothing else. A path is where the file sits on THIS machine,
/// and none of that belongs in a buyer's download. An empty or all-dots name
/// is refused rather than invented, and two originals with one name would be
/// one entry overwriting the other.
fn delivery_names(originals: &[PathBuf]) -> Result<Vec<String>, String> {
    let mut names: Vec<String> = Vec::with_capacity(originals.len());
    for path in originals {
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        if name.is_empty() || name.bytes().all(|b| b == b'.') {
            return Err(format!(
                "--original {} has no usable file name",
                path.display()
            ));
        }
        if names.contains(&name) {
            return Err(format!("two originals are both called {name}"));
        }
        names.push(name);
    }
    Ok(names)
}

/// The buyer's download: the pack at the root, the originals under
/// `originals/`, the readme as `README.txt`. Pack and originals are STORED,
/// not deflated: a WebP, a PNG or a zip does not shrink again, and a store is
/// a copy. The readme is text and deflates.
fn build_delivery(
    pack_name: &str,
    pack_bytes: &[u8],
    originals: &[(String, Vec<u8>)],
    readme: Option<&[u8]>,
) -> Result<Vec<u8>, String> {
    use std::io::Write;

    let stored = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Stored);
    let deflated = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);

    let mut buf = Vec::new();
    {
        let mut zip = zip::ZipWriter::new(std::io::Cursor::new(&mut buf));
        zip.start_file(pack_name, stored)
            .map_err(|e| format!("failed to start the pack entry: {e}"))?;
        zip.write_all(pack_bytes)
            .map_err(|e| format!("failed to write the pack entry: {e}"))?;
        for (name, bytes) in originals {
            zip.start_file(format!("originals/{name}"), stored)
                .map_err(|e| format!("failed to start originals/{name}: {e}"))?;
            zip.write_all(bytes)
                .map_err(|e| format!("failed to write originals/{name}: {e}"))?;
        }
        if let Some(text) = readme {
            zip.start_file("README.txt", deflated)
                .map_err(|e| format!("failed to start README.txt: {e}"))?;
            zip.write_all(text)
                .map_err(|e| format!("failed to write README.txt: {e}"))?;
        }
        zip.finish()
            .map_err(|e| format!("failed to finish the delivery: {e}"))?;
    }
    Ok(buf)
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
