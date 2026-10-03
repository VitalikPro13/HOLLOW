"""ID-1R mutation pass: break each new rule, expect a named test to FAIL, restore.

Run from rust/hollow_core. Prints one line per mutation: KILLED, SURVIVED or BROKEN
(the mutant does not compile). Every file is restored byte for byte whatever happens.
"""
import os
import subprocess
import sys

ROSTER = 'src/identity/roster.rs'
BOOK = 'src/node/roster_book.rs'
HARNESS = 'src/node/test_harness.rs'
SYNC = 'src/node/sync_handler.rs'

UNIT = ['identity::roster::tests', 'roster_book::tests']
RELAY = ['test_harness::mailbox_requires_a_roster', 'test_harness::authz_the_master_key_alone_never_owns',
         'test_harness::authz_a_removed_device_loses_the_inbox']

MUTATIONS = [
    ('vouches need a standing signer',
     [(ROSTER, '.filter(|v| standing.contains_key(&v.by))', '.filter(|_v| true)')], UNIT),
    ('removals need a standing signer',
     [(ROSTER, '.filter(|r| standing.contains_key(&r.by))', '.filter(|_r| true)')], UNIT),
    ('vouches give way by signer rank',
     [(ROSTER, 'vouches.sort_by_cached_key(|v| (rank(&v.by), v.clone()));', '')], UNIT),
    ('removals give way by signer rank',
     [(ROSTER, 'removals.sort_by_cached_key(|r| (rank(&r.by), r.clone()));', '')], UNIT),
    ('pending joins rank after the phrase',
     [(ROSTER, '(1, self.pendings.iter()', '(0, self.pendings.iter()')], UNIT),
    ("each standing device's best vouch stays",
     [(ROSTER, '.partition(|v| standing.contains_key(&v.device) && best.insert(v.device.as_str()));',
       '.partition(|v| best.is_empty() && v.base.is_empty());')], UNIT),
    ('a removed device keeps what every removal keeps',
     [(ROSTER, '.and_modify(|k| k.retain(|d| keep.contains(d)))', '.and_modify(|k| k.extend(keep.iter().copied()))')],
     UNIT),
    ('no wait stops maturity',
     [(ROSTER, '''                !no_wait
                    && first_seen(&p.device)''', '''                first_seen(&p.device)''')],
     UNIT + ['test_harness::authz_the_master_key_alone_never_owns']),
    ('no wait is under the phrase signature',
     [(ROSTER, 'let flag = if no_wait { ":nowait" } else { "" };', 'let flag = "";')], UNIT),
    ('destroying a device keeps its vouchees',
     [(BOOK, 'let keep = roster.vouched_members_of(&me, &state);', 'let keep: Vec<String> = Vec::new();')], UNIT),
    ('relay: a change drops the owners it no longer counts',
     [(HARNESS, '''        if changed {
            self.drop_inbox_owners(room, &state.members);
        }''', '')], RELAY),
    ('relay: what it holds outlives what is shown',
     [(HARNESS, 'let merged = held.roster.merged(&shown.verified(now));',
       'let merged = crate::identity::roster::Roster::new(&master).merged(&shown.verified(now));')], RELAY),
    ('client: the remover tells the relay',
     [(SYNC, '    super::roster_book::show_relay(ws_cmd_tx, local_peer_str, db_path, db_passphrase);\n', '')],
     ['test_harness::authz_a_removed_device_loses_the_inbox']),
    ('relay: a shown roster decides on its own',
     [(HARNESS, '''                if !owner_ok && let Some(owners) = inner.inbox_owners.get_mut(&room_code) {
                    owners.remove(from);
                }''', '')], RELAY),
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
            write(path, cur.replace(old, new))
        verdict, detail = run(filters)
    finally:
        for path, src in originals.items():
            write(path, src)
    print(f'{verdict:9} {name}', flush=True)
    if detail and verdict != 'SURVIVED':
        print('    ' + detail.replace('\n', '\n    ')[:1200], flush=True)
