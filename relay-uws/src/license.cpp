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
        // A members-only relay whose file broke must not open to everyone (HOL-SEC-220).
        if (stamp.exists) {
            refuse_unread();
            fprintf(stderr, "[license] %s is there but does not read: every login is refused until it does\n",
                    path.c_str());
        }
        return false;
    }
    enabled = file->enabled;
    keys = std::move(file->keys);
    last_stamp = stamp;

    fprintf(stderr, "[license] Loaded %zu key(s), enabled=%s\n",
            keys.size(), enabled ? "true" : "false");
    return true;
}

LicenseResult LicenseState::validate_key(const std::string* key, const std::string& peer_id, SeatToken socket) {
    return validate(key, peer_id, socket);
}

void LicenseState::release_seat(SeatToken socket) {
    release(socket);
}

bool LicenseState::try_reload(RelayState& state) {
    if (file_path.empty()) return false;

    const FileStamp stamp = file_stamp(file_path);
    if (!stamp.exists || stamp == last_stamp) return false;

    // Judged once per change: the previous keys stay until the file reads.
    last_stamp = stamp;
    Kicks sockets_to_kick;
    bool read = false;
    try {
        std::optional<std::string> text = read_text(file_path);
        read = text && reload_text(*text, sockets_to_kick);
    } catch (...) {
        read = false;
    }
    if (!read) {
        fprintf(stderr, unread ? "[license] Still does not read on reload, every login stays refused\n"
                               : "[license] Failed to parse on reload, keeping the previous keys\n");
        return false;
    }
    // No logging of the revoked peer_ids (user-identifying).

    fprintf(stderr, "[license] Reloaded: %zu key(s), enabled=%s\n",
            keys.size(), enabled ? "true" : "false");

    // Every socket a revoked key let in goes, fetch and guest sockets too, and with the
    // gate turned on every socket the open gate let in. Each was still open (its close
    // gives its seat back), so the lookup only guards a close one of these ends brought
    // about. The 1008 ends each one's session too, so a relogin is judged afresh.
    auto end = [&state](SeatToken token, const char* error, const char* reason) {
        auto* ws = reinterpret_cast<SSLWebSocket*>(token);
        if (!state.open_sockets.count(ws) || ws->getUserData()->closing) return;
        ws->send(std::string(R"({"type":"auth_failed","error":")") + error + "\"}", uWS::OpCode::TEXT);
        ws->end(1008, reason);
    };
    for (SeatToken token : sockets_to_kick.revoked) end(token, "invalid_license_key", "license_revoked");
    for (SeatToken token : sockets_to_kick.keyless) end(token, "license_key_required", "license_required");
    return true;
}
