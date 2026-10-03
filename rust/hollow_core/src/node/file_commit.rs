//! Self-certifying file ids: a file sent on 0.12 or later is named by the hash of its
//! author, its message and its content, so its bytes prove themselves to a receiver
//! whoever delivers them.
//!
//! The message signature binds the file id and the id binds author, message id, size,
//! SHA-256, name, extension and the vault video a thumbnail stands for, so the
//! author's one signature covers all of them. The id also names its author, so no one
//! else can claim it for a card of their own. Older ids are 32 random hex characters;
//! the 64-character length tells the two apart, so a holder cannot downgrade a new
//! file by leaving its commitment out.

use super::types::VideoThumbRef;
use sha2::{Digest, Sha256};

/// Hex length of a committed id (all of SHA-256).
const COMMITTED_ID_LEN: usize = 64;

/// What a committed file id is the hash of.
#[derive(Clone, Copy, Debug)]
pub(crate) struct FileCommit<'a> {
    /// Master peer id of the message's signer.
    pub author: &'a str,
    pub mid: &'a str,
    pub size: u64,
    /// Lowercase hex SHA-256 of the plaintext.
    pub sha256: &'a str,
    pub name: &'a str,
    pub ext: &'a str,
    /// The vault video this file is the thumbnail of.
    pub vthumb: Option<&'a VideoThumbRef>,
}

/// Lowercase hex SHA-256 of `bytes`.
pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn is_lower_hex(s: &str, len: usize) -> bool {
    s.len() == len && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The id a file with this commitment must carry.
pub(crate) fn file_id_for(c: &FileCommit) -> String {
    let mut h = Sha256::new();
    h.update(b"hollow-file1\0");
    for field in [c.author, c.mid] {
        h.update((field.len() as u32).to_be_bytes());
        h.update(field.as_bytes());
    }
    h.update(c.size.to_be_bytes());
    for field in [c.sha256, c.name, c.ext] {
        h.update((field.len() as u32).to_be_bytes());
        h.update(field.as_bytes());
    }
    match c.vthumb {
        None => h.update([0u8]),
        Some(v) => {
            h.update([1u8]);
            for field in [&v.cid, &v.ext, &v.name] {
                h.update((field.len() as u32).to_be_bytes());
                h.update(field.as_bytes());
            }
            h.update(v.size.to_be_bytes());
            h.update(v.dur_ms.to_be_bytes());
        }
    }
    hex::encode(h.finalize())
}

/// Whether `fid` has the committed shape, which obliges every claim about it to hash
/// to it.
pub(crate) fn is_committed_id(fid: &str) -> bool {
    is_lower_hex(fid, COMMITTED_ID_LEN)
}

/// Why a claim about `fid` may not stand, `None` when it may. An older id carries no
/// commitment and is judged by the delivery gates alone.
pub(crate) fn claim_refused(fid: &str, commit: Option<&FileCommit>) -> Option<&'static str> {
    if !is_committed_id(fid) {
        return None;
    }
    match commit {
        None => Some("a committed file id arrived without its commitment"),
        Some(c) if !is_lower_hex(c.sha256, 64) || file_id_for(c) != fid => {
            Some("the file id does not commit to this author, message and content")
        }
        Some(_) => None,
    }
}

/// Why a FileHeader's claim about its file may not stand. A committed id must come
/// with the commitment it hashes from, and unasked only from a device of the author
/// it names: anyone else holding the key would be delivering a file that is not
/// theirs to announce.
#[allow(clippy::too_many_arguments)]
pub(crate) fn header_claim_refused(
    fid: &str,
    author: Option<&str>,
    mid: Option<&str>,
    size: u64,
    sha256: Option<&str>,
    name: &str,
    ext: &str,
    vthumb: Option<&VideoThumbRef>,
    sender: &str,
    asked: bool,
) -> Option<&'static str> {
    if !is_committed_id(fid) {
        return None;
    }
    let (Some(author), Some(mid), Some(sha256)) = (author, mid, sha256) else {
        return claim_refused(fid, None);
    };
    let commit = FileCommit { author, mid, size, sha256, name, ext, vthumb };
    if let Some(reason) = claim_refused(fid, Some(&commit)) {
        return Some(reason);
    }
    (!asked && super::resolver::resolve(sender) != author)
        .then_some("only the author's own devices announce its file unasked")
}

/// Why `len` bytes hashing to `sha256` may not complete the file `row` describes,
/// `None` when they may. A committed row holds exactly the fields its id hashed from,
/// so the bytes must hash back to it with them.
pub(crate) fn content_refused(
    row: &crate::storage::StoredFile,
    len: u64,
    sha256: &str,
) -> Option<&'static str> {
    if !is_committed_id(&row.file_id) {
        return None;
    }
    let Some(mid) = row.message_id.as_deref() else {
        return Some("the file card names no message to check the bytes against");
    };
    let author = super::resolver::resolve(&row.sender_id);
    let commit = FileCommit {
        author: &author, mid, size: len, sha256,
        name: &row.file_name, ext: &row.file_ext, vthumb: row.video_thumb.as_ref(),
    };
    (file_id_for(&commit) != row.file_id).then_some("the bytes are not the ones the file id commits to")
}

/// Why a vault download's plaintext may not stand for the cards linked to its content
/// id. A thumbnail's card commits to the video's content id, which reconstruction
/// already checks against the ciphertext; any other card must hash to the bytes.
pub(crate) fn vault_plaintext_refused(
    store: &crate::storage::MessageStore,
    content_id: &str,
    plaintext: &[u8],
) -> Option<&'static str> {
    let rows = store.files_with_content_id(content_id).unwrap_or_default();
    let sha256 = rows.iter().any(|r| is_committed_id(&r.file_id)).then(|| sha256_hex(plaintext));
    rows.iter()
        .filter(|r| r.video_thumb.as_ref().is_none_or(|v| v.cid != content_id))
        .find_map(|r| content_refused(r, plaintext.len() as u64, sha256.as_deref().unwrap_or("")))
}

/// Why these plaintext bytes may not complete `fid`, `None` when they may. The ONE
/// check every completion path runs before `mark_file_complete`.
pub(crate) fn completion_refused(
    store: &crate::storage::MessageStore,
    fid: &str,
    plaintext: &[u8],
) -> Option<&'static str> {
    if !is_committed_id(fid) {
        return None;
    }
    completion_refused_hashed(store, fid, plaintext.len() as u64, &sha256_hex(plaintext))
}

/// [`completion_refused`] for bytes already hashed off the event loop.
pub(crate) fn completion_refused_hashed(
    store: &crate::storage::MessageStore,
    fid: &str,
    len: u64,
    sha256: &str,
) -> Option<&'static str> {
    if !is_committed_id(fid) {
        return None;
    }
    match store.get_file_metadata(fid) {
        Ok(Some(row)) => content_refused(&row, len, sha256),
        _ => Some("no file card to check the bytes against"),
    }
}

/// Length and SHA-256 of a file's plaintext on disk, read through the at-rest layer
/// a slice at a time so a large share download never sits in memory.
pub(crate) fn hash_at_rest(path: &std::path::Path) -> Option<(u64, String)> {
    const SLICE: usize = 4 * 1024 * 1024;
    let len = super::at_rest::plaintext_len(path).ok()?;
    let mut h = Sha256::new();
    let mut offset = 0u64;
    while offset < len {
        let want = SLICE.min((len - offset) as usize);
        let chunk = super::at_rest::read_range(path, offset, want).ok()?;
        if chunk.len() != want {
            return None;
        }
        h.update(&chunk);
        offset += want as u64;
    }
    Some((len, hex::encode(h.finalize())))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn commit<'a>(sha: &'a str) -> FileCommit<'a> {
        FileCommit { author: "alice", mid: "m1", size: 3, sha256: sha, name: "a.png", ext: "png", vthumb: None }
    }

    #[test]
    fn a_committed_id_binds_every_field() {
        let sha = sha256_hex(b"abc");
        let base = commit(&sha);
        let fid = file_id_for(&base);
        assert!(is_committed_id(&fid));
        assert_eq!(claim_refused(&fid, Some(&base)), None);
        let other_sha = sha256_hex(b"abd");
        let video = VideoThumbRef { cid: "c".repeat(64), ext: "mp4".into(), name: "v.mp4".into(), size: 9, dur_ms: 1 };
        let variants = [
            FileCommit { author: "mallory", ..base },
            FileCommit { mid: "m2", ..base },
            FileCommit { size: 4, ..base },
            FileCommit { sha256: &other_sha, ..base },
            FileCommit { name: "b.png", ..base },
            FileCommit { ext: "exe", ..base },
            // A boundary moved between two fields is a different commitment.
            FileCommit { name: "a.pngp", ext: "ng", ..base },
            FileCommit { vthumb: Some(&video), ..base },
        ];
        for v in variants {
            assert!(claim_refused(&fid, Some(&v)).is_some(), "{v:?} kept the id");
        }
        assert!(claim_refused(&fid, None).is_some(), "a committed id without its commitment");
    }

    #[test]
    fn an_old_id_is_judged_by_the_delivery_gates_alone() {
        let legacy = crate::node::file_transfer::generate_file_id();
        assert!(!is_committed_id(&legacy));
        assert_eq!(claim_refused(&legacy, None), None);
        let upper = file_id_for(&commit(&sha256_hex(b"abc"))).to_uppercase();
        assert!(!is_committed_id(&upper), "one spelling per id");
    }

    /// A committed card as the receiver stores it, in a fresh store.
    fn card_store(bytes: &[u8], vthumb: Option<&VideoThumbRef>) -> (tempfile::TempDir, crate::storage::MessageStore, String) {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("c.db").to_string_lossy().into_owned();
        let store = crate::storage::MessageStore::open(&path, &"ab".repeat(32)).unwrap();
        let sha = sha256_hex(bytes);
        let fid = file_id_for(&FileCommit {
            author: "alice", mid: "m1", size: bytes.len() as u64, sha256: &sha, name: "a.bin", ext: "bin", vthumb,
        });
        store.insert_file_metadata(
            &fid, "a.bin", "bin", "application/octet-stream", bytes.len() as u64, 0, false, None, None,
            Some("m1"), "channel", "srv:gen", "alice", false, 1, vthumb, None, Some(&sha),
        ).unwrap();
        (tmp, store, fid)
    }

    #[test]
    fn a_card_completes_only_with_its_own_bytes() {
        let _g = crate::node::resolver::test_lock();
        let (_tmp, store, fid) = card_store(b"real", None);
        assert_eq!(completion_refused(&store, &fid, b"real"), None);
        assert!(completion_refused(&store, &fid, b"fake").is_some(), "other bytes of the same size");
        assert!(completion_refused(&store, &fid, b"real!").is_some(), "a longer file");
        let unknown = file_id_for(&commit(&sha256_hex(b"abc")));
        assert!(completion_refused(&store, &unknown, b"abc").is_some(), "no card, nothing to check against");
    }

    #[test]
    fn a_share_download_is_hashed_in_slices() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("big.bin");
        let bytes: Vec<u8> = (0..4 * 1024 * 1024 + 7).map(|i| (i % 251) as u8).collect();
        std::fs::write(&path, &bytes).unwrap();
        assert_eq!(hash_at_rest(&path), Some((bytes.len() as u64, sha256_hex(&bytes))));
        assert_eq!(hash_at_rest(&tmp.path().join("absent.bin")), None);
    }

    #[test]
    fn vault_bytes_answer_to_the_cards_they_stand_for() {
        let _g = crate::node::resolver::test_lock();
        let cid = "c".repeat(64);
        let (_tmp, store, _fid) = card_store(b"the vaulted file", None);
        store.set_file_content_id("m1", &cid).unwrap();
        assert_eq!(vault_plaintext_refused(&store, &cid, b"the vaulted file"), None);
        assert!(vault_plaintext_refused(&store, &cid, b"another file").is_some());

        // A thumbnail's card commits to the video's content id, not to the video's bytes.
        let video = VideoThumbRef { cid: cid.clone(), ext: "mp4".into(), name: "v.mp4".into(), size: 5, dur_ms: 1 };
        let (_tmp2, store2, _thumb) = card_store(b"thumbnail", Some(&video));
        store2.set_file_content_id("m1", &cid).unwrap();
        assert_eq!(vault_plaintext_refused(&store2, &cid, b"video"), None);
    }

    /// Every path that completes a file runs the gate first; a new completion path
    /// changes a count here and has to be looked at.
    #[test]
    fn every_completion_path_runs_the_gate() {
        let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let read = |f: &str| std::fs::read_to_string(src.join(f)).expect("read source").replace("\r\n", "\n");
        let production = |text: &str| text.split("#[cfg(test)]\nmod tests").next().unwrap_or("").to_string();
        for (file, completes, gates) in [
            ("node/swarm.rs", 1, &["file_commit::completion_refused(", "file_commit::header_claim_refused("][..]),
            ("node/fetch.rs", 1, &["file_commit::completion_refused(", "file_commit::header_claim_refused("][..]),
            ("node/file_handler.rs", 2, &["file_commit::completion_refused_hashed(", "file_commit::header_claim_refused(", "file_commit::vault_plaintext_refused("][..]),
            ("api/storage.rs", 1, &["file_commit::content_refused("][..]),
        ] {
            let text = production(&read(file));
            assert_eq!(
                text.matches(".mark_file_complete(").count(), completes,
                "{file}: a completion path was added or removed; it must run file_commit's gate",
            );
            for gate in gates {
                assert!(text.contains(gate), "{file} no longer calls {gate}");
            }
        }
        let vault = production(&read("node/vault_ops.rs"));
        assert_eq!(
            vault.matches("reconstruct_file(").count(),
            vault.matches("vault_bytes_checked(").count() - vault.matches("fn vault_bytes_checked(").count(),
            "node/vault_ops.rs: every reconstruction is checked against its cards",
        );
    }

    #[test]
    fn only_the_author_announces_its_file_unasked() {
        let _g = crate::node::resolver::test_lock();
        let sha = sha256_hex(b"abc");
        let fid = file_id_for(&commit(&sha));
        let claim = |sender: &str, asked: bool, author: &str| {
            header_claim_refused(&fid, Some(author), Some("m1"), 3, Some(&sha), "a.png", "png", None, sender, asked)
        };
        assert_eq!(claim("alice", false, "alice"), None);
        assert!(claim("bob", false, "alice").is_some(), "a holder announced the file unasked");
        assert_eq!(claim("bob", true, "alice"), None, "the holder we asked answers");
        assert!(claim("bob", false, "bob").is_some(), "the id names alice, whoever claims it");
        assert!(
            header_claim_refused(&fid, Some("alice"), Some("m1"), 3, None, "a.png", "png", None, "alice", false).is_some(),
            "no hash, no delivery",
        );
    }
}
