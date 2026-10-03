#pragma once
#include <algorithm>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>

#include "json.hpp"
#include "roster.h"

// Whether a destruction order parked on the kill list is the target identity's own:
// its master signed it, and the recovery key pinned in the roster the relay holds for
// that master stands behind it, directly or through a phrase-signed permission for a
// member device (the duress scope). Such an order gets a slot junk can never evict
// (kill_list.h). Everything else stays opaque, as before.
//
// Mirrors the client's `verify_destroy_identity` and `destroy_order_authorised`
// (rust/hollow_core/src/node/crypto_handler.rs): test/test_kill_order.cpp checks this
// file against the vectors the Rust tests write (test/kill_vectors.json); change both
// or neither. Header-only and free of libsodium: the crypto comes in from outside.

namespace kill_order {

struct Delegation {
    std::string device;
    int64_t at_ms = 0;
    std::string r_pub, sig_r, device_sig;
};

struct Order {
    std::string master_pubkey_b64, master_peer_id;
    int64_t issued_at_ms = 0;
    roster::Ids targets;
    bool notify_friends = false;
    std::string sig_b64, r_pub, sig_r;
    std::optional<Delegation> delegation;
};

// Base64 protobuf key -> the peer id it derives, "" for none (crypto.h derive_peer_id).
using DerivePeerId = std::function<std::string(const std::string& pubkey_b64)>;

// Every signature on an order covers this, targets sorted but not deduped, as the
// client's `destroy_payload_of` builds it.
inline std::string payload(const Order& o) {
    roster::Ids targets = o.targets;
    std::sort(targets.begin(), targets.end());
    return "hollow-destroy2:" + o.master_peer_id + ":" + std::to_string(o.issued_at_ms) + ":" + roster::csv(targets) +
           ":" + (o.notify_friends ? "true" : "false");
}

inline std::string delegation_payload(const std::string& master, const Delegation& d) {
    return "hollow-id1-destroy-delegate:" + master + ":" + d.r_pub + ":" + d.device + ":" + std::to_string(d.at_ms);
}

// Read as strictly as serde reads a DestroyIdentity: a field of the wrong type refuses
// the order, a missing one takes its default, a null delegation is none.
inline std::optional<Order> from_json(const nlohmann::json& j) {
    using namespace roster::detail;
    if (!j.is_object()) return std::nullopt;
    Order o;
    bool ok = text(j, "master_pubkey_b64", o.master_pubkey_b64) && text(j, "master_peer_id", o.master_peer_id) &&
              number(j, "issued_at_ms", o.issued_at_ms) && ids(j, "targets", o.targets) &&
              flag(j, "notify_friends", o.notify_friends) && text(j, "sig_b64", o.sig_b64) &&
              text(j, "r_pub", o.r_pub) && text(j, "sig_r", o.sig_r);
    if (!ok) return std::nullopt;
    auto d = j.find("delegation");
    if (d != j.end() && !d->is_null()) {
        if (!d->is_object()) return std::nullopt;
        Delegation x;
        if (!(text(*d, "device", x.device) && number(*d, "at_ms", x.at_ms) && text(*d, "r_pub", x.r_pub) &&
              text(*d, "sig_r", x.sig_r) && text(*d, "device_sig", x.device_sig))) {
            return std::nullopt;
        }
        o.delegation = std::move(x);
    }
    return o;
}

// The signature half, once per deposit: the master signed `o` for the stamp it was
// deposited under, and `held`'s pinned recovery key stands behind it. `state` is
// `held` folded now; only a delegation reads it.
inline bool authorised(const Order& o, int64_t issued_at_ms, const roster::Roster& held, const roster::State& state,
                       const RosterCrypto& c, const DerivePeerId& derive) {
    if (held.r_pub.empty() || o.master_peer_id != held.master || o.issued_at_ms != issued_at_ms) return false;
    const std::string p = payload(o);
    if (derive(o.master_pubkey_b64) != o.master_peer_id || !c.verify_by_id(o.master_peer_id, o.sig_b64, p)) {
        return false;
    }
    if (o.r_pub == held.r_pub && c.verify_by_key(held.r_pub, o.sig_r, p)) return true;
    if (!o.delegation) return false;
    const Delegation& d = *o.delegation;
    return d.r_pub == held.r_pub && state.is_member(d.device) &&
           c.verify_by_key(held.r_pub, d.sig_r, delegation_payload(o.master_peer_id, d)) &&
           c.verify_by_id(d.device, d.device_sig, p);
}

// The per-target half: the order names `target` (or every device), and `target` itself
// consented to belong to the order's identity, so nobody's phrase reaches another
// identity's device.
inline bool reaches(const Order& o, const std::string& target, const roster::Roster& held) {
    const bool named = o.targets.empty() || std::find(o.targets.begin(), o.targets.end(), target) != o.targets.end();
    return named && held.consented().count(target) != 0;
}

}  // namespace kill_order
