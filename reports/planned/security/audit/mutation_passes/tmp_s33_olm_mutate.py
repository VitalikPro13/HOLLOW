"""Session 33 mutation pass (the Olm stale-frame rule, AR-19): break each new rule,
expect a named test to FAIL, restore byte for byte.

Prints one line per mutation: KILLED, SURVIVED or BROKEN. Pass words to run only the
mutations whose name has one.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RUST = os.path.join(ROOT, 'rust', 'hollow_core')

OLM = os.path.join(RUST, 'src/crypto/olm_manager.rs')
STORE = os.path.join(RUST, 'src/storage/messages.rs')
SWARM = os.path.join(RUST, 'src/node/swarm.rs')
CRYPTO = os.path.join(RUST, 'src/node/crypto_handler.rs')
FETCH = os.path.join(RUST, 'src/node/fetch.rs')
NETWORK = os.path.join(RUST, 'src/api/network.rs')
ENRICH = os.path.join(RUST, 'src/push_enrich.rs')

U_SPENT = ['crypto::olm_manager::tests::a_spent_message_key_is_stale_on_our_session_or_a_retired_one']
U_PREKEY = ['crypto::olm_manager::tests::a_replayed_prekey_is_stale_with_or_without_its_session']
U_MARK = ['crypto::olm_manager::tests::a_read_mark_covers_what_was_sealed_up_to_it_and_never_moves_back']
U_SAVED = ['crypto::olm_manager::tests::read_marks_survive_a_restart_and_never_move_back']
U_FETCH = ['node::fetch::tests::a_push_fetched_dm_moves_the_olm_read_mark']
U_BOOT = ['crypto::olm_manager::tests::every_process_that_reads_olm_frames_boots_with_its_read_marks']
REPLAY = ['node::test_harness::olm_a_frame_replayed_after_a_restart_leaves_the_session_alone']
RESTORED = ['node::test_harness::olm_a_sender_back_on_an_older_copy_of_its_session_is_re_keyed']
FRESH_PREKEY = ['node::test_harness::olm_a_fresh_prekey_we_cannot_open_still_asks_for_a_key']

MUTATIONS = [
    ('ordinary frame: every failure re-keys, a replay included',
     [(SWARM, '''                        if olm.read_past(peer_str, frame_ts_ms) {
                            hollow_log!("[HOLLOW-SECURITY] Dropped an Olm frame''', '''                        if false {
                            hollow_log!("[HOLLOW-SECURITY] Dropped an Olm frame''')], REPLAY),
    ('PreKey: every failure asks for a key, a replay included',
     [(SWARM, '''                        if olm.read_past(peer_str, frame_ts_ms) {
                            hollow_log!("[HOLLOW-SECURITY] Dropped a PreKey''', '''                        if false {
                            hollow_log!("[HOLLOW-SECURITY] Dropped a PreKey''')], REPLAY),
    ('ordinary frame: every failure is dropped, a fresh one included',
     [(SWARM, '''                        if olm.read_past(peer_str, frame_ts_ms) {
                            hollow_log!("[HOLLOW-SECURITY] Dropped an Olm frame''', '''                        if true {
                            hollow_log!("[HOLLOW-SECURITY] Dropped an Olm frame''')], RESTORED),
    ('PreKey: every failure is dropped, a fresh one included',
     [(SWARM, '''                        if olm.read_past(peer_str, frame_ts_ms) {
                            hollow_log!("[HOLLOW-SECURITY] Dropped a PreKey''', '''                        if true {
                            hollow_log!("[HOLLOW-SECURITY] Dropped a PreKey''')], FRESH_PREKEY),
    ('verdict: the newest frame read is news again',
     [(OLM, 'self.read_marks.get(peer).is_some_and(|&mark| sealed_ms <= mark)',
       'self.read_marks.get(peer).is_some_and(|&mark| sealed_ms < mark)')], U_MARK),
    ('verdict: a frame newer than the mark counts as read',
     [(OLM, 'self.read_marks.get(peer).is_some_and(|&mark| sealed_ms <= mark)',
       'self.read_marks.contains_key(peer)')], U_MARK + RESTORED),
    ('mark: an older frame moves it back',
     [(OLM, '            Some(mark) if *mark >= sealed_ms => false,\n', '')], U_MARK),
    ('node: the mark is never saved',
     [(CRYPTO, '''    if olm.note_read(peer_id, sealed_ms) {
        crypto_store.save_read_mark(peer_id.to_string(), sealed_ms);
    }''', '''    let _ = (sealed_ms, olm.note_read(peer_id, 0));''')], REPLAY),
    ('node: a decrypt leaves the mark alone',
     [(SWARM, '            persist_olm_read(olm, crypto_store, peer_str, frame_ts_ms);',
       '            crypto_handler::persist_olm_session(olm, crypto_store, peer_str);')], REPLAY),
    ('restart: the marks are not loaded',
     [(OLM, '            Ok(marks) => olm.read_marks = marks.into_iter().collect(),',
       '            Ok(marks) => drop(marks),')], U_SAVED),
    ('restart, on the wire: the marks are not loaded',
     [(OLM, '            Ok(marks) => olm.read_marks = marks.into_iter().collect(),',
       '            Ok(marks) => drop(marks),')], REPLAY),
    ('boot: the node loads its sessions without the marks',
     [(NETWORK, '''        crate::chat_clock::observe(store.max_chat_stamp_us());
        match OlmManager::load(&store)? {''', '''        crate::chat_clock::observe(store.max_chat_stamp_us());
        match store.load_olm_account()?.map(|a| OlmManager::from_pickles(&a, store.load_all_olm_sessions().unwrap_or_default())).transpose()? {''')],
     U_BOOT),
    ('boot: the fetch node loads its sessions without the marks',
     [(NETWORK, '''        match OlmManager::load(&store)? {
            Some(olm) => olm,
            None => {
                hollow_log!("[HOLLOW-FETCH]''', '''        match store.load_olm_account()?.map(|a| OlmManager::from_pickles(&a, store.load_all_olm_sessions().unwrap_or_default())).transpose()? {
            Some(olm) => olm,
            None => {
                hollow_log!("[HOLLOW-FETCH]''')], U_BOOT),
    ('boot: the iOS push extension loads its sessions without the marks',
     [(ENRICH, '        match OlmManager::load(&store)? {',
       '        match store.load_olm_account()?.map(|a| OlmManager::from_pickles(&a, store.load_all_olm_sessions().unwrap_or_default())).transpose()? {')],
     U_BOOT),
    ('store: a later, older write moves the mark back',
     [(STORE, 'ON CONFLICT(peer_id) DO UPDATE SET sealed_ms = MAX(sealed_ms, excluded.sealed_ms)',
       'ON CONFLICT(peer_id) DO UPDATE SET sealed_ms = excluded.sealed_ms')], U_SAVED),
    ('push fetch: a decrypt leaves the mark alone',
     [(FETCH, '                persist_olm_read(olm, crypto_store, &from, sealed_at);',
       '                crate::node::crypto_handler::persist_olm_session(olm, crypto_store, &from);')], U_FETCH),
    ('kind: a spent message key reads as unreadable',
     [(OLM, '    matches!(e, DecryptionError::MissingMessageKey(_))', '    matches!(e, DecryptionError::TooBigMessageGap(..))')],
     U_SPENT + U_PREKEY),
    ('kind: a retired session never calls a key spent',
     [(OLM, '                    stale |= spent(&e);\n', '                    let _ = spent(&e);\n')], U_SPENT),
    ('kind: a gone one-time key reads as unreadable',
     [(OLM, 'let stale = matches!(e, SessionCreationError::MissingOneTimeKey(_));', 'let stale = false;')], U_PREKEY),
]

ENV = dict(os.environ)
ENV['PATH'] = r'C:\Program Files\OpenSSL-Win64\bin;' + ENV['PATH']
ENV['CARGO_TARGET_DIR'] = 'D:/dev/wt/s33-olm/rust/hollow_core/target'
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
