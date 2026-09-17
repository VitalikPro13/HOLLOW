#pragma once
#include "license_pool.h"
#include <string>
#include <ctime>

struct RelayState;

// The pool plus the file it is loaded from.
struct LicenseState : LicensePool {
    std::string file_path;
    time_t last_mtime = 0;

    bool load_from_file(const std::string& path);
    LicenseResult validate_key(const std::string* key, const std::string& peer_id);
    void release_key(const std::string& peer_id);
    void try_reload(RelayState& state);
};
