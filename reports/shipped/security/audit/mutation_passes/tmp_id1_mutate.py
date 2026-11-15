"""ID-1 mutation pass: put each old rule back, expect a named test to FAIL, restore.

Run from rust/hollow_core. Prints one line per mutation: KILLED, SURVIVED or BROKEN
(the mutant does not compile). Every file is restored whatever happens.
"""
import os
import subprocess
import sys

ROSTER = 'src/identity/roster.rs'
BOOK = 'src/node/roster_book.rs'
CRYPTO = 'src/node/crypto_handler.rs'
MLSA = 'src/node/mls_authority.rs'
STORAGE = 'src/api/storage.rs'
SWARM = 'src/node/swarm.rs'
FETCH = 'src/node/fetch.rs'

UNIT = ['identity::roster', 'roster_book::tests']

MUTATIONS = [
    ('consent required',
     [(ROSTER, 'roots.retain(|d| consented.contains(d.as_str()));', ''),
      (ROSTER, '.filter(|v| v.base == base && consented.contains(v.device.as_str()))', '.filter(|v| v.base == base)'),
      (ROSTER, '.filter(|p| p.base == base && consented.contains(p.device.as_str()))', '.filter(|p| p.base == base)')],
     UNIT + ['verify_carried_bundle_accepts']),
    ('keep_vouched',
     [(ROSTER, '''                    || kept_by
                        .get(v.by.as_str())
                        .is_some_and(|k| k.contains(v.device.as_str()));''', '                    || false;')],
     UNIT),
    ("removed signer's vouches void",
     [(ROSTER, 'let voucher_ok = !removed.contains_key(&v.by)', 'let voucher_ok = true')],
     UNIT),
    ('removal needs a rooted signer',
     [(ROSTER, 'for r in self.removals.iter().filter(|r| r.base == base && rooted.contains(&r.by)) {',
       'for r in self.removals.iter().filter(|r| r.base == base) {')],
     UNIT),
    ('base binding',
     [(ROSTER, '''                self.vouches.retain(|v| &v.base == base);
                self.pendings.retain(|p| &p.base == base);
                self.removals.retain(|r| &r.base == base);''', ''),
      (ROSTER, '.filter(|v| v.base == base && consented.contains(v.device.as_str()))', '.filter(|v| consented.contains(v.device.as_str()))'),
      (ROSTER, 'for r in self.removals.iter().filter(|r| r.base == base && rooted.contains(&r.by)) {',
       'for r in self.removals.iter().filter(|r| rooted.contains(&r.by)) {')],
     UNIT + ['test_harness::authz_the_phrase_takes']),
    ('recovery key pin',
     [(ROSTER, 'let same_key = out.r_pub.is_empty() || out.r_pub == incoming.r_pub;', 'let same_key = !incoming.r_pub.is_empty();')],
     UNIT + ['verify_carried_bundle_accepts']),
    ('phrase admission dated after the base',
     [(ROSTER, 'roots.extend(self.phrase_admits.iter().filter(|p| p.at_ms > at).map(|p| p.device.clone()));',
       'roots.extend(self.phrase_admits.iter().map(|p| p.device.clone()));'),
      (ROSTER, 'self.phrase_admits.retain(|p| p.at_ms > *at);', '')],
     UNIT),
    ('pending maturity clock',
     [(ROSTER, '.is_some_and(|seen| seen.saturating_add(PENDING_MATURITY_MS) <= now_ms)', '.is_some_and(|seen| seen <= now_ms)')],
     UNIT + ['test_harness::authz_a_stolen_backup']),
    ('legacy claims die with the first recovery',
     [(ROSTER, '''                Some((base, at, keep)) => {
                    let mut roots = keep;''', '''                Some((base, at, keep)) => {
                    let mut roots = keep;
                    roots.extend(self.legacy.iter().map(|l| l.device.clone()));'''),
      (ROSTER, '''                self.legacy.clear();
''', '')],
     UNIT),
    ('disowns in MLS',
     [(MLSA, '|| super::resolver::disowns(&leaf.master, &leaf.device)', '|| false')],
     ['mls_authority']),
    ('disowns in live MLS + fetch',
     [(SWARM, 'if super::resolver::disowns(&sender.master, &sender.device) {', 'if false {'),
      (FETCH, 'if crate::node::resolver::disowns(&sender.master, &sender.device) {', 'if false {')],
     ['channel_ingest_gates_stay_wired']),
    ('carried_member merges the stored roster',
     [(BOOK, 'Some(stored) => stored.merged(&carried),', 'Some(_) => carried,')],
     ['verify_carried_bundle_accepts']),
    ('unknown master kept only from a member',
     [(BOOK, '        if !alone.is_member(sender) {', '        if false && !alone.is_member(sender) {')],
     UNIT + ['test_harness::friend_reject_with_bad_carried_list', 'test_harness::replayed_device_list_from_an_unlisted',
             'test_harness::friend_request_from_an_unlisted']),
    ('inbox proof names members only',
     [(BOOK, '        state.members.iter().cloned().collect(),\n        state.removed.keys().cloned().collect(),',
       '        state.members.iter().chain(state.pending.iter()).cloned().collect(),\n        state.removed.keys().cloned().collect(),')],
     ['the_inbox_proof_names']),
    ('destroy: the master key alone',
     [(CRYPTO, '''    if pinned_r.is_empty() {
        return true;
    }
    let Some(rk) = r_key(pinned_r) else { return false };''', '''    if true {
        return true;
    }
    let Some(rk) = r_key(pinned_r) else { return false };''')],
     ['authz_a_destroy_order_needs_the_phrase']),
    ('destroy: a permission for a non-member',
     [(CRYPTO, '        && members.is_member(&d.device)\n', '')],
     ['authz_a_destroy_order_needs_the_phrase']),
    ('destroy: a permission carried by another device',
     [(CRYPTO, '        && verify_raw(&dk, &payload, &d.device_sig)\n', '        && !d.device_sig.is_empty()\n')],
     ['authz_a_destroy_order_needs_the_phrase']),
    ('export scrub',
     [(STORAGE, '        store.scrub_device_secrets()?;\n        drop(store);', '        drop(store);')],
     ['snapshots_leave_device_secrets']),
    ('import scrub',
     [(STORAGE, '            && let Err(e) = store.scrub_device_secrets()\n', '            && let Err(e) = Ok::<(), String>(())\n')],
     ['snapshots_leave_device_secrets']),
    ('matured pending counts as added',
     [(BOOK, '''        .map(|r| RosterState {
            members: store.device_links_for(&master).unwrap_or_default(),
            ..fold(&store, r)
        })''', '''        .map(|r| fold(&store, r))''')],
     ['test_harness::a_restored_device_matures']),
    ('a phrase change reaches contacts without a session',
     [(SWARM, '''                        super::roster_book::announce_phrase_change(
                            &ws_cmd_tx, &local_peer_str, server_states.keys(), &db_path, &db_passphrase,
                        );
''', '')],
     ['test_harness::authz_the_phrase_takes']),
    ('pending ask reaches a single-device friend',
     [(BOOK, '''    for room in dm_rooms {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom { room_code: room.clone() });
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom { room_code: room, data: data.clone() });
    }''', '''    for room in dm_rooms {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom { room_code: room.clone() });
    }''')],
     ['test_harness::authz_the_phrase_takes']),
]

LINK = 'src/node/link_handler.rs'
PAKE = 'src/node/link_pake.rs'
MUTATIONS += [
    ('link: the code answers once',
     [(LINK, 'if p.peer.is_some() || !ws_room_peers', 'if !ws_room_peers')],
     ['test_harness::authz_a_relay_that_answers']),
    ('link: only from the code room',
     [(LINK, 'if p.peer.is_some() || !ws_room_peers.get(&room).is_some_and(|r| r.contains(sender)) {', 'if p.peer.is_some() {')],
     ['test_harness::authz_a_relay_that_answers']),
    ('link: the joiner checks the confirmation',
     [(PAKE, """    keys.mac(joiner_msg, presenter_msg)
        .verify_slice(confirm)
        .map_err(|_| "The code didn't match.".to_string())?;""", "    let _ = confirm;")],
     ['link_pake', 'test_harness::authz_a_relay_that_answers']),
    ('link: a hello that does not open burns the code',
     [(LINK, """            hollow_log!("[HOLLOW-SECURITY] A link hello from {sender} did not open: the code was wrong or guessed");
            release(link, ws_cmd_tx);""", """            hollow_log!("[HOLLOW-SECURITY] A link hello from {sender} did not open: the code was wrong or guessed");""")],
     ['test_harness::authz_a_relay_that_answers']),
    ('link: direction-bound keys',
     [(PAKE, """            Direction::ToJoiner => &self.to_joiner,
        };""", """            Direction::ToJoiner => &self.to_presenter,
        };""")],
     ['link_pake']),
    ('link: rendezvous in the AAD',
     [(PAKE, 'format!("hollow-link1:{}:{}", self.rendezvous, dir.label())', 'format!("hollow-link1:{}", dir.label())')],
     ['link_pake']),
    ('link: rendezvous bound into the handshake',
     [(PAKE, """        Identity::new(format!("hollow-link1:{rendezvous}:joiner").as_bytes()),
        Identity::new(format!("hollow-link1:{rendezvous}:presenter").as_bytes()),""", """        Identity::new(b"hollow-link1:joiner"),
        Identity::new(b"hollow-link1:presenter"),""")],
     ['link_pake']),
    ('link: the offer key travels only sealed',
     [(LINK, "let blob = match crate::api::storage::export_backup_bytes(&key_hex, include_vault, include_files) {", "let blob = match crate::api::storage::export_backup_bytes(&link_room(&room[5..]), include_vault, include_files) {")],
     ['test_harness::link_the_relay_cannot']),
    ('link: the stash installs the vouched device',
     [(STORAGE, """        std::fs::write(data_dir.join("identity.device"), &device[..])""", """        std::fs::remove_file(data_dir.join("identity.device")).or(Ok::<(), std::io::Error>(()))""")],
     ['a_pending_link_installs']),
]

ENV = dict(os.environ)
ENV['PATH'] = r'C:\Program Files\OpenSSL-Win64\bin;' + ENV['PATH']


def run(filters):
    cmd = ['cargo', 'nextest', 'run', '--lib', '--no-fail-fast',
           '--failure-output', 'never', '--success-output', 'never'] + filters
    p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace', env=ENV)
    out = p.stdout + p.stderr
    if 'error[E' in out or 'could not compile' in out:
        return 'BROKEN', out
    failed = [l.strip() for l in out.splitlines() if 'FAIL [' in l or 'ABORT [' in l]
    if p.returncode != 0 and failed:
        return 'KILLED', '\n'.join(sorted(set(failed)))
    if p.returncode != 0:
        return 'BROKEN', out[-3000:]
    return 'SURVIVED', ''


only = sys.argv[1:]
for name, edits, filters in MUTATIONS:
    if only and not any(o in name for o in only):
        continue
    originals = {}
    try:
        for path, old, new in edits:
            src = originals.get(path) or open(path, encoding='utf-8', newline='').read()
            originals.setdefault(path, src)
            cur = open(path, encoding='utf-8', newline='').read()
            if cur.count(old) != 1:
                raise SystemExit(f'{name}: pattern found {cur.count(old)}x in {path}: {old[:70]!r}')
            open(path, 'w', encoding='utf-8', newline='').write(cur.replace(old, new))
        verdict, detail = run(filters)
    finally:
        for path, src in originals.items():
            open(path, 'w', encoding='utf-8', newline='').write(src)
    print(f'{verdict:9} {name}', flush=True)
    if detail and verdict != 'SURVIVED':
        print('    ' + detail.replace('\n', '\n    ')[:1500], flush=True)
