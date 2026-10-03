"""Session 31 mutation pass (follow-up 3e, Olm frames encrypted in wire order): break each
new rule, expect a named test to FAIL, restore byte for byte.

Prints one line per mutation: KILLED, SURVIVED or BROKEN. Pass words to run only the
mutations whose name has one.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RUST = os.path.join(ROOT, 'rust', 'hollow_core')
NODE = os.path.join(RUST, 'src', 'node')

LANE = os.path.join(NODE, 'olm_lane.rs')
SWARM = os.path.join(NODE, 'swarm.rs')
CRYPTO = os.path.join(NODE, 'crypto_handler.rs')
OPS = os.path.join(NODE, 'message_ops.rs')
FWD = os.path.join(NODE, 'forwarder_client.rs')

HARNESS = ['test_harness::olm_a_direct_burst_behind_a_waiting_carry_keeps_the_session']
UNIT = ['olm_lane::tests::a_direct_burst_encrypts_the_carries_queued_before_it_first']
SCAN = ['olm_lane::tests::node_code_encrypts_olm_only_in_turn']
ALL = HARNESS + UNIT + SCAN

MUTATIONS = [
    ('a direct send encrypts ahead of waiting carries',
     [(LANE, '''    let _ = WAITING.try_with(|waiting| {
        for carry in waiting.borrow_mut().carries.iter_mut().filter(|c| c.device == device && c.sealed.is_none()) {''',
       '''    let _ = WAITING.try_with(|waiting| {
        for carry in waiting.borrow_mut().carries.iter_mut().filter(|_| false) {''')], ALL),
    ('delivery ignores the early ciphertext',
     [(LANE, 'match sealed.map_or_else(|| self.olm.encrypt(device, json.as_bytes()), Ok) {',
       'match { let _ = sealed; self.olm.encrypt(device, json.as_bytes()) } {')], ALL),
    ('a carry takes no ticket',
     [(LANE, 'let ticket = WAITING.try_with(|waiting| waiting.borrow_mut().enter(device, &json)).ok();',
       'let ticket: Option<u64> = None;')], ALL),
    ('early encryption ignores the device',
     [(LANE, '.filter(|c| c.device == device && c.sealed.is_none())',
       '.filter(|c| c.sealed.is_none())')], ALL),
    ('the node loop has no book',
     [(SWARM, 'let handle = tokio::spawn(super::olm_lane::with_carry_book(super::door_room::with_heard_routes(Box::pin(run_event_loop(\n        event_tx, cmd_rx, cmd_tx, olm, crypto_store, crdt_store,\n        bundle_keypair, device_keypair, ws_cmd_tx, ws_event_rx, master_peer_id.clone(), device_peer_id,\n        initial_invisible, db_path, db_passphrase,\n    )))));\n\n    Ok((master_peer_id, handle, ws_cmd_rx, ws_event_tx))',
       'let handle = tokio::spawn(super::door_room::with_heard_routes(Box::pin(run_event_loop(\n        event_tx, cmd_rx, cmd_tx, olm, crypto_store, crdt_store,\n        bundle_keypair, device_keypair, ws_cmd_tx, ws_event_rx, master_peer_id.clone(), device_peer_id,\n        initial_invisible, db_path, db_passphrase,\n    ))));\n\n    Ok((master_peer_id, handle, ws_cmd_rx, ws_event_tx))')], ALL),
    ('a DM encrypts out of turn',
     [(OPS, 'let (msg_type, ciphertext) = super::olm_lane::encrypt_in_turn(olm, device_peer, envelope_json.as_bytes())',
       'let (msg_type, ciphertext) = olm.encrypt(device_peer, envelope_json.as_bytes())')], ALL),
    ('a direct send encrypts out of turn',
     [(CRYPTO, '''pub(crate) async fn send_encrypted_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    peer_id_str: &str,
    text: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> bool {
    match super::olm_lane::encrypt_in_turn(olm, peer_id_str, text.as_bytes()) {''',
       '''pub(crate) async fn send_encrypted_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    peer_id_str: &str,
    text: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> bool {
    match olm.encrypt(peer_id_str, text.as_bytes()) {''')], SCAN),
    ('a signal in a room encrypts out of turn',
     [(CRYPTO, '''    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
) -> bool {
    match super::olm_lane::encrypt_in_turn(olm, peer_id_str, text.as_bytes()) {
        Ok((msg_type, ciphertext)) => {
            persist_olm_session(olm, crypto_store, peer_id_str);
            let haven_msg = encrypted_frame(olm, msg_type, &ciphertext);
            let json = serde_json::to_string(&haven_msg).unwrap_or_default();
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {''',
       '''    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
) -> bool {
    match olm.encrypt(peer_id_str, text.as_bytes()) {
        Ok((msg_type, ciphertext)) => {
            persist_olm_session(olm, crypto_store, peer_id_str);
            let haven_msg = encrypted_frame(olm, msg_type, &ciphertext);
            let json = serde_json::to_string(&haven_msg).unwrap_or_default();
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {''')], SCAN),
    ('an image encrypts out of turn',
     [(CRYPTO, '''    match super::olm_lane::encrypt_in_turn(olm, peer_id_str, text.as_bytes()) {
        Ok((msg_type, ciphertext)) => {
            persist_olm_session(olm, crypto_store, peer_id_str);
            let haven_msg = encrypted_frame(olm, msg_type, &ciphertext);
            let json = serde_json::to_string(&haven_msg).unwrap_or_default();
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirectImage {''',
       '''    match olm.encrypt(peer_id_str, text.as_bytes()) {
        Ok((msg_type, ciphertext)) => {
            persist_olm_session(olm, crypto_store, peer_id_str);
            let haven_msg = encrypted_frame(olm, msg_type, &ciphertext);
            let json = serde_json::to_string(&haven_msg).unwrap_or_default();
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirectImage {''')], SCAN),
    ('a forwarder signal encrypts out of turn',
     [(FWD, 'match super::olm_lane::encrypt_in_turn(olm, &target_peer, env_json.as_bytes()) {',
       'match olm.encrypt(&target_peer, env_json.as_bytes()) {')], SCAN),
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
print('MUTATION PASS DONE', flush=True)
