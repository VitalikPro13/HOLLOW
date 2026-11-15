"""Session 32 mutation pass (crdt worktree: phase B guard tests and the SyncResponse store):
break each guard, expect a named test to FAIL, restore byte for byte.

Prints one line per mutation: KILLED, SURVIVED or BROKEN, with the failing tests. Pass
words to run only the mutations whose name has one; `--check` only verifies that every
pattern is found exactly once.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RUST = os.path.join(ROOT, 'rust', 'hollow_core')

SWARM = os.path.join(RUST, 'src/node/swarm.rs')
FOLD = os.path.join(RUST, 'src/crdt/fold.rs')
OPS = os.path.join(RUST, 'src/crdt/operations.rs')
STATE = os.path.join(RUST, 'src/crdt/server_state.rs')
MLSA = os.path.join(RUST, 'src/node/mls_authority.rs')

RESOLVED_FUTURE = ['test_harness::authz_a_resolution_never_answers_an_ask_made_after_it']
RESOLVED_MEMBER = ['test_harness::authz_a_resolution_counts_only_from_a_member']
KICK_NEW = ['test_harness::authz_a_kick_notice_needs_a_kicker_with_the_right_and_the_rank']
KICK_OLD = [
    'test_harness::authz_a_kick_notice_without_its_removal_op_is_ignored',
    'server_state::tests::op_allowed_ingest_matrix',
    'server_state::tests::authz_moderation_edges_respect_rank',
    'server_state::tests::authz_the_owner_is_fixed',
]
SEAT = ['mls_authority::tests::authz_a_banned_or_departed_identity_holds_no_seat']
SEAT_OLD = ['mls_authority::tests::', 'test_harness::authz_no_one_seats_a_leaf_in_another_devices_name']
KP_SCAN = ['crypto_handler::tests::authz_key_package_must_name_its_sending_device']
INGEST = ['server_state::tests::ingest_', 'server_state::tests::server_created_on_owned_server_is_rejected',
          'server_state::tests::snapshot_clamp_future_hlcs_bounds_every_register']
MESH = ['test_harness::authz_a_data_channel_op_takes_the_one_ingest']
BATCH = ['test_harness::authz_both_batch_arms_take_backfill_only_from_a_reader']
BATCH_SCAN = ['crypto_handler::tests::channel_ingest_gates_stay_wired']
STORE = ['test_harness::a_sync_answer_stores_exactly_what_the_fold_admitted']
MATRIX = ['server_state::tests::op_allowed_ingest_matrix']

STICKER_ARM = '''            CrdtPayload::StickerAdded { hash, name, pack, w, h, .. } => {
                has(Permission::MANAGE_EMOTES)
                    && super::valid_emote_hash(hash)
                    && valid_sticker_label(name)
                    && valid_sticker_label(pack)'''

MUTATIONS = [
    ('1a resolution: an ask after the seal counts',
     [(SWARM, 'if requested_at > frame_ts_ms.saturating_add(super::frame_auth::LIVE_SKEW_MS) {', 'if false {')],
     RESOLVED_FUTURE),
    ('7 resolution: a non-member answers',
     [(SWARM, '''            if !sender_is_member {
                hollow_log!("[HOLLOW-SECURITY] Ignoring ServerJoinResolved''', '''            if false {
                hollow_log!("[HOLLOW-SECURITY] Ignoring ServerJoinResolved''')],
     RESOLVED_MEMBER),
    ('1b kick: no rank needed',
     [(STATE, '(perms & Permission::KICK_MEMBERS != 0 && actor.outranks(&target_role))',
       '(perms & Permission::KICK_MEMBERS != 0)')], KICK_NEW + KICK_OLD),
    ('1b kick: no Kick Members needed',
     [(STATE, '(perms & Permission::KICK_MEMBERS != 0 && actor.outranks(&target_role))',
       '(actor.outranks(&target_role))')], KICK_NEW + KICK_OLD),
    ('1c seat: a banned identity still listed counts',
     [(MLSA, 'if !state.members.contains_key(master) || state.is_banned(master) {',
       'if !state.members.contains_key(master) {')], SEAT + SEAT_OLD),
    ('1c seat: a non-member counts',
     [(MLSA, 'if !state.members.contains_key(master) || state.is_banned(master) {',
       'if state.is_banned(master) {')], SEAT + SEAT_OLD),
    ('1c KeyPackage arm stops asking the rule',
     [(SWARM, 'if let crate::crypto::Verdict::Hold(why) = rules.membership(&sender_leaf.master, "sender") {',
       'if let Some(why) = None::<String> {')], KP_SCAN + SEAT_OLD),
    ('2 stateless: no author signature check',
     [(FOLD, '''        op.verify_author()?;
        if op.hlc.physical_ms > now_ms''', '''        let _ = op.verify_author();
        if op.hlc.physical_ms > now_ms''')], INGEST),
    ('2 stateless: no clock bound',
     [(FOLD, 'if op.hlc.physical_ms > now_ms + super::hlc::MAX_DRIFT_MS {', 'if false {')], INGEST),
    ('6 stateless: another server\'s op passes',
     [(FOLD, '''        if op.server_id != self.server_id {
            return Err(OpReject::WrongServer);''', '''        if false {
            return Err(OpReject::WrongServer);''')], INGEST),
    ('2 ingest stops asking stateless_check',
     [(FOLD, 'if let Err(reason) = self.stateless_check(op, now) {',
       'if let Err(reason) = Ok::<(), OpReject>(()) {')], INGEST),
    ('2 verify_author: the clock may name another author',
     [(OPS, 'if self.hlc.actor != self.author {', 'if false {')], INGEST),
    ('3 mesh entry also applies outside the ingest',
     [(SWARM, '''                            super::gossip_relay::accept_gossip_op(&mut gossip_overlays, &payload)
                        {
''', '''                            super::gossip_relay::accept_gossip_op(&mut gossip_overlays, &payload)
                        {
                            if let (Some(s), Ok(op)) = (server_states.get_mut(&server_id), serde_json::from_str::<crate::crdt::operations::CrdtOp>(&op_json)) { let _ = s.apply_op(&op); }
''')], MESH),
    ('3 mesh entry ingests nothing',
     [(SWARM, '''                                HavenMessage::CrdtOpBroadcast { server_id, op_json },
                                super::frame_auth::now_ms(),''', '''                                HavenMessage::CrdtOpBroadcast { server_id: String::new(), op_json },
                                super::frame_auth::now_ms(),''')], MESH),
    ('4 Olm batch arm takes anyone',
     [(SWARM, 'if !crypto_handler::channel_backfill_allowed_from(server_states.get(&sid), peer_str, &cid) {',
       'if false && !crypto_handler::channel_backfill_allowed_from(server_states.get(&sid), peer_str, &cid) {')],
     BATCH + BATCH_SCAN),
    ('4 MLS batch arm takes anyone',
     [(SWARM, 'if crypto_handler::channel_backfill_allowed_from(server_states.get(&sid), &sender_master, &cid) {',
       'if true || crypto_handler::channel_backfill_allowed_from(server_states.get(&sid), &sender_master, &cid) {')],
     BATCH + BATCH_SCAN),
    ('5 sync answer stores op by op (the old way)',
     [(SWARM, 'store.persist_admitted_ops(&admitted, state.checkpoint_hlc.as_ref());',
       'for op in &admitted { let _ = store.insert_crdt_op(op); }')], STORE),
    ('5 sync answer stores every incoming op',
     [(SWARM, 'store.persist_admitted_ops(&admitted, state.checkpoint_hlc.as_ref());',
       'store.persist_admitted_ops(&incoming_ops, state.checkpoint_hlc.as_ref());')], STORE),
    ('8 sticker: no Manage Emotes',
     [(STATE, STICKER_ARM, STICKER_ARM.replace('has(Permission::MANAGE_EMOTES)', 'true'))], MATRIX),
    ('8 sticker: any hash',
     [(STATE, STICKER_ARM, STICKER_ARM.replace('                    && super::valid_emote_hash(hash)\n', ''))], MATRIX),
    ('8 sticker: any name',
     [(STATE, STICKER_ARM, STICKER_ARM.replace('                    && valid_sticker_label(name)\n', ''))], MATRIX),
    ('8 sticker: any pack',
     [(STATE, STICKER_ARM, STICKER_ARM.replace('\n                    && valid_sticker_label(pack)', ''))], MATRIX),
    ('8 sticker: any width',
     [(STATE, '                    && (1..=4096).contains(w)\n', '')], MATRIX),
    ('8 sticker: any height',
     [(STATE, '                    && (1..=4096).contains(h)\n', '')], MATRIX),
    ('8 sticker removal: no Manage Emotes',
     [(STATE, '''            CrdtPayload::EmojiRemoved { .. } | CrdtPayload::StickerRemoved { .. } => {
                has(Permission::MANAGE_EMOTES)''', '''            CrdtPayload::EmojiRemoved { .. } | CrdtPayload::StickerRemoved { .. } => {
                true''')], MATRIX),
]

ENV = dict(os.environ)
ENV['PATH'] = r'C:\Program Files\OpenSSL-Win64\bin;' + ENV['PATH']
ENV['CARGO_TARGET_DIR'] = os.path.join(ROOT, 'target')
ENV['CARGO_BUILD_JOBS'] = '4'


def read(path):
    return open(path, encoding='utf-8', newline='').read()


def write(path, text):
    open(path, 'w', encoding='utf-8', newline='').write(text)


def crlf(cur, text):
    return text.replace('\n', '\r\n') if '\r\n' in cur else text


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


def check():
    for name, edits, _ in MUTATIONS:
        for path, old, _new in edits:
            cur = read(path)
            n = cur.count(crlf(cur, old))
            print(f'{n}  {name}')


def mutate(name, edits, filters):
    originals = {}
    try:
        for path, old, new in edits:
            cur = read(path)
            originals.setdefault(path, cur)
            old, new = crlf(cur, old), crlf(cur, new)
            if cur.count(old) != 1:
                raise SystemExit(f'{name}: pattern found {cur.count(old)}x in {path}: {old[:70]!r}')
            write(path, cur.replace(old, new))
        verdict, detail = run_rust(filters)
    finally:
        for path, src in originals.items():
            write(path, src)
    print(f'{verdict:9} {name}', flush=True)
    if detail:
        print('    ' + detail.replace('\n', '\n    ')[:1500], flush=True)


args = sys.argv[1:]
if args == ['--check']:
    check()
else:
    for name, edits, filters in MUTATIONS:
        if not args or any(o in name for o in args):
            mutate(name, edits, filters)
