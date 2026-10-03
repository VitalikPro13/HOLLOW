"""Session 30 mutation pass (D5, the relay kill list: a phrase-proven slot and acks by
issuer + stamp): break each new rule, expect a named test to FAIL, restore.

Rust mutants run from rust/hollow_core with nextest; kill_list.h mutants build
relay-uws/test/test_kill_list.cpp with the local g++. kill_order.h needs libsodium, so
its mutants run on the relay box (pass `--print-order` to print them as a shell list).
Prints one line per mutation: KILLED, SURVIVED or BROKEN. Every file is restored byte
for byte whatever happens. Pass words to run only the mutations whose name has one.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RUST = os.path.join(ROOT, 'rust', 'hollow_core')
RELAY = os.path.join(ROOT, 'relay-uws')

DESTROY = os.path.join(RUST, 'src/node/destroy.rs')
FETCH = os.path.join(RUST, 'src/node/fetch.rs')
WS = os.path.join(RUST, 'src/node/ws_client.rs')
KILL_LIST = os.path.join(RELAY, 'src/kill_list.h')

JUNK = ['test_harness::authz_turning_away_junk_that_shares_an_orders_stamp_keeps_the_order']
FETCH_ACK = ['fetch::tests::a_junk_kill_deposit_is_acked_alone']
WIRE = ['ws_client::tests::a_kill_signal_keeps_its_issuer_for_the_ack']

RUST_MUTATIONS = [
    ('client: the ack names no issuer',
     [(DESTROY, 'WsCommand::KillAck { signal: Some(signal) }',
       'WsCommand::KillAck { signal: Some(super::ws_client::KillSignalId { issuer: String::new(), ..signal }) }')], JUNK),
    ('client: the fetch node acks by stamp alone',
     [(FETCH, 'let signal = crate::node::ws_client::KillSignalId { issuer, issued_at_ms };',
       'let signal = crate::node::ws_client::KillSignalId { issuer: { let _ = issuer; String::new() }, issued_at_ms };')],
     FETCH_ACK),
    ('client: the ack frame drops the issuer',
     [(WS, 'Some(s) => serde_json::json!({ "type": "kill_ack", "issuer": s.issuer, "issued_at_ms": s.issued_at_ms }),',
       'Some(s) => serde_json::json!({ "type": "kill_ack", "issued_at_ms": s.issued_at_ms }),')], WIRE + FETCH_ACK),
    ('client: the signal forgets its issuer',
     [(WS, 'WsEvent::KillSignal { blob, signal: KillSignalId { issuer, issued_at_ms } }',
       'WsEvent::KillSignal { blob, signal: KillSignalId { issuer: { let _ = issuer; String::new() }, issued_at_ms } }')],
     WIRE),
]

KILL_LIST_MUTATIONS = [
    ('relay: an ack ignores the issuer',
     [(KILL_LIST, 'return e.issuer == issuer && e.issued_at_ms == issued_at_ms;',
       'return e.issued_at_ms == issued_at_ms;')]),
    ('relay: a proven order waits with the junk',
     [(KILL_LIST, '        insert_proven(target, issuer, share, blob, issued_at_ms, now);\n        return true;',
       '        insert(target, issuer, share, blob, issued_at_ms, now);\n        return true;')]),
    ('relay: an equal proven stamp replaces',
     [(KILL_LIST, 'held && issued_at_ms <= held->issued_at_ms) return false;',
       'held && issued_at_ms < held->issued_at_ms) return false;')]),
    ('relay: the proven slot ignores the future bound',
     [(KILL_LIST, '''        if (issued_at_ms > now_wall_ms + MAX_FUTURE_MS) return false;
        if (const Entry* held = find_proven(target);''', '''        if (const Entry* held = find_proven(target);''')]),
    ('relay: the bare ack leaves the proven order',
     [(KILL_LIST, '        bool any = drop_proven(target);\n        auto it = entries.find(target);',
       '        bool any = false;\n        auto it = entries.find(target);')]),
    ('relay: an ack for the proven order ignores its issuer',
     [(KILL_LIST, 'p && p->issuer == issuer && p->issued_at_ms == issued_at_ms) {',
       'p && p->issued_at_ms == issued_at_ms) {')]),
    ('relay: proven slots are unbounded',
     [(KILL_LIST, 'while (proven_ledger.size() > MAX_PROVEN) {', 'while (false) {')]),
    ('relay: proven slots never age out',
     [(KILL_LIST, '            if (const Entry* p = find_proven(target); p && aged(*p)) drop_proven(target);\n', '')]),
    ('relay: delivery leaves out the proven order',
     [(KILL_LIST, '        if (const Entry* p = find_proven(target)) out.push_back(p);\n', '')]),
]

# kill_order.h, for the relay box: name, old, new.
ORDER_MUTATIONS = [
    ('order: the master signature is not checked',
     '!c.verify_by_id(o.master_peer_id, o.sig_b64, p)', 'false'),
    ('order: the master key need not derive the id',
     'derive(o.master_pubkey_b64) != o.master_peer_id ||', ''),
    ('order: any recovery key counts',
     'if (o.r_pub == held.r_pub && c.verify_by_key(held.r_pub, o.sig_r, p)) return true;',
     'if (c.verify_by_key(o.r_pub, o.sig_r, p)) return true;'),
    ('order: a delegation needs no member',
     'return d.r_pub == held.r_pub && state.is_member(d.device) &&', 'return d.r_pub == held.r_pub &&'),
    ('order: a delegation needs no device signature',
     '&&\n           c.verify_by_id(d.device, d.device_sig, p);', ';'),
    ('order: the deposit stamp may differ',
     ' || o.issued_at_ms != issued_at_ms) return false;', ') return false;'),
    ('order: a target need not consent',
     'return named && held.consented().count(target) != 0;', 'return named;'),
    ('order: a target need not be named',
     'return named && held.consented().count(target) != 0;', 'return held.consented().count(target) != 0;'),
    ('order: targets are not sorted',
     '    std::sort(targets.begin(), targets.end());\n    return "hollow-destroy2:"', '    return "hollow-destroy2:"'),
    ('order: a legacy roster pins a key',
     'if (held.r_pub.empty() || o.master_peer_id', 'if (o.master_peer_id'),
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


def run_kill_list(_):
    exe = os.path.join(RELAY, 'test', 'mut_kill_list.exe')
    b = subprocess.run(['g++', '-std=c++17', '-O1', '-I../src', 'test_kill_list.cpp', '-o', exe],
                       capture_output=True, text=True, cwd=os.path.join(RELAY, 'test'))
    if b.returncode != 0:
        return 'BROKEN', b.stderr[-2000:]
    t = subprocess.run([exe], capture_output=True, text=True, cwd=os.path.join(RELAY, 'test'))
    os.remove(exe)
    failed = [l.strip() for l in t.stdout.splitlines() if 'FAIL' in l]
    if t.returncode != 0 and failed:
        return 'KILLED', '\n'.join(failed[:4])
    if t.returncode != 0:
        return 'BROKEN', t.stdout[-1500:]
    return 'SURVIVED', ''


def mutate(name, edits, runner, filters):
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
        verdict, detail = runner(filters)
    finally:
        for path, src in originals.items():
            write(path, src)
    print(f'{verdict:9} {name}', flush=True)
    if detail and verdict != 'SURVIVED':
        print('    ' + detail.replace('\n', '\n    ')[:1200], flush=True)


if '--print-order' in sys.argv:
    import json
    print(json.dumps(ORDER_MUTATIONS))
    raise SystemExit(0)

only = sys.argv[1:]
for name, edits, filters in RUST_MUTATIONS:
    if not only or any(o in name for o in only):
        mutate(name, edits, run_rust, filters)
for name, edits in KILL_LIST_MUTATIONS:
    if not only or any(o in name for o in only):
        mutate(name, edits, run_kill_list, None)
