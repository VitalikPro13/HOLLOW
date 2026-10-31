#pragma once
#include <string>
#include <unordered_map>
#include <cstdint>
#include <cstddef>

#include "fair_share.h"

// User reports (spam / harassment / ...). This is the ONE thing the relay
// persists about peers: per-(target, category) counts plus KEYED dedup fingerprints,
// each beside its target and category, oldest first, so the file shows the order
// reports arrived in but never who filed one. Reporter ids never appear on disk or in
// logs, only target totals the operator can act on (e.g. restricting access).
//
// Anyone may report, so the byte budget bounds the table: each report is charged to
// the reporter's address share, and past the budget the share holding the most gives
// up its least recently used report, count included (fair_share.h). A flood from one
// address block pushes out only its own reports and never stops another's counting.
// Counts carried from a file whose fingerprints this key cannot read stand apart: no
// report can add one at runtime, so no flood ever evicts one.
struct ReportsState {
    static constexpr size_t SECRET_BYTES = 32;
    // Files older than 2 carry unsalted sha256 keys, which anyone holding the file
    // could test against a guessed "A reported B"; 3 ties each report to its count.
    static constexpr int FILE_VERSION = 3;
    static constexpr size_t MAX_BYTES = 128ull * 1024 * 1024;
    // The shares of reports the snapshot named none for, one each; never handed over.
    static constexpr uint64_t OWN_SHARE = 0xffff000000000000ull;
    static bool is_own_share(uint64_t share) { return (share & OWN_SHARE) == OWN_SHARE; }

    // Every entry costs the same (two copies of a 64-hex fingerprint, a peer-id-shaped
    // target, the longest category, map overhead), so which report gives way never
    // depends on a string's length.
    static constexpr size_t ENTRY_BYTES = 384 + 2 * 64 + 64 + 16;
    // Carried counts past this give way smallest first: a flood's counts of one before
    // a target many people reported.
    static constexpr size_t MAX_CARRIED_BYTES = MAX_BYTES / 2;

    // What one entry counts. A fingerprint with an empty target is a report an older
    // file kept for dedup alone, its count carried.
    struct Held {
        std::string target;
        std::string category;
        uint64_t n = 1;
    };

    // BLAKE2b(key = secret, reporter '\0' target '\0' category) -> the report: one per
    // reporter per target per category.
    std::unordered_map<std::string, Held> held;
    FairShare<std::string> ledger;
    size_t budget = MAX_BYTES;
    // carried_key(target, category) -> a count whose fingerprints this key cannot read;
    // outside the ledger, filled only by load_from_file.
    std::unordered_map<std::string, Held> carried;
    size_t carried_budget = MAX_CARRIED_BYTES;
    // target peer_id -> category -> count, the sum of the held and carried entries.
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

    // Each fingerprint's address share, handed over by the restart snapshot (never a
    // disk) and taken by load_from_file; a report without one becomes a share of its own.
    std::unordered_map<std::string, uint64_t> adopted_shares;

    // The key a previous process of this service handed over. Call before
    // load_from_file; false (and nothing taken) unless it is SECRET_BYTES long.
    bool adopt_key(const std::string& key);
    // The key for the restart snapshot; empty while there is none.
    std::string key_bytes() const;

    // A fresh key unless one was adopted. Fingerprints made under another secret or
    // before the salt existed are dropped, counts kept. A key file an older relay left
    // beside the reports is zeroed and removed, never read.
    bool load_from_file(const std::string& path);
    // Atomic write (tmp + rename); no-op unless dirty. Keeps dirty set on
    // failure so the next flush retries.
    void save_if_dirty();
    // The categories a client may file. "blocked" is the count a block sends:
    // like every other category it adds to the blocked person's total only, so
    // the relay never holds anyone's block list.
    static bool is_category(const std::string& category);

    // Returns true if this (reporter, target, category) was new. `share` is the
    // reporter's address share (socket_share).
    bool add(const std::string& reporter, const std::string& target,
             const std::string& category, uint64_t share);

    std::string fingerprint(const std::string& reporter, const std::string& target,
                            const std::string& category) const;

    // Held fingerprints, the entries dedup can match.
    size_t fingerprints() const;

    // Where relays before 0.13 kept the key.
    static std::string secret_path_for(const std::string& reports_path);

    static std::string carried_key(const std::string& target, const std::string& category) {
        return "c:" + target + ":" + category;
    }
    static bool is_fingerprint(const std::string& key);

private:
    void ensure_key();
    // Names the secret in the reports file without revealing it, so a file
    // paired with a different secret is detected on load.
    std::string salt_id() const;
    void hold(const std::string& key, Held h, uint64_t share);
    void drop(const std::string& key);
    void count(const Held& h, bool add);
    // Shed carried counts past carried_budget, smallest first.
    void trim_carried();
    // Evict down to the budget, never `spare` while another entry is left.
    void trim(const std::string* spare);
};
