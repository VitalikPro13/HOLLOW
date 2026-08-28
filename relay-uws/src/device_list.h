#pragma once
#include <cstdint>
#include <string>
#include <vector>

// A master-signed device list. Mirrors the client's `SignedDeviceList`
// (rust/hollow_core/src/node/types.rs): one MASTER identity vouching for the
// set of DEVICE peer_ids it owns, plus the tombstones it has revoked.
//
// The relay only ever VERIFIES one of these; it never builds, stores, or
// forwards one. The single use is the inbox mailbox ownership proof: a socket
// that authenticated as device D may read the mailbox of master M only by
// showing M's signature over a list that still contains D.
struct SignedDeviceList {
    std::string master_pubkey_b64;   // base64 protobuf Ed25519 public key
    std::string master_peer_id;      // claimed id; MUST derive from the pubkey
    std::vector<std::string> devices;
    std::vector<std::string> revoked;
    uint64_t version = 0;
    std::string sig_b64;             // master signature over the payload below
};

// Canonical signing payload, byte-for-byte identical to the Rust
// `device_list_signing_payload` (crypto_handler.rs):
//
//   "hollow-devices:{master_peer_id}:{version}:{devices_csv}:{revoked_csv}"
//
// Both arrays are SORTED here (the signer sorts before signing), and the
// trailing revoked segment is always present even when the list is empty, so
// one signature covers adds and removes under one version. Taken by value
// because it sorts its own copies.
std::string device_list_signing_payload(const std::string& master_peer_id,
                                        uint64_t version,
                                        std::vector<std::string> devices,
                                        std::vector<std::string> revoked);

// True iff the list is cryptographically sound: the master pubkey derives to
// the claimed `master_peer_id` AND the signature validates over the canonical
// payload. Mirrors the Rust `verify_device_list`. Does NOT enforce version
// monotonicity (the relay keeps no history and needs none: the proof is only
// ever used to gate a read of a mailbox the master itself named).
//
// SECURITY: rejects, never logs-and-continues. Every failure path returns
// false; there is no "sig present so probably fine" branch.
bool verify_signed_device_list(const SignedDeviceList& dl);

// True iff `device_peer_id` is an active device of this list: present in
// `devices` and absent from `revoked`. Says NOTHING about the signature; call
// verify_signed_device_list first.
bool device_list_owns_device(const SignedDeviceList& dl,
                             const std::string& device_peer_id);
