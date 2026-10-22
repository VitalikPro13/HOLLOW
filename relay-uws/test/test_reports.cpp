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

        check("a first report counts", r.add(A, B, "spam"));
        check("the same report is deduped", !r.add(A, B, "spam"));
        check("another category counts", r.add(A, B, "harassment"));
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
        check("fingerprints survive a restart that hands the key over", again.keys.size() == 2);
        check("dedup survives it", !again.add(A, B, "spam"));
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
        check("fingerprints from the lost key are dropped", r.keys.empty());
        check("and leave the disk at once", json::parse(slurp(path))["keys"].empty() && !r.dirty);
        check("counts are kept", r.counts[B]["spam"] == 1 && r.counts[B]["harassment"] == 1);
        check("a repeat report counts again", r.add(A, B, "spam") && r.counts[B]["spam"] == 2);
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
        old.add(A, B, "impersonation");
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
        check("fingerprints made under it are dropped", r.keys.empty());
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
        check("a block counts", r.add(A, B, "blocked"));
        check("blocking the same person again does not", !r.add(A, B, "blocked"));
        check("a block is its own count beside a report",
              r.add(A, B, "spam") && r.counts[B]["blocked"] == 1 && r.counts[B]["spam"] == 1);
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
        check("unsalted keys are dropped", r.keys.empty());
        check("counts are kept", r.counts[B]["spam"] == 1);
        check("the rewritten file holds no unsalted key",
              slurp(path).find(unsalted(A, B, "spam")) == std::string::npos);
        check("a repeat report counts again after migration", r.add(A, B, "spam") &&
                                                             r.counts[B]["spam"] == 2);
        r.save_if_dirty();
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
