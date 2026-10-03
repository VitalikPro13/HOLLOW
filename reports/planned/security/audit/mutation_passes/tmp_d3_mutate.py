"""Session 29 mutation pass (D3, MemberAdded carries the joiner's own ask; D2, a member's
snapshot decides nothing): break each new rule, expect a named test to FAIL, restore.

Run from rust/hollow_core. Prints one line per mutation: KILLED, SURVIVED or BROKEN
(the mutant does not compile). Every file is restored byte for byte whatever happens.
Pass words to run only the mutations whose name contains one of them.
"""
import os
import subprocess
import sys

OPS = 'src/crdt/operations.rs'
STATE = 'src/crdt/server_state.rs'
SWARM = 'src/node/swarm.rs'
LANE = 'src/node/join_lane.rs'
JOIN = 'src/node/sync_handler.rs'
FOLD = 'src/crdt/fold.rs'
SYNC = 'src/node/sync_handler.rs'
GUEST = 'src/node/guest_view.rs'
CARD = 'src/node/profile_card.rs'
SOCIAL = 'src/node/social.rs'

ASK = ['crdt::operations::tests::authz_a_join_ask_stands_only_for_its_own_signer']
RULE = ['crdt::server_state::tests::authz_member_added_names_only_someone_who_asked']
HOSTILE = ['test_harness::authz_a_member_lists_only_someone_who_asked_to_join']
HONEST = ['test_harness::authz_a_member_cannot_admit_past_the_join_gates']
RESTORED = ['test_harness::a_join_restored_after_a_restart_still_carries_its_ask']
SNAP = ['crdt::fold::tests::authz_a_join_snapshot_carries_no_authority']
OLDER = ['test_harness::authz_a_members_snapshot_of_an_older_server_decides_nothing']
NEVER_PUBLIC = ['crdt::server_state::tests::authz_a_restricted_channel_is_never_public']
HIDDEN = ['test_harness::authz_a_hidden_channel_never_shows_to_a_guest']
IN_MEMORY = ['test_harness::authz_a_guest_keeps_public_posts_in_memory_only']
SHOWS = ['profile_card::tests::authz_a_guest_shows_only_what_the_senders_card_signs']
HANDS = ['profile_card::tests::a_member_hands_a_guest_only_signed_cards']
BY_CARD = ['test_harness::authz_a_guest_shows_an_author_only_by_its_own_card']

MUTATIONS = [
    ('D3 rule: no ask needed',
     [(STATE, '''        let Some(ask) = ask.filter(|a| a.verifies(&self.server_id, target)) else {
            return false;
        };''', '''        let none = super::operations::JoinAsk { at: i64::MAX, sig: String::new(), pk: String::new() };
        let ask = ask.unwrap_or(&none);''')], RULE + HOSTILE),
    ('D3 rule: any ask counts',
     [(STATE, 'let Some(ask) = ask.filter(|a| a.verifies(&self.server_id, target)) else {',
       'let Some(ask) = ask else {')], RULE + HOSTILE),
    ('D3 rule: an ask admits again',
     [(STATE, 'spans.iter().any(|s| ask.at <= s.asked_at)', 'spans.iter().any(|s| ask.at < s.asked_at)')], RULE + HOSTILE),
    ('D3 rule: the record forgets which ask admitted',
     [(STATE, 'self.open_span(peer_id, op.hlc.physical_ms, ask.as_ref().map_or(0, |a| a.at));',
       'self.open_span(peer_id, op.hlc.physical_ms, 0);')], RULE + HOSTILE),
    ('D3 ask: the server is not signed',
     [(OPS, '[b"hollow-join-ask1\\0".as_slice(), server_id.as_bytes(), b"\\0",',
       '[b"hollow-join-ask1\\0".as_slice(), b"", b"\\0",')], ASK + RULE),
    ('D3 ask: the key need not be the target\'s',
     [(OPS, 'NativeKeypair::peer_id_from_pubkey_protobuf(&pk).is_some_and(|id| id == joiner)',
       'NativeKeypair::peer_id_from_pubkey_protobuf(&pk).is_some()')], ASK),
    ('D3 ask: the signature is not checked',
     [(OPS, '''            && matches!(
                NativeKeypair::verify_peer_signature(&pk, &sig, &Self::signing_payload(server_id, joiner, self.at)),
                Ok(true)
            )''', '''            && !sig.is_empty()''')], ASK + RULE),
    ('D3 admitter: the ask is not copied',
     [(SWARM, '''                        follow,
                        ask,
                    }) else {''', '''                        follow,
                        ask: { let _ = ask; None },
                    }) else {''')], HONEST),
    ('D3 joiner: the request carries no ask',
     [(LANE, '        ask: pending.ask.clone(),\n', '        ask: None,\n')], HONEST),
    ('D3 joiner: a join signs no ask',
     [(JOIN, '        ask: Some(crate::crdt::operations::JoinAsk::sign(&server_id, requested_at, master_keypair)),\n', '')], HONEST),
    ('D3 joiner: a restored join signs no ask',
     [(SWARM, '                        ask: Some(crate::crdt::operations::JoinAsk::sign(&row.server_id, row.requested_at, &master_keypair)),\n',
       '')], RESTORED),
    ('D2 snapshot: a member keeps its role',
     [(FOLD, '        snap.roles.retain(|id, _| *id == owner);\n', '')], SNAP + OLDER),
    ('D2 snapshot: role permissions stay',
     [(FOLD, '        snap.role_permissions.clear();\n', '')], SNAP + OLDER),
    ('D2 snapshot: bans stay',
     [(FOLD, '        snap.banned_members.clear();\n', '')], SNAP + OLDER),
    ('D2 snapshot: mutes stay',
     [(FOLD, '        snap.muted_members.clear();\n', '')], SNAP + OLDER),
    ('D2 snapshot: label assignments stay',
     [(FOLD, '        snap.label_assignments.clear();\n', '')], SNAP),
    ('D2 snapshot: grants stay',
     [(FOLD, '        snap.channel_grants.clear();\n', '')], SNAP),
    ('D2 snapshot: public channels stay public',
     [(FOLD, '            channel.is_public = false;\n', '')], SNAP + OLDER),
    # -- D6 --
    ('D6 public: a restricted channel reads public',
     [(STATE, 'self.is_public && self.channel_type == ChannelType::Text && !self.restricted()',
       'self.is_public && self.channel_type == ChannelType::Text')], NEVER_PUBLIC + HIDDEN),
    ('D6 public: a tier keeps the flag',
     [(STATE, '''                        _ => ChannelVisibility::Everyone,
                    };
                    ch.is_public &= !ch.restricted();''', '''                        _ => ChannelVisibility::Everyone,
                    };''')], NEVER_PUBLIC + HIDDEN),
    ('D6 public: a label gate keeps the flag',
     [(STATE, '''                    ch.visibility_labels = labels.clone();
                    ch.is_public &= !ch.restricted();''', '''                    ch.visibility_labels = labels.clone();''')], NEVER_PUBLIC),
    ('D6 public: a restricted channel can be flagged',
     [(STATE, 'ch.channel_type == ChannelType::Text && !(*is_public && ch.restricted())',
       'ch.channel_type == ChannelType::Text')], NEVER_PUBLIC),
    ('D6 public: guests are not told',
     [(SYNC, '''    tell_guests_if_closed(server_states, event_tx, ws_cmd_tx, &server_id, &channel_id, was_public).await;

    // Per-channel MLS subgroup''', '''    let _ = was_public;

    // Per-channel MLS subgroup''')], HIDDEN),
    ('D6 guest: posts land in our database',
     [(GUEST, 'if member { db_path } else { &self.store_path }', 'let _ = member; db_path')], IN_MEMORY),
    ('D6 guest: the store outlives the last room',
     [(GUEST, '            *keeper = None;\n', '')], IN_MEMORY),
    ('D6 card: any card names the sender',
     [(CARD, '    if card.master != sender || !card_holds(&card) {', '    if card.master != sender {')], SHOWS + BY_CARD),
    ('D6 card: another identity\'s card names the sender',
     [(CARD, '    if card.master != sender || !card_holds(&card) {', '    if !card_holds(&card) {')], SHOWS),
    ('D6 card: any picture shows',
     [(CARD, '''        .filter(|b| b.len() <= GUEST_AVATAR_MAX_BYTES && !card.avatar_hash.is_empty())
        .filter(|b| super::social::profile_blob_hash(Some(b)) == card.avatar_hash);''',
       '''        .filter(|b| b.len() <= GUEST_AVATAR_MAX_BYTES);''')], SHOWS),
    ('D6 card: a card is kept for anyone',
     [(CARD, '    card.master == master\n        && card_holds(card)', '    card_holds(card)')], HANDS),
    ('D6 card: a profile update carries no card',
     [(SOCIAL, '        card: card.clone().map(Box::new),\n    };\n    let mut mls_reached', '        card: None,\n    };\n    let mut mls_reached'),
      (SOCIAL, '        card: card.clone().map(Box::new),\n    };\n    // The whole update', '        card: None,\n    };\n    // The whole update')], BY_CARD),
    ('D6 card: a received card is not kept',
     [(SWARM, '                super::profile_card::keep_card(card, &super::resolver::resolve(peer_str), db_path, db_passphrase);\n', ''),
      (SWARM, '                                    super::profile_card::keep_card(&card, &super::resolver::resolve(&card_sender), db_path, db_passphrase);\n', '')], BY_CARD),
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
