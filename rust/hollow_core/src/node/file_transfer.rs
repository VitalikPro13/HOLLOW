//! File transfer utilities — chunking, reassembly, file ID generation, paths.

use std::path::PathBuf;

/// Chunk size: 2 MB. Larger chunks mean fewer Olm messages per file,
/// reducing risk of ratchet desync from out-of-order delivery.
pub const CHUNK_SIZE: usize = 2 * 1024 * 1024;

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

/// Split file data into chunks of CHUNK_SIZE bytes.
pub fn chunk_file(data: &[u8]) -> Vec<Vec<u8>> {
    data.chunks(CHUNK_SIZE)
        .map(|c| c.to_vec())
        .collect()
}

/// Calculate how many chunks a file of the given size will need.
pub fn chunk_count(size: u64) -> u32 {
    ((size as f64) / (CHUNK_SIZE as f64)).ceil() as u32
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
