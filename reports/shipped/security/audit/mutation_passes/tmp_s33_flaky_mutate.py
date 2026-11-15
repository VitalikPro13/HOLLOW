"""Session 33 mutation pass (the flaky harness pair: the join re-ask reaches a joiner
the relay hides; the Olm VC flood test counts the VC bucket with its refill paused;
a join's timers act only on the ask that armed them, the re-ask window counts from the
first copy out; each received stream has its own temp file): break each rule, expect
the named test to FAIL on every run, restore byte for byte.

Prints one line per mutation: KILLED (every run failed), SURVIVED n/N (some run passed)
or BROKEN. Pass words to run only the mutations whose name has one; `--runs N` repeats
each mutant's test N times (default 1).
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RUST = os.path.join(ROOT, 'rust', 'hollow_core')

SYNC = os.path.join(RUST, 'src/node/sync_handler.rs')
SWARM = os.path.join(RUST, 'src/node/swarm.rs')
VOICE = os.path.join(RUST, 'src/node/voice_handler.rs')
LANE = os.path.join(RUST, 'src/node/join_lane.rs')
STREAM = os.path.join(RUST, 'src/node/ws_stream_transfer.rs')

REASK = ['test_harness::join_survives_a_coordinator_that_vanished_silently']
FLOOD = ['test_harness::authz_a_vc_signal_flood_over_olm_is_rate_limited']
TIMERS = ['test_harness::a_join_timer_acts_only_on_the_ask_that_armed_it']
LATE_LOCK = ['test_harness::a_join_whose_lock_read_lands_late_is_still_asked_again']
TEMPS = ['ws_stream_transfer::tests::two_streams_of_one_id_never_share_a_temp_file']

MUTATIONS = [
    ('re-ask: only the members the joiner can see are asked again',
     [(SYNC, '''    // A locked room shows a joiner none of its members, so the room is asked instead.
    if hidden {
        super::join_lane::send_request_to_room(ws_cmd_tx, &server_id, our_device, pending);
    }
''', '''    let _ = hidden;
''')], REASK),
    ('gate: every member serves a first ask',
     [(SWARM, '                    if !is_sibling && !repeat_ask {', '                    if false {')], REASK),
    ('olm vc: targeted VC signals over Olm skip the VC bucket',
     [(SWARM, '''                Ok(ref env)
                    if voice_handler::is_vc_signal(env)
                        && !voice_handler::vc_rate_check(vc_signal_rate_tokens, peer_str) => {}
''', '''                Ok(ref env)
                    if voice_handler::is_vc_signal(env)
                        && { let _ = &vc_signal_rate_tokens; false } => {}
''')], FLOOD),
    ('live window: ends whatever ask is pending',
     [(SYNC, '''    // A window armed for an earlier ask to this server is not this ask's to end.
    if pending.opened_at != opened_at {
        return;
    }
''', '')], TIMERS),
    ('retry: re-sends whatever ask is pending',
     [(SYNC, '    if pending.opened_at != opened_at || pending.asked {', '    if pending.asked {')], TIMERS),
    ('retry: the window counts from the click',
     [(SYNC, '    let waited = pending.first_sent_at.map_or(Duration::ZERO, |t| t.elapsed());',
       '    let waited = JOIN_RETRY_WINDOW;')], LATE_LOCK),
    ('retry: the first copy out starts no window',
     [(LANE, '    pending.first_sent_at.get_or_insert_with(std::time::Instant::now);', '    let _ = &pending;')], REASK),
    ('stream temp: one file per id',
     [(STREAM, 'format!(".ws_recv_{id}.{}.tmp", RECV_TEMP_SEQ.fetch_add(1, Ordering::Relaxed))',
       'format!(".ws_recv_{id}.tmp")')], TEMPS),
]

ENV = dict(os.environ)
ENV['PATH'] = r'C:\Program Files\OpenSSL-Win64\bin;' + ENV['PATH']
ENV['CARGO_TARGET_DIR'] = 'D:/dev/wt/s33-flaky-mut-target'


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


def mutate(name, edits, filters, runs):
    originals = {}
    verdicts = []
    detail = ''
    try:
        for path, old, new in edits:
            cur = read(path)
            originals.setdefault(path, cur)
            if '\r\n' in cur:
                old, new = old.replace('\n', '\r\n'), new.replace('\n', '\r\n')
            if cur.count(old) != 1:
                raise SystemExit(f'{name}: pattern found {cur.count(old)}x in {path}: {old[:70]!r}')
            write(path, cur.replace(old, new))
        for _ in range(runs):
            verdict, d = run_rust(filters)
            verdicts.append(verdict)
            detail = d or detail
            if verdict == 'BROKEN':
                break
    finally:
        for path, src in originals.items():
            write(path, src)
    killed = verdicts.count('KILLED')
    if 'BROKEN' in verdicts:
        summary = 'BROKEN'
    elif killed == len(verdicts):
        summary = f'KILLED {killed}/{len(verdicts)}'
    else:
        summary = f'SURVIVED {len(verdicts) - killed}/{len(verdicts)}'
    print(f'{summary:16} {name}', flush=True)
    if detail and summary.startswith('BROKEN'):
        print('    ' + detail.replace('\n', '\n    ')[:1200], flush=True)


args = sys.argv[1:]
runs = 1
if '--runs' in args:
    i = args.index('--runs')
    runs = int(args[i + 1])
    del args[i:i + 2]
for name, edits, filters in MUTATIONS:
    if not args or any(o in name for o in args):
        mutate(name, edits, filters, runs)
