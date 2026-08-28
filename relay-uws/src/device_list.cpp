#include "device_list.h"
#include "crypto.h"
#include <algorithm>

std::string device_list_signing_payload(const std::string& master_peer_id,
                                        uint64_t version,
                                        std::vector<std::string> devices,
                                        std::vector<std::string> revoked) {
    // std::string's operator< compares unsigned bytes, which is exactly what
    // Rust's `Vec<String>::sort()` does — the two orderings cannot diverge for
    // any input, ASCII peer_ids included.
    std::sort(devices.begin(), devices.end());
    std::sort(revoked.begin(), revoked.end());

    auto join = [](const std::vector<std::string>& v) {
        std::string out;
        for (size_t i = 0; i < v.size(); i++) {
            if (i) out += ',';
            out += v[i];
        }
        return out;
    };

    // Deliberately built by concatenation rather than a format helper: this
    // string IS the signed message, so it must stay trivially auditable
    // against the Rust format! literal it mirrors.
    std::string payload = "hollow-devices:";
    payload += master_peer_id;
    payload += ':';
    payload += std::to_string(version);
    payload += ':';
    payload += join(devices);
    payload += ':';
    payload += join(revoked);
    return payload;
}

bool verify_signed_device_list(const SignedDeviceList& dl) {
    if (dl.master_pubkey_b64.empty() || dl.master_peer_id.empty() ||
        dl.sig_b64.empty()) {
        return false;
    }

    // Bind pubkey -> claimed master peer_id. Without this a stranger could
    // sign a list naming the victim's master id with their OWN key: the
    // signature would verify and the ownership check would pass.
    // derive_peer_id returns "" on malformed input, and master_peer_id is
    // already known non-empty, so a bad key can never match by accident.
    if (derive_peer_id(dl.master_pubkey_b64) != dl.master_peer_id) {
        return false;
    }

    // Verify over SORTED copies so an attacker cannot reorder or strip either
    // array after the master signed it.
    const std::string payload = device_list_signing_payload(
        dl.master_peer_id, dl.version, dl.devices, dl.revoked);
    return verify_ed25519(dl.master_pubkey_b64, dl.sig_b64, payload);
}

bool device_list_owns_device(const SignedDeviceList& dl,
                             const std::string& device_peer_id) {
    if (device_peer_id.empty()) return false;
    // A revoked id can never be an active device, whatever `devices` says:
    // check the tombstones first so a list that (wrongly) carries an id in
    // both arrays fails closed.
    if (std::find(dl.revoked.begin(), dl.revoked.end(), device_peer_id) !=
        dl.revoked.end()) {
        return false;
    }
    return std::find(dl.devices.begin(), dl.devices.end(), device_peer_id) !=
           dl.devices.end();
}
