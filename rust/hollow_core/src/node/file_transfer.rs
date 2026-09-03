//! File transfer utilities — chunking, reassembly, file ID generation, paths.

use std::path::PathBuf;

/// Default max file size: 34 MB (sussy easter egg default).
pub const DEFAULT_MAX_FILE_SIZE: u64 = 34 * 1024 * 1024;

/// Generate a 32-char hex file ID (same format as message IDs).
pub fn generate_file_id() -> String {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).unwrap_or(());
    hex::encode(bytes)
}

/// Get the directory for storing files.
/// Creates it if it doesn't exist.
pub fn files_dir() -> PathBuf {
    let dir = crate::identity::data_dir()
        .unwrap_or_else(|_| PathBuf::from("hollow"))
        .join("files");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// Write a single chunk to disk as a temporary file.
pub fn write_chunk(file_id: &str, chunk_index: u32, data: &[u8]) -> Result<(), String> {
    let path = chunk_path(file_id, chunk_index);
    std::fs::write(&path, data)
        .map_err(|e| format!("Failed to write chunk {chunk_index} for {file_id}: {e}"))
}

/// Reassemble chunks into the final file.
/// Reads chunk files from disk in order, concatenates, writes to final path.
/// Cleans up chunk files after successful assembly.
pub fn assemble_file(
    file_id: &str,
    total_chunks: u32,
    final_path: &std::path::Path,
) -> Result<(), String> {
    use std::io::Write;

    let mut output = std::fs::File::create(final_path)
        .map_err(|e| format!("Failed to create output file: {e}"))?;

    for idx in 0..total_chunks {
        let cp = chunk_path(file_id, idx);
        let data = std::fs::read(&cp)
            .map_err(|e| format!("Failed to read chunk {idx}: {e}"))?;
        output.write_all(&data)
            .map_err(|e| format!("Failed to write chunk {idx} to output: {e}"))?;
    }

    output.flush()
        .map_err(|e| format!("Failed to flush output file: {e}"))?;

    // Clean up chunk files.
    for idx in 0..total_chunks {
        let _ = std::fs::remove_file(chunk_path(file_id, idx));
    }

    Ok(())
}

/// SECURITY: Sanitize file ID / extension to prevent path traversal.
/// Only allows alphanumeric characters (strips path separators, dots, etc.).
fn sanitize_path_component(s: &str) -> String {
    s.chars().filter(|c| c.is_ascii_alphanumeric()).collect()
}

/// Path for a temporary chunk file.
fn chunk_path(file_id: &str, chunk_index: u32) -> PathBuf {
    let safe_id = sanitize_path_component(file_id);
    files_dir().join(format!("{safe_id}.chunk.{chunk_index}"))
}

/// Build the final file path: files_dir/{file_id}.{ext}
pub fn final_file_path(file_id: &str, ext: &str) -> PathBuf {
    let safe_id = sanitize_path_component(file_id);
    let safe_ext = sanitize_path_component(ext);
    files_dir().join(format!("{safe_id}.{safe_ext}"))
}

/// SECURITY: does a wire-supplied file id have the shape this client mints?
///
/// `generate_file_id` produces 32 hex characters; older senders and the
/// share/vault lanes use other alphanumeric ids, so the check is a SHAPE
/// check, not a format check. Anything carrying a separator, a dot, a drive
/// letter or a NUL fails here — a receive path that cannot name the file
/// cannot be talked into naming a file somewhere else.
pub(crate) fn is_wire_file_id(s: &str) -> bool {
    (8..=64).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_alphanumeric())
}

/// SECURITY: does a wire-supplied extension have the shape a real one has?
/// Alphanumeric, 1 to 8 characters. Same reasoning as [`is_wire_file_id`].
pub(crate) fn is_wire_ext(s: &str) -> bool {
    (1..=8).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_alphanumeric())
}

/// Detect MIME type from file extension.
pub fn mime_from_ext(ext: &str) -> String {
    match ext.to_lowercase().as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "bmp" => "image/bmp",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "mp4" => "video/mp4",
        "webm" => "video/webm",
        "mp3" => "audio/mpeg",
        "ogg" => "audio/ogg",
        "wav" => "audio/wav",
        "pdf" => "application/pdf",
        "zip" => "application/zip",
        "txt" => "text/plain",
        _ => "application/octet-stream",
    }
    .to_string()
}

/// Check if a MIME type is an image.
pub fn is_image_mime(mime: &str) -> bool {
    mime.starts_with("image/")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// FILE-1 regression: every path the receive sites build has to land
    /// inside the files dir, whatever the peer put in the header. The inputs
    /// are the ones a peer can actually send, including the exact absolute
    /// path the audit's proof-of-concept used.
    #[test]
    fn final_file_path_stays_inside_files_dir() {
        let dir = files_dir();
        // The proof-of-concept's own input shape: an absolute path pointing
        // at a directory the attacker chose, which `Path::join` would adopt
        // wholesale in place of the base.
        let poc = std::env::temp_dir()
            .join("evil")
            .join("pwned")
            .to_string_lossy()
            .to_string();
        let hostile = [
            (r"C:\Users\Public\Startup\pwned", "exe"),
            ("/etc/cron.d/pwned", "sh"),
            (r"..\..\..\x", "txt"),
            ("../../x", "txt"),
            (poc.as_str(), "txt"),
            ("a/b", "e/f"),
            ("id", r"..\..\evil"),
        ];
        for (fid, ext) in hostile {
            let p = final_file_path(fid, ext);
            assert!(
                p.starts_with(&dir),
                "final_file_path({fid:?}, {ext:?}) escaped: {p:?} is not under {dir:?}",
            );
            let name = p
                .file_name()
                .expect("a built path always has a file name")
                .to_string_lossy()
                .to_string();
            assert!(
                !name.contains('/') && !name.contains('\\') && !name.contains(':'),
                "the file name still carries a separator: {name:?}",
            );
            assert_eq!(
                name.matches('.').count(),
                1,
                "exactly one dot separates id from extension: {name:?}",
            );
        }
    }

    /// The shape gate the two inline-header receive sites apply before they
    /// name a file at all.
    #[test]
    fn wire_file_id_and_ext_shapes() {
        assert!(is_wire_file_id(&generate_file_id()), "our own ids pass");
        assert!(is_wire_file_id("abcd1234"), "8 chars is the floor");
        assert!(is_wire_file_id(&"a".repeat(64)), "64 chars is the ceiling");

        assert!(!is_wire_file_id(""), "empty");
        assert!(!is_wire_file_id("abc1234"), "7 chars is under the floor");
        assert!(!is_wire_file_id(&"a".repeat(65)), "65 chars is over the ceiling");
        assert!(!is_wire_file_id(r"C:\Users\Public\pwned"), "absolute Windows path");
        assert!(!is_wire_file_id("/etc/cron.d/pwned"), "absolute POSIX path");
        assert!(!is_wire_file_id("../../escape"), "relative traversal");
        assert!(!is_wire_file_id("abcd1234.exe"), "a dot is not part of an id");
        assert!(!is_wire_file_id("abcd 1234"), "a space is not alphanumeric");
        assert!(!is_wire_file_id("abcd1234\0x"), "a NUL truncates a path");

        assert!(is_wire_ext("e"), "one char is the floor");
        assert!(is_wire_ext("webp"));
        assert!(is_wire_ext("12345678"), "8 chars is the ceiling");

        assert!(!is_wire_ext(""), "empty");
        assert!(!is_wire_ext("123456789"), "9 chars is over the ceiling");
        assert!(!is_wire_ext("e/f"), "a separator is not an extension");
        assert!(!is_wire_ext(r"..\evil"), "traversal is not an extension");
        assert!(!is_wire_ext("ex e"), "a space is not alphanumeric");
    }
}
