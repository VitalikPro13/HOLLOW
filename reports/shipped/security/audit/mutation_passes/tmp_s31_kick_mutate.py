"""Session 31 mutation pass (HOL-SEC-114, a member removed while away learns it):
break each new rule, expect a named test to FAIL, restore byte for byte.

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
SYNC = os.path.join(RUST, 'src/crdt/sync.rs')

KICK = ['test_harness::authz_a_member_kicked_while_away_learns_it_when_it_asks_for_the_door']
BAN = ['test_harness::authz_a_member_banned_while_away_learns_it_from_its_sync']
DELETED = ['test_harness::offline_member_reconciles_server_deletion_on_reconnect']
U_RANK = ['sync::tests::authz_a_former_member_is_told_its_removal_and_the_rank_behind_it_only']
U_NONE = ['sync::tests::authz_no_removal_notice_for_a_stranger_or_a_member']
U_CP = ['sync::tests::a_removal_after_a_checkpoint_is_still_told']
U_DEV = ['door_room::tests::authz_a_bare_master_or_revoked_device_speaks_for_no_one']
U_DOOR = ['door_room::tests::a_former_member_asking_for_the_door_is_told_its_removal_once']

MUTATIONS = [
    ('sync answer: a former member gets nothing',
     [(SWARM, '''                    super::door_room::speaks_for(peer_str)
                        .map(|master| crdt_sync::removal_notice(state, &master, &their_vector))
                        .unwrap_or_default()''', '''                    Vec::new()''')], BAN),
    ('door ask: a former member gets nothing',
     [(DOOR, '            return self.tell_removal(room, asker, &master, state, ws_room_peers, our_device, ws_cmd_tx);',
       '            return false;')], KICK + U_DOOR),
    ('notice: ops after the removal ride along',
     [(SYNC, '        .filter(|op| op.hlc < removal.hlc)\n', '')], U_RANK + KICK + BAN),
    ('notice: the removal alone, no ranks behind it',
     [(SYNC, '    earlier.into_iter().zip(picked).filter_map(|(op, keep)| keep.then_some(op)).collect()',
       '    { let _ = (earlier, picked); vec![removal] }')], U_RANK + KICK),
    ('notice: every op before the removal, not only the ranks',
     [(SYNC, '            if !*pick && decides_rank(op, &chain) {', '            if !*pick {')], U_RANK),
    ('notice: a ban of someone never a member counts as its removal',
     [(SYNC, 'if peer_id == master && member => {', 'if peer_id == master => {')], U_NONE + BAN),
    ('notice: a member admitted again still gets its old removal',
     [(SYNC, '    end.filter(|_| !member)\n', '    end\n')], U_NONE),
    ('notice: a checkpoint lists no one',
     [(SYNC, '    serde_json::from_str::<Members>(base).is_ok_and(|s| s.members.contains_key(master))',
       '    { let _ = (base, master); false }')], U_CP),
    ('device: a bare master id or revoked device speaks for its identity',
     [(DOOR, '    (!refused).then_some(master)', '    { let _ = refused; Some(master) }')], U_DEV),
    ('door ask: told again on every ask',
     [(DOOR, '        if self.told.get(&key).is_some_and(|t| t.elapsed() < TOLD_GAP)\n            || !self.first_to_answer',
       '        if !self.first_to_answer')], U_DOOR),
    ('sync answer: a tombstone answers like a live server',
     [(SWARM, '                } else if state.is_deleted() {', '                } else if false {')], DELETED),
]

ENV = dict(os.environ)
ENV['PATH'] = r'C:\Program Files\OpenSSL-Win64\bin;' + ENV['PATH']


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
