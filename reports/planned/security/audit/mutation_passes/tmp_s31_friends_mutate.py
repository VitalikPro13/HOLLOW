"""Mutation pass for HOL-SEC-115 (sibling friend removals). One mutant per rule:
apply, run the named tests, record KILLED/SURVIVED, restore byte for byte."""
import os
import subprocess
import sys

ROOT = r'D:\dev\wt\s31-friends\rust\hollow_core'
SRC = os.path.join(ROOT, 'src', 'node')

T_ONLINE = 'authz_a_removal_reaches_an_online_sibling_and_never_undoes_a_readd'
T_AWAY = 'a_removal_reaches_a_sibling_that_was_away'
T_OWN = 'authz_only_our_own_device_tells_us_a_friendship_ended'
T_UNIT = 'a_siblings_removal_ends_only_what_was_made_before_it'

# (name, file, old, new, tests expected to kill it)
MUTANTS = [
    ('M1 newer-than-row rule', 'social.rs',
     'if since >= at {', 'if false {', [T_ONLINE, T_UNIT]),
    ('M2 stamp held to its frame', 'social.rs',
     'let at = removal.at.min(ceiling);', 'let at = removal.at;', [T_ONLINE, T_UNIT]),
    ('M3a legacy mark never shared', 'social.rs',
     '.filter(|at| *at > 1)?;', '?;', [T_UNIT]),
    ('M3b legacy mark never taken', 'social.rs',
     'if removal.at <= 1 {', 'if false {', [T_UNIT]),
    ('M4 only live rows end', 'social.rs',
     'Ok(Some((status, _, since))) if status == "accepted" || status == "pending" => {',
     'Ok(Some((_status, _, since))) => {', [T_UNIT]),
    ('M5 shared list capped', 'social.rs',
     'out.truncate(MAX_SHARED_REMOVALS);', '', [T_UNIT]),
    ('M6 removed device refused', 'swarm.rs',
     'if !super::resolver::same_identity(peer_str, local_peer_str) || super::resolver::is_revoked(peer_str) {',
     'if !super::resolver::same_identity(peer_str, local_peer_str) {', [T_OWN]),
    ('M7 non-sibling refused', 'swarm.rs',
     'if !super::resolver::same_identity(peer_str, local_peer_str) || super::resolver::is_revoked(peer_str) {',
     'if super::resolver::is_revoked(peer_str) {', [T_OWN]),
    ('M8 our removal told to online siblings', 'social.rs',
     '    share_removal_with_siblings(ws_cmd_tx, ws_room_peers, local_peer_str, device_peer_id, &master, ended_at);\r\n',
     '', [T_ONLINE]),
    ('M9 a friend\'s removal passed on', 'swarm.rs',
     '            social::share_removal_with_siblings(ws_cmd_tx, ws_room_peers, local_peer_str, device_peer_id, &master, frame_ts_ms);\r\n',
     '', [T_ONLINE]),
    ('M10 sibling list carries removals', 'crypto_handler.rs',
     '.map(|store| super::social::friend_removals(&store))',
     '.map(|_store| Vec::new())', [T_AWAY]),
]


def run(tests):
    expr = 'test(/' + '|'.join(tests) + '/)'
    env = dict(os.environ)
    env['PATH'] = r'C:\Program Files\OpenSSL-Win64\bin;' + env['PATH']
    p = subprocess.run(
        ['cargo', 'nextest', 'run', '--lib', '--no-fail-fast', '-E', expr],
        cwd=ROOT, env=env, capture_output=True, encoding='utf-8', errors='replace',
    )
    out = p.stdout + p.stderr
    failed = [line.strip() for line in out.splitlines() if line.strip().startswith(('FAIL ', 'SIGABRT', 'SIGSEGV'))]
    return p.returncode, failed, out


def main():
    only = sys.argv[1:]
    results = []
    for name, fname, old, new, tests in MUTANTS:
        if only and not any(name.startswith(o) for o in only):
            continue
        path = os.path.join(SRC, fname)
        with open(path, encoding='utf-8', newline='') as f:
            original = f.read()
        if original.count(old) != 1:
            results.append((name, 'NOT APPLIED (pattern count %d)' % original.count(old), []))
            continue
        with open(path, 'w', encoding='utf-8', newline='') as f:
            f.write(original.replace(old, new))
        try:
            code, failed, out = run(tests)
        finally:
            with open(path, 'w', encoding='utf-8', newline='') as f:
                f.write(original)
        if 'error[' in out and code != 0 and not failed:
            verdict = 'BUILD ERROR'
        else:
            verdict = 'KILLED' if code != 0 else 'SURVIVED'
        results.append((name, verdict, failed))
        print(name, verdict, failed, flush=True)
    print('==== SUMMARY ====')
    for name, verdict, failed in results:
        print(f'{name}: {verdict} {failed}')


if __name__ == '__main__':
    main()
