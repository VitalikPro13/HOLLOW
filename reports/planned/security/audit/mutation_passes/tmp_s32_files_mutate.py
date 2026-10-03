"""Session 32 mutation pass (files agent): break each guard, expect a named test to FAIL,
restore.

Prints one line per mutation: KILLED, SURVIVED or BROKEN. Every file is restored byte
for byte whatever happens. Pass words to run only the mutations whose name has one.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RUST = os.path.join(ROOT, 'rust', 'hollow_core')
OPS = os.path.join(RUST, 'src/node/vault_ops.rs')
HANDLER = os.path.join(RUST, 'src/node/file_handler.rs')
SWARM = os.path.join(RUST, 'src/node/swarm.rs')

# Item 1: the guest file header.
GUEST = ['test_harness::authz_a_guest_takes_a_public_file_header_only_from_the_peer_it_asked']
GUEST_UNIT = ['file_handler::tests::a_guest_pull_is_answered_only_for_its_server_while_fresh']
# Items 2 and 4: the recovery plan.
PLAN = ['test_harness::authz_a_recovery_plan_counts_only_from_the_coordinator']
# Item 3: vault deletes.
DELETE = ['test_harness::authz_a_vault_delete_needs_a_member_with_manage_server_on_both_lanes']
# Item 4: shard ids and temps.
WRITE = ['vault_ops::tests::authz_shard_write_needs_a_member_and_a_shard_we_lack']
TEMP = ['vault_ops::tests::a_shard_answer_temp_stays_in_its_folder']
WIRED = ['vault_ops::tests::vault_gates_stay_wired']
# Item 5: a failed legacy rebuild keeps what we hold for others.
LEGACY_KEEP = ['vault_ops::tests::a_failed_legacy_rebuild_keeps_the_copies_we_hold_for_others']
LOCAL = ['vault_ops::tests::a_failed_local_rebuild_pulls_afresh']
REBUILD = ['file_handler::tests::a_failed_rebuild_hands_back_a_fresh_pull']
# Item 6: the stream we asked for wins over an unasked store.
ASKED_WINS = ['test_harness::the_holder_we_asked_wins_over_unasked_stores_of_a_shard']
PIN = ['vault_ops::tests::a_shard_must_be_the_one_its_manifest_names']
WAITING = ['vault_ops::tests::a_pull_waits_only_for_its_own_content']
# Item 8: the stream ceiling.
CEILING = ['file_handler::tests::a_stream_ceiling_follows_the_header_the_ask_or_the_link']

MUTATIONS = [
    # ── Item 1 ──
    ('guest header: any peer answers',
     [(SWARM, '            if asked != peer_str {\n                hollow_log!("[HOLLOW-SECURITY] REJECTED PublicFileHeader',
       '            if false && asked != peer_str {\n                hollow_log!("[HOLLOW-SECURITY] REJECTED PublicFileHeader')], GUEST),
    ('guest header: the server and age are not checked',
     [(SWARM, 'let fresh = file_handler::guest_answer_fresh(req_sid, *req_at, &sid);',
       'let fresh = true || file_handler::guest_answer_fresh(req_sid, *req_at, &sid);')], GUEST),
    ('guest freshness: another server answers',
     [(HANDLER, 'asked_sid == sid && asked_at.elapsed() <= GUEST_PULL_TTL',
       '(true || asked_sid == sid) && asked_at.elapsed() <= GUEST_PULL_TTL')], GUEST_UNIT + GUEST),
    ('guest freshness: an old pull answers',
     [(HANDLER, 'asked_sid == sid && asked_at.elapsed() <= GUEST_PULL_TTL',
       'asked_sid == sid && (true || asked_at.elapsed() <= GUEST_PULL_TTL)')], GUEST_UNIT),
    # ── Item 2 ──
    ('recovery plan: any member plans',
     [(SWARM, 'let from_coordinator = pool.members.keys().min() == Some(&from);',
       'let from_coordinator = true || pool.members.keys().min() == Some(&from);')], PLAN),
    ('recovery plan: a shard goes to a non-member',
     [(SWARM, '&& pool.members.contains_key(&assignment.dest_peer)',
       '&& (true || pool.members.contains_key(&assignment.dest_peer))')], PLAN),
    # ── Item 3 ──
    ('vault delete: no Manage Server needed',
     [(OPS, '&& s.has_permission(sender_peer_id, crate::crdt::operations::Permission::MANAGE_SERVER)',
       '&& (true || s.has_permission(sender_peer_id, crate::crdt::operations::Permission::MANAGE_SERVER))')], DELETE),
    ('vault delete: a non-member counts',
     [(OPS, '        s.is_member(sender_peer_id)\n            && s.has_permission(',
       '        (true || s.is_member(sender_peer_id))\n            && s.has_permission(')], DELETE),
    ('vault delete: the refusal is ignored',
     [(OPS, '    if !allowed {\n        hollow_log!("[HOLLOW-SECURITY] REJECTED ShardDelete',
       '    if false && !allowed {\n        hollow_log!("[HOLLOW-SECURITY] REJECTED ShardDelete')], DELETE),
    # ── Item 4 ──
    ('recovery plan: any content id',
     [(SWARM, 'if !crate::vault::content_store::is_content_id(&assignment.content_id) {',
       'if false && !crate::vault::content_store::is_content_id(&assignment.content_id) {')], PLAN),
    ('shard write: any content id',
     [(OPS, '    if !crate::vault::content_store::is_content_id(cid) {\n        return Some("not a content id");',
       '    if false && !crate::vault::content_store::is_content_id(cid) {\n        return Some("not a content id");')], WRITE),
    ('answer temp: path characters kept',
     [(OPS, 'let prefix: String = cid.chars().filter(|c| c.is_ascii_alphanumeric()).take(16).collect();',
       'let prefix: String = cid.chars().take(16).collect();')], TEMP),
    ('answer temp: cut by bytes',
     [(OPS, 'let prefix: String = cid.chars().filter(|c| c.is_ascii_alphanumeric()).take(16).collect();',
       'let prefix: String = cid[..16.min(cid.len())].chars().filter(|c| c.is_ascii_alphanumeric()).collect();')], TEMP),
    ('answer temp: the arm names it from the raw id',
     [(SWARM, 'let shard_temp_path = vault_ops::shard_send_temp(&crate::node::file_transfer::files_dir(), &cid, si);',
       'let shard_temp_path = crate::node::file_transfer::files_dir().join(format!(".stream_shard_{cid}_{si}.tmp"));')], WIRED),
    # ── Item 5 ──
    ('legacy rebuild: our placement copies are deleted too',
     [(OPS, 'if manifest.shard_hash(si as u16).is_some() || ours.contains(&(si as u16)) {',
       'if manifest.shard_hash(si as u16).is_some() || (false && ours.contains(&(si as u16))) {')], LEGACY_KEEP),
    ('legacy rebuild: placements name nobody as us',
     [(OPS, '.filter(|p| super::resolver::resolve(&p.target_peer) == local)',
       '.filter(|p| super::resolver::resolve(&p.target_peer) == local && false)')], LEGACY_KEEP),
    ('legacy rebuild: every copy counts as ours',
     [(OPS, '.filter(|p| super::resolver::resolve(&p.target_peer) == local)',
       '.filter(|p| super::resolver::resolve(&p.target_peer) == local || true)')], LEGACY_KEEP + LOCAL),
    ('stream rebuild: a failed legacy rebuild hands back no fresh pull',
     [(HANDLER, '&& super::vault_ops::holds_unpinned(&manifest, &packed)',
       '&& false && super::vault_ops::holds_unpinned(&manifest, &packed)')], REBUILD),
    ('stream rebuild: every copy counts as unpinned',
     [(OPS, 'packed.iter().enumerate().any(|(si, copy)| copy.is_some() && manifest.shard_hash(si as u16).is_none())',
       'packed.iter().enumerate().any(|(_, copy)| copy.is_some())')], REBUILD),
    # ── Item 6 ──
    ('response: the answer keeps an older registration',
     [(SWARM, 'pending_shard_streams.insert(key.clone(), PendingShardStream {',
       'pending_shard_streams.entry(key.clone()).or_insert(PendingShardStream {')], ASKED_WINS),
    ('stream: an unasked copy needs no pin while we pull',
     [(HANDLER, 'let pulling = !pss.asked && pss.sender.is_some() && pending_vault_downloads.contains_key(&content_id);',
       'let pulling = false && !pss.asked && pss.sender.is_some() && pending_vault_downloads.contains_key(&content_id);')],
     ASKED_WINS),
    ('stream: an asked answer is held to the pin rule',
     [(HANDLER, 'let pulling = !pss.asked && pss.sender.is_some() && pending_vault_downloads.contains_key(&content_id);',
       'let pulling = pss.sender.is_some() && pending_vault_downloads.contains_key(&content_id);')], ASKED_WINS),
    ('inline store: no pin needed while we pull',
     [(SWARM, '&content_store, &cid, si, &shard_bytes, vault_ops::pull_waiting(vault_shard_asks, &cid),',
       '&content_store, &cid, si, &shard_bytes, false && vault_ops::pull_waiting(vault_shard_asks, &cid),')], ASKED_WINS),
    ('migrate: no pin needed while we pull',
     [(SWARM, '&cs, &cid, si, &shard_bytes, vault_ops::pull_waiting(vault_shard_asks, &cid),',
       '&cs, &cid, si, &shard_bytes, false && vault_ops::pull_waiting(vault_shard_asks, &cid),')], ASKED_WINS),
    ('pin rule: pulling is ignored',
     [(OPS, 'None => pulling.then_some(', 'None => (false && pulling).then_some(')], PIN + ASKED_WINS),
    ('pull waiting: any content counts',
     [(OPS, "key.strip_prefix(cid).is_some_and(|rest| rest.starts_with(':')) && at.elapsed() < SHARD_ASK_TTL",
       "(true || key.strip_prefix(cid).is_some_and(|rest| rest.starts_with(':'))) && at.elapsed() < SHARD_ASK_TTL")], WAITING),
    ('pull waiting: a prefix of the id counts',
     [(OPS, "key.strip_prefix(cid).is_some_and(|rest| rest.starts_with(':')) && at.elapsed() < SHARD_ASK_TTL",
       "key.starts_with(cid) && at.elapsed() < SHARD_ASK_TTL")], WAITING),
    ('pull waiting: an expired ask waits',
     [(OPS, "key.strip_prefix(cid).is_some_and(|rest| rest.starts_with(':')) && at.elapsed() < SHARD_ASK_TTL",
       "key.strip_prefix(cid).is_some_and(|rest| rest.starts_with(':')) && (true || at.elapsed() < SHARD_ASK_TTL)")], WAITING),
    # ── Item 8 ──
    ('ceiling: any device rides our pull',
     [(HANDLER, '_ if asked_from && requested_file_receipts', '_ if (true || asked_from) && requested_file_receipts')], CEILING),
    ('ceiling: the ask table names any device',
     [(HANDLER, 'pending_file_asks.get(id).is_some_and(|ask| ask.asked.contains(from))',
       'pending_file_asks.get(id).is_some_and(|ask| !ask.asked.is_empty())')], CEILING),
    ('ceiling: a guest pull answered by any peer',
     [(HANDLER, 'pending_public_file_requests.get(id).is_some_and(|(_, asked, _)| asked == from)',
       'pending_public_file_requests.get(id).is_some()')], CEILING),
    ('ceiling: an expired receipt counts',
     [(HANDLER, '&& requested_file_receipts.get(id).is_some_and(|at| at.elapsed() < RECEIPT_TTL) => u64::MAX',
       '&& requested_file_receipts.get(id).is_some() => u64::MAX')], CEILING),
]

ENV = dict(os.environ)
ENV['PATH'] = r'C:\Program Files\OpenSSL-Win64\bin;' + ENV['PATH']
ENV['CARGO_TARGET_DIR'] = os.path.join(ROOT, 'target')
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
