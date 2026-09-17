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
    return validate(key, peer_id);
}

void LicenseState::release_key(const std::string& peer_id) {
    release(peer_id);
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

    // No logging of the revoked peer_ids (user-identifying).
    std::vector<std::string> peers_to_kick = replace_keys(std::move(new_keys), j.value("enabled", false));
    last_mtime = st.st_mtime;

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
