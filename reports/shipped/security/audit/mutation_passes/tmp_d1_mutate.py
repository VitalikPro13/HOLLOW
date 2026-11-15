"""Session 28 mutation pass (D1, door-proof rooms): break each new rule, expect a named
test to FAIL, restore.

Run from rust/hollow_core. Prints one line per mutation: KILLED, SURVIVED or BROKEN
(the mutant does not compile). Every file is restored byte for byte whatever happens.
Pass words to run only the mutations whose name contains one of them.
"""
import os
import subprocess
import sys

HARNESS = 'src/node/test_harness.rs'
DOOR = 'src/node/door_room.rs'
SWARM = 'src/node/swarm.rs'
CLIENT = 'src/node/ws_client.rs'
CRYPTO = 'src/node/crypto_handler.rs'
JOIN = 'src/node/sync_handler.rs'

OUTSIDER = ['test_harness::authz_an_outsider_holding_a_server_id_sees_nobody_in_its_room']
REMOVED = ['test_harness::authz_a_removed_member_stops_seeing_the_room_once_the_lock_moves']
OFFLINE = ['test_harness::a_member_offline_through_a_lock_move_gets_the_door_and_sees_again']
JOINER = ['test_harness::a_joiner_completes_its_join_in_a_room_that_hides_its_members']
GUEST = ['test_harness::file_request_gate_refuses_stranger_and_serves_guest_public']
EMPTY = ['test_harness::empty_server_join_parks_on_the_full_window_behind_its_door']
PROOF = ['ws_client::tests::door_proof_matches_the_relays_pinned_vector']
D1 = OUTSIDER + REMOVED + OFFLINE + JOINER

MUTATIONS = [
    # -- The relay's rules, as the mock mirrors them --
    ('D1 relay: a locked room is open (the old relay)',
     [(HARNESS, '''    fn room_door(&self, room: &str) -> Option<String> {
        if !crate::crdt::anchor::is_genesis_id(room) {''', '''    fn room_door(&self, room: &str) -> Option<String> {
        if true {''')], OUTSIDER + REMOVED),
    ('D1 relay: any join proves the door',
     [(HARNESS, 'let proves = self.proves_door(room, from, &door);\n                let in_room',
       'let proves = true;\n                let in_room')], OUTSIDER),
    ('D1 relay: an outsider is listed',
     [(HARNESS, '        let visible = (!inbox || owner) && door_ok;', '        let visible = !inbox || owner;')], OUTSIDER),
    ('D1 relay: an outsider hears broadcasts',
     [(HARNESS, 'if m == from || self.broadcast_deaf.contains(&m) || !self.receives(room, &m) {',
       'if m == from || self.broadcast_deaf.contains(&m) || !self.reachable(room, &m) {')], OUTSIDER),
    ('D1 relay: a lock move keeps everyone for good',
     [(HARNESS, '                provers.insert(peer, Some(keep));', '                provers.insert(peer, None);')], REMOVED),
    ('D1 relay: the grace never ends',
     [(HARNESS, '                let keep = until.is_none_or(|t| now < t);', '                let keep = true;')], REMOVED),
    ('D1 relay: directs never reach a hidden peer',
     [(HARNESS, 'if self.peer_in_room(room, target) && !self.reachable(room, target) {',
       'if self.peer_in_room(room, target) && !self.receives(room, target) {')], OFFLINE + JOINER),
    ('D1 relay: public frames stay with provers',
     [(HARNESS, 'let to_all = inner.room_door(&room_code).is_some() && inner.receives(&room_code, from);',
       'let to_all = false;')], GUEST),
    # -- The client --
    ('D1 client: the proof message drops the relay key',
     [(CLIENT, '"hollow-door1\\n{}\\n{}\\n{}\\n{room}\\n{door}\\n{}",', '"hollow-door1\\n{}\\n{}\\n{}\\n{room}\\n{door}\\n{}\\n",')], PROOF),
    ('D1 client: a low-order relay key still gets a proof',
     [(CLIENT, '    if !shared.was_contributory() {\n        return None;\n    }', '')], PROOF),
    ('D1 client: the door never reaches the socket',
     [(DOOR, '            let _ = ws_cmd_tx.send(WsCommand::SetDoor { room_code: sid.clone(), door: Some(DoorSecret(secret)) });',
       '            let _ = (DoorSecret(secret), ws_cmd_tx);')], D1),
    ('D1 client: a removed member gets the door',
     [(DOOR, '            || !state.is_member(&master)\n', '')], REMOVED),
    ('D1 client: a hidden member never asks',
     [(DOOR, '            let _ = ws_cmd_tx.send(WsCommand::SendToRoom { room_code: room.to_string(), data });',
       '            let _ = (ws_cmd_tx, data);')], OFFLINE),
    ('D1 client: a grant is never taken',
     [(DOOR, '        self.granted.insert(room.to_string(), (n, public, secret));', '        let _ = (n, public, secret);')], OFFLINE),
    ('D1 client: an answer is throttled whatever the door',
     [(DOOR, "if self.answered.get(&key).is_some_and(|(sent, t)| *sent == n && t.elapsed() < ASK_GAP) {",
       "if self.answered.get(&key).is_some_and(|(_, t)| t.elapsed() < ASK_GAP) {")], OFFLINE),
    ('D1 client: a joiner never asks the whole room',
     [(SWARM, '                            && super::join_lane::send_request_to_room(&ws_cmd_tx, &room, &device_peer_id, pending)',
       '                            && false'),
      (JOIN, '        if hidden && super::join_lane::send_request_to_room(ws_cmd_tx, server_id, our_device, pending) {',
       '        if hidden && false {')], JOINER),
    ('D1 client: a hidden room is known to be empty',
     [(SWARM, '                        if !(only_if_empty && door_rooms.is_hidden(&server_id)) {',
       '                        if true {')], EMPTY),
    ('D1 client: no way back to a hidden peer is kept',
     [(DOOR, '        heard.insert(peer.to_string(), room.to_string());', '        let _ = (peer, room, &mut heard);')], GUEST),
    ('D1 client: sends ignore the way back',
     [(CRYPTO, '    ws_room_for_peer(ws_room_peers, peer_str).or_else(|| super::door_room::heard_room(peer_str))',
       '    ws_room_for_peer(ws_room_peers, peer_str)')], GUEST),
    ('D1 client: public posts ride the plain broadcast',
     [('src/node/message_ops.rs', '    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendPublic {\n        room_code: server.server_id.clone(),',
       '    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {\n        room_code: server.server_id.clone(),')], GUEST),
]

ENV = dict(os.environ)
ENV['PATH'] = r'C:\Program Files\OpenSSL-Win64\bin;' + ENV['PATH']


def read(path):
    return open(path, encoding='utf-8', newline='').read()


def write(path, text):
    open(path, 'w', encoding='utf-8', newline='').write(text)


def run(filters):
    cmd = ['cargo', 'nextest', 'run', '--lib', '--no-fail-fast',
           '--failure-output', 'never', '--success-output', 'never'] + filters
    p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace', env=ENV)
    out = p.stdout + p.stderr
    if 'error[E' in out or 'could not compile' in out:
        return 'BROKEN', out[-3000:]
    failed = [l.strip() for l in out.splitlines() if 'FAIL [' in l or 'ABORT [' in l]
    if p.returncode != 0 and failed:
        return 'KILLED', '\n'.join(sorted(set(failed)))
    if p.returncode != 0:
        return 'BROKEN', out[-3000:]
    return 'SURVIVED', ''


only = sys.argv[1:]
for name, edits, filters in MUTATIONS:
    if only and not any(o in name for o in only):
        continue
    originals = {}
    try:
        for path, old, new in edits:
            cur = read(path)
            originals.setdefault(path, cur)
            crlf = '\r\n' in cur
            if crlf:
                old, new = old.replace('\n', '\r\n'), new.replace('\n', '\r\n')
            if cur.count(old) != 1:
                raise SystemExit(f'{name}: pattern found {cur.count(old)}x in {path}: {old[:70]!r}')
            cur = cur.replace(old, new)
            write(path, cur)
        verdict, detail = run(filters)
    finally:
        for path, src in originals.items():
            write(path, src)
    print(f'{verdict:9} {name}', flush=True)
    if detail and verdict != 'SURVIVED':
        print('    ' + detail.replace('\n', '\n    ')[:1200], flush=True)
