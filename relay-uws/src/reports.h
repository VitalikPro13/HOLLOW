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

    // Lives in its own file (secret_path_for) so the reports file alone
    // proves nothing; never logged.
    unsigned char secret[SECRET_BYTES] = {};

    // Loads (or creates) the secret first; keys made under another secret or
    // before the salt existed are dropped, counts kept.
    bool load_from_file(const std::string& path);
    // Atomic write (tmp + rename); no-op unless dirty. Keeps dirty set on
    // failure so the next flush retries.
    void save_if_dirty();
    // Returns true if this (reporter, target, category) was new.
    bool add(const std::string& reporter, const std::string& target,
             const std::string& category);

    std::string fingerprint(const std::string& reporter, const std::string& target,
                            const std::string& category) const;

    static std::string secret_path_for(const std::string& reports_path);
    // false = the file could not be read or written; a key for this run only
    // is in place, so fingerprints saved now will not match after a restart.
    bool load_or_create_secret(const std::string& path);

private:
    // Names the secret in the reports file without revealing it, so a file
    // paired with a different secret is detected on load.
    std::string salt_id() const;
};
