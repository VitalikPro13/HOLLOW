#pragma once
#include <string>
#include <unordered_set>
#include <unordered_map>
#include <cstdint>
#include <cstddef>

// User reports (spam / harassment / ...). This is the ONE thing the relay
// persists about peers, so it is deliberately minimal: per-(target, category)
// counts plus KEYED dedup fingerprints. Reporter ids never appear on disk or in
// logs, only target totals the operator can act on (e.g. restricting access).
struct ReportsState {
    static constexpr size_t SECRET_BYTES = 32;
    // Files older than this carry unsalted sha256 keys, which anyone holding
    // the file could test against a guessed "A reported B".
    static constexpr int FILE_VERSION = 2;

    // BLAKE2b(key = secret, reporter '\0' target '\0' category): dedup only,
    // one report per reporter per target per category.
    std::unordered_set<std::string> keys;
    // target peer_id -> category -> count.
    std::unordered_map<std::string,
        std::unordered_map<std::string, uint64_t>> counts;

    std::string file_path;
    bool dirty = false;
    // One log line per unwritable path, not one every flush.
    bool save_failed_logged = false;

    // Only in memory and the restart snapshot (snapshot_codec.h), never on a disk, so
    // a copy of the disk cannot test a guessed pair; never logged.
    unsigned char secret[SECRET_BYTES] = {};
    bool has_key = false;

    // The key a previous process of this service handed over. Call before
    // load_from_file; false (and nothing taken) unless it is SECRET_BYTES long.
    bool adopt_key(const std::string& key);
    // The key for the restart snapshot; empty while there is none.
    std::string key_bytes() const;

    // A fresh key unless one was adopted. Keys made under another secret or before the
    // salt existed are dropped, counts kept. A key file an older relay left beside the
    // reports is zeroed and removed, never read.
    bool load_from_file(const std::string& path);
    // Atomic write (tmp + rename); no-op unless dirty. Keeps dirty set on
    // failure so the next flush retries.
    void save_if_dirty();
    // The categories a client may file. "blocked" is the count a block sends:
    // like every other category it adds to the blocked person's total only, so
    // the relay never holds anyone's block list.
    static bool is_category(const std::string& category);

    // Returns true if this (reporter, target, category) was new.
    bool add(const std::string& reporter, const std::string& target,
             const std::string& category);

    std::string fingerprint(const std::string& reporter, const std::string& target,
                            const std::string& category) const;

    // Where relays before 0.13 kept the key.
    static std::string secret_path_for(const std::string& reports_path);

private:
    void ensure_key();
    // Names the secret in the reports file without revealing it, so a file
    // paired with a different secret is detected on load.
    std::string salt_id() const;
};
