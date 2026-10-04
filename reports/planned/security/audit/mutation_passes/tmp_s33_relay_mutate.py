"""Session 33 mutation pass (HOL-SEC-126 forwarder rooms, HOL-SEC-127 channel copies from
a hidden socket): break each new check, expect the named tests to FAIL, restore byte for
byte.

Two halves:
- relay (default): on Linux, from a scratch copy laid out as <dir>/tmp_s33_relay_mutate.py
  + <dir>/relay-uws/ (uWebSockets/uSockets submodules in place). Each mutation must fail
  the live tests (relay-uws/test/run_live.sh, the real relay on loopback); a mutation of
  fwd_room.h is also run against its unit test (test_fwd_room.cpp).
- --mock: on Windows, from the worktree root. MockRelay's copy of the rules
  (rust/hollow_core/src/node/test_harness.rs), each expected to fail the two harness tests.

Prints one line per mutation: KILLED, SURVIVED or BROKEN. Pass words to run only the
mutations whose name has one; --check only verifies every pattern matches once.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RELAY = os.path.join(ROOT, 'relay-uws')
WS = os.path.join(RELAY, 'src/ws_handler.cpp')
FWD = os.path.join(RELAY, 'src/fwd_room.h')
HARNESS = os.path.join(ROOT, 'rust/hollow_core/src/node/test_harness.rs')
CACHE = os.path.join(ROOT, 'mutation-build')
OUT = os.path.join(ROOT, 'mutation-out')
ON = 'on'
MOCK_TESTS = ('test(authz_a_stranger_in_a_forwarder_room_meets_only_the_forwarder)'
              ' | test(authz_a_socket_the_room_hides_leaves_no_channel_copy)'
              ' | test(forwarder_room_and_signal_round_trip) | test(fwd_room_join_skips_discovery_but_keeps_olm)')


def ws(name, old, new, variant=ON):
    return (name, [(WS, old, new)], variant)


def fwd(name, old, new):
    return (name, [(FWD, old, new)], ON)


def mock(name, old, new):
    return (name, [(HARNESS, old, new)], None)


RELAY_MUTATIONS = [
    ws('shares: the pair not asked', '        return sees(pid) && fwd_room::paired(name, pid, other);',
       '        return sees(pid);'),
    ws('shares: the room not asked', '        return sees(pid) && fwd_room::paired(name, pid, other);',
       '        return fwd_room::paired(name, pid, other);'),
    ws('shares: no room name', 'steady_ms(), name};', 'steady_ms(), std::string_view()};'),
    ws('check_peers: any co-member', '            if (!aud.shares(pid, caller)) continue;',
       '            if (!aud.sees(pid)) continue;'),
    ws('presence: told to every member',
       '        if (pid != peer && !sock->getUserData()->is_guest && aud.shares(pid, peer)) {',
       '        if (pid != peer && !sock->getUserData()->is_guest && aud.sees(pid)) {'),
    ws('join: the roster lists every member',
       'aud.shares(pid, data->peer_id)) {\n                existing_peers',
       'aud.sees(pid)) {\n                existing_peers'),
    ws('0x09: any pair in a forwarder room',
       '    if (!fwd_room::paired(room_str, data->peer_id, target_str)) return;\n\n    // Sender must',
       '\n    // Sender must'),
    ws('0x09: a hidden sender', '    if (!aud.sees(data->peer_id)) return;\n\n    // Buffer whenever',
       '    if (false) return;\n\n    // Buffer whenever'),
    ws('JSON msg: every member',
       '        if (pid != data->peer_id && aud.shares(pid, data->peer_id)) {\n            send_to_peer(peer_ws, broadcast_str',
       '        if (pid != data->peer_id && aud.sees(pid)) {\n            send_to_peer(peer_ws, broadcast_str'),
    ws('JSON direct: any pair', '    if (!fwd_room::paired(room, data->peer_id, target)) return;\n', ''),
    ws('0x02: any pair',
       '    if (!fwd_room::paired(room_str, data->peer_id, target_str)) return;\n    auto tit',
       '    auto tit'),
    ws('0x03/0x0A: every member', '(public_frame || aud.shares(pid, data->peer_id))', '(public_frame || aud.sees(pid))'),
    ws('0x04/0x08: any pair, live or deposited',
       '    // In a forwarder\'s room, live or deposited, only the forwarder and one member.\n'
       '    if (!fwd_room::paired(room_str, data->peer_id, target_str)) return;\n', ''),
    ws('0x07: a forwarder room keeps a ring', ' && !fwd_room::forwarder_of(room_str)) {', ') {'),
    ws('0x07: every member', '        if (!aud.shares(pid, data->peer_id)) continue;\n\n        auto* peer_data',
       '        if (!aud.sees(pid)) continue;\n\n        auto* peer_data'),
    ws('discover: every member', '                        aud.shares(pid, data->peer_id)) {',
       '                        aud.sees(pid)) {'),
    fwd('fwd_room: anyone paired', '    return !x || a == *x || b == *x;', '    return true;'),
    fwd('fwd_room: only the first may be the forwarder', '    return !x || a == *x || b == *x;', '    return !x || a == *x;'),
    fwd('fwd_room: only the second may be the forwarder', '    return !x || a == *x || b == *x;', '    return !x || b == *x;'),
    fwd('fwd_room: every room a forwarder room', '    if (room.substr(0, PREFIX.size()) != PREFIX) return std::nullopt;',
        '    if (false) return std::nullopt;'),
    fwd('fwd_room: no forwarder room', '    if (room.substr(0, PREFIX.size()) != PREFIX) return std::nullopt;',
        '    return std::nullopt;'),
]

MOCK_MUTATIONS = [
    mock('mock paired: anyone', '        room.strip_prefix("fwd:").is_none_or(|x| a == x || b == x)', '        true'),
    mock('mock paired: only the first may be the forwarder',
         '        room.strip_prefix("fwd:").is_none_or(|x| a == x || b == x)',
         '        room.strip_prefix("fwd:").is_none_or(|x| a == x)'),
    mock('mock paired: only the second may be the forwarder',
         '        room.strip_prefix("fwd:").is_none_or(|x| a == x || b == x)',
         '        room.strip_prefix("fwd:").is_none_or(|x| b == x)'),
    mock('mock shares: the pair not asked', '        self.receives(room, pid) && Self::paired(room, pid, other)',
         '        self.receives(room, pid)'),
    mock('mock join: the roster lists every member', '.filter(|p| *p != from && self.shares(room, p, from))',
         '.filter(|p| *p != from && self.receives(room, p))'),
    mock('mock presence/topics: to every member', '            if !self.shares(room, &m, from) {\n                continue;',
         '            if !self.receives(room, &m) {\n                continue;'),
    mock('mock 0x03: every member', '|| self.broadcast_deaf.contains(&m) || !self.shares(room, &m, from) {',
         '|| self.broadcast_deaf.contains(&m) || !self.receives(room, &m) {'),
    mock('mock 0x0A: every member', '!(to_all || inner.shares(&room_code, &m, from))', '!(to_all || inner.receives(&room_code, &m))'),
    mock('mock directs: any pair', '        if !Self::paired(room, from, target) {\n            return 0;\n        }\n', ''),
    mock('mock 0x02: any pair', 'if !sender_in_room || !RelayInner::paired(&room_code, from, &target_peer) { return; }',
         'if !sender_in_room { return; }'),
    mock('mock discover: every member', '.filter(|p| *p != from && inner.shares(&room_code, p, from))',
         '.filter(|p| *p != from && inner.receives(&room_code, p))'),
    mock('mock 0x09: any pair', '                    || !RelayInner::paired(&room_code, from, &target_peer)\n', ''),
    mock('mock 0x09: a hidden sender', '                    || !inner.receives(&room_code, from)\n', ''),
    mock('mock 0x09: a member who heard the room gets a copy',
         '                    || (inner.peer_in_room(&room_code, &target_peer) && inner.receives(&room_code, &target_peer))\n',
         ''),
    mock('mock 0x09: nothing kept', '                inner.channel_copies.push((from.to_string(), room_code, target_peer));',
         '                let _ = (room_code, target_peer);'),
]


def read(path):
    return open(path, encoding='utf-8', newline='').read()


def write(path, text):
    open(path, 'w', encoding='utf-8', newline='').write(text)


def crlf(cur, text):
    return text.replace('\n', '\r\n') if '\r\n' in cur else text


def patterns_ok(mutations):
    ok = True
    for name, edits, _ in mutations:
        for path, old, _new in edits:
            cur = read(path)
            n = cur.count(crlf(cur, old))
            if n != 1:
                print(f'PATTERN   {name}: found {n}x: {old[:70]!r}')
                ok = False
    return ok


def run(cmd, env=None, cwd=None):
    p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace', env=env, cwd=cwd)
    return p.returncode, p.stdout + p.stderr


def run_unit():
    exe = os.path.join(OUT, 'test_fwd_room')
    os.makedirs(OUT, exist_ok=True)
    rc, out = run(['g++', '-std=c++17', '-O1', '-I' + os.path.join(RELAY, 'src'),
                   os.path.join(RELAY, 'test/test_fwd_room.cpp'), '-o', exe])
    if rc != 0:
        return 'BROKEN', out[-1500:]
    rc, out = run([exe])
    return ('KILLED', '\n'.join(l for l in out.splitlines() if 'FAIL' in l)) if rc else ('SURVIVED', '')


def run_live(variant):
    env = dict(os.environ, RELAY_LIVE_BUILD=CACHE, RELAY_LIVE_VARIANTS=variant)
    rc, out = run(['bash', os.path.join(RELAY, 'test/run_live.sh'), OUT], env=env)
    if 'BUILD FAIL' in out:
        return 'BROKEN', out[-2000:]
    if rc != 0 and 'FAIL test_relay_live' in out:
        return 'KILLED', '\n'.join(l for l in out.splitlines() if 'FAIL' in l)
    if rc != 0:
        return 'BROKEN', out[-2000:]
    return 'SURVIVED', ''


def run_mock():
    manifest = os.path.join(ROOT, 'rust/hollow_core/Cargo.toml')
    rc, out = run(['cargo', 'nextest', 'run', '--lib', '--manifest-path', manifest, '-E', MOCK_TESTS])
    if 'error[' in out or 'could not compile' in out:
        return 'BROKEN', out[-2000:]
    if rc != 0:
        return 'KILLED', '\n'.join(l for l in out.splitlines() if 'FAIL' in l or 'panicked' in l)
    return 'SURVIVED', ''


def mutate(name, edits, variant):
    originals = {}
    try:
        for path, old, new in edits:
            cur = read(path)
            originals.setdefault(path, cur)
            old, new = crlf(cur, old), crlf(cur, new)
            if cur.count(old) != 1:
                raise SystemExit(f'{name}: pattern found {cur.count(old)}x in {path}: {old[:70]!r}')
            write(path, cur.replace(old, new))
        if variant is None:
            verdict, detail = run_mock()
        else:
            verdict, detail = run_live(variant)
            if any(path == FWD for path, _, _ in edits):
                unit, unit_detail = run_unit()
                name = f'{name} (unit: {unit})'
                detail = (detail + '\n' + unit_detail).strip()
    finally:
        for path, src in originals.items():
            write(path, src)
    print(f'{verdict:9} [{variant or "mock":4}] {name}', flush=True)
    if detail and verdict != 'SURVIVED':
        print('    ' + detail.replace('\n', '\n    ')[:1200], flush=True)
    return verdict


mutations = MOCK_MUTATIONS if '--mock' in sys.argv else RELAY_MUTATIONS
if '--check' in sys.argv:
    sys.exit(0 if patterns_ok(mutations) else 1)
if not patterns_ok(mutations):
    sys.exit(1)
only = [a for a in sys.argv[1:] if not a.startswith('--')]
tally = {}
for name, edits, variant in mutations:
    if not only or any(o in name for o in only):
        v = mutate(name, edits, variant)
        tally[v] = tally.get(v, 0) + 1
if '--mock' in sys.argv:
    verdict, _ = run_mock()
else:
    verdict, _ = run_live('on off')
    unit, _ = run_unit()
    verdict = verdict if unit == 'SURVIVED' else unit
print(f'baseline after restore: {"pass" if verdict == "SURVIVED" else verdict}')
print('tally: ' + ', '.join(f'{k} {v}' for k, v in sorted(tally.items())))
