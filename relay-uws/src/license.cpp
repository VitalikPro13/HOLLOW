#include "license.h"
#include "state.h"
#include "json.hpp"
#include <cstdio>
#include <fstream>
#include <sstream>
#include <sys/stat.h>

using json = nlohmann::json;

bool LicenseState::load_from_file(const std::string& path) {
    file_path = path;

    std::ifstream f(path);
    if (!f.is_open()) return false;

    std::stringstream buf;
    buf << f.rdbuf();

    json j;
    try {
        j = json::parse(buf.str());
    } catch (...) {
        fprintf(stderr, "[license] Failed to parse %s\n", path.c_str());
        return false;
    }

    enabled = j.value("enabled", false);
    keys.clear();
    if (j.contains("keys") && j["keys"].is_array()) {
        for (auto& k : j["keys"]) {
            if (k.is_string()) keys.insert(k.get<std::string>());
        }
    }

    struct stat st;
    if (stat(path.c_str(), &st) == 0) {
        last_mtime = st.st_mtime;
    }

    fprintf(stderr, "[license] Loaded %zu key(s), enabled=%s\n",
            keys.size(), enabled ? "true" : "false");
    return true;
}

LicenseResult LicenseState::validate_key(const std::string* key,
                                          const std::string& peer_id) {
    if (!enabled) return LicenseResult::NotRequired;

    if (!key || key->empty()) return LicenseResult::KeyRequired;

    if (keys.find(*key) == keys.end()) return LicenseResult::InvalidKey;

    auto it = active_keys.find(*key);
    if (it != active_keys.end() && it->second != peer_id) {
        return LicenseResult::KeyInUse;
    }

    active_keys[*key] = peer_id;
    return LicenseResult::Ok;
}

void LicenseState::release_key(const std::string& peer_id) {
    for (auto it = active_keys.begin(); it != active_keys.end(); ) {
        if (it->second == peer_id)
            it = active_keys.erase(it);
        else
            ++it;
    }
}

void LicenseState::try_reload(RelayState& state) {
    if (file_path.empty()) return;

    struct stat st;
    if (stat(file_path.c_str(), &st) != 0) return;

    if (st.st_mtime == last_mtime) return;

    std::ifstream f(file_path);
    if (!f.is_open()) {
        fprintf(stderr, "[license] Failed to re-read %s\n", file_path.c_str());
        return;
    }

    std::stringstream buf;
    buf << f.rdbuf();

    json j;
    try {
        j = json::parse(buf.str());
    } catch (...) {
        fprintf(stderr, "[license] Failed to parse on reload\n");
        return;
    }

    std::unordered_set<std::string> new_keys;
    if (j.contains("keys") && j["keys"].is_array()) {
        for (auto& k : j["keys"]) {
            if (k.is_string()) new_keys.insert(k.get<std::string>());
        }
    }

    // Collect peers to kick (keys removed)
    std::vector<std::string> peers_to_kick;
    for (auto& [lic_key, pid] : active_keys) {
        if (new_keys.find(lic_key) == new_keys.end()) {
            peers_to_kick.push_back(pid);
            fprintf(stderr, "[license] Key revoked for peer %s\n", pid.c_str());
        }
    }

    enabled = j.value("enabled", false);
    keys = std::move(new_keys);
    last_mtime = st.st_mtime;

    // Remove revoked from active tracking
    if (!peers_to_kick.empty()) {
        for (auto& pid : peers_to_kick) {
            for (auto it = active_keys.begin(); it != active_keys.end(); ) {
                if (it->second == pid) it = active_keys.erase(it);
                else ++it;
            }
        }
    }

    fprintf(stderr, "[license] Reloaded: %zu key(s), enabled=%s\n",
            keys.size(), enabled ? "true" : "false");

    // Kick peers with revoked keys
    for (auto& pid : peers_to_kick) {
        auto it = state.peer_sockets.find(pid);
        if (it != state.peer_sockets.end()) {
            std::string err = R"({"type":"auth_failed","error":"invalid_license_key"})";
            it->second->send(err, uWS::OpCode::TEXT);
            it->second->end(1008, "license_revoked");
        }
    }
}
