"""Session 32 mutation pass (recovery pool keyed by device, coordinator's own part,
planned source bound): break each rule, expect a named test to FAIL, restore byte for byte.

Prints one line per mutation: KILLED, SURVIVED or BROKEN. Pass words to run only the
mutations whose name has one.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RUST = os.path.join(ROOT, 'rust', 'hollow_core')

SWARM = os.path.join(RUST, 'src/node/swarm.rs')
OPS = os.path.join(RUST, 'src/node/vault_ops.rs')
HANDLER = os.path.join(RUST, 'src/node/file_handler.rs')

DEVICES = ['test_harness::a_recovery_transfer_reaches_a_device_that_is_not_its_master']
OWN_PART = ['test_harness::the_recovery_coordinator_carries_out_its_own_part_of_the_plan']
SOURCE = ['test_harness::authz_a_recovery_shard_lands_only_from_the_plans_source']
PLAN = ['test_harness::authz_a_recovery_plan_counts_only_from_the_coordinator']

MUTATIONS = [
    # Item 1: every member keyed by its device, ours included.
    ('initiate: our own entry keyed by our master',
     [(SWARM, '''                        vault_ops::handle_initiate_recovery_pool(
                            &mut recovery_pool_state,
                            &event_tx, &ws_cmd_tx,
                            &device_peer_id,''', '''                        vault_ops::handle_initiate_recovery_pool(
                            &mut recovery_pool_state,
                            &event_tx, &ws_cmd_tx,
                            &local_peer_str,''')], DEVICES + OWN_PART),
    ('join: our own entry keyed by our master',
     [(SWARM, '''                        vault_ops::handle_join_recovery_pool(
                            &mut recovery_pool_state,
                            &event_tx, &ws_cmd_tx,
                            &device_peer_id,''', '''                        vault_ops::handle_join_recovery_pool(
                            &mut recovery_pool_state,
                            &event_tx, &ws_cmd_tx,
                            &local_peer_str,''')], DEVICES + OWN_PART),
    ('plan: the dest matched against our master',
     [(OPS, '        if assignment.dest_peer == pool.local_device\n', '        if assignment.dest_peer == local_peer_str\n')],
     DEVICES + OWN_PART + SOURCE),
    ('plan: the source matched against our master',
     [(OPS, '        if assignment.source_peer == pool.local_device && pool.members',
       '        if assignment.source_peer == local_peer_str && pool.members')], DEVICES + OWN_PART),
    ('welcomes: our inventory looked up by our master (both welcome sites)',
     [(SWARM, '''sending our inventory");
                                    if let Some(our_inv) = pool.own_inventory() {''', '''sending our inventory");
                                    if let Some(our_inv) = pool.members.get(&local_peer_str) {'''),
      (SWARM, '''                                                        let fresh = pool.add_member(from.clone(), inventory);

                                                        if let Some(our_inv) = pool.own_inventory() {''',
       '''                                                        let fresh = pool.add_member(from.clone(), inventory);

                                                        if let Some(our_inv) = pool.members.get(&local_peer_str) {''')],
     DEVICES + OWN_PART),
    # The coordinator carries out its own part.
    ('coordinator: skips its own part of the plan',
     [(OPS, '''    apply_recovery_plan(
        pool, &plan, pending_shard_streams, pending_vault_downloads, server_states, ws_cmd_tx, local_peer_str,
        db_path, db_passphrase,
    )
    .await;
}''', '''    let _ = (pending_shard_streams, pending_vault_downloads, server_states, local_peer_str, db_path, db_passphrase);
}''')], OWN_PART),
    ('coordinator: streams before its plan is on its way',
     [(OPS, '''    if let Some(bytes) = pool.seal(&pool.local_device, &msg) {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom { room_code: pool.room_code(), data: bytes });
    }
    apply_recovery_plan(
        pool, &plan, pending_shard_streams, pending_vault_downloads, server_states, ws_cmd_tx, local_peer_str,
        db_path, db_passphrase,
    )
    .await;
}''', '''    apply_recovery_plan(
        pool, &plan, pending_shard_streams, pending_vault_downloads, server_states, ws_cmd_tx, local_peer_str,
        db_path, db_passphrase,
    )
    .await;
    if let Some(bytes) = pool.seal(&pool.local_device, &msg) {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom { room_code: pool.room_code(), data: bytes });
    }
}''')], OWN_PART),
    # A member is listed once.
    ('welcome: every copy lists its member again',
     [(SWARM, '                                                    if pool.add_member(from.clone(), inventory) {',
       '                                                    if { pool.add_member(from.clone(), inventory); true } {')], OWN_PART),
    ('hello: every copy lists its member again',
     [(SWARM, '''                                                        if fresh {
                                                            let _ = event_tx.send(NetworkEvent::RecoveryPoolMemberJoined {''',
       '''                                                        if { let _ = fresh; true } {
                                                            let _ = event_tx.send(NetworkEvent::RecoveryPoolMemberJoined {''')], SOURCE),
    # Item 2: a planned transfer completes only from its planned source.
    ('completion: any device completes a shard stream',
     [(HANDLER, '    if pending_shard_streams.get(&key).is_some_and(|p| p.sender != sender_peer) {',
       '    if false && pending_shard_streams.get(&key).is_some_and(|p| p.sender != sender_peer) {')], SOURCE),
    ('plan: the registration bound to the coordinator, not the source',
     [(OPS, '                sender: assignment.source_peer.clone(),',
       '                sender: pool.coordinator().unwrap_or_default().to_string(),')], SOURCE + DEVICES),
    ('completion: a planned transfer judged as an unasked copy',
     [(HANDLER, '            let pulling = !pss.asked && !pss.recovery && pending_vault_downloads.contains_key(&content_id);',
       '            let pulling = !pss.asked && pending_vault_downloads.contains_key(&content_id);')], SOURCE),
    ('plan: a recovery registration not marked as one',
     [(OPS, '                recovery: true,', '                recovery: false,')], SOURCE),
    # HOL-SEC-026/106 rules, moved into apply_recovery_plan: still alive.
    ('plan: from any member, not only the coordinator',
     [(SWARM, '                                                    if pool.coordinator() != Some(from.as_str()) {',
       '                                                    if false {')], PLAN),
    ('plan: streams to a peer outside the pool',
     [(OPS, '        if assignment.source_peer == pool.local_device && pool.members.contains_key(&assignment.dest_peer) {',
       '        if assignment.source_peer == pool.local_device {')], PLAN),
    ('plan: takes an id that is not a content id',
     [(OPS, '        if !crate::vault::content_store::is_content_id(&assignment.content_id) {', '        if false {')], PLAN),
]

ENV = dict(os.environ)
ENV['PATH'] = r'C:\Program Files\OpenSSL-Win64\bin;' + ENV['PATH']
ENV['CARGO_TARGET_DIR'] = r'D:\dev\wt\s32-recov\target'
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
