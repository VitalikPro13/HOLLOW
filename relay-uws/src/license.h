#pragma once
#include "file_stamp.h"
#include "license_pool.h"
#include <string>

struct RelayState;

// The pool plus the file it is loaded from.
struct LicenseState : LicensePool {
    std::string file_path;
    FileStamp last_stamp;

    bool load_from_file(const std::string& path);
    LicenseResult validate_key(const std::string* key, const std::string& peer_id);
    void release_key(const std::string& peer_id);
    void try_reload(RelayState& state);
};
