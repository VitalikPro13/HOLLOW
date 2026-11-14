//! Zip files outlive the `zip` crate version that wrote them: a backup, link snapshot,
//! archive, sticker pack, `.hollowpack` or shard bundle made today must still open after
//! a bump. `write_zip_fixtures` writes one of each with this build into
//! `HOLLOW_ZIP_FIXTURES`; `zip_fixtures_still_load`, run on the bumped build, reads every
//! file there back through the real import path (plus any `.zip` dropped in by hand, such
//! as a release zip, through the updater) and writes `results.txt` beside them.

use std::path::{Path, PathBuf};

use crate::identity::native_identity::NativeKeypair;
use crate::storage::MessageStore;

const PASS: &str = "zip compat fixture passphrase";
const SERVER: &str = "zipcompatsrv";
const CHANNEL: &str = "general";
const FILE_ID: &str = "0123456789abcdef0123456789abcdef";

fn fixture_dir() -> PathBuf {
    PathBuf::from(std::env::var("HOLLOW_ZIP_FIXTURES").expect("set HOLLOW_ZIP_FIXTURES to a folder"))
}

/// Points the data root at `root` with the identity `seed`, and returns the keypair.
fn data_root(root: &Path, seed: u8) -> NativeKeypair {
    std::fs::create_dir_all(root).unwrap();
    // SAFETY: serialized by the callers' locks.
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", root) };
    crate::identity::encryption::clear_session_key();
    let master = NativeKeypair::from_secret_bytes(&[seed; 32]);
    std::fs::write(root.join("identity.key"), master.to_protobuf_encoding().unwrap()).unwrap();
    let db = root.join("messages.db");
    let pass = crate::api::storage::derive_db_key_public().unwrap();
    MessageStore::migrate_auto_vacuum_once(db.to_str().unwrap(), &pass).unwrap();
    crate::api::storage::set_test_store(MessageStore::open(db.to_str().unwrap(), &pass).unwrap());
    master
}

fn with_store<T>(body: impl FnOnce(&MessageStore) -> T) -> T {
    let guard = crate::api::storage::get_store().lock().unwrap_or_else(|e| e.into_inner());
    body(guard.as_ref().expect("store installed"))
}

fn png(side: u32) -> Vec<u8> {
    let mut img = image::RgbaImage::new(side, side);
    for (x, y, px) in img.enumerate_pixels_mut() {
        *px = image::Rgba([(x * 4) as u8, (y * 4) as u8, 140, 255]);
    }
    let mut out = Vec::new();
    image::DynamicImage::ImageRgba8(img)
        .write_to(&mut std::io::Cursor::new(&mut out), image::ImageFormat::Png)
        .unwrap();
    out
}

/// A zip laid out as Compress-Archive and .NET write release zips: backslash names, a
/// directory entry with a trailing backslash, a top folder the updater strips.
fn release_style_zip(backslash: bool) -> Vec<u8> {
    use std::io::Write;
    let sep = if backslash { "\\" } else { "/" };
    let mut out = std::io::Cursor::new(Vec::new());
    let mut z = zip::ZipWriter::new(&mut out);
    let opts = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    z.start_file(format!("Hollow{sep}data{sep}flutter_assets{sep}packages{sep}"), opts).unwrap();
    z.start_file(format!("Hollow{sep}hollow.exe"), opts).unwrap();
    z.write_all(&[0x4d; 4096]).unwrap();
    z.start_file(format!("Hollow{sep}data{sep}flutter_assets{sep}kernel_blob.bin"), opts).unwrap();
    z.write_all(b"blob").unwrap();
    z.finish().unwrap();
    out.into_inner()
}

#[test]
#[ignore = "writes fixtures for a zip crate bump; HOLLOW_ZIP_FIXTURES=<dir>"]
fn write_zip_fixtures() {
    use std::io::Write;
    let out = fixture_dir();
    std::fs::create_dir_all(&out).unwrap();
    let _g = crate::node::resolver::test_lock();
    let _s = crate::api::storage::store_test_lock();
    let tmp = crate::test_tmp::tempdir().unwrap();
    let root = tmp.path().join("data");
    let keypair = data_root(&root, 0x5a);

    // A channel with a message, its attachment on disk and a vault shard file.
    let attachment = png(32);
    std::fs::create_dir_all(root.join("files")).unwrap();
    std::fs::write(root.join("files").join(format!("{FILE_ID}.png")), &attachment).unwrap();
    std::fs::create_dir_all(root.join("vault")).unwrap();
    std::fs::write(root.join("vault").join("cafe01.shard"), [7u8; 300]).unwrap();
    with_store(|s| {
        s.insert_channel_message(
            SERVER, CHANNEL, &keypair.peer_id(), "hello **zip**", true, 1_700_000_000_000,
            None, None, Some("mid-zip-1"), None, Some(FILE_ID), Some(1_700_000_000_000_000), None,
        )
        .unwrap();
        s.insert_file_metadata(
            FILE_ID, "picture.png", "png", "image/png", attachment.len() as u64, 1, true, Some(32), Some(32),
            Some("mid-zip-1"), "channel", &format!("{SERVER}:{CHANNEL}"), &keypair.peer_id(), true,
            1_700_000_000_000, None, None, None,
        )
        .unwrap();
        s.wal_checkpoint().unwrap();
    });

    std::fs::write(out.join("snapshot.zip"), crate::api::storage::build_snapshot_bytes(true, true).unwrap()).unwrap();
    std::fs::write(out.join("backup.hollow"), crate::api::storage::export_backup_bytes(PASS, true, true).unwrap()).unwrap();

    use crate::archive::types::{ArchiveTarget, FileMode};
    for (name, target, mode) in [
        (
            "channel_full.hollow-archive",
            ArchiveTarget::Channel { server_id: SERVER.into(), channel_id: CHANNEL.into(), channel_name: Some("general".into()) },
            FileMode::Full,
        ),
        (
            "server_placeholder.hollow-archive",
            ArchiveTarget::Server { server_id: SERVER.into(), server_name: "Zip".into(), channels: vec![(CHANNEL.into(), "general".into())] },
            FileMode::Placeholder,
        ),
    ] {
        let bytes = with_store(|s| crate::archive::exporter::export_archive(s, &keypair, target, mode, &root)).unwrap();
        std::fs::write(out.join(name), bytes).unwrap();
    }

    let sticker = crate::api::stickers::process_and_store_sticker(png(64)).unwrap();
    crate::api::stickers::add_personal_sticker(
        "Zip pack".into(), sticker.hash, "square".into(), sticker.animated, sticker.w, sticker.h, "upload".into(),
    )
    .unwrap();
    crate::api::stickers::export_personal_sticker_pack(
        "Zip pack".into(),
        out.join("stickers.hollow-pack").to_string_lossy().into_owned(),
    )
    .unwrap();

    let files = crate::hollowpack::process_source(crate::hollowpack::RoleHint::Avatar, &png(64)).unwrap();
    let (pack, _) = crate::hollowpack::build_pack(&crate::hollowpack::PackInput {
        title: "Zip compat".into(),
        artist_name: "Fixture".into(),
        artist_slug: "fixture".into(),
        artist_url: "https://example.invalid/fixture".into(),
        license: "test".into(),
        item_id: None,
        kinds: vec!["avatar".into()],
        files,
    })
    .unwrap();
    std::fs::write(out.join("art.hollowpack"), pack).unwrap();

    // A vault shard with its manifest, opened the way the shard export opens the store.
    {
        let proto = keypair.to_protobuf_encoding().unwrap();
        let store = crate::vault::content_store::ContentStore::open(
            root.join("messages.db").to_str().unwrap(),
            &hex::encode(&proto[..32]),
            &root.join("vault"),
        )
        .unwrap();
        let shard = [9u8; 512];
        let cid = hex::encode(<sha2::Sha256 as sha2::Digest>::digest(shard));
        let manifest = crate::vault::pipeline::VaultManifest {
            content_id: cid.clone(),
            encryption_key: "00".repeat(32),
            nonce: "00".repeat(12),
            original_size: 512,
            k: 0,
            m: 0,
            shard_count: 1,
            file_name: "shard.bin".into(),
            mime_type: "application/octet-stream".into(),
            storage_tier: "standard".into(),
            created_at: 1_700_000_000,
            creator_peer_id: keypair.peer_id(),
            channel_id: CHANNEL.into(),
            message_id: "mid-zip-1".into(),
            shard_hashes: Vec::new(),
        };
        store.save_manifest(SERVER, CHANNEL, &manifest).unwrap();
        store
            .store_shard(SERVER, &cid, 0, 0, 0, 512, crate::vault::content_store::StorageTier::from_str("standard"), &shard)
            .unwrap();
    }
    crate::api::archive::export_server_shards(
        SERVER.into(),
        out.join("server.hollow-shards").to_string_lossy().into_owned(),
    )
    .unwrap();

    write_hostile(&out.join("hostile"), &std::fs::read(out.join("snapshot.zip")).unwrap());
    std::fs::write(out.join("release_backslash.zip"), release_style_zip(true)).unwrap();
    std::fs::write(out.join("release_slash.zip"), release_style_zip(false)).unwrap();
    let mut stamp = std::fs::File::create(out.join("written_by.txt")).unwrap();
    writeln!(stamp, "{}", env!("CARGO_PKG_VERSION")).unwrap();
}

/// Reads one fixture through the path the app imports it by; `Ok` names what landed.
fn load_one(path: &Path, work: &Path) -> Result<String, String> {
    let name = path.file_name().unwrap().to_string_lossy().into_owned();
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    let fresh = |tag: &str| {
        let root = work.join(tag);
        // SAFETY: serialized by the caller's locks.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &root) };
        std::fs::create_dir_all(&root).unwrap();
        crate::identity::encryption::clear_session_key();
        root
    };
    let landed = |root: &Path| -> Result<String, String> {
        let key = NativeKeypair::from_secret_bytes(&[0x5a; 32]).to_protobuf_encoding().unwrap();
        if std::fs::read(root.join("identity.key")).map_err(|e| e.to_string())? != key {
            return Err("identity.key differs".into());
        }
        let files = std::fs::read_dir(root.join("files")).map(|d| d.count()).unwrap_or(0);
        let vault = std::fs::read_dir(root.join("vault")).map(|d| d.count()).unwrap_or(0);
        if !root.join("messages.db").exists() || files == 0 || vault == 0 {
            return Err(format!("landed incomplete: files {files}, vault {vault}"));
        }
        let pass = crate::api::storage::derive_db_key_public()?;
        let store = MessageStore::open(root.join("messages.db").to_str().unwrap(), &pass)?;
        let rows = store.load_channel_messages(SERVER, CHANNEL, 10)?;
        if !rows.iter().any(|m| m.text == "hello **zip**") {
            return Err("the landed database lost its channel row".into());
        }
        store.save_setting("written_after_landing", "yes")?;
        Ok(format!("identity + messages.db (rows read, a row written) + {files} file(s) + {vault} vault file(s) landed"))
    };
    if name == "snapshot.zip" {
        if !crate::api::storage::fuzz_check_snapshot(&bytes) {
            return Err("check_snapshot refused it".into());
        }
        let root = fresh("snapshot");
        crate::api::storage::import_snapshot_bytes(&bytes)?;
        return landed(&root);
    }
    if name.ends_with(".hollow") {
        let root = fresh("backup");
        crate::api::storage::import_backup_bytes(&bytes, PASS)?;
        return landed(&root);
    }
    if name.ends_with(".hollow-archive") {
        let loaded = crate::archive::loader::load_archive(&bytes)?;
        if !loaded.archive_signature_valid || loaded.messages.is_empty() {
            return Err(format!("signature valid {}, {} messages", loaded.archive_signature_valid, loaded.messages.len()));
        }
        let unpacked = loaded.files_dir.as_ref().and_then(|d| std::fs::read_dir(d).ok()).map(|d| d.count()).unwrap_or(0);
        let included = loaded.file_metadata.iter().filter(|f| f.included).count();
        if included != unpacked {
            return Err(format!("{included} attachment(s) listed, {unpacked} unpacked"));
        }
        return Ok(format!(
            "format {}, signature valid, {} message(s), {unpacked} attachment(s) unpacked",
            loaded.manifest.format_version,
            loaded.messages.len(),
        ));
    }
    if name.ends_with(".hollow-pack") {
        fresh("stickers");
        data_root(&work.join("stickers"), 0x5b);
        let p = path.to_string_lossy().into_owned();
        let preview = crate::api::stickers::preview_sticker_pack(p.clone())?;
        let got = crate::api::stickers::import_sticker_pack(p, String::new())?;
        if !preview.author_verified || got.added != preview.count || got.rejected != 0 {
            return Err(format!("verified {}, {} of {} added, {} rejected", preview.author_verified, got.added, preview.count, got.rejected));
        }
        return Ok(format!("author verified, {} sticker(s) added", got.added));
    }
    if name.ends_with(".hollowpack") {
        let v = crate::hollowpack::verify_pack(&bytes)?;
        return Ok(format!("verified, {} file(s)", v.files.len()));
    }
    if name.ends_with(".hollow-shards") {
        data_root(&work.join("shards"), 0x5c);
        let got = crate::api::archive::import_server_shards(path.to_string_lossy().into_owned())?;
        if got.manifests_imported == 0 || got.shards_imported == 0 {
            return Err(format!("{} manifest(s), {} shard(s) imported", got.manifests_imported, got.shards_imported));
        }
        return Ok(format!(
            "{} manifest(s), {} shard(s) imported",
            got.manifests_imported, got.shards_imported
        ));
    }
    if name.ends_with(".zip") {
        let staging = work.join(format!("staging-{name}"));
        std::fs::create_dir_all(&staging).unwrap();
        crate::api::updater::extract_zip_to(&path.to_string_lossy(), &staging)?;
        let mut count = 0usize;
        let mut stack = vec![staging];
        while let Some(dir) = stack.pop() {
            for e in std::fs::read_dir(dir).unwrap().flatten() {
                if e.path().is_dir() {
                    stack.push(e.path());
                } else {
                    count += 1;
                }
            }
        }
        return if count > 0 { Ok(format!("{count} file(s) extracted")) } else { Err("nothing extracted".into()) };
    }
    Err("no import path for this name".into())
}

#[test]
#[ignore = "reads fixtures after a zip crate bump; HOLLOW_ZIP_FIXTURES=<dir>"]
fn zip_fixtures_still_load() {
    use std::io::Write;
    let dir = fixture_dir();
    let _g = crate::node::resolver::test_lock();
    let _s = crate::api::storage::store_test_lock();
    let mut names: Vec<PathBuf> = std::fs::read_dir(&dir)
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_file() && !p.extension().is_some_and(|x| x == "txt"))
        .collect();
    names.sort();
    assert!(!names.is_empty(), "no fixtures in {}", dir.display());
    let mut report = std::fs::File::create(dir.join("results.txt")).unwrap();
    let mut failed = Vec::new();
    for path in &names {
        let work = crate::test_tmp::tempdir().unwrap();
        let outcome = load_one(path, work.path());
        let name = path.file_name().unwrap().to_string_lossy();
        match &outcome {
            Ok(what) => writeln!(report, "PASS {name}: {what}").unwrap(),
            Err(why) => {
                writeln!(report, "FAIL {name}: {why}").unwrap();
                failed.push(name.into_owned());
            }
        }
    }
    assert!(failed.is_empty(), "refused: {failed:?} (see results.txt)");
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &b in data {
        crc ^= u32::from(b);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xEDB8_8320 & (crc & 1).wrapping_neg());
        }
    }
    !crc
}

/// A zip of STORED entries with names, methods and flags written as given, which
/// `ZipWriter` refuses to produce.
fn raw_zip(entries: &[(&[u8], &[u8], u16, u16)]) -> Vec<u8> {
    let (mut out, mut central) = (Vec::new(), Vec::new());
    for (name, data, method, flags) in entries {
        let offset = out.len() as u32;
        let crc = crc32(data);
        let head = |sig: u32, central: bool| {
            let mut h = Vec::new();
            h.extend_from_slice(&sig.to_le_bytes());
            if central {
                h.extend_from_slice(&20u16.to_le_bytes());
            }
            h.extend_from_slice(&20u16.to_le_bytes());
            h.extend_from_slice(&flags.to_le_bytes());
            h.extend_from_slice(&method.to_le_bytes());
            h.extend_from_slice(&[0; 4]);
            h.extend_from_slice(&crc.to_le_bytes());
            h.extend_from_slice(&(data.len() as u32).to_le_bytes());
            h.extend_from_slice(&(data.len() as u32).to_le_bytes());
            h.extend_from_slice(&(name.len() as u16).to_le_bytes());
            h.extend_from_slice(&0u16.to_le_bytes());
            if central {
                h.extend_from_slice(&[0; 6]);
                h.extend_from_slice(&0u32.to_le_bytes());
                h.extend_from_slice(&offset.to_le_bytes());
            }
            h.extend_from_slice(name);
            h
        };
        out.extend(head(0x0403_4b50, false));
        out.extend_from_slice(data);
        central.extend(head(0x0201_4b50, true));
    }
    let start = out.len() as u32;
    out.extend_from_slice(&central);
    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
    out.extend_from_slice(&[0; 4]);
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&(central.len() as u32).to_le_bytes());
    out.extend_from_slice(&start.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out
}

type Writer<'a> = zip::ZipWriter<&'a mut std::io::Cursor<Vec<u8>>>;

/// Zips every import path must refuse, written by this build for the next one.
fn write_hostile(dir: &Path, snapshot: &[u8]) {
    use std::io::Write;
    std::fs::create_dir_all(dir).unwrap();
    let key: &[u8] = b"key";
    let put = |name: &str, bytes: Vec<u8>| std::fs::write(dir.join(name), bytes).unwrap();
    put("traversal.zip", raw_zip(&[(b"identity.key", key, 0, 0), (b"../identity.key", key, 0, 0)]));
    put("absolute.zip", raw_zip(&[(b"identity.key", key, 0, 0), (b"/tmp/hollow_zip_planted", key, 0, 0)]));
    put("backslash_traversal.zip", raw_zip(&[(b"identity.key", key, 0, 0), (b"files\\..\\..\\planted.exe", key, 0, 0)]));
    put("drive.zip", raw_zip(&[(b"identity.key", key, 0, 0), (b"C:\\planted.exe", key, 0, 0)]));
    put("nul_name.zip", raw_zip(&[(b"identity.key", key, 0, 0), (b"files/a\0b.png", key, 0, 0)]));
    put("duplicate.zip", raw_zip(&[(b"identity.key", key, 0, 0), (b"identity.key", b"other", 0, 0)]));
    put("method_99.zip", raw_zip(&[(b"identity.key", key, 99, 0)]));
    put("encrypted_flag.zip", raw_zip(&[(b"identity.key", key, 0, 1)]));
    put("truncated.zip", snapshot[..snapshot.len() / 2].to_vec());
    put("garbage.zip", vec![0x50, 0x4b, 0x05, 0x06, 0xff, 0x00, 0x13, 0x37]);
    let writer = |entries: &dyn Fn(&mut Writer<'_>)| {
        let mut out = std::io::Cursor::new(Vec::new());
        let mut z = zip::ZipWriter::new(&mut out);
        entries(&mut z);
        z.finish().unwrap();
        out.into_inner()
    };
    let opts = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    put(
        "foreign_entry.zip",
        writer(&|z| {
            z.start_file("identity.key", opts).unwrap();
            z.write_all(b"key").unwrap();
            z.start_file("profiles.json", opts).unwrap();
            z.write_all(b"{}").unwrap();
        }),
    );
    put(
        "symlink.zip",
        writer(&|z| {
            z.start_file("identity.key", opts).unwrap();
            z.write_all(b"key").unwrap();
            z.add_symlink("files/link.png", "../../identity.key", opts).unwrap();
        }),
    );
    put(
        "bomb.zip",
        writer(&|z| {
            z.start_file("identity.key", opts).unwrap();
            z.write_all(b"key").unwrap();
            z.start_file("messages.db", opts.large_file(true)).unwrap();
            let zeros = vec![0u8; 1 << 20];
            for _ in 0..400 {
                z.write_all(&zeros).unwrap();
            }
        }),
    );
}

/// What every import path answers to one hostile zip, so two builds can be compared.
fn hostile_answers(path: &Path, work: &Path) -> Vec<String> {
    let bytes = std::fs::read(path).unwrap();
    let short = |r: Result<String, String>| match r {
        Ok(v) => format!("ACCEPTED {v}"),
        Err(e) => format!("refused: {e}"),
    };
    let p = path.to_string_lossy().into_owned();
    let staging = work.join("staging");
    std::fs::create_dir_all(&staging).unwrap();
    data_root(&work.join("root"), 0x5d);
    vec![
        format!("snapshot   {}", if crate::api::storage::fuzz_check_snapshot(&bytes) { "ACCEPTED".into() } else { short(crate::api::storage::import_snapshot_bytes(&bytes).map(|_| "landed".into())) }),
        format!("archive    {}", short(crate::archive::loader::load_archive(&bytes).map(|l| format!("{} messages", l.messages.len())))),
        format!("stickers   {}", short(crate::api::stickers::import_sticker_pack(p.clone(), String::new()).map(|r| format!("{} added", r.added)))),
        format!("hollowpack {}", short(crate::hollowpack::verify_pack(&bytes).map(|v| format!("{} files", v.files.len())))),
        format!("shards     {}", short(crate::api::archive::import_server_shards(p.clone()).map(|r| format!("{} shards", r.shards_imported)))),
        format!("updater    {}", short(crate::api::updater::extract_zip_to(&p, &staging).map(|_| "extracted".into()))),
    ]
}

#[test]
#[ignore = "records how every import path refuses hostile zips; HOLLOW_ZIP_FIXTURES=<dir>"]
fn hostile_zip_answers() {
    use std::io::Write;
    let dir = fixture_dir().join("hostile");
    let _g = crate::node::resolver::test_lock();
    let _s = crate::api::storage::store_test_lock();
    let mut names: Vec<PathBuf> = std::fs::read_dir(&dir).unwrap().flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "zip")).collect();
    names.sort();
    let mut report = std::fs::File::create(dir.join("answers.txt")).unwrap();
    for path in &names {
        let work = crate::test_tmp::tempdir().unwrap();
        writeln!(report, "== {}", path.file_name().unwrap().to_string_lossy()).unwrap();
        for line in hostile_answers(path, work.path()) {
            writeln!(report, "  {line}").unwrap();
        }
    }
    assert!(!std::path::Path::new("/tmp/hollow_zip_planted").exists(), "an absolute entry landed");
}
