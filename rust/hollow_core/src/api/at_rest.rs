//! Dart's only way to touch a content file under the data root (issue 78).
//!
//! Reads and exports accept a source outside the data root and pass it through,
//! so Dart has one primitive; anything that WRITES or hands out a URL refuses a
//! path outside it.

use flutter_rust_bridge::frb;

use crate::node::{at_rest, at_rest_server};

/// Progress of the one-per-boot sweep that protects files an older version left
/// in plaintext.
pub struct AtRestStatus {
    pub total: u32,
    pub done: u32,
    pub failed: u32,
    pub running: bool,
}

#[frb(ignore)]
const OUTSIDE_ROOT: &str = "Path is outside the Hollow data folder";

/// Resolve `path` and prove it lands under the data root, walking up to the deepest
/// ancestor that EXISTS: neither the file nor its folders need exist yet, and a raw
/// path never matches a canonical root on Windows, where canonicalize adds a prefix.
#[frb(ignore)]
fn under_data_root(path: &str) -> Result<std::path::PathBuf, String> {
    let root = crate::identity::data_dir()?;
    let root = std::fs::canonicalize(&root).unwrap_or(root);
    let p = std::path::PathBuf::from(path);

    let mut anchor = p.as_path();
    while !anchor.exists() {
        // `file_name` is None for `..`, a root and a prefix, so no component below
        // the anchor can climb out.
        if anchor.file_name().is_none() {
            return Err(OUTSIDE_ROOT.to_string());
        }
        let Some(parent) = anchor.parent() else {
            return Err(OUTSIDE_ROOT.to_string());
        };
        anchor = parent;
    }
    let anchor = std::fs::canonicalize(anchor).map_err(|e| format!("Failed to resolve path: {e}"))?;
    if !anchor.starts_with(&root) {
        return Err(OUTSIDE_ROOT.to_string());
    }
    Ok(p)
}

#[frb]
pub fn read_at_rest(path: String) -> Result<Vec<u8>, String> {
    at_rest::read_all(std::path::Path::new(&path))
}

#[frb]
pub fn read_at_rest_range(path: String, offset: u64, len: u32) -> Result<Vec<u8>, String> {
    at_rest::read_range(std::path::Path::new(&path), offset, len as usize)
}

#[frb]
pub fn write_at_rest(path: String, bytes: Vec<u8>) -> Result<(), String> {
    let p = under_data_root(&path)?;
    at_rest::write_all(&p, &bytes)
}

#[frb]
pub fn remove_at_rest(path: String) -> Result<(), String> {
    let p = under_data_root(&path)?;
    at_rest::remove(&p)
}

#[frb]
pub fn export_at_rest(src_path: String, dest_path: String) -> Result<u64, String> {
    at_rest::export_to(
        std::path::Path::new(&src_path),
        std::path::Path::new(&dest_path),
    )
}

#[frb]
pub fn at_rest_plaintext_len(path: String) -> Result<u64, String> {
    at_rest::plaintext_len(std::path::Path::new(&path))
}

#[frb]
pub fn at_rest_media_url(path: String) -> Result<String, String> {
    let p = under_data_root(&path)?;
    at_rest_server::media_url(&p)
}

#[frb]
pub fn at_rest_status() -> AtRestStatus {
    let s = at_rest::status();
    AtRestStatus { total: s.total, done: s.done, failed: s.failed, running: s.running }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn at_rest_write_under_a_not_yet_existing_subdir_is_allowed() {
        let _g = crate::node::resolver::test_lock();
        let dir = tempfile::tempdir().expect("tempdir");
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", dir.path()) };
        at_rest::reset_for_test();
        let db = dir.path().join("messages.db").to_string_lossy().to_string();
        at_rest::init(&db, &"3f".repeat(32)).expect("ring");

        let nested = dir.path().join("newdir").join("sub").join("x.bin");
        let data = b"a first write into a folder nobody has created yet".to_vec();
        write_at_rest(nested.to_string_lossy().to_string(), data.clone())
            .expect("a new subfolder under the data root is writable");
        assert_eq!(
            read_at_rest(nested.to_string_lossy().to_string()).expect("read back"),
            data,
        );

        let up = dir.path().join("..").join("x.bin");
        assert!(
            write_at_rest(up.to_string_lossy().to_string(), vec![1]).is_err(),
            "a path climbing out of the root is refused",
        );
        let through = dir.path().join("newdir").join("..").join("..").join("x.bin");
        assert!(
            write_at_rest(through.to_string_lossy().to_string(), vec![1]).is_err(),
            "climbing out through an existing subfolder is refused",
        );
    }
}
