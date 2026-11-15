"""Session 32 mutation pass (phase B row 0.5, the relay's dispatch gates): break each
gate in relay-uws/src/ws_handler.cpp, expect the live tests (relay-uws/test/run_live.sh,
the real relay on loopback) to FAIL, restore byte for byte. Runs on Linux, from a scratch
copy laid out as <dir>/tmp_s32_relay_mutate.py + <dir>/relay-uws/.

Prints one line per mutation: KILLED, SURVIVED or BROKEN. Pass words to run only the
mutations whose name has one; --check only verifies every pattern matches once.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RELAY = os.path.join(ROOT, 'relay-uws')
WS = os.path.join(RELAY, 'src/ws_handler.cpp')
CACHE = os.path.join(ROOT, 'mutation-build')
OUT = os.path.join(ROOT, 'mutation-out')
ON, OFF = 'on', 'off'


def m(name, old, new, variant=ON):
    return (name, [(WS, old, new)], variant)


MUTATIONS = [
    # The four release-day switches, each forced open and forced shut.
    m('switch: v1 auth accepted whatever the switch', '    } else if (ACCEPT_AUTH_V1) {', '    } else if (true) {', OFF),
    m('switch: v1 auth refused whatever the switch', '    } else if (ACCEPT_AUTH_V1) {', '    } else if (false) {', ON),
    m('switch: unsigned ring control applied whatever the switch',
      '    if (ACCEPT_UNSIGNED_RING_CONTROL) {', '    if (true) {', OFF),
    m('switch: unsigned ring control ignored whatever the switch',
      '    if (ACCEPT_UNSIGNED_RING_CONTROL) {', '    if (false) {', ON),
    m('switch: unsigned nickname taken whatever the switch',
      '    } else if (!ACCEPT_UNSIGNED_NICKNAME_CLAIMS) {', '    } else if (false) {', OFF),
    m('switch: unsigned nickname refused whatever the switch',
      '    } else if (!ACCEPT_UNSIGNED_NICKNAME_CLAIMS) {', '    } else if (true) {', ON),
    m('switch: device list read whatever the switch',
      '    if (!ACCEPT_DEVICE_LIST_INBOX_PROOF || data->is_guest) return false;',
      '    if (data->is_guest) return false;', OFF),
    m('switch: device list ignored whatever the switch',
      '    if (!ACCEPT_DEVICE_LIST_INBOX_PROOF || data->is_guest) return false;',
      '    if (true) return false;', ON),
    m('device list: any socket owns the listed inbox',
      '    const bool owns = device_list_owns_device(dl, data->peer_id);',
      '    const bool owns = true;', ON),

    # Auth v2.
    m('auth v2: domain not checked',
      '        if (!mode || !challenged || frame->domain != auth_domain(config.domain)) {',
      '        if (!mode || !challenged) {'),
    m('auth v2: challenge not checked',
      '        if (!mode || !challenged || frame->domain != auth_domain(config.domain)) {',
      '        if (!mode || frame->domain != auth_domain(config.domain)) {'),

    # Guests.
    m('guest: 0x04 allowed', 'if (opcode == 0x04 || opcode == 0x07 || opcode == 0x08 || opcode == 0x09) return;',
      'if (opcode == 0x07 || opcode == 0x08 || opcode == 0x09) return;'),
    m('guest: 0x07 allowed', 'if (opcode == 0x04 || opcode == 0x07 || opcode == 0x08 || opcode == 0x09) return;',
      'if (opcode == 0x04 || opcode == 0x08 || opcode == 0x09) return;'),
    m('guest: 0x08 allowed', 'if (opcode == 0x04 || opcode == 0x07 || opcode == 0x08 || opcode == 0x09) return;',
      'if (opcode == 0x04 || opcode == 0x07 || opcode == 0x09) return;'),
    m('guest: 0x09 allowed', 'if (opcode == 0x04 || opcode == 0x07 || opcode == 0x08 || opcode == 0x09) return;',
      'if (opcode == 0x04 || opcode == 0x07 || opcode == 0x08) return;'),
    m('guest: no broadcast rate', '                            if (data->binary_frames_this_minute >= GUEST_BINARY_PER_MIN) return;',
      '                            if (false) return;'),
    m('guest: no room cap', '    size_t max_rooms = data->is_guest ? MAX_GUEST_ROOMS : MAX_ROOMS_PER_PEER;',
      '    size_t max_rooms = MAX_ROOMS_PER_PEER;'),
    m('guest: JSON direct allowed', "    // wakes the target's phone.\n    if (data->is_guest) return;",
      "    // wakes the target's phone.\n    if (false) return;"),
    m('guest: check_peers answered', '        if (!data->is_guest && j.contains("peers") && j["peers"].is_array()) {',
      '        if (j.contains("peers") && j["peers"].is_array()) {'),
    m('guest: TURN credentials',
      '        if (data->is_guest) {\n            send_json(ws, {{"type", "turn_credentials"}, {"error", "auth required"}});',
      '        if (false) {\n            send_json(ws, {{"type", "turn_credentials"}, {"error", "auth required"}});'),
    m('guest: media forwarder',
      '        if (data->is_guest) {\n            send_json(ws, {{"type", "media_forwarder"}, {"error", "auth required"}});',
      '        if (false) {\n            send_json(ws, {{"type", "media_forwarder"}, {"error", "auth required"}});'),
    m('guest: report filed', '    if (data->is_guest) return;\n    std::string target = j.value("target", "");',
      '    if (false) return;\n    std::string target = j.value("target", "");'),
    m('guest: destroy signal parked',
      '    if (data->is_guest) return;\n    // A fetch socket is a push isolate: it receives signals, it never issues.',
      '    if (false) return;\n    // A fetch socket is a push isolate: it receives signals, it never issues.'),
    m('guest: join lock read', '    if (data->is_guest) return;\n    auto locks = j.find("locks");',
      '    if (false) return;\n    auto locks = j.find("locks");'),
    m('guest: join lock offered', '    if (data->is_guest || data->is_fetch) return;\n    std::string server = json_text(j, "server");',
      '    if (data->is_fetch) return;\n    std::string server = json_text(j, "server");'),
    m('guest: nickname claimed', '    if (data->is_guest || data->is_fetch) return;\n\n    std::string nickname',
      '    if (data->is_fetch) return;\n\n    std::string nickname'),
    m('guest: link code claimed', '    if (data->is_guest) return;\n\n    std::string code = to_uppercase(raw_code);\n    if (!is_valid_link_code',
      '    if (false) return;\n\n    std::string code = to_uppercase(raw_code);\n    if (!is_valid_link_code'),
    m('guest: link code resolved',
      '    // Mirrors handle_claim_link_code: a guest has no identity to link to.\n    if (data->is_guest) return;',
      '    // Mirrors handle_claim_link_code: a guest has no identity to link to.\n    if (false) return;'),
    m('guest: ring catch-up', '    if (data->is_guest) return;\n    std::string room = j.value("room", "");\n    std::string channel',
      '    if (false) return;\n    std::string room = j.value("room", "");\n    std::string channel'),
    m('guest: ring control', '    if (data->is_guest || data->is_fetch) return;\n    ring_auth::Control c;',
      '    if (data->is_fetch) return;\n    ring_auth::Control c;'),
    m('guest: owns an inbox by roster', '    if (data->is_guest || !is_inbox_room(room)) return false;',
      '    if (!is_inbox_room(room)) return false;'),
    m('guest: door proof counts', '        const std::string proof = data->is_guest ? std::string() : door_proof;',
      '        const std::string proof = door_proof;'),
    m('guest: listed to later joiners',
      '            if (pid != data->peer_id && !pd->is_guest && !pd->is_fetch && aud.sees(pid)) {\n                existing_peers',
      '            if (pid != data->peer_id && !pd->is_fetch && aud.sees(pid)) {\n                existing_peers'),
    m('guest: announced', '    if (!data->is_guest && !data->is_fetch && !already_present && visible) {',
      '    if (!data->is_fetch && !already_present && visible) {'),
    m('guest: discovered', '                    if (sees && pid != data->peer_id && !pd->is_guest && !pd->is_fetch && aud.sees(pid)) {',
      '                    if (sees && pid != data->peer_id && !pd->is_fetch && aud.sees(pid)) {'),
    m('guest: its leave announced', '    return d->is_guest || d->is_fetch;', '    return d->is_fetch;'),

    # Fetch sockets.
    m('fetch: takes a full socket\'s slot', '        if (!full_holds) {', '        if (true) {'),
    m('fetch: joins like a full socket', '    if (data->is_fetch) {\n        auto held = ws_room.peers.find(data->peer_id);',
      '    if (false) {\n        auto held = ws_room.peers.find(data->peer_id);'),
    m('fetch: listed to later joiners',
      '            if (pid != data->peer_id && !pd->is_guest && !pd->is_fetch && aud.sees(pid)) {\n                existing_peers',
      '            if (pid != data->peer_id && !pd->is_guest && aud.sees(pid)) {\n                existing_peers'),
    m('fetch: discovered', '                    if (sees && pid != data->peer_id && !pd->is_guest && !pd->is_fetch && aud.sees(pid)) {',
      '                    if (sees && pid != data->peer_id && !pd->is_guest && aud.sees(pid)) {'),
    m('fetch: login supersedes the full socket', '    if (!data->is_fetch) {\n        auto existing = state.peer_sockets.find(peer_id);',
      '    if (true) {\n        auto existing = state.peer_sockets.find(peer_id);'),
    m('fetch: login resets the full socket\'s rooms',
      '        state.peer_rooms[peer_id] = {};\n    }\n\n    send_json(ws, {{"type", "auth_ok"}});',
      '    }\n    state.peer_rooms[peer_id] = {};\n\n    send_json(ws, {{"type", "auth_ok"}});'),
    m('fetch: leave evicts the full socket', '        leave_room(state, data->peer_id, room, ws);\n        data->fetch_rooms.erase(room);',
      '        leave_room(state, data->peer_id, room);\n        data->fetch_rooms.erase(room);'),
    m('fetch: close evicts the full socket',
      '                for (const auto& room : data->fetch_rooms) {\n                    leave_room(state, data->peer_id, room, ws);',
      '                for (const auto& room : data->fetch_rooms) {\n                    leave_room(state, data->peer_id, room);'),
    m('fetch: its leave announced', '    return d->is_guest || d->is_fetch;', '    return d->is_guest;'),
    m('fetch: join lock offered', '    if (data->is_guest || data->is_fetch) return;\n    std::string server = json_text(j, "server");',
      '    if (data->is_guest) return;\n    std::string server = json_text(j, "server");'),
    m('fetch: destroy signal parked',
      '    // A fetch socket is a push isolate: it receives signals, it never issues.\n    if (data->is_fetch) return;',
      '    // A fetch socket is a push isolate: it receives signals, it never issues.\n    if (false) return;'),
    m('fetch: nickname claimed', '    if (data->is_guest || data->is_fetch) return;\n\n    std::string nickname',
      '    if (data->is_guest) return;\n\n    std::string nickname'),
    m('fetch: ring control', '    if (data->is_guest || data->is_fetch) return;\n    ring_auth::Control c;',
      '    if (data->is_guest) return;\n    ring_auth::Control c;'),

    # Inbox rooms (receives_in_room is the Audience).
    m('inbox: everyone sees', '        if (inbox) return room.owners.count(peer) != 0;',
      '        if (false) return room.owners.count(peer) != 0;'),
    m('inbox: everyone reachable', '    bool reachable(const std::string& peer) const { return !inbox || room.owners.count(peer) != 0; }',
      '    bool reachable(const std::string& peer) const { return true; }'),
    m('co-members: the caller not checked', '        if (!aud.sees(caller)) continue;', '        if (false) continue;'),
    m('co-members: the peer not checked', '            if (!aud.sees(pid)) continue;\n            if (budget == 0)',
      '            if (false) continue;\n            if (budget == 0)'),
    m('JSON msg: to the whole room', '        if (pid != data->peer_id && aud.sees(pid)) {\n            send_to_peer(peer_ws, broadcast_str',
      '        if (pid != data->peer_id) {\n            send_to_peer(peer_ws, broadcast_str'),
    m('0x03: to the whole room', '        if (pid != data->peer_id && (public_frame || aud.sees(pid))) {',
      '        if (pid != data->peer_id) {'),
    m('0x07: to the whole room', '        if (!aud.sees(pid)) continue;\n\n        auto* peer_data',
      '        if (false) continue;\n\n        auto* peer_data'),
    m('0x02: any target', '    if (!audience(state, rit->second, room_str).reachable(target_str)) return;\n\n    // Build forwarded frame',
      '    if (false) return;\n\n    // Build forwarded frame'),
    m('JSON direct: any target',
      '    if (tit != rit->second.peers.end() && !audience(state, rit->second, room).reachable(target)) return;',
      '    if (false) return;'),
    m('0x04: any target', '    if (!audience(state, rit->second, room_str).reachable(target_str)) return;\n\n    if (!g_forwarder_peer_id',
      '    if (false) return;\n\n    if (!g_forwarder_peer_id'),
    m('inbox: a deposit goes live to everyone', '            for (const auto& owner_id : rit->second.owners) {',
      '            for (const auto& [owner_id, unused_ws] : rit->second.peers) {'),
    m('join: everyone sees the roster', '    const bool visible = (!inbox || owner) && door_ok;', '    const bool visible = door_ok;'),
    m('discover: the caller not checked', '                    if (sees && pid != data->peer_id',
      '                    if (pid != data->peer_id'),
    m('inbox: every joiner reads the mailbox',
      '    if (owner) {\n        replay_mailbox_no_delete(ws, room.substr(sizeof(INBOX_ROOM_PREFIX) - 1), room, state);\n    }\n}',
      '    if (true) {\n        replay_mailbox_no_delete(ws, room.substr(sizeof(INBOX_ROOM_PREFIX) - 1), room, state);\n    }\n}'),
    m('inbox: any shown roster owns', '    if (r.changed) drop_inbox_owners(state, room, r.state);\n    return r.member;',
      '    if (r.changed) drop_inbox_owners(state, room, r.state);\n    return true;'),

    # Door rooms (D1).
    m('door: everyone sees a locked room', '        return !locked || room.doors.sees(peer, now_ms);', '        return true;'),
    m('door: no room is locked', '    if (!join_lock::is_genesis_id(room)) return nullptr;', '    return nullptr;'),
    m('door: the proof is not checked',
      '        const bool opens = !proof.empty() && door_opens(state, data, room, lock->door, proof);',
      '        const bool opens = !proof.empty();'),
    m('door: a public frame is not public', '    const bool public_frame = to_all && aud.locked && aud.sees(data->peer_id);',
      '    const bool public_frame = false;'),
    m('door: a hidden socket\'s public frame reaches the hidden',
      '    const bool public_frame = to_all && aud.locked && aud.sees(data->peer_id);',
      '    const bool public_frame = to_all && aud.locked;'),
    m('door: a hidden socket\'s leave announced',
      '    bool leaving_peer_invisible = is_invisible_in_room(state, peer_id, room) ||\n                                  !audience(state, rit->second, room).sees(peer_id);',
      '    bool leaving_peer_invisible = is_invisible_in_room(state, peer_id, room);'),
    m('door: the hidden read the ring', '    if (!audience(state, rit->second, room).sees(data->peer_id)) return;\n    std::string key = room;',
      '    if (false) return;\n    std::string key = room;'),
    m('door: no channel copy for a hidden member',
      '    bool in_room = rit->second.peers.find(target_str) != rit->second.peers.end() &&\n                   audience(state, rit->second, room_str).sees(target_str);',
      '    bool in_room = rit->second.peers.find(target_str) != rit->second.peers.end();'),
    m('door: presence told to the hidden',
      '    for (const auto& [pid, sock] : room.peers) {\n        if (pid != peer && !sock->getUserData()->is_guest && aud.sees(pid)) {\n            send_to_peer(sock, frame',
      '    for (const auto& [pid, sock] : room.peers) {\n        if (pid != peer && !sock->getUserData()->is_guest) {\n            send_to_peer(sock, frame'),
    m('door: the hidden listed to provers',
      '            if (pid != data->peer_id && !pd->is_guest && !pd->is_fetch && aud.sees(pid)) {\n                existing_peers',
      '            if (pid != data->peer_id && !pd->is_guest && !pd->is_fetch) {\n                existing_peers'),
]


def read(path):
    return open(path, encoding='utf-8', newline='').read()


def write(path, text):
    open(path, 'w', encoding='utf-8', newline='').write(text)


def patterns_ok():
    ok = True
    for name, edits, _ in MUTATIONS:
        for path, old, _new in edits:
            cur = read(path)
            if '\r\n' in cur:
                old = old.replace('\n', '\r\n')
            n = cur.count(old)
            if n != 1:
                print(f'PATTERN   {name}: found {n}x: {old[:70]!r}')
                ok = False
    return ok


def run_live(variant):
    env = dict(os.environ, RELAY_LIVE_BUILD=CACHE, RELAY_LIVE_VARIANTS=variant)
    p = subprocess.run(['bash', os.path.join(RELAY, 'test/run_live.sh'), OUT], capture_output=True, text=True,
                       encoding='utf-8', errors='replace', env=env)
    out = p.stdout + p.stderr
    if 'BUILD FAIL' in out:
        return 'BROKEN', out[-2000:]
    if p.returncode != 0 and 'FAIL test_relay_live' in out:
        return 'KILLED', '\n'.join(l for l in out.splitlines() if 'FAIL' in l)
    if p.returncode != 0:
        return 'BROKEN', out[-2000:]
    return 'SURVIVED', ''


def mutate(name, edits, variant):
    originals = {}
    try:
        for path, old, new in edits:
            cur = read(path)
            originals.setdefault(path, cur)
            if '\r\n' in cur:
                old, new = old.replace('\n', '\r\n'), new.replace('\n', '\r\n')
            if cur.count(old) != 1:
                raise SystemExit(f'{name}: pattern found {cur.count(old)}x in {path}: {old[:70]!r}')
            write(path, cur.replace(old, new))
        verdict, detail = run_live(variant)
    finally:
        for path, src in originals.items():
            write(path, src)
    print(f'{verdict:9} [{variant:3}] {name}', flush=True)
    if detail and verdict != 'SURVIVED':
        print('    ' + detail.replace('\n', '\n    ')[:1200], flush=True)
    return verdict


if '--check' in sys.argv:
    sys.exit(0 if patterns_ok() else 1)
if not patterns_ok():
    sys.exit(1)
only = [a for a in sys.argv[1:] if not a.startswith('--')]
tally = {}
for name, edits, variant in MUTATIONS:
    if not only or any(o in name for o in only):
        v = mutate(name, edits, variant)
        tally[v] = tally.get(v, 0) + 1
verdict, _ = run_live('on off')
print(f'baseline after restore: {"pass" if verdict == "SURVIVED" else verdict}')
print('tally: ' + ', '.join(f'{k} {v}' for k, v in sorted(tally.items())))
