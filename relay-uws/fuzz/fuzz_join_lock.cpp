// Join lock chains (`lock_put`, src/join_lock.h) offered one after another the way
// handle_lock_put takes them: the key shape, the links read whole or not at all, then
// the put rule against whatever the relay holds. The input is a JSON array of
// lock_put frames. Whatever the relay ends up holding for a server must still be one
// chain that verifies, under the owner its record is keyed by.

#include <string>
#include <vector>

#include "client_json.h"
#include "fuzz_support.h"
#include "join_lock.h"
#include "validate.h"

namespace {

std::string text_field(const nlohmann::json& j, const char* field) {
    auto it = j.find(field);
    return it != j.end() && it->is_string() ? it->get<std::string>() : std::string();
}

bool same_links(const std::vector<LockLink>& a, const std::vector<LockLink>& b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); i++) {
        if (!(a[i] == b[i]) || a[i].has_owner != b[i].has_owner || a[i].has_nonce != b[i].has_nonce) return false;
    }
    return true;
}

}  // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    const nlohmann::json frames = client_json::parse(fuzz::as_text(data, size));
    if (!frames.is_array()) return 0;
    static const LockCrypto crypto = fuzz::lock_crypto();
    JoinLocks locks;
    // Small enough that a handful of chains already evicts.
    locks.budget = 16 * 1024;
    uint64_t share = 1;
    size_t puts = 0;
    for (const auto& j : frames) {
        if (++puts > 32) break;
        if (!j.is_object()) continue;
        const std::string server = text_field(j, "server");
        const std::string owner = text_field(j, "owner");
        if (!join_lock::is_server_id_shape(server) || !(owner.empty() || is_peer_id_shape(owner))) continue;
        auto links_it = j.find("links");
        if (links_it == j.end()) continue;
        auto links = join_lock::links_from_json(*links_it);
        if (!links) continue;
        FUZZ_CHECK(links->size() <= join_lock::MAX_CHAIN);
        auto back = join_lock::links_from_json(join_lock::links_to_json(*links));
        FUZZ_CHECK(back && same_links(*back, *links));

        std::vector<LockLink> current;
        const bool accepted = locks.put(server, owner, *links, crypto, current, share++ % 3);
        FUZZ_CHECK(current.size() <= join_lock::MAX_CHAIN);
        if (accepted) FUZZ_CHECK(!current.empty() && current.back().same_lock(links->back()));
        if (!current.empty()) {
            const std::string chain_owner = join_lock::verify_chain(server, current, crypto);
            FUZZ_CHECK(!chain_owner.empty());
            if (!join_lock::is_genesis_id(server)) FUZZ_CHECK(chain_owner == owner);
        }
        const std::vector<LockLink>* held = locks.get(join_lock::record_key(server, owner));
        if (held) FUZZ_CHECK(same_links(*held, current));
        FUZZ_CHECK(locks.bytes() <= locks.budget || locks.size() <= 1);
    }
    return 0;
}
