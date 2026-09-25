// Unit tests for the relay's user-report store (src/reports.cpp).
//
// The property that matters: the reports file alone cannot confirm a guessed
// "A reported B". Fingerprints are keyed by a secret in its own 0600 file,
// dedup survives a restart, and a file whose fingerprints were not made with
// the current secret (unsalted legacy, or a lost key) loses its fingerprints
// but keeps its counts.
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
        struct stat st {};
        check("first load creates the key file", ::stat(key_path.c_str(), &st) == 0);
        check("the key file is 32 bytes", st.st_size == 32);
        check("the key file is 0600", (st.st_mode & 0777) == 0600);
        check("the key file is not the reports file", key_path != path);

        check("a first report counts", r.add(A, B, "spam"));
        check("the same report is deduped", !r.add(A, B, "spam"));
        check("another category counts", r.add(A, B, "harassment"));
        check("the fingerprint is not the unsalted hash",
              r.fingerprint(A, B, "spam") != unsalted(A, B, "spam"));
        ::umask(022);
        r.save_if_dirty();
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
    }

    printf("restart\n");
    {
        ReportsState r;
        r.load_from_file(path);
        check("fingerprints survive a restart", r.keys.size() == 2);
        check("dedup survives a restart", !r.add(A, B, "spam"));
        check("counts survive a restart", r.counts[B]["spam"] == 1 && r.counts[B]["harassment"] == 1);
        check("a clean load is not dirty", !r.dirty);
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
        check("the load is dirty so the old keys leave the disk", r.dirty);
        r.save_if_dirty();
        check("the rewritten file holds no unsalted key",
              slurp(path).find(unsalted(A, B, "spam")) == std::string::npos);
        check("a repeat report counts again after migration", r.add(A, B, "spam") &&
                                                             r.counts[B]["spam"] == 2);
        r.save_if_dirty();
    }

    printf("lost key\n");
    {
        ::unlink(key_path.c_str());
        ReportsState r;
        r.load_from_file(path);
        check("a new key is created", ::access(key_path.c_str(), F_OK) == 0);
        check("fingerprints from the old key are dropped", r.keys.empty());
        check("counts are kept", r.counts[B]["spam"] == 2);
    }

    printf("malformed key file\n");
    {
        { std::ofstream f(key_path, std::ios::trunc); f << "short"; }
        ReportsState r;
        check("a short key file is replaced", r.load_or_create_secret(key_path));
        struct stat st {};
        ::stat(key_path.c_str(), &st);
        check("the replacement is 32 bytes and 0600", st.st_size == 32 && (st.st_mode & 0777) == 0600);
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
