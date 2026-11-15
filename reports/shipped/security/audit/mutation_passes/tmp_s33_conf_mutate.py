"""Session 33 mutation pass (HOL-SEC-123 residual: the host of a meeting unseats a device
its roster stops counting, and a device out of the meeting group loses its call): break
each new rule, expect a named test to FAIL, restore byte for byte. The LAYERS entries take
one trigger away and expect the harness test to PASS, so each trigger is shown to unseat
the device on its own.

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
VOICE = os.path.join(RUST, 'src/node/voice_handler.rs')

U_WATCH = ['conference::tests::a_seat_watch_fires_once_per_move_of_the_resolver']
W_SEATS = ['conference::tests::meeting_seats_follow_the_roster_stay_wired']
UNSEAT = ['test_harness::authz_the_host_unseats_a_device_its_roster_drops_mid_meeting']
CALL = ['test_harness::authz_a_device_out_of_the_meeting_group_loses_its_call_for_good']
CONFERENCE = ['test_harness::conference_waiting_room_admits_denies_and_chats']
MEETING = ['test_harness::authz_a_device_its_roster_leaves_out_never_joins_or_speaks_in_a_meeting']

LOOP_HEAD = '''        // A device its roster just stopped counting loses its seat in our meetings now.
        if seat_watch.moved()
            && let Some(mls_mgr) = mls.as_mut()
        {
            super::conference::unseat_refused(
                &conference_host, mls_mgr, &crypto_store, &ws_cmd_tx, &event_tx,
                &mut voice_channel_participants, &mut voice_channel_gossip_mode, &device_peer_id,
            ).await;
        }
'''
BATCH_TICK = '''                    super::conference::unseat_refused(
                        &conference_host, mls_mgr, &crypto_store, &ws_cmd_tx, &event_tx,
                        &mut voice_channel_participants, &mut voice_channel_gossip_mode, &device_peer_id,
                    ).await;
'''
LEAFLESS = 'call.iter().filter(|d| d.as_str() != device_peer_id && !leaves.contains(d))'

MUTATIONS = [
    ('sweep: a participant who does not host commits too',
     [(CONF, '''        // Participants accept the host's commits only.
        if !conference_host.contains_key(conf_id) {
            continue;
        }
''', '''        let _ = conference_host;
''')], UNSEAT),
    ('sweep: a leaf its roster stopped counting keeps its seat',
     [(CONF, '.filter(|leaf| leaf.id() != device_peer_id && leaf.bound().is_none_or(refused))',
       '.filter(|leaf| leaf.id() != device_peer_id && leaf.bound().is_none())')], UNSEAT),
    ('sweep: every other leaf loses its seat, the sibling too',
     [(CONF, '.filter(|leaf| leaf.id() != device_peer_id && leaf.bound().is_none_or(refused))',
       '.filter(|leaf| leaf.id() != device_peer_id)')], UNSEAT),
    ('sweep: the commit never reaches the room',
     [(CONF, '''        broadcast_mls_commit(mls_mgr, ws_cmd_tx, &sid, None,
            base64::engine::general_purpose::STANDARD.encode(&done.commit), epoch);
''', '''        let _ = (&done.commit, ws_cmd_tx);
''')], UNSEAT),
    ('sweep: the host keeps the old epoch\'s media key',
     [(CONF, '''        if let Ok(sframe_key) = mls_mgr.export_secret(&sid, "sframe", b"", 32) {
            let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
                server_id: sid.clone(), epoch: epoch.unwrap_or(0), sframe_key,
                channel_id: None,
            }).await;
        }
        drop_leafless_from_call(''', '''        drop_leafless_from_call(''')], UNSEAT),
    ('wiring: the loop head never sweeps',
     [(SWARM, LOOP_HEAD, '        let _ = &mut seat_watch;\n')], W_SEATS),
    ('wiring: the loop head ignores a move of the resolver',
     [(SWARM, '        if seat_watch.moved()\n            && let Some(mls_mgr) = mls.as_mut()',
       '        if false && seat_watch.moved()\n            && let Some(mls_mgr) = mls.as_mut()')], W_SEATS),
    ('wiring: the batch tick never sweeps',
     [(SWARM, BATCH_TICK, '')], W_SEATS),
    ('watch: never fires',
     [(CONF, '        std::mem::replace(&mut self.0, now) != now', '        self.0 = now;\n        false')], U_WATCH),
    ('watch: fires on every look',
     [(CONF, '        std::mem::replace(&mut self.0, now) != now', '        self.0 = now;\n        true')], U_WATCH),
    ('call: the host keeps an unseated device in its call',
     [(CONF, '''        drop_leafless_from_call(mls_mgr, voice_channel_participants, voice_channel_gossip_mode, event_tx, &sid, device_peer_id).await;
        hollow_log!("[HOLLOW-SECURITY] Unseated''', '''        hollow_log!("[HOLLOW-SECURITY] Unseated''')], UNSEAT),
    ('call: the host keeps a kicked device in its call',
     [(CONF, '''    drop_leafless_from_call(mls_mgr, voice_channel_participants, voice_channel_gossip_mode, event_tx, &sid, device_peer_id).await;
    hollow_log!("[HOLLOW-CONF] Kicked''', '''    let _ = (voice_channel_participants, voice_channel_gossip_mode, device_peer_id);
    hollow_log!("[HOLLOW-CONF] Kicked''')], CALL),
    ('call: a participant merging the commit keeps the device in its call',
     [(SWARM, '''                if super::conference::is_conference_sid(&server_id) {
                    super::conference::drop_leafless_from_call(
                        mls_mgr, voice_channel_participants, voice_channel_gossip_mode, event_tx, &server_id, device_peer_id,
                    ).await;
                }
''', '')], UNSEAT + CALL + CONFERENCE),
    ('call: nobody leaves',
     [(CONF, LEAFLESS, 'call.iter().filter(|d| d.as_str() != device_peer_id && leaves.is_empty() && false)')], UNSEAT + CALL),
    ('call: everyone but us leaves, seated or not',
     [(CONF, LEAFLESS, 'call.iter().filter(|d| d.as_str() != device_peer_id)')], UNSEAT),
    ('call: an evicted device reports itself leaving as a remote peer',
     [(CONF, LEAFLESS, 'call.iter().filter(|d| !leaves.contains(d))')], CONFERENCE),
    ('voice join: a meeting join only has to decrypt',
     [(VOICE, '''        if !super::conference::seated(&mls.group_leaves(&sid), &sender_peer_id) {
            Some("no seat in the meeting group")
        } else {
            (cid != super::conference::CONF_CHANNEL).then_some("not the meeting channel")
        }
''', '''        (cid != super::conference::CONF_CHANNEL).then_some("not the meeting channel")
''')], CALL),
    ('s32 chat: a line from a device its roster does not count is read (test edited this session)',
     [(CONF, '    if refused(&sender) {', '    if false {')], MEETING),
    ('s32 admit: the host seats a device its roster dropped since the knock (test edited this session)',
     [(CONF, '    if seat_of(key_package_b64, peer_id).is_none_or(|leaf| refused(&leaf)) {', '    if false {')], MEETING),
]

# Each trigger alone unseats the device: expected SURVIVED.
LAYERS = [
    ('layer: the batch tick alone unseats',
     [(SWARM, LOOP_HEAD, '        let _ = &mut seat_watch;\n')], UNSEAT),
    ('layer: the loop head alone unseats',
     [(SWARM, BATCH_TICK, '')], UNSEAT),
]

ENV = dict(os.environ)
ENV['PATH'] = r'C:\Program Files\OpenSSL-Win64\bin;' + ENV['PATH']
ENV['CARGO_TARGET_DIR'] = os.path.join(RUST, 'target')
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
for name, edits, filters in MUTATIONS + LAYERS:
    if not only or any(o in name for o in only):
        mutate(name, edits, filters)
