// Unit tests for the relay's user-report store (src/reports.cpp).
//
// The property that matters: nothing on the disk can confirm a guessed "A reported
// B". Fingerprints are keyed by a secret that lives only in memory and in the restart
// snapshot, a key file an older relay left is wiped, dedup survives a restart that
// hands the key over, and a file whose fingerprints were not made with the current
// secret (unsalted legacy, a reboot, an old key) loses its fingerprints but keeps
// its counts.
//
// Build + run from relay-uws/test (no uWebSockets, needs libsodium):
//   g++ -std=c++17 -I../src test_reports.cpp ../src/reports.cpp ../src/crypto.cpp
//       -lsodium -lcrypto -o test_reports && ./test_reports

#include "reports.h"
#include "crypto.h"
#include "json.hpp"

#include <sodium.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>

using json = nlohmann::json;

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

static std::string slurp(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    std::stringstream b;
    b << f.rdbuf();
    return b.str();
}

static std::string unsalted(const std::string& reporter, const std::string& target,
                            const std::string& category) {
    std::string m = reporter + '\0' + target + '\0' + category;
    unsigned char h[crypto_hash_sha256_BYTES];
    crypto_hash_sha256(h, reinterpret_cast<const unsigned char*>(m.data()), m.size());
    return hex_encode(h, sizeof(h));
}

// Whether a reports file still holds a fingerprint dedup could match.
static bool has_fingerprint(const json& j) {
    if (!j.contains("reports")) return false;
    for (const auto& e : j["reports"]) {
        if (e.is_array() && !e.empty() && ReportsState::is_fingerprint(e[0].get<std::string>())) return true;
    }
    return false;
}

// The salt id a file written under `key` carries (reports.cpp salt_id).
static std::string salt_id_for(const unsigned char* key) {
    const std::string label = "hollow-report-salt-id";
    unsigned char h[8];
    crypto_generichash(h, sizeof(h), reinterpret_cast<const unsigned char*>(label.data()), label.size(), key, 32);
    return hex_encode(h, sizeof(h));
}

static uint64_t counted(const ReportsState& r) {
    uint64_t n = 0;
    for (const auto& [t, cats] : r.counts)
        for (const auto& [c, k] : cats) n += k;
    return n;
}

static const std::string A = "12D3KooWReporterA";
static const std::string B = "12D3KooWTargetB";

int main() {
    if (sodium_init() < 0) return 1;
    char tmpl[] = "/tmp/hollow_reports_XXXXXX";
    const std::string dir = mkdtemp(tmpl);
    const std::string path = dir + "/reports.json";
    const std::string key_path = ReportsState::secret_path_for(path);

    printf("report key\n");
    {
        ReportsState r;
        r.load_from_file(path);
        check("loading writes no key file", ::access(key_path.c_str(), F_OK) != 0);

        check("a first report counts", r.add(A, B, "spam", 1));
        check("the same report is deduped", !r.add(A, B, "spam", 1));
        check("another category counts", r.add(A, B, "harassment", 1));
        check("the fingerprint is not the unsalted hash",
              r.fingerprint(A, B, "spam") != unsalted(A, B, "spam"));
        ::umask(022);
        r.save_if_dirty();
        check("saving writes no key file", ::access(key_path.c_str(), F_OK) != 0);
        struct stat rst {};
        check("the reports file is 0600 whatever the umask",
              ::stat(path.c_str(), &rst) == 0 && (rst.st_mode & 0777) == 0600);
        check("no temp file is left behind", ::access((path + ".tmp").c_str(), F_OK) != 0);

        const std::string file = slurp(path);
        check("the file never names the reporter", file.find(A) == std::string::npos);
        check("the file does not hold the unsalted hash",
              file.find(unsalted(A, B, "spam")) == std::string::npos);
        check("the file does not hold the key", file.find(hex_encode(r.secret, 32)) == std::string::npos);
        json j = json::parse(file);
        check("the file carries the version", j.value("version", 0) == ReportsState::FILE_VERSION);

        // The restart snapshot is the only place the key goes.
        const std::string key = r.key_bytes();
        check("the key is 32 bytes", key.size() == ReportsState::SECRET_BYTES);
        ReportsState again;
        check("a handed-over key is taken", again.adopt_key(key));
        again.load_from_file(path);
        check("fingerprints survive a restart that hands the key over", again.fingerprints() == 2);
        check("dedup survives it", !again.add(A, B, "spam", 1));
        check("counts survive it", again.counts[B]["spam"] == 1 && again.counts[B]["harassment"] == 1);
        check("a clean load is not dirty", !again.dirty);
        check("no key file after the restart either", ::access(key_path.c_str(), F_OK) != 0);

        ReportsState bad;
        check("a key of another length is refused", !bad.adopt_key(std::string(31, 'k')));
        check("an empty one too", !bad.adopt_key(std::string()));
    }

    printf("reboot\n");
    {
        // No snapshot survives a reboot: a new key, so the old fingerprints say nothing.
        ReportsState r;
        r.load_from_file(path);
        check("fingerprints from the lost key are dropped", r.fingerprints() == 0);
        check("and leave the disk at once", !has_fingerprint(json::parse(slurp(path))) && !r.dirty);
        check("counts are kept", r.counts[B]["spam"] == 1 && r.counts[B]["harassment"] == 1);
        check("a repeat report counts again", r.add(A, B, "spam", 1) && r.counts[B]["spam"] == 2);
        r.save_if_dirty();
    }

    printf("a key file an older relay left\n");
    {
        // An older relay kept its key beside the file, and wrote fingerprints under it.
        unsigned char old_key[32];
        randombytes_buf(old_key, sizeof(old_key));
        ReportsState old;
        old.adopt_key(std::string(reinterpret_cast<const char*>(old_key), sizeof(old_key)));
        old.file_path = path;
        old.add(A, B, "impersonation", 1);
        old.save_if_dirty();
        { std::ofstream f(key_path, std::ios::binary | std::ios::trunc);
          f.write(reinterpret_cast<const char*>(old_key), sizeof(old_key)); }
        // A second name for the same inode shows what was left in its blocks.
        const std::string witness = dir + "/witness";
        check("the witness link is made", ::link(key_path.c_str(), witness.c_str()) == 0);

        ReportsState r;
        r.load_from_file(path);
        check("the old key file is gone", ::access(key_path.c_str(), F_OK) != 0);
        check("its bytes were zeroed first", slurp(witness) == std::string(32, '\0'));
        check("the old key is not taken", std::memcmp(r.secret, old_key, sizeof(old_key)) != 0);
        check("fingerprints made under it are dropped", r.fingerprints() == 0);
        check("its counts are kept", r.counts[B]["impersonation"] == 1);
        ::unlink(witness.c_str());
    }

    printf("categories\n");
    {
        for (const char* c : {"spam", "harassment", "illegal_content", "impersonation", "blocked"})
            check(std::string("the relay counts ") + c, ReportsState::is_category(c));
        for (const char* c : {"", "Blocked", "blocked ", "other", "spam,blocked"})
            check(std::string("the relay refuses '") + c + "'", !ReportsState::is_category(c));
        check("a category with a NUL inside is refused",
              !ReportsState::is_category(std::string("blocked\0x", 9)));

        ReportsState r;
        randombytes_buf(r.secret, 32);
        check("a block counts", r.add(A, B, "blocked", 1));
        check("blocking the same person again does not", !r.add(A, B, "blocked", 1));
        check("a block is its own count beside a report",
              r.add(A, B, "spam", 1) && r.counts[B]["blocked"] == 1 && r.counts[B]["spam"] == 1);
        r.file_path = dir + "/blocked.json";
        r.save_if_dirty();
        const std::string file = slurp(r.file_path);
        check("a block names no blocker on disk", file.find(A) == std::string::npos);
        // Only the per-target counts are readable: nothing is keyed by the blocker.
        json j = json::parse(file);
        bool only_targets = j["counts"].size() == 1 && j["counts"].contains(B);
        check("the counts are keyed by the blocked person only", only_targets);
    }

    printf("different secrets\n");
    {
        ReportsState x, y;
        randombytes_buf(x.secret, 32);
        randombytes_buf(y.secret, 32);
        check("two relays fingerprint the same report differently",
              x.fingerprint(A, B, "spam") != y.fingerprint(A, B, "spam"));
        check("the separator keeps fields apart",
              x.fingerprint("ab", "c", "spam") != x.fingerprint("a", "bc", "spam"));
    }

    printf("legacy unsalted file\n");
    {
        json legacy;
        legacy["keys"] = json::array({unsalted(A, B, "spam")});
        legacy["counts"] = {{B, {{"spam", 1}}}};
        { std::ofstream f(path, std::ios::trunc); f << legacy.dump(); }

        ReportsState r;
        r.load_from_file(path);
        check("unsalted keys are dropped", r.fingerprints() == 0);
        check("counts are kept", r.counts[B]["spam"] == 1);
        check("the rewritten file holds no unsalted key",
              slurp(path).find(unsalted(A, B, "spam")) == std::string::npos);
        check("a repeat report counts again after migration", r.add(A, B, "spam", 1) &&
                                                             r.counts[B]["spam"] == 2);
        r.save_if_dirty();
    }

    printf("a flood from one address block\n");
    {
        ReportsState r;
        randombytes_buf(r.secret, 32);
        r.has_key = true;
        const size_t one = ReportsState::ENTRY_BYTES;
        r.budget = one * 20;
        for (int i = 0; i < 3; i++) r.add("honest" + std::to_string(i), B, "spam", 100 + i);
        bool all_taken = true;
        for (int i = 0; i < 2000; i++) {
            all_taken &= r.add("throwaway" + std::to_string(i), "12D3KooWTarget" + std::to_string(i % 50), "spam", 7);
        }
        check("nothing a flood sends is refused", all_taken);
        check("the table stays inside its byte budget", r.ledger.total() <= r.budget);
        check("the honest reports outlast the flood", r.counts[B]["spam"] == 3);
        check("the flood holds only what is left", r.ledger.held(7) <= r.budget - 3 * one);
        check("counts are the held reports, no more", counted(r) == r.held.size());
        check("a flooded target's count is bounded too", r.counts.size() <= 21);
        check("a later honest report still counts", r.add("honest3", B, "spam", 103) && r.counts[B]["spam"] == 4);
        check("and pushes out a flood report, not an honest one",
              r.ledger.held(100) == one && r.ledger.held(101) == one && r.ledger.held(102) == one &&
                  r.ledger.held(103) == one && r.ledger.total() <= r.budget);
        bool honest_dedup = !r.add("honest0", B, "spam", 100);
        check("an honest report kept is still deduped", honest_dedup && r.counts[B]["spam"] == 4);
    }

    printf("a full table never drops the report just made\n");
    {
        ReportsState r;
        randombytes_buf(r.secret, 32);
        r.has_key = true;
        const size_t one = ReportsState::ENTRY_BYTES;
        r.budget = one * 3;
        for (int i = 1; i <= 3; i++) r.add("rep" + std::to_string(i), B, "spam", i);
        // Every share now holds one report; the newcomer's share is as heavy as any.
        check("a report into a full table is taken", r.add("rep4", B, "spam", 4));
        check("and kept", r.held.count(r.fingerprint("rep4", B, "spam")) == 1 && r.counts[B]["spam"] == 3);
    }

    printf("a restart keeps each report's share\n");
    {
        const std::string fpath = dir + "/fair.json";
        ReportsState r;
        r.load_from_file(fpath);
        const size_t one = ReportsState::ENTRY_BYTES;
        r.budget = one * 10;
        r.add("honest", B, "spam", 100);
        for (int i = 0; i < 9; i++) r.add("throwaway" + std::to_string(i), "12D3KooWT" + std::to_string(i), "spam", 7);
        r.save_if_dirty();

        // What the restart snapshot hands the next process.
        ReportsState again;
        again.adopt_key(r.key_bytes());
        for (const auto& [key, h] : r.held) again.adopted_shares[key] = *r.ledger.share_of(key);
        again.budget = r.budget;
        again.load_from_file(fpath);
        check("every report comes back", again.held.size() == 10 && again.counts[B]["spam"] == 1);
        check("each in the share it was charged to", again.ledger.held(7) == r.ledger.held(7) && again.ledger.held(100) == one);
        check("the handed-over shares are spent", again.adopted_shares.empty());
        for (int i = 0; i < 5; i++) again.add("next" + std::to_string(i), "12D3KooWU" + std::to_string(i), "spam", 7);
        check("the same flood after the restart still evicts only itself", again.counts[B]["spam"] == 1);

        // Without the snapshot (a reboot) each report is a share of its own.
        ReportsState cold;
        cold.adopt_key(r.key_bytes());
        cold.budget = r.budget;
        cold.load_from_file(fpath);
        check("a report the snapshot names no share for is its own share",
              cold.ledger.share_of(cold.fingerprint("honest", B, "spam")).has_value() &&
              ReportsState::is_own_share(*cold.ledger.share_of(cold.fingerprint("honest", B, "spam"))));
    }

    printf("a file past the budget\n");
    {
        const std::string fpath = dir + "/big.json";
        ReportsState r;
        r.load_from_file(fpath);
        for (int i = 0; i < 30; i++) r.add("rep" + std::to_string(i), B, "spam", 7);
        r.save_if_dirty();
        ReportsState small;
        small.adopt_key(r.key_bytes());
        const size_t one = ReportsState::ENTRY_BYTES;
        small.budget = one * 10;
        small.load_from_file(fpath);
        check("a load trims to the budget", small.ledger.total() <= small.budget && small.held.size() == 10);
        check("the oldest reports go first", small.fingerprints() == 10 &&
              small.held.count(r.fingerprint("rep29", B, "spam")) && !small.held.count(r.fingerprint("rep0", B, "spam")));
        check("and their counts with them", small.counts[B]["spam"] == 10);
    }

    printf("a 0.13 file\n");
    {
        // The file a 0.13 relay wrote, read by this one with the key the snapshot handed over.
        const std::string fpath = dir + "/v2.json";
        unsigned char key[32];
        randombytes_buf(key, sizeof(key));
        ReportsState keyed;
        keyed.adopt_key(std::string(reinterpret_cast<const char*>(key), sizeof(key)));
        json v2;
        v2["version"] = 2;
        v2["salt_id"] = salt_id_for(key);
        v2["keys"] = json::array({keyed.fingerprint(A, B, "spam")});
        v2["counts"] = {{B, {{"spam", 3}}}};
        { std::ofstream f(fpath, std::ios::trunc); f << v2.dump(); }

        ReportsState r;
        r.adopt_key(keyed.key_bytes());
        r.load_from_file(fpath);
        check("its fingerprints keep dedup", r.fingerprints() == 1 && !r.add(A, B, "spam", 1));
        check("its counts are carried", r.counts[B]["spam"] == 3);
        check("a new report adds to them", r.add("someone", B, "spam", 1) && r.counts[B]["spam"] == 4);
        r.save_if_dirty();
        ReportsState back;
        back.adopt_key(keyed.key_bytes());
        back.load_from_file(fpath);
        check("the migrated file reads back the same", back.counts[B]["spam"] == 4 && back.fingerprints() == 2 &&
              !back.add(A, B, "spam", 1));
    }

    printf("a 0.13 file past the budget\n");
    {
        const std::string fpath = dir + "/v2big.json";
        unsigned char key[32];
        randombytes_buf(key, sizeof(key));
        ReportsState keyed;
        keyed.adopt_key(std::string(reinterpret_cast<const char*>(key), sizeof(key)));
        json v2;
        v2["version"] = 2;
        v2["salt_id"] = salt_id_for(key);
        v2["keys"] = json::array();
        for (int i = 0; i < 40; i++) v2["keys"].push_back(keyed.fingerprint("rep" + std::to_string(i), B, "spam"));
        const std::string RB = "12D3KooWAbCdEfGhJkLmNpQrStUvWxYz123456789AbCdEfGhJkLm";
        const std::string RC = "12D3KooWZyXwVuTsRqPoNmLkJhGfEdCbA987654321ZyXwVuTsRqPo";
        v2["counts"] = {{RB, {{"spam", 40}}}, {RC, {{"harassment", 5}}}};
        { std::ofstream f(fpath, std::ios::trunc); f << v2.dump(); }
        ReportsState r;
        r.adopt_key(keyed.key_bytes());
        r.budget = ReportsState::ENTRY_BYTES * 20;
        r.load_from_file(fpath);
        check("a migration trimmed past the budget keeps the carried counts",
              r.counts[RB]["spam"] == 40 && r.counts[RC]["harassment"] == 5);
        check("and trims only fingerprints", r.fingerprints() == 20 && r.ledger.total() <= r.budget);
        bool flood_taken = true;
        for (int i = 0; i < 200; i++) flood_taken &= r.add("throwaway" + std::to_string(i), "12D3KooWT" + std::to_string(i), "spam", 7);
        check("a flood after the upgrade evicts no carried count",
              flood_taken && r.counts[RB]["spam"] == 40 && r.counts[RC]["harassment"] == 5 && r.carried.size() == 2);
        r.save_if_dirty();
        ReportsState back;
        back.adopt_key(keyed.key_bytes());
        back.budget = r.budget;
        back.load_from_file(fpath);
        check("the carried counts read back from the v3 file",
              back.carried.size() == 2 && back.counts[RB]["spam"] == 40 && back.counts[RC]["harassment"] == 5);
    }

    printf("every report weighs the same\n");
    {
        ReportsState r;
        randombytes_buf(r.secret, 32);
        r.has_key = true;
        r.budget = ReportsState::ENTRY_BYTES * 3;
        const std::string longest = "12D3KooWAbCdEfGhJkLmNpQrStUvWxYz123456789AbCdEfGhJkLmNpQrStUvWx";
        r.add("long1", longest, "illegal_content", 1);
        r.add("short1", "12D3KooWShort1", "spam", 2);
        check("a long target costs what a short one does", r.ledger.held(1) == r.ledger.held(2));
        r.add("long2", longest, "impersonation", 1);
        r.add("short2", "12D3KooWShort2", "spam", 2);
        // Two each: the newcomer's share gives way, as it would if both named short targets.
        check("which report gives way never reads a string's length",
              r.ledger.held(1) == 2 * ReportsState::ENTRY_BYTES && !r.held.count(r.fingerprint("short1", "12D3KooWShort1", "spam")));
    }

    printf("carried counts past their budget\n");
    {
        const std::string fpath = dir + "/v2counts.json";
        json v2;
        v2["version"] = 2;
        v2["salt_id"] = "other";
        v2["keys"] = json::array();
        v2["counts"] = {{"12D3KooWOne", {{"spam", 1}}}, {"12D3KooWMany", {{"spam", 50}}}, {"12D3KooWSome", {{"blocked", 7}}}};
        { std::ofstream f(fpath, std::ios::trunc); f << v2.dump(); }
        ReportsState r;
        r.carried_budget = ReportsState::ENTRY_BYTES * 2;
        r.load_from_file(fpath);
        check("the smallest count gives way first",
              r.carried.size() == 2 && !r.counts.count("12D3KooWOne") && r.counts["12D3KooWMany"]["spam"] == 50 &&
                  r.counts["12D3KooWSome"]["blocked"] == 7);
    }

    std::string cmd = "rm -rf '" + dir + "'";
    if (std::system(cmd.c_str()) != 0) printf("  (could not remove %s)\n", dir.c_str());

    if (failures) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
