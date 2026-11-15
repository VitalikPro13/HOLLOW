"""Session 32 mutation pass (meetings ask the roster; MLS-triggered syncs ask only a
member; discovery keeps a bare master id out of room presence): break each new rule,
expect a named test to FAIL, restore byte for byte.

Prints one line per mutation: KILLED, SURVIVED or BROKEN. Pass words to run only the
mutations whose name has one.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RUST = os.path.join(ROOT, 'rust', 'hollow_core')

CONF = os.path.join(RUST, 'src/node/conference.rs')
SWARM = os.path.join(RUST, 'src/node/swarm.rs')
CRYPTO = os.path.join(RUST, 'src/node/crypto_handler.rs')

U_HOST = ['conference::tests::a_host_frame_counts_only_from_a_device_the_hosts_roster_counts']
U_SEAT = ['conference::tests::a_meeting_seat_needs_a_leaf_its_masters_roster_counts']
U_PARTNER = ['server_state::tests::authz_mls_syncs_ask_only_a_member_device']
LOBBY = ['test_harness::authz_a_device_the_hosts_roster_leaves_out_runs_no_lobby']
MEETING = ['test_harness::authz_a_device_its_roster_leaves_out_never_joins_or_speaks_in_a_meeting']
HELD = ['test_harness::authz_a_held_commit_asks_only_a_member_to_sync']
WELCOME = ['test_harness::authz_a_welcome_asks_only_a_member_to_sync']
W_VOICE = ['crypto_handler::tests::channel_ingest_gates_stay_wired']
W_WELCOME = ['crypto_handler::tests::welcome_channel_syncs_stay_gated']
W_BARE = ['roster_book::tests::bare_master_gates_stay_wired']

MUTATIONS = [
    ('host frame: the certificate alone proves the host',
     [(CONF, '    (identity.device == sender_device && identity.master == host.master && !refused(&identity))',
       '    (identity.device == sender_device && identity.master == host.master)')], U_HOST + LOBBY),
    ('knock: a device its roster does not count reaches the waiting room',
     [(CONF, '    if refused(&knocker) {', '    if false {')], MEETING),
    ('admit: the host seats a device its roster dropped since the knock',
     [(CONF, '    if seat_of(key_package_b64, peer_id).is_none_or(|leaf| refused(&leaf)) {', '    if false {')], MEETING),
    ('chat: a line from a device its roster does not count is read',
     [(CONF, '    if refused(&sender) {', '    if false {')], MEETING),
    ('seat: any bound leaf holds a meeting seat',
     [(CONF, 'any(|leaf| leaf.device == device && !refused(leaf))', 'any(|leaf| leaf.device == device)')], U_SEAT),
    ('voice arm: a meeting join asks group membership only',
     [(SWARM, 'super::conference::seated(&m.group_leaves(&server_id), peer_str)',
       'm.group_members(&server_id).iter().any(|c| c == peer_str)')], W_VOICE),
    ('discovery: a bare master id enters room presence',
     [(SWARM, '''                        hollow_log!("[HOLLOW-WS] Discovered {} peers in room {room}", peers.len());
                        let peers: Vec<String> = peers.into_iter().filter(|p| bare_presence.admits(p)).collect();
''', '''                        hollow_log!("[HOLLOW-WS] Discovered {} peers in room {room}", peers.len());
''')], W_BARE),
    ('partner: whoever delivered the frame',
     [(CRYPTO, '''    let state = state?;
    if let Some(leaf) = leaf.filter(|l| state.is_member(&l.master) && !super::mls_authority::refused(l)) {
        return Some((leaf.device.as_str(), leaf.master.clone()));
    }
    frame_sender
        .filter(|d| sync_partner(Some(state), d, None))
        .map(|d| (d, super::resolver::resolve(d)))
''', '''    let _ = (state, leaf);
    frame_sender.map(|d| (d, super::resolver::resolve(d)))
''')], U_PARTNER + HELD + WELCOME),
    ('partner: a leaf counts by its certificate, whatever the roster says',
     [(CRYPTO, 'state.is_member(&l.master) && !super::mls_authority::refused(l)', 'state.is_member(&l.master)')], U_PARTNER),
    ('partner: any leaf the roster counts, member or not',
     [(CRYPTO, 'state.is_member(&l.master) && !super::mls_authority::refused(l)', '!super::mls_authority::refused(l)')], U_PARTNER),
    ('partner: a frame sender outside the server',
     [(CRYPTO, '        .filter(|d| sync_partner(Some(state), d, None))\n', '        .filter(|_| true)\n')], U_PARTNER),
    ('held commit: the sync goes to the frame sender',
     [(CRYPTO, '(state, mls_sync_partner(state, committer.as_ref(), Some(frame_sender)))',
       '(state, { let _ = &committer; Some((frame_sender, String::new())) })')], HELD),
    ('welcome: the syncs go to the frame sender',
     [(SWARM, '''                        let sync_peer = crate::node::crypto_handler::mls_sync_partner(
                            server_states.get(&server_id), welcome_leaf.as_ref(), Some(peer_str),
                        );''', '''                        let sync_peer = Some((peer_str, super::resolver::resolve(peer_str)));''')], WELCOME),
    ('welcome: every channel sync goes to the partner',
     [(SWARM, 'for cid in sync_cids.iter().filter(|c| state.can_see_channel(&peer_master, c)) {',
       'for cid in sync_cids.iter() {')], W_WELCOME),
]

ENV = dict(os.environ)
ENV['PATH'] = r'C:\Program Files\OpenSSL-Win64\bin;' + ENV['PATH']
ENV['CARGO_TARGET_DIR'] = 'D:/dev/wt/s32-conf/target'
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
