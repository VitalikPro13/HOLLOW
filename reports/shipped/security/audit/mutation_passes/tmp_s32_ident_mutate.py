"""Session 32 mutation pass (phase B guard tests, agent `ident`): break each guard,
expect a named test to FAIL, restore byte for byte.

Prints one line per mutation: KILLED, SURVIVED or BROKEN. Pass words to run only the
mutations whose name has one.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RUST = os.path.join(ROOT, 'rust', 'hollow_core')

SWARM = os.path.join(RUST, 'src/node/swarm.rs')
DESTROY = os.path.join(RUST, 'src/node/destroy.rs')
FETCH = os.path.join(RUST, 'src/node/fetch.rs')
FWD = os.path.join(RUST, 'src/forwarder/signaling.rs')
VH = os.path.join(RUST, 'src/node/voice_handler.rs')

KILL_S30 = ['test_harness::authz_turning_away_junk_that_shares_an_orders_stamp_keeps_the_order']
KILL_NEW = ['test_harness::authz_an_unreadable_kill_blob_is_acked_alone_by_the_full_node']
PREKEY = ['fetch::tests::authz_a_push_prekey_opens_only_with_its_senders_own_proof']
MEETING = ['fetch::tests::a_public_frame_naming_a_meeting_is_never_stored']
BLOCK_NEW = ['test_harness::authz_a_blocked_identitys_unknown_device_is_dropped_once_its_roster_binds']
BLOCK_OLD = ['test_harness::blocked_sender_mailbox_request_dropped',
             'test_harness::blocked_peer_dm_and_friend_request_dropped']
FWD_T = ['forwarder::signaling::tests::fwd_opens_a_prekey_only_with_its_senders_own_proof']
VC_H = ['test_harness::authz_a_vc_signal_from_outside_the_call_is_refused']
VC_U = ['voice_handler::tests::authz_a_vc_signal_counts_only_from_a_participant_of_that_call']
DC_U = ['voice_handler::tests::authz_room_presence_alone_opens_no_channel_to_us']

FORWARDER = ['--features', 'forwarder']


def olm_arm(label):
    """The participant check of one inline Olm SDP/ICE arm in swarm.rs."""
    old = f'                    if !is_participant {{\n                        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC {label} (Olm) from non-participant'
    return (SWARM, old, old.replace('if !is_participant', 'if false && !is_participant'))


def carried_arm(label):
    """The participant check of one carried VC state arm in swarm.rs."""
    old = f'            if !is_participant {{\n                hollow_log!("[HOLLOW-SECURITY] BLOCKED plaintext VC {label} from non-participant'
    return (SWARM, old, old.replace('if !is_participant', 'if false && !is_participant'))


def vh_gate(log):
    """The participant check of one group VC handler in voice_handler.rs."""
    old = f'    if !is_vc_participant(voice_channel_participants, &vc_key, &sender_peer_id) {{\n        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC {log} from non-participant'
    return (VH, old, old.replace('if !is_vc_participant', 'if false && !is_vc_participant'))


def vh_helper_gate(tail):
    """The participant check of a shared SDP helper, told apart by its last parameter."""
    old = f'{tail}\n) {{\n    let vc_key = format!("{{sid}}:{{cid}}");\n    if !is_vc_participant('
    return (VH, old, old.replace('if !is_vc_participant', 'if false && !is_vc_participant'))


MUTATIONS = [
    # Item 1: kill acks on the full node.
    ('kill ack: bare for every turned-away signal',
     [(DESTROY, 'WsCommand::KillAck { signal: Some(signal) };',
       'WsCommand::KillAck { signal: { let _ = signal; None } };')], KILL_S30 + KILL_NEW, []),
    ('kill ack: bare for an unreadable blob',
     [(DESTROY, '        hollow_log!("[HOLLOW-DESTROY] Kill signal blob is not a destruction order, acked and dropped");\n        let _ = ws_cmd_tx.send(ack);',
       '        hollow_log!("[HOLLOW-DESTROY] Kill signal blob is not a destruction order, acked and dropped");\n        let _ = ack;\n        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::KillAck { signal: None });')],
     KILL_S30 + KILL_NEW, []),
    # Item 2: the push fetch node's PreKey gate.
    ('fetch: a PreKey opens without its device proof',
     [(FETCH, 'if !crate::node::crypto_handler::verify_olm_identity(from, their_identity, identity_sig, identity_pk) {',
       'if false && !crate::node::crypto_handler::verify_olm_identity(from, their_identity, identity_sig, identity_pk) {')],
     PREKEY, []),
    # Item 3: the push fetch node's meeting guard on the public arm.
    ('fetch: a public frame naming a meeting is stored',
     [(FETCH, '            if crate::node::conference::is_conference_sid(&server_id) {\n                return None;\n            }\n            let state = stored_server_state(',
       '            if false && crate::node::conference::is_conference_sid(&server_id) {\n                return None;\n            }\n            let state = stored_server_state(')],
     MEETING, []),
    # Item 4: the friend request's block check after the roster binds.
    ('friend request: no block check once the roster binds',
     [(SWARM, '                // is bound to its master only now.\n                if super::blocklist::is_blocked(peer_str) {',
       '                // is bound to its master only now.\n                if false && super::blocklist::is_blocked(peer_str) {')],
     BLOCK_NEW + BLOCK_OLD, []),
    # Item 5: the forwarder's PreKey gate.
    ('forwarder: a PreKey opens without its device proof',
     [(FWD, 'if !crate::node::crypto_handler::verify_olm_identity(from, their_identity, identity_sig, identity_pk) {',
       'if false && !crate::node::crypto_handler::verify_olm_identity(from, their_identity, identity_sig, identity_pk) {')],
     FWD_T, FORWARDER),
    # Item 6: VC signals from outside the call, the inline Olm and carried arms.
    ('olm arm: SDP offer from a non-participant', [olm_arm('SDP offer')], VC_H, []),
    ('olm arm: SDP answer from a non-participant', [olm_arm('SDP answer')], VC_H, []),
    ('olm arm: ICE from a non-participant', [olm_arm('ICE')], VC_H, []),
    ('olm arm: reneg offer from a non-participant', [olm_arm('reneg offer')], VC_H, []),
    ('olm arm: reneg answer from a non-participant', [olm_arm('reneg answer')], VC_H, []),
    ('carried arm: audio state from a non-participant', [carried_arm('audio state')], VC_H, []),
    ('carried arm: screen state from a non-participant', [carried_arm('screen state')], VC_H, []),
    ('carried arm: camera state from a non-participant', [carried_arm('camera state')], VC_H, []),
    ('carried arm: recording state from a non-participant', [carried_arm('recording state')], VC_H, []),
    # Item 6: the group (MLS) handlers, shared by the Olm screen arms.
    ('group: SDP helper (offer, answer, reneg)', [vh_helper_gate('    ice_restart: bool,')], VC_U, []),
    ('group: screen SDP helper (offer, answer)', [vh_helper_gate("    signal_type: &'static str,\n    log_label: &'static str,")], VC_U, []),
    ('group: ICE', [vh_gate('ICE')], VC_U, []),
    ('group: screen ICE', [vh_gate('screen ICE')], VC_U, []),
    ('group: screen watch', [vh_gate('screen watch')], VC_U, []),
    ('group: leg restart', [vh_gate('leg restart')], VC_U, []),
    ('group: audio state', [vh_gate('audio state')], VC_U, []),
    ('group: screen state', [vh_gate('screen state')], VC_U, []),
    ('group: camera state', [vh_gate('camera state')], VC_U, []),
    ('group: recording state', [vh_gate('recording state')], VC_U, []),
    # Item 10: the flood test without its "flood-ready" DM still sees the Olm guard.
    ('olm arm: VC signals skip the rate limit',
     [(SWARM, '                    if voice_handler::is_vc_signal(env)\n                        && !voice_handler::vc_rate_check(vc_signal_rate_tokens, peer_str) => {}',
       '                    if false && voice_handler::is_vc_signal(env)\n                        && !voice_handler::vc_rate_check(vc_signal_rate_tokens, peer_str) => {}')],
     ['test_harness::authz_a_vc_signal_flood_over_olm_is_rate_limited'], []),
    # Item 7: the event loop's data channel gate keeps the sync gate's answer.
    ('data channel: the loop gate lets a stranger in',
     [(VH, '    tokio::task::spawn_blocking(move || super::social::holds_accepted_friend(&db, &pass, &master))',
       '    tokio::task::spawn_blocking(move || super::social::holds_accepted_friend(&db, &pass, &master) || !master.is_empty())')],
     DC_U, []),
]

ENV = dict(os.environ)
ENV['PATH'] = r'C:\Program Files\OpenSSL-Win64\bin;' + ENV['PATH']
ENV['CARGO_TARGET_DIR'] = os.path.join(ROOT, 'target')
ENV['CARGO_BUILD_JOBS'] = '4'


def read(path):
    return open(path, encoding='utf-8', newline='').read()


def write(path, text):
    open(path, 'w', encoding='utf-8', newline='').write(text)


def run_rust(filters, extra):
    cmd = ['cargo', 'nextest', 'run', '--lib', '--no-fail-fast',
           '--failure-output', 'never', '--success-output', 'never'] + extra + filters
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


def mutate(name, edits, filters, extra):
    originals = {}
    try:
        for path, old, new in edits:
            cur = read(path)
            originals.setdefault(path, cur)
            if '\r\n' in cur:
                old, new = old.replace('\n', '\r\n'), new.replace('\n', '\r\n')
            if cur.count(old) != 1:
                raise SystemExit(f'{name}: pattern found {cur.count(old)}x in {path}: {old[:90]!r}')
            write(path, cur.replace(old, new))
        verdict, detail = run_rust(filters, extra)
    finally:
        for path, src in originals.items():
            write(path, src)
    print(f'{verdict:9} {name}', flush=True)
    if detail and verdict != 'SURVIVED':
        print('    ' + detail.replace('\n', '\n    ')[:1200], flush=True)


if sys.argv[1:] == ['--check']:
    for name, edits, _, _ in MUTATIONS:
        for path, old, _ in edits:
            cur = read(path)
            if '\r\n' in cur:
                old = old.replace('\n', '\r\n')
            print(f'{cur.count(old)}  {name}')
    raise SystemExit(0)

only = sys.argv[1:]
for name, edits, filters, extra in MUTATIONS:
    if not only or any(o in name for o in only):
        mutate(name, edits, filters, extra)
