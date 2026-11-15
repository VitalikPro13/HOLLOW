"""Session 32 kick agent mutation pass: break each rule this pass relies on or adds,
expect a named test to FAIL, restore byte for byte.

1. A removed joiner's old parked ask, read back out of the join ring, gets nothing.
2c. A former member's device hears of one removal once, and only over a session.
3. The de-flaked lock-move test still fails when no member hands the door over.

Prints one line per mutation: KILLED, SURVIVED or BROKEN. Pass words to run only the
mutations whose name has one.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RUST = os.path.join(ROOT, 'rust', 'hollow_core')

SWARM = os.path.join(RUST, 'src/node/swarm.rs')
DOOR = os.path.join(RUST, 'src/node/door_room.rs')
STATE = os.path.join(RUST, 'src/crdt/server_state.rs')

RING = ['test_harness::authz_a_removed_joiners_parked_ask_read_back_gets_nothing']
LEAVE = ['test_harness::authz_a_join_request_from_before_a_leave_never_readmits']
U_ASK = ['server_state::tests::authz_member_added_names_only_someone_who_asked']
U_DOOR = ['door_room::tests::a_former_member_asking_for_the_door_is_told_its_removal_once']
LOCKMOVE = ['test_harness::a_member_offline_through_a_lock_move_gets_the_door_and_sees_again']

MUTATIONS = [
    ('parked ask: one sealed before the joiner was removed still counts',
     [(SWARM, '            if server_states.get(&server_id).and_then(|s| s.left_at(&member_master))\n',
       '            if false && server_states.get(&server_id).and_then(|s| s.left_at(&member_master))\n')],
     RING + LEAVE),
    ('admission: an ask that admitted once admits again',
     [(STATE, '        if self.member_record.get(target).is_some_and(|spans| spans.iter().any(|s| ask.at <= s.asked_at)) {\n',
       '        if false {\n')],
     U_ASK + RING),
    ('door ask: told of the same removal again',
     [(DOOR, '        if self.told.get(&key) == Some(&removal) || !self.first_to_answer(room, asker, ws_room_peers, our_device) {\n',
       '        if !self.first_to_answer(room, asker, ws_room_peers, our_device) {\n')],
     U_DOOR),
    ('door ask: one notice per device whatever the removal',
     [(DOOR, '        if self.told.get(&key) == Some(&removal) || !self.first_to_answer(',
       '        if self.told.contains_key(&key) || !self.first_to_answer(')],
     U_DOOR),
    ('door ask: told with no session to carry it',
     [(DOOR, '            return olm.has_session(asker) && self.tell_removal(',
       '            return self.tell_removal(')],
     U_DOOR),
    ('door grant: a member never hands the door over',
     [(DOOR, '        if !self.first_to_answer(room, asker, ws_room_peers, our_device) {\n            return false;\n        }\n        let key = (room.to_string(), asker.to_string());\n        if self.answered',
       '        if true {\n            return false;\n        }\n        let key = (room.to_string(), asker.to_string());\n        if self.answered')],
     LOCKMOVE),
]

ENV = dict(os.environ)
ENV['PATH'] = r'C:\Program Files\OpenSSL-Win64\bin;' + ENV['PATH']
ENV['CARGO_TARGET_DIR'] = os.path.join(ROOT, 'target')
ENV['CARGO_BUILD_JOBS'] = '4'


def read(path):
    return open(path, encoding='utf-8', newline='').read()


def write(path, text):
    open(path, 'w', encoding='utf-8', newline='').write(text)


def run_rust(filters):
    cmd = ['cargo', 'nextest', 'run', '--lib', '--no-fail-fast',
           '--failure-output', 'never', '--success-output', 'never'] + filters
    p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace', env=ENV, cwd=RUST)
    out = p.stdout + p.stderr
    if 'error[E' in out or 'could not compile' in out:
        return 'BROKEN', out[-3000:]
    failed = [l.strip() for l in out.splitlines() if 'FAIL [' in l or 'ABORT [' in l]
    if p.returncode != 0 and failed:
        return 'KILLED', '\n'.join(sorted(set(failed)))
    if p.returncode != 0:
        return 'BROKEN', out[-3000:]
    return 'SURVIVED', ''


def mutate(name, edits, filters):
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
        verdict, detail = run_rust(filters)
    finally:
        for path, src in originals.items():
            write(path, src)
    print(f'{verdict:9} {name}', flush=True)
    if detail and verdict != 'SURVIVED':
        print('    ' + detail.replace('\n', '\n    ')[:1200], flush=True)


only = sys.argv[1:]
for name, edits, filters in MUTATIONS:
    if not only or any(o in name for o in only):
        mutate(name, edits, filters)
