"""Session 32 lead mutation pass (re-check A-CH04 / A-CH05 and the HOL-SEC-033 arm guard):
break each new rule, expect a named test to FAIL, restore byte for byte.

Prints one line per mutation: KILLED, SURVIVED or BROKEN. Pass words to run only the
mutations whose name has one.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RUST = os.path.join(ROOT, 'rust', 'hollow_core')

OPS = os.path.join(RUST, 'src/node/message_ops.rs')
SWARM = os.path.join(RUST, 'src/node/swarm.rs')

STORED = ['message_ops::tests::authz_a_channel_change_reaches_dart_only_once_stored']
HELD = ['message_ops::tests::authz_olm_channel_changes_need_a_server_we_hold']
CARRIED = ['roster_book::tests::carried_roster_arms_stay_wired']

MUTATIONS = [
    ('delete: an unopenable store still tells Dart',
     [(OPS, '''    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else { return };
    let scope = RowScope::Channel { sid: s, cid: c, signer: sender_peer_id };''',
       '''    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        let _ = event_tx.send(NetworkEvent::ChannelMessageDeleted {
            server_id: s.to_string(), channel_id: c.to_string(), message_id: mid, deleted_at: ts,
        }).await;
        return;
    };
    let scope = RowScope::Channel { sid: s, cid: c, signer: sender_peer_id };''')], STORED),
    ('reaction: a refused add still tells Dart',
     [(OPS, 'if store.add_reaction(&mid, &emoji, peer_str, ts, sig.as_deref(), pk.as_deref()) != Ok(true) {',
       'if store.add_reaction(&mid, &emoji, peer_str, ts, sig.as_deref(), pk.as_deref()).is_err() {')], STORED),
    ('olm: an unknown server is held',
     [(OPS, '    let unknown = sid.is_some_and(|s| !server_states.contains_key(s));',
       '    let unknown = { let _ = (server_states, sid); false };')], HELD),
    ('olm: the reaction arm stops asking',
     [(SWARM, 'if message_ops::olm_change_for_unknown_server(server_states, sid.as_deref(), "reaction") {',
       'if false {')], HELD),
    ('olm: the delete arm stops asking',
     [(SWARM, 'if message_ops::olm_change_for_unknown_server(server_states, sid.as_deref(), "delete") {',
       'if false {')], HELD),
    ('carried roster: FriendReject attributes by the resolver',
     [(SWARM, '''                    let Some(master) = super::roster_book::carried_master(list, peer_str) else {
                        hollow_log!("[HOLLOW-FRIENDS] Dropping FriendReject from''',
       '''                    let Some(master) = Some(super::resolver::resolve(peer_str)) else {
                        hollow_log!("[HOLLOW-FRIENDS] Dropping FriendReject from''')], CARRIED),
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
