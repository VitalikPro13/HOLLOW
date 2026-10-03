"""Session 27 mutation pass: break each new rule, expect a named test to FAIL, restore.

Run from rust/hollow_core. Prints one line per mutation: KILLED, SURVIVED or BROKEN
(the mutant does not compile). Every file is restored byte for byte whatever happens.
Pass words to run only the mutations whose name contains one of them.
"""
import os
import subprocess
import sys

RESOLVER = 'src/node/resolver.rs'
BOOK = 'src/node/roster_book.rs'
SWARM = 'src/node/swarm.rs'
FETCH = 'src/node/fetch.rs'
CRYPTO = 'src/node/crypto_handler.rs'
MLS = 'src/node/mls_authority.rs'
STORE = 'src/storage/messages.rs'
FOLD = 'src/crdt/fold.rs'
VOICE = 'src/node/voice_handler.rs'
NETWORK = 'src/api/network.rs'
ENRICH = 'src/push_enrich.rs'

G1_UNIT = ['resolver::tests', 'roster_book::tests', 'mls_authority::tests']
G1_HARNESS = ['test_harness::authz_the_master_key_alone_never_speaks_as_the_bare_master_id']

MUTATIONS = [
    # -- G1: the bare master id --
    ('G1 seed_self maps the master to itself again',
     [(RESOLVER, '''            map.insert(d.clone(), master_peer_id.to_string());
        }
    }
    changed();
}

/// Warm''', '''            map.insert(d.clone(), master_peer_id.to_string());
        }
        map.insert(master_peer_id.to_string(), master_peer_id.to_string());
    }
    changed();
}

/// Warm''')], G1_UNIT),
    ('G1 a held roster is not noted',
     [(BOOK, '''    super::resolver::note_roster(&roster.master);
    if roster.master == local_master {''', '''    if roster.master == local_master {''')], G1_UNIT),
    ('G1 a master id that left the roster stays linked',
     [(BOOK, '.into_iter().chain([roster.master.clone()]);', '.into_iter().chain([]);')], G1_UNIT),
    ('G1 a restart forgets which rosters are held',
     [(RESOLVER, '''        for master in &masters {
            note_roster(master);
        }''', '''        for _master in &masters {}''')], G1_UNIT),
    ('G1 the rostered query reads 0.11 rows',
     [(STORE, "json_extract(json, '$.master') IS NOT NULL", "json_extract(json, '$.master') IS NULL")], G1_UNIT),
    ('G1 is_bare_master ignores the roster',
     [(RESOLVER, 'rostered().read().is_ok_and(|set| set.contains(peer_id)) && !is_device_of(peer_id, peer_id)',
       'rostered().read().is_ok_and(|set| set.contains(peer_id)) && false')], G1_UNIT + G1_HARNESS),
    ('G1 disowns never judges the master id',
     [(RESOLVER, '''    if device == master {
        return is_bare_master(master);
    }''', '''    if device == master {
        return false;
    }''')], G1_UNIT),
    ('G1 disowns ignores a held roster',
     [(RESOLVER, 'let known = held || map.iter()', 'let known = map.iter()')], G1_UNIT),
    ('G1 carried_master resolves instead of linking',
     [(BOOK, 'let bound = super::resolver::is_device_of(sender, &roster.master);',
       'let bound = super::resolver::resolve(sender) == roster.master;')], G1_UNIT),
    ('G1 key exchange takes a bare master id',
     [(CRYPTO, 'if super::resolver::is_revoked(sender_device) || super::resolver::is_bare_master(sender_device) {',
       'if super::resolver::is_revoked(sender_device) {')], G1_UNIT),
    ('G1 heard_from reads every frame',
     [(BOOK, "!super::resolver::is_bare_master(from) || matches!(msg, super::types::HavenMessage::RosterNotice { .. })",
       "true || matches!(msg, super::types::HavenMessage::RosterNotice { .. })")], G1_UNIT),
    ('G1 heard_from drops roster notices too',
     [(BOOK, "!super::resolver::is_bare_master(from) || matches!(msg, super::types::HavenMessage::RosterNotice { .. })",
       "!super::resolver::is_bare_master(from) && matches!(msg, super::types::HavenMessage::RosterNotice { .. })")],
     G1_UNIT),
    ('G1 swarm frames skip heard_from',
     [(SWARM, 'if !super::roster_book::heard_from(&from, &msg) {', 'if false {')], G1_UNIT),
    ('G1 stream chunks skip the bare check',
     [(SWARM, 'Ok(_) if super::resolver::is_bare_master(&from) => {', 'Ok(_) if false => {')], G1_UNIT),
    ('G1 PeerJoined skips presence',
     [(SWARM, 'if !bare_presence.admits(&peer_id) {', 'if false {')], G1_UNIT),
    ('G1 RoomMembers skips presence',
     [(SWARM, 'peers.into_iter().filter(|p| bare_presence.admits(p)).collect();', 'peers;')], G1_UNIT),
    ('G1 the loop never settles presence',
     [(SWARM, '''        if bare_presence.stale() {
            Box::pin(settle_bare_presence(&mut bare_presence, &mut ws_room_peers, &mut synced_peers, &event_tx, &ws_cmd_tx)).await;
        }''', '')], G1_UNIT),
    ('G1 fetch reads frames from a bare master id',
     [(FETCH, 'if crate::node::resolver::is_bare_master(&from) {\n            hollow_log!("[HOLLOW-FETCH]',
       'if false {\n            hollow_log!("[HOLLOW-FETCH]')], G1_UNIT),
    ('G1 presence admits a bare master id',
     [(BOOK, '''        if super::resolver::is_bare_master(peer) {
            self.held.insert(peer.to_string());
            return false;
        }''', '')], G1_UNIT),
    ('G1 settle keeps a master id that turned bare',
     [(BOOK, '''                let bare = super::resolver::is_bare_master(p);''', '''                let bare = false && super::resolver::is_bare_master(p);''')], G1_UNIT),
    ('G1 settle never asks for an admitted master id again',
     [(BOOK, '(out.into_iter().collect(), self.held.len() < before)', '(out.into_iter().collect(), false)')], G1_UNIT),
    ('G1 push fetch seeds the master as a device (network.rs)',
     [(NETWORK, 'node::resolver::seed_self(&local_master, std::slice::from_ref(&peer_id));',
       'node::resolver::seed_self(&local_master, &[peer_id.clone(), local_master.clone()]);')], G1_UNIT),
    ('G1 push fetch seeds the master as a device (push_enrich.rs)',
     [(ENRICH, 'crate::node::resolver::seed_self(&local_master, std::slice::from_ref(&peer_id));',
       'crate::node::resolver::seed_self(&local_master, &[peer_id.clone(), local_master.clone()]);')], G1_UNIT),
    ('G1 end to end: presence, frames and key exchange all open',
     [(SWARM, 'if !super::roster_book::heard_from(&from, &msg) {', 'if false {'),
      (SWARM, 'if !bare_presence.admits(&peer_id) {', 'if false {'),
      (SWARM, 'peers.into_iter().filter(|p| bare_presence.admits(p)).collect();', 'peers;'),
      (CRYPTO, 'if super::resolver::is_revoked(sender_device) || super::resolver::is_bare_master(sender_device) {',
       'if super::resolver::is_revoked(sender_device) {')], G1_HARNESS),
    # -- A-10: the committer --
    ('A-10 a refused committer commits',
     [(MLS, '''    if refused(committer) {
        return Verdict::Refuse(format!("committed by revoked or disowned device {}", committer.device));
    }''', '')], ['mls_authority::tests']),
    ('A-10 a legacy leaf rebinds as a refused device',
     [(MLS, '''            if refused(after) {
                return Verdict::Refuse(format!("rebinds as revoked or disowned device {}", after.device));
            }''', '')], ['mls_authority::tests']),
    # -- A-T12: DM push wakes --
    ('A-T12 a DM wake joins a room for anyone',
     [(FETCH, '(ours || friend).then(|| crate::node::types::dm_room_code(local_master, &master))',
       'Some(crate::node::types::dm_room_code(local_master, &master))')], ['fetch::tests']),
    ('A-T12 a DM wake takes a blocked friend',
     [(FETCH, '''    if crate::node::blocklist::is_blocked(sender) {
        return None;
    }
    let ours''', '''    let ours''')], ['fetch::tests']),
    ('A-T12 the fetch node skips the gate',
     [(FETCH, '''            let Some(room) = dm_wake_room(&store, local_master, sender_peer_id) else {''',
       '''            let Some(room) = Some(crate::node::types::dm_room_code(local_master, &crate::node::resolver::resolve(sender_peer_id))) else {''')],
     ['fetch::tests']),
    ('A-T12 the live nudge skips the gate',
     [(NETWORK, 'let Some(room) = node::fetch::dm_wake_room(&open_local_store()?, &local_master, &sender_peer_id) else {',
       'let Some(room) = Some(crate::node::types::dm_room_code(&local_master, &sender_peer_id)) else {')],
     ['fetch::tests']),
    # -- D7: the HLC witness and the stale-decrypt sync target --
    ('D7 every fresh op moves our clock',
     [(FOLD, '''            fresh.push(op.clone());''', '''            if let Some(hlc) = &mut self.hlc {
                hlc.witness(&op.hlc);
            }
            fresh.push(op.clone());''')], ['crdt::fold::tests']),
    ('D7 an admitted op does not move our clock',
     [(FOLD, '''            for op in &out.admitted {
                hlc.witness(&op.hlc);
            }''', '''            for _op in &out.admitted {}''')], ['crdt::fold::tests']),
    ('D7 a stale frame asks anyone for a channel sync',
     [(SWARM, 'for cid in sync_cids.iter().filter(|c| crate::node::crypto_handler::sync_partner(state, peer_str, Some(c))) {',
       'for cid in sync_cids.iter().filter(|_c| state.is_some()) {')],
     ['test_harness::authz_a_frame_that_fails_to_decrypt_asks_only_a_member_to_sync']),
    ('D7 a stale frame asks anyone for an op sync',
     [(SWARM, '''                        if msg_channel_id.is_none()
                            && crate::node::crypto_handler::sync_partner(server_states.get(&server_id), peer_str, None)
                        {''', '''                        if msg_channel_id.is_none() {''')],
     ['test_harness::authz_a_frame_that_fails_to_decrypt_asks_only_a_member_to_sync']),
    ('D7 sync_partner takes a non-member',
     [(CRYPTO, '&& state.is_some_and(|s| s.is_member(&master) && channel.is_none_or(|c| s.can_see_channel(&master, c)))',
       '&& state.is_some_and(|s| channel.is_none_or(|c| s.can_see_channel(&master, c)))')],
     ['test_harness::authz_a_frame_that_fails_to_decrypt_asks_only_a_member_to_sync']),
    # -- D4: restricted voice presence --
    ('D4 the Olm twin goes to every member',
     [(VOICE, 'let viewers = state.members.keys().filter(|m| state.can_see_channel(m, channel_id));',
       'let viewers = state.members.keys();')], ['restricted_voice_presence_reaches_only_its_viewers']),
    ('D4 the MLS copy rides the server group',
     [(VOICE, '''        .is_some_and(|s| s.channel_uses_subgroup(channel_id))
        .then_some(channel_id);''', '''        .is_some_and(|s| s.channel_uses_subgroup(channel_id) && false)
        .then_some(channel_id);''')], ['restricted_voice_presence_reaches_only_its_viewers']),
    # -- A-DM-19: a blocked friend's sync --
    ('A-DM-19 a blocked friend pulls our conversation',
     [(SWARM, '''            if super::blocklist::is_blocked(peer_str) {
                hollow_log!("[HOLLOW-SECURITY] Dropped a DmSyncRequest from blocked {peer_str}");
                return;
            }''', '')], ['test_harness::authz_a_blocked_friend_pulls_no_dm_history']),
]

ENV = dict(os.environ)
ENV['PATH'] = r'C:\Program Files\OpenSSL-Win64\bin;' + ENV['PATH']


def read(path):
    return open(path, encoding='utf-8', newline='').read()


def write(path, text):
    open(path, 'w', encoding='utf-8', newline='').write(text)


def run(filters):
    cmd = ['cargo', 'nextest', 'run', '--lib', '--no-fail-fast',
           '--failure-output', 'never', '--success-output', 'never'] + filters
    p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace', env=ENV)
    out = p.stdout + p.stderr
    if 'error[E' in out or 'could not compile' in out:
        return 'BROKEN', out[-3000:]
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
            cur = read(path)
            originals.setdefault(path, cur)
            crlf = '\r\n' in cur
            if crlf:
                old, new = old.replace('\n', '\r\n'), new.replace('\n', '\r\n')
            if cur.count(old) != 1:
                raise SystemExit(f'{name}: pattern found {cur.count(old)}x in {path}: {old[:70]!r}')
            cur = cur.replace(old, new)
            write(path, cur)
        verdict, detail = run(filters)
    finally:
        for path, src in originals.items():
            write(path, src)
    print(f'{verdict:9} {name}', flush=True)
    if detail and verdict != 'SURVIVED':
        print('    ' + detail.replace('\n', '\n    ')[:1200], flush=True)

