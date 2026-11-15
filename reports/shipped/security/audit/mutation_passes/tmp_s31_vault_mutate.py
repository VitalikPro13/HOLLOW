"""Session 31 mutation pass (HOL-SEC-117, a bad vault shard never blocks a download for
good): break each new rule, expect a named test to FAIL, restore.

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
PIPELINE = os.path.join(RUST, 'src/vault/pipeline.rs')

GATE = ['vault_ops::tests::a_shard_must_be_the_one_its_manifest_names']
GATHER = ['vault_ops::tests::a_rebuild_deletes_the_copies_its_manifest_refutes']
LOCAL = ['vault_ops::tests::a_failed_local_rebuild_pulls_afresh']
CAP = ['vault_ops::tests::a_refuted_holder_is_skipped_and_fresh_pulls_are_capped']
WIRED = ['vault_ops::tests::vault_gates_stay_wired']
REBUILD = ['file_handler::tests::a_failed_rebuild_hands_back_a_fresh_pull']
PIN = ['pipeline::tests::a_manifest_pins_every_shard_it_places']
PLANT = ['test_harness::a_planted_vault_shard_is_dropped_and_the_real_one_pulled']
HOLDER = ['test_harness::a_holder_that_answers_with_a_wrong_shard_is_not_asked_again']

MUTATIONS = [
    ('write gate: bytes are not checked against the manifest',
     [(OPS, '(crate::vault::content_store::content_id(bytes) != expected).then_some(',
       '(crate::vault::content_store::content_id(bytes) != expected && false).then_some(')], GATE),
    ('upload: the manifest pins no shard',
     [(PIPELINE, 'let shard_hashes = if shard_count == 0 {', 'let shard_hashes = if true || shard_count == 0 {')], PIN),
    ('rebuild: a refuted copy is kept',
     [(OPS, 'Ok(bytes) if crate::vault::content_store::content_id(&bytes) == expected => *slot = Some(bytes),',
       'Ok(bytes) if true || crate::vault::content_store::content_id(&bytes) == expected => *slot = Some(bytes),')],
     GATHER + PLANT),
    ('rebuild: only the server named is looked in',
     [(OPS, 'let Ok(Some(record)) = cs.get_shard_record(&key) else { continue };',
       'let Ok(Some(record)) = cs.get_shard_record(&key).map(|r| r.filter(|r| r.server_id == "srv")) else { continue };')],
     GATHER),
    ('failed rebuild: unvouched copies are kept',
     [(OPS, '            && cs.delete_shard(&record.server_id, &key).is_ok()',
       '            && false\n            && cs.delete_shard(&record.server_id, &key).is_ok()')], GATHER),
    ('download: a failed local rebuild never drops',
     [(OPS, 'if drop_unpinned_shards(&cs, &manifest, &packed) == 0 {',
       'if true || drop_unpinned_shards(&cs, &manifest, &packed) == 0 {')], LOCAL),
    ('download: replicated content is never pulled',
     [(OPS, '    // Non-uploaders hold no placements: recompute them as the uploader did.',
       '    if manifest.k == 0 && manifest.m == 0 {\n        return Err("No local shard available for replicated content".into());\n    }\n'
       '    // Non-uploaders hold no placements: recompute them as the uploader did.')], LOCAL + PLANT),
    ('download: a refuted holder is asked again',
     [(OPS, '.filter(|(peer, _)| !holder_refuted(vault_shard_asks, &content_id, peer))',
       '.filter(|(peer, _)| true || !holder_refuted(vault_shard_asks, &content_id, peer))')], HOLDER),
    ('repull: fresh pulls are not capped',
     [(OPS, 'book.repulls <= MAX_VAULT_REPULLS', 'book.repulls <= MAX_VAULT_REPULLS || book.repulls > 0')], CAP),
    ('repull: the wrong holder is not refuted',
     [(OPS, '        refute_holder(vault_shard_asks, &content_id, holder);\n', '        let _ = holder;\n')], HOLDER),
    ('stream: a shard is stored unchecked against its manifest',
     [(HANDLER, 'if let Some(reason) = super::vault_ops::shard_bytes_refused(&content_store, &pss.content_id, pss.shard_index, &shard_bytes) {',
       'if let Some(reason) = None::<&\'static str> {')], WIRED + HOLDER),
    ('stream: a refused answer hands back no fresh pull',
     [(HANDLER, 'return (pss.asked && pending_vault_downloads.contains_key(&content_id)).then(|| {',
       'return (false && pss.asked && pending_vault_downloads.contains_key(&content_id)).then(|| {')], HOLDER),
    ('stream: an answer is registered as unasked',
     [(SWARM, '                            asked: true,\n', '                            asked: false,\n')], HOLDER),
    ('reconstruction: a failed rebuild never drops',
     [(HANDLER, '&& super::vault_ops::drop_unpinned_shards(&content_store, &manifest, &packed) > 0',
       '&& false && super::vault_ops::drop_unpinned_shards(&content_store, &manifest, &packed) > 0')], REBUILD),
    ('reconstruction: deleted copies are never asked for again',
     [(HANDLER, '        if dropped > 0 {\n            // Nothing asks', '        if dropped > 0 && false {\n            // Nothing asks')],
     REBUILD),
    ('migrate: the manifest is not consulted',
     [(SWARM, '                    .or_else(|| vault_ops::shard_bytes_refused(&cs, &cid, si, &shard_bytes))\n', '')], WIRED),
    ('response: an inline answer is not checked',
     [(SWARM, '} else if let Some(reason) = vault_ops::shard_bytes_refused(&cs, &cid, si, &shard_bytes) {',
       '} else if let Some(reason) = None::<&\'static str> {')], WIRED),
    ('store: an inline store is not checked',
     [(SWARM, 'None => match vault_ops::shard_bytes_refused(&content_store, &cid, si, &shard_bytes) {',
       'None => match None::<&\'static str> {')], WIRED),
    ('stream: the completion drops its fresh pull',
     [(HANDLER, '                pending_vault_downloads, event_tx, db_path, db_passphrase,\n            ).await\n        }',
       '                pending_vault_downloads, event_tx, db_path, db_passphrase,\n            ).await;\n            None\n        }')],
     HOLDER),
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
