#pragma once
#include <string>
#include <unordered_set>
#include <unordered_map>
#include <cstdint>

// User reports (spam / harassment / ...). This is the ONE thing the relay
// persists about peers, so it is deliberately minimal: per-(target, category)
// counts plus HASHED dedup keys. The file never contains who reported whom,
// and reporter ids never appear on disk or in logs — only target totals the
// operator can act on (e.g. restricting relay access).
struct ReportsState {
    // sha256_hex(reporter '\0' target '\0' category) — dedup only, one report
    // per reporter per target per category.
    std::unordered_set<std::string> keys;
    // target peer_id -> category -> count.
    std::unordered_map<std::string,
        std::unordered_map<std::string, uint64_t>> counts;

    std::string file_path;
    bool dirty = false;

    bool load_from_file(const std::string& path);
    // Atomic write (tmp + rename); no-op unless dirty. Keeps dirty set on
    // failure so the next flush retries.
    void save_if_dirty();
    // Returns true if this (reporter, target, category) was new.
    bool add(const std::string& reporter, const std::string& target,
             const std::string& category);
};
