#include "reports.h"
#include "crypto.h"
#include "json.hpp"
#include <sodium.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

using json = nlohmann::json;

// Backstop against a report-flood inflating RAM/disk; organic use never gets
// near this. New reports are dropped past the cap (counts stay accurate for
// everything already recorded).
static constexpr size_t MAX_REPORT_KEYS = 500000;

static std::string keyed_hex(const unsigned char* key, const std::string& material,
                             size_t out_len) {
    unsigned char h[crypto_generichash_BYTES_MAX];
    crypto_generichash(h, out_len,
                       reinterpret_cast<const unsigned char*>(material.data()),
                       material.size(), key, ReportsState::SECRET_BYTES);
    return hex_encode(h, out_len);
}

std::string ReportsState::fingerprint(const std::string& reporter,
                                      const std::string& target,
                                      const std::string& category) const {
    std::string material;
    material.reserve(reporter.size() + target.size() + category.size() + 2);
    material += reporter;
    material += '\0';
    material += target;
    material += '\0';
    material += category;
    return keyed_hex(secret, material, 32);
}

// No NUL in this label, while every fingerprint's material has two, so the
// two uses of the key never share an input.
std::string ReportsState::salt_id() const {
    return keyed_hex(secret, "hollow-report-salt-id", 8);
}

std::string ReportsState::secret_path_for(const std::string& reports_path) {
    return reports_path + ".key";
}

static bool read_exact(int fd, unsigned char* buf, size_t want, size_t& got) {
    got = 0;
    while (got < want) {
        ssize_t n = ::read(fd, buf + got, want - got);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return false;
        if (n == 0) break;
        got += static_cast<size_t>(n);
    }
    return true;
}

// Owner-only from creation (never a umask-wide window), then renamed into place.
static bool write_private_file(const std::string& path, const void* data, size_t size) {
    std::string tmp = path + ".tmp";
    ::unlink(tmp.c_str());
    int fd = ::open(tmp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) return false;
    const auto* bytes = static_cast<const unsigned char*>(data);
    size_t off = 0;
    bool ok = true;
    while (off < size) {
        ssize_t n = ::write(fd, bytes + off, size - off);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { ok = false; break; }
        off += static_cast<size_t>(n);
    }
    if (ok) ok = ::fsync(fd) == 0;
    ::close(fd);
    if (ok) ok = ::rename(tmp.c_str(), path.c_str()) == 0;
    if (!ok) ::unlink(tmp.c_str());
    return ok;
}

static bool write_secret_file(const std::string& path, const unsigned char* secret) {
    return write_private_file(path, secret, ReportsState::SECRET_BYTES);
}

bool ReportsState::load_or_create_secret(const std::string& path) {
    int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        // One byte past the size tells a longer foreign file from ours.
        unsigned char buf[SECRET_BYTES + 1];
        size_t got = 0;
        bool read_ok = read_exact(fd, buf, sizeof(buf), got);
        ::close(fd);
        if (read_ok && got == SECRET_BYTES) {
            std::memcpy(secret, buf, SECRET_BYTES);
            sodium_memzero(buf, sizeof(buf));
            return true;
        }
        sodium_memzero(buf, sizeof(buf));
        if (!read_ok) {
            randombytes_buf(secret, SECRET_BYTES);
            fprintf(stderr, "[reports] Cannot read %s, using a report key for this run only\n",
                    path.c_str());
            return false;
        }
        fprintf(stderr, "[reports] %s is not a %zu-byte report key, replacing it\n",
                path.c_str(), SECRET_BYTES);
    } else if (errno != ENOENT) {
        randombytes_buf(secret, SECRET_BYTES);
        fprintf(stderr, "[reports] Cannot read %s, using a report key for this run only\n",
                path.c_str());
        return false;
    }

    randombytes_buf(secret, SECRET_BYTES);
    if (!write_secret_file(path, secret)) {
        fprintf(stderr, "[reports] Cannot write %s, using a report key for this run only\n",
                path.c_str());
        return false;
    }
    fprintf(stderr, "[reports] Created report key %s\n", path.c_str());
    return true;
}

bool ReportsState::load_from_file(const std::string& path) {
    file_path = path;  // set even when absent so the first save creates it
    load_or_create_secret(secret_path_for(path));

    std::ifstream f(path);
    if (!f.is_open()) return false;
    std::stringstream buf;
    buf << f.rdbuf();
    size_t dropped = 0;
    try {
        json j = json::parse(buf.str());
        const bool same_salt = j.value("version", 1) == FILE_VERSION &&
                               j.value("salt_id", std::string()) == salt_id();
        if (j.contains("keys") && j["keys"].is_array()) {
            for (auto& k : j["keys"]) {
                if (!k.is_string()) continue;
                if (same_salt) keys.insert(k.get<std::string>());
                else dropped++;
            }
        }
        if (j.contains("counts") && j["counts"].is_object()) {
            for (auto& [target, cats] : j["counts"].items()) {
                if (!cats.is_object()) continue;
                for (auto& [cat, n] : cats.items()) {
                    if (n.is_number_unsigned()) counts[target][cat] = n.get<uint64_t>();
                }
            }
        }
    } catch (...) {
        fprintf(stderr, "[reports] Failed to parse %s\n", path.c_str());
        return false;
    }
    if (dropped > 0) {
        // Rewrite now so the old fingerprints leave the disk at the next flush.
        dirty = true;
        fprintf(stderr, "[reports] Dropped %zu report fingerprint(s) not made with this relay's "
                        "report key; counts kept, a repeat of one of those reports counts again\n",
                dropped);
    }
    fprintf(stderr, "[reports] Loaded %zu report(s) across %zu reported peer(s)\n",
            keys.size(), counts.size());
    return true;
}

void ReportsState::save_if_dirty() {
    if (!dirty || file_path.empty()) return;
    json j;
    j["version"] = FILE_VERSION;
    j["salt_id"] = salt_id();
    j["keys"] = json::array();
    for (const auto& k : keys) j["keys"].push_back(k);
    json c = json::object();
    for (const auto& [target, cats] : counts) {
        json cc = json::object();
        for (const auto& [cat, n] : cats) cc[cat] = n;
        c[target] = std::move(cc);
    }
    j["counts"] = std::move(c);

    const std::string body = j.dump(2);
    const bool ok = write_private_file(file_path, body.data(), body.size());
    if (!ok) {
        // Stays dirty, so a path that becomes writable still saves. The line
        // is logged once because the flush runs every five minutes.
        if (!save_failed_logged) {
            fprintf(stderr, "[reports] Cannot write %s, keeping reports in memory only\n",
                    file_path.c_str());
            save_failed_logged = true;
        }
        return;
    }
    save_failed_logged = false;
    dirty = false;
    // No content logging — the file itself is the operator's view.
}

bool ReportsState::add(const std::string& reporter, const std::string& target,
                       const std::string& category) {
    std::string key = fingerprint(reporter, target, category);
    if (keys.count(key)) return false;
    if (keys.size() >= MAX_REPORT_KEYS) return false;
    keys.insert(std::move(key));
    counts[target][category] += 1;
    dirty = true;
    return true;
}
