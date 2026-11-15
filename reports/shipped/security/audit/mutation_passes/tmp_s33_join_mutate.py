"""Session 33 mutation pass (HOL-SEC-121: a member just back holds a join ask until
the join ring's replay has ended and a member's sync has landed): break each new rule,
expect a named test to FAIL, restore byte for byte.

Prints one line per mutation: KILLED, SURVIVED or BROKEN. Pass words to run only the
mutations whose name has one.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RUST = os.path.join(ROOT, 'rust', 'hollow_core')

HOLD = os.path.join(RUST, 'src/node/join_hold.rs')
SWARM = os.path.join(RUST, 'src/node/swarm.rs')

U_RING = ['join_hold::tests::a_parked_ask_waits_for_the_end_of_the_ring_replay']
U_HIDDEN = ['join_hold::tests::a_hidden_room_answers_nothing_and_starts_no_wait']
U_LOST = ['join_hold::tests::losing_the_room_drops_what_waits_and_makes_the_server_stale']
HIDDEN_BACK = ['test_harness::authz_a_member_back_hidden_answers_no_direct_ask']
HIDDEN_LOST = ['test_harness::authz_a_member_that_loses_the_room_answers_no_direct_ask']
RESTART = ['test_harness::authz_a_member_restarted_while_away_learns_an_admission_from_its_sync']
U_STALE = ['join_hold::tests::a_stale_member_waits_for_a_sync_from_someone_but_the_asker']
U_EXPIRE = ['join_hold::tests::nothing_waits_past_the_hold']
U_BOUND = ['join_hold::tests::held_asks_are_bounded_and_die_with_the_socket']
U_MARK = ['join_hold::tests::only_a_members_answer_to_an_ask_of_this_connection_counts']
GUARD = ['test_harness::authz_a_member_back_from_away_gives_a_kicked_joiners_old_ask_nothing']
SYNC_ALONE = ['test_harness::authz_a_member_back_from_away_learns_a_kick_from_its_sync_alone']
BANNED = ['test_harness::authz_a_member_back_from_away_gives_a_banned_joiners_old_ask_nothing']
ALONE = ['test_harness::authz_a_member_back_alone_gives_an_answered_ask_nothing']
BESIDE = ['test_harness::parked_join_read_beside_a_present_member_is_admitted_once']
FALLBACK = ['test_harness::parked_join_is_judged_when_the_relay_never_marks_the_rings_end']
READBACK = ['test_harness::authz_a_removed_joiners_parked_ask_read_back_gets_nothing']
LIVE = ['test_harness::authz_a_member_back_from_away_admits_no_banned_identitys_live_ask']
EMPTY = ['test_harness::sync_answers_a_member_that_misses_nothing']

MUTATIONS = [
    # The baseline: every ask judged on arrival, as before the fix (the RED of each guard).
    ('swarm: no ask is held',
     [(SWARM, 'let Some(inner) = join_hold.hold(&from, frame_ts, inner, &visible) else { continue };',
       'let _ = (&visible, &mut join_hold);')], GUARD + SYNC_ALONE + BANNED + ALONE + LIVE + HIDDEN_BACK + HIDDEN_LOST + RESTART),
    ('hold: a room we are not shown answers too',
     [(HOLD, '            if self.known.contains(&server) {\n', '            if false {\n')], U_HIDDEN + U_LOST + HIDDEN_BACK + HIDDEN_LOST),
    ('hidden: what waits stays',
     [(HOLD, 'let dropped = self.fresh.remove(server).map_or(0, |f| f.held.len());',
       'let dropped = self.fresh.get(server).map_or(0, |f| f.held.len());')], U_LOST),
    ('hidden: the server is not marked stale',
     [(HOLD, '        self.known.insert(server.to_string());\n', '')], U_LOST + HIDDEN_LOST),
    ('swarm: losing the room is not noted',
     [(SWARM, '                            join_hold.hidden(&room);\n', '')], HIDDEN_LOST),
    ('hold: a parked ask skips the ring replay',
     [(HOLD, '((parked && fresh.ring.is_some())', '((parked && false)')], U_RING + ALONE + FALLBACK),
    ('hold: a stale member skips the sync',
     [(HOLD, '|| (fresh.stale && !informed(&asker,', '|| (false && !informed(&asker,')], U_STALE + SYNC_ALONE + BANNED + LIVE),
    ('hold: no window',
     [(HOLD, 'let waits = fresh.since.elapsed() < HOLD_WAIT', 'let waits = true')], U_EXPIRE),
    ('hold: unbounded',
     [(HOLD, 'if fresh.held.len() >= MAX_HELD {', 'if false {')], U_BOUND),
    ('joined: a hidden room starts the wait',
     [(HOLD, '        if hidden {\n            return;\n        }\n', '')], U_HIDDEN),
    ('due: never forced',
     [(HOLD, '                expired || known\n', '                known\n')], U_EXPIRE + FALLBACK),
    ('due: the ring replay not waited for',
     [(HOLD, 'let known = (!ask.parked || fresh.ring.is_none()) &&', 'let known = true &&')], U_RING + ALONE + FALLBACK),
    ('due: the sync not waited for',
     [(HOLD, '&& (!fresh.stale || informed(&ask.asker, synced, &room));', '&& true;')], U_STALE + SYNC_ALONE + BANNED + LIVE),
    ('informed: a sync never counts',
     [(HOLD, 'synced.is_some_and(|s| s.iter().any(|m| other(m)))', 'synced.is_some_and(|_| false)')], U_STALE + BESIDE),
    ('informed: the asker vouches for itself',
     [(HOLD, 'let other = |id: &str| !asker.iter().any(|a| super::resolver::same_identity(id, a));',
       'let other = |id: &str| { let _ = asker; !id.is_empty() };')], U_STALE),
    ('informed: who is here does not matter',
     [(HOLD, '|| !visible.iter().any(|d| other(d))', '|| visible.is_empty()')], U_STALE),
    ('sync_mark: a server made on this socket counts',
     [(HOLD, ' && self.known.contains(server_id) && ', ' && ')], U_MARK),
    ('sync_mark: any sender counts',
     [(HOLD, ' && server_states.get(server_id)?.is_member(from))', ' && server_states.get(server_id).is_some())')], U_MARK),
    ('sync_mark: an answer to an earlier ask counts',
     [(HOLD, '(*nonce == self.ask && ', '(*nonce > 0 && ')], U_MARK),
    ('sync_mark: an answer to no ask counts',
     [(HOLD, 'let HavenMessage::SyncResponse { server_id, nonce: Some(nonce), .. } = msg else { return None };',
       'let HavenMessage::SyncResponse { server_id, nonce, .. } = msg else { return None }; let nonce = &nonce.unwrap_or(self.ask);')], U_MARK),
    ('went_away: one nonce for every connection',
     [(HOLD, '        self.ask = (super::types::now_ms().max(0) as u64).max(self.ask + 1);\n', '        self.ask = self.ask.max(1);\n')], U_MARK),
    ('swarm: the reconnect sync ask carries no nonce',
     [(SWARM, '''                                                        state_vector_json: sv_json.clone(),
                                                        // Epoch hint: lets the responder detect
                                                        // us (or itself) stale on first contact.
                                                        mls_epoch: mls.as_ref().and_then(|m| m.epoch(sid).ok()),
                                                        nonce: Some(join_hold.ask()),
''', '''                                                        state_vector_json: sv_json.clone(),
                                                        // Epoch hint: lets the responder detect
                                                        // us (or itself) stale on first contact.
                                                        mls_epoch: mls.as_ref().and_then(|m| m.epoch(sid).ok()),
                                                        nonce: None,
''')], BESIDE),
    ('sync: the answer does not echo the nonce',
     [(SWARM, '&HavenMessage::SyncResponse { server_id: server_id.clone(), ops_json, nonce },',
       '&HavenMessage::SyncResponse { server_id: server_id.clone(), ops_json, nonce: nonce.and(None) },')], EMPTY + BESIDE),
    ('ring_ended: any ring ends it',
     [(HOLD, 'self.fresh.get_mut(room).filter(|f| f.ring.as_deref() == Some(channel))', 'self.fresh.get_mut(room).filter(|_| !channel.is_empty())')], U_RING),
    ('went_away: held asks outlive the socket',
     [(HOLD, '        self.fresh.clear();\n', '')], U_BOUND),
    ('went_away: nothing held counts as stale',
     [(HOLD, 'self.known = server_states.keys().cloned().collect();', 'let _ = server_states;')], U_MARK + SYNC_ALONE + BANNED),
    ('swarm: the ring replay is never waited for',
     [(SWARM, 'join_hold.ring_asked(&room, &topic);', 'let _ = &topic;')], ALONE + FALLBACK),
    ('swarm: no end mark asked for',
     [(SWARM, '                                    end: member,\n', '                                    end: false,\n')], BESIDE),
    ('swarm: the end mark ignored',
     [(SWARM, 'join_hold.ring_ended(&room, &channel);', 'let _ = (&room, &channel);')], BESIDE),
    ('swarm: syncs never noted',
     [(SWARM, 'join_hold.synced(synced);', 'let _ = synced;')], BESIDE),
    ('swarm: the window starts at a hidden roster',
     [(SWARM, 'join_hold.joined(&room, hidden);', 'join_hold.joined(&room, false);')], LIVE),
    ('swarm: released asks are dropped',
     [(SWARM, '            for ask in due {\n', '            for ask in due.into_iter().filter(|_| false) {\n')], READBACK + BESIDE + FALLBACK),
    ('swarm: servers held at start never stale',
     [(SWARM, '    let mut join_hold = super::join_hold::JoinHold::default();\n    join_hold.went_away(&server_states);\n',
       '    let mut join_hold = super::join_hold::JoinHold::default();\n')], SYNC_ALONE + RESTART),
    ('swarm: a dead socket marks nothing stale',
     [(SWARM, '                        join_hold.went_away(&server_states);\n', '')], BANNED + LIVE),
    ('sync: a member missing nothing hears nothing',
     [(SWARM, 'if (member || !delta.is_empty())', 'if (!delta.is_empty())')], EMPTY),
]

ENV = dict(os.environ)
ENV['PATH'] = r'C:\Program Files\OpenSSL-Win64\bin;' + ENV['PATH']
ENV['CARGO_TARGET_DIR'] = 'D:/dev/wt/s33-join/rust/hollow_core/target'
ENV['CARGO_BUILD_JOBS'] = '4'


def read(path):
    return open(path, encoding='utf-8', newline='').read()


def write(path, text):
    open(path, 'w', encoding='utf-8', newline='').write(text)


def run_rust(filters):
    cmd = ['cargo', 'nextest', 'run', '--lib', '--no-fail-fast',
           '--failure-output', 'final', '--success-output', 'never'] + filters
    p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace', env=ENV, cwd=RUST)
    out = p.stdout + p.stderr
    if 'error[E' in out or 'could not compile' in out:
        return 'BROKEN', out[-3000:]
    failed = [l.strip() for l in out.splitlines() if 'FAIL [' in l or 'ABORT [' in l]
    if p.returncode != 0 and failed:
        lines = out.splitlines()
        why = [lines[i + 1].strip() for i, l in enumerate(lines) if 'panicked at' in l and i + 1 < len(lines)]
        return 'KILLED', '\n'.join(sorted(set(failed)) + sorted(set(why))[:8])
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
        print('    ' + detail.replace('\n', '\n    ')[:1500], flush=True)


only = sys.argv[1:]
for name, edits, filters in MUTATIONS:
    if not only or any(o in name for o in only):
        mutate(name, edits, filters)
