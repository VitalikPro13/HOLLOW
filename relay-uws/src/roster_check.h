#pragma once
#include <cstdint>
#include <string>
#include <string_view>

#include "join_lock.h"
#include "roster.h"
#include "validate.h"

// `roster_check`: a member asks for the statements the relay holds for one identity, to
// judge a co-member's device by a second source before it hands that device a KeyPackage
// or takes its Welcome (design ROSTER-CHECK). The relay answers with statements, never a
// verdict, and only about an identity the asker already sees a device of in a server room
// it sits in, so the query names nothing a stranger could not already hear there.
//
// Header-only and free of uWebSockets: test/test_roster_check.cpp replays
// roster_check_vectors.json through `answers`, and the client's harness relay reads the
// same file.
namespace roster_check {

// Everything the answer depends on, as the handler finds it.
struct Facts {
    bool full = false;          // a full socket: never fetch or guest
    std::string master, device, nonce, room;
    bool asker_in_room = false;  // this socket holds the asker's slot in `room`
    bool locked = false;         // the relay holds `room`'s join lock
    bool newest_door = false;    // the asker holds the newest door (never a grace)
    bool device_listed = false;  // `device` sits in `room` and presence lists it to the asker
    bool placed = false;         // the relay's own fold of `master` places `device`
};

inline bool nonce_shape(std::string_view n) {
    if (n.empty() || n.size() > 32) return false;
    for (char c : n) {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z'))) return false;
    }
    return true;
}

// Rooms named like a server (legacy 32 hex, genesis 40 hex). DM and own rooms share the
// shape; their occupants already hold each other's rosters. Prefixed rooms never answer.
inline bool room_shape(std::string_view room) { return join_lock::is_server_id_shape(room); }

// A device the fold names by statements with standing: a member, a removed device or a
// pending join. A consent alone, which any key can sign for any master, places nothing.
inline bool places(const roster::State& s, const std::string& device) {
    return s.members.count(device) != 0 || s.removed.count(device) != 0 || s.pending.count(device) != 0;
}

inline bool answers(const Facts& f) {
    return f.full && is_peer_id_shape(f.master) && is_peer_id_shape(f.device) && nonce_shape(f.nonce) &&
           room_shape(f.room) && f.asker_in_room && (!f.locked || f.newest_door) && f.device_listed && f.placed;
}

}  // namespace roster_check
