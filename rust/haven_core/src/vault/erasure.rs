use reed_solomon_erasure::galois_8::ReedSolomon;
use serde::{Deserialize, Serialize};

/// Self-describing header prepended to each stored shard.
/// Allows any shard to be independently identified and used for reconstruction
/// without external metadata.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ShardMetadata {
    /// Index of this shard within the erasure coding set (0..k+m).
    pub shard_index: u16,
    /// Content-addressed ID (SHA-256 hex of the original encrypted data).
    pub content_id: String,
    /// Number of data shards.
    pub k: u16,
    /// Number of parity shards.
    pub m: u16,
    /// Size of each shard in bytes (after padding).
    pub shard_size: u32,
    /// Original data size in bytes (before padding), used to strip padding on decode.
    pub total_data_size: u64,
}

/// Prepend ShardMetadata to raw shard data.
/// Format: [header_len: u32 LE][header JSON bytes][shard data]
pub fn pack_shard(metadata: &ShardMetadata, shard_data: &[u8]) -> Vec<u8> {
    let header_json = serde_json::to_vec(metadata).expect("ShardMetadata serialization cannot fail");
    let header_len = header_json.len() as u32;
    let mut packed = Vec::with_capacity(4 + header_json.len() + shard_data.len());
    packed.extend_from_slice(&header_len.to_le_bytes());
    packed.extend_from_slice(&header_json);
    packed.extend_from_slice(shard_data);
    packed
}

/// Extract ShardMetadata and raw shard data from a packed shard.
pub fn unpack_shard(packed: &[u8]) -> Result<(ShardMetadata, Vec<u8>), String> {
    if packed.len() < 4 {
        return Err("Packed shard too short: missing header length".into());
    }
    let header_len = u32::from_le_bytes(
        packed[..4].try_into().map_err(|_| "Failed to read header length")?,
    ) as usize;
    if packed.len() < 4 + header_len {
        return Err(format!(
            "Packed shard too short: need {} bytes for header, have {}",
            header_len,
            packed.len() - 4
        ));
    }
    let metadata: ShardMetadata = serde_json::from_slice(&packed[4..4 + header_len])
        .map_err(|e| format!("Failed to deserialize shard header: {e}"))?;
    let shard_data = packed[4 + header_len..].to_vec();
    Ok((metadata, shard_data))
}

/// Erasure-encode data into raw shards (no metadata headers).
/// Returns k+m raw shard byte vectors.
pub fn encode_raw(data: &[u8], k: usize, m: usize) -> Result<Vec<Vec<u8>>, String> {
    if k == 0 {
        return Err("k must be at least 1".into());
    }
    if m == 0 {
        return Err("m must be at least 1".into());
    }
    if data.is_empty() {
        return Err("Data must not be empty".into());
    }

    let shard_size = (data.len() + k - 1) / k;
    let mut shards: Vec<Vec<u8>> = Vec::with_capacity(k + m);

    // Build data shards (zero-pad last if needed)
    for i in 0..k {
        let start = i * shard_size;
        let end = std::cmp::min(start + shard_size, data.len());
        let mut shard = Vec::with_capacity(shard_size);
        if start < data.len() {
            shard.extend_from_slice(&data[start..end]);
        }
        // Zero-pad to shard_size
        shard.resize(shard_size, 0);
        shards.push(shard);
    }

    // Build empty parity shards
    for _ in 0..m {
        shards.push(vec![0u8; shard_size]);
    }

    let r = ReedSolomon::new(k, m).map_err(|e| format!("Reed-Solomon init failed: {e}"))?;
    r.encode(&mut shards).map_err(|e| format!("Reed-Solomon encode failed: {e}"))?;

    Ok(shards)
}

/// Reconstruct data from raw shards (no metadata headers).
/// Shards must be indexed 0..k+m. `total_data_size` is needed to strip padding.
pub fn decode_raw(
    shards: &mut [Option<Vec<u8>>],
    k: usize,
    m: usize,
    total_data_size: usize,
) -> Result<Vec<u8>, String> {
    if shards.len() != k + m {
        return Err(format!(
            "Expected {} shards (k={k} + m={m}), got {}",
            k + m,
            shards.len()
        ));
    }

    let present = shards.iter().filter(|s| s.is_some()).count();
    if present < k {
        return Err(format!("Not enough shards: need {k}, have {present}"));
    }

    let r = ReedSolomon::new(k, m).map_err(|e| format!("Reed-Solomon init failed: {e}"))?;
    r.reconstruct_data(shards)
        .map_err(|e| format!("Reed-Solomon reconstruct failed: {e}"))?;

    // Concatenate data shards and truncate to original size
    let mut result = Vec::with_capacity(total_data_size);
    for shard in shards.iter().take(k) {
        if let Some(data) = shard {
            result.extend_from_slice(data);
        }
    }
    result.truncate(total_data_size);
    Ok(result)
}

/// Erasure-encode data into k data shards + m parity shards.
///
/// Returns k+m packed shards, each with a ShardMetadata header prepended.
/// The caller provides the `content_id` (SHA-256 hex of the data).
pub fn encode(data: &[u8], k: usize, m: usize, content_id: &str) -> Result<Vec<Vec<u8>>, String> {
    let total_data_size = data.len() as u64;
    let raw_shards = encode_raw(data, k, m)?;
    let shard_size = raw_shards[0].len() as u32;

    let packed: Vec<Vec<u8>> = raw_shards
        .into_iter()
        .enumerate()
        .map(|(i, shard_data)| {
            let metadata = ShardMetadata {
                shard_index: i as u16,
                content_id: content_id.to_string(),
                k: k as u16,
                m: m as u16,
                shard_size,
                total_data_size,
            };
            pack_shard(&metadata, &shard_data)
        })
        .collect();

    Ok(packed)
}

/// Reconstruct original data from any k of the k+m packed shards.
///
/// `packed_shards` must have exactly k+m entries. `Some` contains a packed shard
/// (with metadata header), `None` indicates a missing shard.
pub fn decode(packed_shards: &[Option<Vec<u8>>], k: usize, m: usize) -> Result<Vec<u8>, String> {
    if packed_shards.len() != k + m {
        return Err(format!(
            "Expected {} shards (k={k} + m={m}), got {}",
            k + m,
            packed_shards.len()
        ));
    }

    // Unpack present shards and validate metadata consistency
    let mut total_data_size: Option<u64> = None;
    let mut expected_shard_size: Option<u32> = None;
    let mut raw_shards: Vec<Option<Vec<u8>>> = vec![None; k + m];
    let mut present_count = 0usize;

    for packed in packed_shards.iter().flatten() {
        let (meta, shard_data) = unpack_shard(packed)?;

        // Validate metadata consistency
        if meta.k as usize != k || meta.m as usize != m {
            return Err(format!(
                "Shard metadata mismatch: expected k={k}/m={m}, got k={}/m={}",
                meta.k, meta.m
            ));
        }
        if let Some(sz) = expected_shard_size {
            if meta.shard_size != sz {
                return Err(format!(
                    "Shard size mismatch: expected {sz}, got {}",
                    meta.shard_size
                ));
            }
        } else {
            expected_shard_size = Some(meta.shard_size);
        }
        if let Some(tds) = total_data_size {
            if meta.total_data_size != tds {
                return Err(format!(
                    "Total data size mismatch: expected {tds}, got {}",
                    meta.total_data_size
                ));
            }
        } else {
            total_data_size = Some(meta.total_data_size);
        }

        let idx = meta.shard_index as usize;
        if idx >= k + m {
            return Err(format!("Shard index {idx} out of range for k={k}+m={m}"));
        }
        raw_shards[idx] = Some(shard_data);
        present_count += 1;
    }

    if present_count < k {
        return Err(format!(
            "Not enough shards: need {k}, have {present_count}"
        ));
    }

    let tds = total_data_size.ok_or("No shards present to determine total_data_size")? as usize;
    decode_raw(&mut raw_shards, k, m, tds)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── Correctness ──────────────────────────────────────────────

    #[test]
    fn encode_decode_all_shards() {
        let data = b"Hello, Haven Vault! This is erasure coding.";
        let k = 4;
        let m = 2;
        let encoded = encode(data, k, m, "test_content_id").unwrap();
        assert_eq!(encoded.len(), k + m);

        let packed: Vec<Option<Vec<u8>>> = encoded.into_iter().map(Some).collect();
        let decoded = decode(&packed, k, m).unwrap();
        assert_eq!(decoded, data);
    }

    #[test]
    fn encode_decode_data_shards_only() {
        let data = b"Data shards only test";
        let k = 3;
        let m = 2;
        let encoded = encode(data, k, m, "cid").unwrap();

        // Keep only data shards (0..k), drop parity
        let mut packed: Vec<Option<Vec<u8>>> = encoded.into_iter().map(Some).collect();
        for i in k..k + m {
            packed[i] = None;
        }
        let decoded = decode(&packed, k, m).unwrap();
        assert_eq!(decoded, data);
    }

    #[test]
    fn encode_decode_mixed_shards() {
        let data = b"Mixed data and parity shards";
        let k = 3;
        let m = 2;
        let encoded = encode(data, k, m, "cid").unwrap();

        // Keep shard 0 (data), drop shard 1 (data), keep shard 2 (data),
        // drop shard 3 (parity), keep shard 4 (parity) — 3 of 5 present
        let mut packed: Vec<Option<Vec<u8>>> = encoded.into_iter().map(Some).collect();
        packed[1] = None;
        packed[3] = None;
        let decoded = decode(&packed, k, m).unwrap();
        assert_eq!(decoded, data);
    }

    #[test]
    fn encode_decode_every_drop_combination() {
        let data = b"Test all C(5,2)=10 drop combinations for k=3, m=2";
        let k = 3;
        let m = 2;
        let n = k + m;
        let encoded = encode(data, k, m, "cid").unwrap();

        // Try every combination of dropping exactly m=2 shards
        for drop_a in 0..n {
            for drop_b in (drop_a + 1)..n {
                let mut packed: Vec<Option<Vec<u8>>> =
                    encoded.iter().cloned().map(Some).collect();
                packed[drop_a] = None;
                packed[drop_b] = None;
                let decoded = decode(&packed, k, m).unwrap();
                assert_eq!(
                    decoded,
                    data.to_vec(),
                    "Failed with shards {drop_a} and {drop_b} dropped"
                );
            }
        }
    }

    #[test]
    fn decode_fewer_than_k_fails() {
        let data = b"Not enough shards";
        let k = 3;
        let m = 2;
        let encoded = encode(data, k, m, "cid").unwrap();

        // Keep only k-1 = 2 shards
        let mut packed: Vec<Option<Vec<u8>>> = encoded.into_iter().map(Some).collect();
        packed[0] = None;
        packed[1] = None;
        packed[2] = None; // Now only 2 present (indices 3, 4)
        let result = decode(&packed, k, m);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Not enough shards"));
    }

    #[test]
    fn decode_all_missing_fails() {
        let k = 3;
        let m = 2;
        let packed: Vec<Option<Vec<u8>>> = vec![None; k + m];
        let result = decode(&packed, k, m);
        assert!(result.is_err());
    }

    // ── Edge cases ───────────────────────────────────────────────

    #[test]
    fn single_byte_input() {
        let data = &[0xAB];
        let k = 2;
        let m = 1;
        let encoded = encode(data, k, m, "cid").unwrap();
        assert_eq!(encoded.len(), 3);

        let packed: Vec<Option<Vec<u8>>> = encoded.into_iter().map(Some).collect();
        let decoded = decode(&packed, k, m).unwrap();
        assert_eq!(decoded, data);
    }

    #[test]
    fn exact_divisible_input() {
        // 12 bytes / k=3 = 4 bytes per shard, no padding needed
        let data = b"ABCDEFGHIJKL";
        assert_eq!(data.len() % 3, 0);
        let k = 3;
        let m = 2;
        let encoded = encode(data, k, m, "cid").unwrap();
        let packed: Vec<Option<Vec<u8>>> = encoded.into_iter().map(Some).collect();
        let decoded = decode(&packed, k, m).unwrap();
        assert_eq!(decoded, data);
    }

    #[test]
    fn not_divisible_input() {
        // 13 bytes / k=3 = ceil to 5 bytes per shard, 2 bytes of padding
        let data = b"ABCDEFGHIJKLM";
        assert_ne!(data.len() % 3, 0);
        let k = 3;
        let m = 2;
        let encoded = encode(data, k, m, "cid").unwrap();
        let packed: Vec<Option<Vec<u8>>> = encoded.into_iter().map(Some).collect();
        let decoded = decode(&packed, k, m).unwrap();
        assert_eq!(decoded, data);
    }

    #[test]
    fn large_input_1mb() {
        let data: Vec<u8> = (0..1_000_000).map(|i| (i % 256) as u8).collect();
        let k = 10;
        let m = 5;
        let encoded = encode(&data, k, m, "large_cid").unwrap();
        assert_eq!(encoded.len(), 15);

        // Drop 5 parity shards
        let mut packed: Vec<Option<Vec<u8>>> = encoded.into_iter().map(Some).collect();
        for i in k..k + m {
            packed[i] = None;
        }
        let decoded = decode(&packed, k, m).unwrap();
        assert_eq!(decoded, data);
    }

    #[test]
    fn varied_k_m() {
        let data: Vec<u8> = (0..100_000).map(|i| (i % 256) as u8).collect();
        let configs = [(3, 2), (5, 3), (8, 4), (20, 10)];

        for (k, m) in configs {
            let encoded = encode(&data, k, m, "cid").unwrap();
            assert_eq!(encoded.len(), k + m, "k={k}, m={m}");

            // Drop m shards (the parity ones)
            let mut packed: Vec<Option<Vec<u8>>> = encoded.into_iter().map(Some).collect();
            for i in k..k + m {
                packed[i] = None;
            }
            let decoded = decode(&packed, k, m).unwrap();
            assert_eq!(decoded, data, "Round-trip failed for k={k}, m={m}");
        }
    }

    #[test]
    fn k1_m1_minimal() {
        let data = b"Minimal config";
        let k = 1;
        let m = 1;
        let encoded = encode(data, k, m, "cid").unwrap();
        assert_eq!(encoded.len(), 2);

        // Either shard alone can reconstruct
        for drop_idx in 0..2 {
            let mut packed: Vec<Option<Vec<u8>>> =
                encoded.iter().cloned().map(Some).collect();
            packed[drop_idx] = None;
            let decoded = decode(&packed, k, m).unwrap();
            assert_eq!(decoded, data, "Failed dropping shard {drop_idx}");
        }
    }

    // ── Validation ───────────────────────────────────────────────

    #[test]
    fn encode_empty_data_fails() {
        let result = encode(&[], 3, 2, "cid");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("empty"));
    }

    #[test]
    fn encode_k_zero_fails() {
        let result = encode(b"data", 0, 2, "cid");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("k must be at least 1"));
    }

    #[test]
    fn encode_m_zero_fails() {
        let result = encode(b"data", 3, 0, "cid");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("m must be at least 1"));
    }

    #[test]
    fn decode_wrong_shard_count_fails() {
        let data = b"wrong count";
        let k = 3;
        let m = 2;
        let encoded = encode(data, k, m, "cid").unwrap();
        let mut packed: Vec<Option<Vec<u8>>> = encoded.into_iter().map(Some).collect();
        packed.push(Some(vec![0])); // Now 6 instead of 5
        let result = decode(&packed, k, m);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Expected 5 shards"));
    }

    // ── Metadata ─────────────────────────────────────────────────

    #[test]
    fn pack_unpack_round_trip() {
        let meta = ShardMetadata {
            shard_index: 3,
            content_id: "abc123def456".into(),
            k: 10,
            m: 5,
            shard_size: 1024,
            total_data_size: 10000,
        };
        let shard_data = vec![1u8, 2, 3, 4, 5];
        let packed = pack_shard(&meta, &shard_data);
        let (unpacked_meta, unpacked_data) = unpack_shard(&packed).unwrap();
        assert_eq!(unpacked_meta, meta);
        assert_eq!(unpacked_data, shard_data);
    }

    #[test]
    fn metadata_serde_round_trip() {
        let meta = ShardMetadata {
            shard_index: 7,
            content_id: "deadbeef".into(),
            k: 5,
            m: 3,
            shard_size: 2048,
            total_data_size: 9999,
        };
        let json = serde_json::to_string(&meta).unwrap();
        let back: ShardMetadata = serde_json::from_str(&json).unwrap();
        assert_eq!(back, meta);
    }

    #[test]
    fn metadata_fields_correct() {
        let data = b"Check metadata fields";
        let k = 3;
        let m = 2;
        let encoded = encode(data, k, m, "my_content_id").unwrap();

        let expected_shard_size = (data.len() + k - 1) / k;

        for (i, packed) in encoded.iter().enumerate() {
            let (meta, shard_data) = unpack_shard(packed).unwrap();
            assert_eq!(meta.shard_index, i as u16);
            assert_eq!(meta.content_id, "my_content_id");
            assert_eq!(meta.k, k as u16);
            assert_eq!(meta.m, m as u16);
            assert_eq!(meta.shard_size, expected_shard_size as u32);
            assert_eq!(meta.total_data_size, data.len() as u64);
            assert_eq!(shard_data.len(), expected_shard_size);
        }
    }

    #[test]
    fn unpack_truncated_fails() {
        let result = unpack_shard(&[0, 0]);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("too short"));
    }

    #[test]
    fn unpack_corrupt_header_fails() {
        // Valid length prefix (10 bytes) but garbage JSON
        let mut packed = Vec::new();
        packed.extend_from_slice(&10u32.to_le_bytes());
        packed.extend_from_slice(b"not json!!");
        let result = unpack_shard(&packed);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("deserialize"));
    }

    #[test]
    fn decode_shuffled_shards() {
        let data = b"Shuffled shard order test";
        let k = 3;
        let m = 2;
        let encoded = encode(data, k, m, "cid").unwrap();

        // Place shards in reversed order — metadata shard_index should route correctly
        let mut packed: Vec<Option<Vec<u8>>> = vec![None; k + m];
        for (i, shard) in encoded.into_iter().enumerate() {
            let reversed_pos = (k + m) - 1 - i;
            packed[reversed_pos] = Some(shard);
        }
        let decoded = decode(&packed, k, m).unwrap();
        assert_eq!(decoded, data);
    }

    // ── Benchmark ────────────────────────────────────────────────

    #[test]
    #[ignore] // Run: cargo test --release -p haven_core erasure::tests::bench_throughput -- --ignored --nocapture
    fn bench_throughput() {
        let data = vec![42u8; 1_000_000]; // 1MB
        let k = 10;
        let m = 5;
        let iterations = 50;

        // Benchmark encode
        let start = std::time::Instant::now();
        let mut last_encoded = Vec::new();
        for _ in 0..iterations {
            last_encoded = encode_raw(&data, k, m).unwrap();
        }
        let encode_elapsed = start.elapsed();
        let encode_mbps = (iterations as f64) / encode_elapsed.as_secs_f64();
        eprintln!(
            "Encode: {encode_mbps:.1} MB/s ({iterations} x 1MB, k={k}, m={m}, {:.1}ms avg)",
            encode_elapsed.as_millis() as f64 / iterations as f64
        );

        // Benchmark decode (drop m parity shards)
        let start = std::time::Instant::now();
        for _ in 0..iterations {
            let mut shards: Vec<Option<Vec<u8>>> =
                last_encoded.iter().cloned().map(Some).collect();
            for i in k..k + m {
                shards[i] = None;
            }
            let _ = decode_raw(&mut shards, k, m, data.len()).unwrap();
        }
        let decode_elapsed = start.elapsed();
        let decode_mbps = (iterations as f64) / decode_elapsed.as_secs_f64();
        eprintln!(
            "Decode: {decode_mbps:.1} MB/s ({iterations} x 1MB, k={k}, m={m}, {:.1}ms avg)",
            decode_elapsed.as_millis() as f64 / iterations as f64
        );

        assert!(
            encode_mbps > 100.0,
            "Encode too slow: {encode_mbps:.1} MB/s (target >100 MB/s)"
        );
        assert!(
            decode_mbps > 100.0,
            "Decode too slow: {decode_mbps:.1} MB/s (target >100 MB/s)"
        );
    }
}
