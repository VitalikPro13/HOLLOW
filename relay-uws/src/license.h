#pragma once
#include <string>
#include <unordered_set>
#include <unordered_map>
#include <ctime>

struct RelayState;

enum class LicenseResult {
    Ok,
    NotRequired,
    InvalidKey,
    KeyInUse,
    KeyRequired,
};

struct LicenseState {
    bool enabled = false;
    std::unordered_set<std::string> keys;
    std::unordered_map<std::string, std::string> active_keys; // license_key -> peer_id

    std::string file_path;
    time_t last_mtime = 0;

    bool load_from_file(const std::string& path);
    LicenseResult validate_key(const std::string* key, const std::string& peer_id);
    void release_key(const std::string& peer_id);
    void try_reload(RelayState& state);
};
