#include "license.h"
#include "state.h"
#include <cstdio>
#include <fstream>
#include <sstream>

static std::optional<std::string> read_text(const std::string& path) {
    std::ifstream f(path);
    if (!f.is_open()) return std::nullopt;
    std::stringstream buf;
    buf << f.rdbuf();
    return buf.str();
}

static std::optional<KeysFile> read_keys_file(const std::string& path) {
    std::optional<std::string> text = read_text(path);
    if (!text) return std::nullopt;
    return parse_keys_file(*text);
}

bool LicenseState::load_from_file(const std::string& path) {
    file_path = path;
    // Taken before the read: a write landing meanwhile is read on the next reload.
    const FileStamp stamp = file_stamp(path);
    std::optional<KeysFile> file;
    try {
        file = read_keys_file(path);
    } catch (...) {
        file.reset();
    }
    if (!file) {
        if (stamp.exists) fprintf(stderr, "[license] Failed to parse %s\n", path.c_str());
        return false;
    }
    enabled = file->enabled;
    keys = std::move(file->keys);
    last_stamp = stamp;

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

    const FileStamp stamp = file_stamp(file_path);
    if (!stamp.exists || stamp == last_stamp) return;

    // Judged once per change: the previous keys stay until the file reads.
    last_stamp = stamp;
    std::vector<std::string> peers_to_kick;
    bool read = false;
    try {
        std::optional<std::string> text = read_text(file_path);
        read = text && reload_text(*text, peers_to_kick);
    } catch (...) {
        read = false;
    }
    if (!read) {
        fprintf(stderr, "[license] Failed to parse on reload, keeping the previous keys\n");
        return;
    }
    // No logging of the revoked peer_ids (user-identifying).

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
