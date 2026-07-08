#include "reports.h"
#include "crypto.h"
#include "json.hpp"
#include <sodium.h>
#include <fstream>
#include <sstream>
#include <cstdio>

using json = nlohmann::json;

// Backstop against a report-flood inflating RAM/disk; organic use never gets
// near this. New reports are dropped past the cap (counts stay accurate for
// everything already recorded).
static constexpr size_t MAX_REPORT_KEYS = 500000;

static std::string report_key_hash(const std::string& reporter,
                                   const std::string& target,
                                   const std::string& category) {
    std::string material;
    material.reserve(reporter.size() + target.size() + category.size() + 2);
    material += reporter;
    material += '\0';
    material += target;
    material += '\0';
    material += category;
    unsigned char h[crypto_hash_sha256_BYTES];
    crypto_hash_sha256(h, reinterpret_cast<const unsigned char*>(material.data()),
                       material.size());
    return hex_encode(h, sizeof(h));
}

bool ReportsState::load_from_file(const std::string& path) {
    file_path = path;  // set even when absent so the first save creates it
    std::ifstream f(path);
    if (!f.is_open()) return false;
    std::stringstream buf;
    buf << f.rdbuf();
    try {
        json j = json::parse(buf.str());
        if (j.contains("keys") && j["keys"].is_array()) {
            for (auto& k : j["keys"]) {
                if (k.is_string()) keys.insert(k.get<std::string>());
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
    fprintf(stderr, "[reports] Loaded %zu report(s) across %zu reported peer(s)\n",
            keys.size(), counts.size());
    return true;
}

void ReportsState::save_if_dirty() {
    if (!dirty || file_path.empty()) return;
    json j;
    j["keys"] = json::array();
    for (const auto& k : keys) j["keys"].push_back(k);
    json c = json::object();
    for (const auto& [target, cats] : counts) {
        json cc = json::object();
        for (const auto& [cat, n] : cats) cc[cat] = n;
        c[target] = std::move(cc);
    }
    j["counts"] = std::move(c);

    std::string tmp = file_path + ".tmp";
    {
        std::ofstream f(tmp, std::ios::trunc);
        if (!f.is_open()) return;  // keep dirty — retry on the next flush
        f << j.dump(2);
        if (!f.good()) return;
    }
    if (::rename(tmp.c_str(), file_path.c_str()) != 0) return;
    dirty = false;
    // No content logging — the file itself is the operator's view.
}

bool ReportsState::add(const std::string& reporter, const std::string& target,
                       const std::string& category) {
    std::string key = report_key_hash(reporter, target, category);
    if (keys.count(key)) return false;
    if (keys.size() >= MAX_REPORT_KEYS) return false;
    keys.insert(std::move(key));
    counts[target][category] += 1;
    dirty = true;
    return true;
}
