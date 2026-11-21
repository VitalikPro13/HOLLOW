//! A server's home relay (#151, HOL-SEC-211): the owner-signed relay a server lives on.
//!
//! Servers are not bound to a relay by anything a relay enforces, so a member that moved
//! to another relay could put the join lock there and admit people the owner never sees.
//! A device whose relay is not its server's home sends nothing scoped to that server (it
//! rides the denylist's gate as an `Elsewhere` mark): no join answers, no Welcomes, no
//! commits, no lock puts. A server whose owner has not named a home behaves as before.

use crate::crdt::server_state::ServerState;
use crate::crypto::MlsManager;

use super::types::{NetworkEvent, ServerStates};
use super::ws_client::WsCommand;

/// The default port a relay URL leaves out.
const DEFAULT_PORT: &str = "443";

/// The one form a relay is named and compared in: a lowercase host, with `:port` only
/// when the port is not 443. Dart's `normalizeRelayHost` gives the same answer for the
/// same input (the shared vectors in both test suites); `None` for anything that is not
/// a host.
pub(crate) fn canonical(input: &str) -> Option<String> {
    let mut s = input.trim().to_ascii_lowercase();
    for scheme in ["wss://", "ws://", "https://", "http://"] {
        if let Some(rest) = s.strip_prefix(scheme) {
            s = rest.to_string();
            break;
        }
    }
    let s = s.trim_end_matches('/');
    let s = s.strip_suffix("/ws").unwrap_or(s).trim_end_matches('/');
    if s.is_empty() {
        return None;
    }
    let (host, port) = if let Some(rest) = s.strip_prefix('[') {
        let close = rest.find(']')?;
        let inner = &rest[..close];
        if !inner.contains(':') || !inner.bytes().all(|b| b.is_ascii_hexdigit() || b == b':' || b == b'.') {
            return None;
        }
        (&s[..close + 2], &rest[close + 1..])
    } else {
        match s.find(':') {
            Some(colon) => {
                if s[colon + 1..].contains(':') {
                    return None;
                }
                (&s[..colon], &s[colon..])
            }
            None => (s, ""),
        }
    };
    if !host.starts_with('[') {
        if host.len() > 253 {
            return None;
        }
        let label_ok = |l: &str| {
            !l.is_empty()
                && l.len() <= 63
                && l.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
                && !l.starts_with('-')
                && !l.ends_with('-')
        };
        if !host.split('.').all(label_ok) {
            return None;
        }
    }
    let port = match port.strip_prefix(':') {
        None if port.is_empty() => "",
        None => return None,
        Some(digits) => {
            if digits.is_empty() || digits.len() > 5 || !digits.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            let value: u32 = digits.parse().ok()?;
            if !(1..=65535).contains(&value) {
                return None;
            }
            if digits == DEFAULT_PORT { "" } else { port }
        }
    };
    Some(format!("{host}{port}"))
}

/// The home relay of `state` when it is not the relay this node loop dials.
pub(crate) fn elsewhere(state: &ServerState) -> Option<String> {
    let ours = super::ws_client::relay_home()?;
    state.home_relay().filter(|home| *home != ours)
}

/// Mark or unmark every server by whether it lives on the relay we dial, once per loop
/// turn, telling Dart whenever the relay a server lives on changes. `local_master` = us.
pub(crate) fn sync(
    server_states: &ServerStates,
    local_master: &str,
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &super::types::WsCmdTx,
) -> Vec<NetworkEvent> {
    let Some(ours) = super::ws_client::relay_home() else { return Vec::new() };
    let denials = super::relay_denial::current();
    let marked = denials.elsewhere();
    let mut events = Vec::new();
    for (server_id, state) in server_states {
        // Cheap on the common path: a home equal to ours, or none, allocates nothing.
        let differs = state
            .settings
            .get(crate::crdt::server_state::HOME_RELAY_KEY)
            .is_some_and(|reg| reg.read() != &ours);
        let told = if marked.is_empty() { None } else { marked.get(&super::relay_denial::room_key(server_id)) };
        if !differs && told.is_none() {
            continue;
        }
        let home = if state.is_deleted() { None } else { elsewhere(state) };
        let owned = state.current_owner().as_deref() == Some(local_master);
        match (home, told) {
            (Some(home), told) if told != Some(&home) => {
                leave(server_id, &home, &denials, ws_cmd_tx);
                events.push(NetworkEvent::ServerElsewhere { server_id: server_id.clone(), relay: Some(home), owned });
            }
            (None, Some(_)) if denials.clear_elsewhere(server_id) => {
                hollow_log!("[HOLLOW-WS] {server_id} lives on this relay again");
                let _ = ws_cmd_tx.send(WsCommand::RetryDenied { room: Some(server_id.clone()) });
                let _ = ws_cmd_tx.send(WsCommand::JoinRoom { room_code: server_id.clone() });
                events.push(NetworkEvent::ServerElsewhere { server_id: server_id.clone(), relay: None, owned });
            }
            _ => {}
        }
    }
    if !events.is_empty()
        && let Some(m) = mls.as_mut()
    {
        m.set_frozen(denials.rooms());
    }
    events
}

/// [`sync`] for one server at once, before anything else is sent for it: a join that
/// just learned where its server lives. The event, when it was not marked before.
pub(crate) fn settle(
    server_id: &str,
    state: &ServerState,
    local_master: &str,
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &super::types::WsCmdTx,
) -> Option<NetworkEvent> {
    let home = elsewhere(state)?;
    let denials = super::relay_denial::current();
    if denials.elsewhere().get(&super::relay_denial::room_key(server_id)) == Some(&home) {
        return None;
    }
    leave(server_id, &home, &denials, ws_cmd_tx);
    if let Some(m) = mls.as_mut() {
        m.set_frozen(denials.rooms());
    }
    let owned = state.current_owner().as_deref() == Some(local_master);
    Some(NetworkEvent::ServerElsewhere { server_id: server_id.to_string(), relay: Some(home), owned })
}

/// From now on nothing scoped to `server_id` leaves through this relay, and its room
/// goes: what a member does here, nobody on the server's home relay would see.
fn leave(server_id: &str, home: &str, denials: &super::relay_denial::Denials, ws_cmd_tx: &super::types::WsCmdTx) {
    hollow_log!("[HOLLOW-SECURITY] {server_id} lives on {home}, not this relay: sending nothing for it here");
    denials.mark_elsewhere(server_id, home);
    let _ = ws_cmd_tx.send(WsCommand::LeaveRoom { room_code: server_id.to_string() });
    let _ = ws_cmd_tx.send(WsCommand::RefuseRoom { room: server_id.to_string() });
}

/// The relay a server we own gets as its home now: the one we dial, when the owner has
/// named none (an admin's value a 0.14.1 owner folded counts as none). Set once: in
/// 0.14.2 nothing moves a server to another relay, since a move needs a client that
/// listens on two relays (MULTI_RELAY_CLIENT_PLAN section 13).
pub(crate) fn missing_home(state: &ServerState) -> Option<String> {
    #[cfg(test)]
    if STAMP_OFF.load(std::sync::atomic::Ordering::Relaxed) {
        return None;
    }
    if state.is_deleted() || state.home_relay().is_some() {
        return None;
    }
    super::ws_client::relay_home()
}

/// TEST-ONLY: owners name no home on their own, as before 0.14.2.
#[cfg(test)]
pub(crate) static STAMP_OFF: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(test)]
mod tests {
    use super::canonical;
    use crate::crdt::admin_lww::AdminLwwReg;
    use crate::crdt::hlc::HlcTimestamp;
    use crate::crdt::server_state::{ServerState, HOME_RELAY_KEY};
    use crate::node::types::NetworkEvent;

    fn with_home(state: &mut ServerState, actor: &str, relay: &str, ms: u64) {
        let at = HlcTimestamp { physical_ms: ms, counter: 0, actor: actor.into() };
        state.settings.insert(HOME_RELAY_KEY.into(), AdminLwwReg::new(relay.into(), at, 0));
    }

    /// Run `f` as a node loop dialling relay.a.test would.
    async fn on_relay_a<T>(f: impl std::future::Future<Output = T>) -> T {
        let dialed = crate::node::ws_client::DialedRelay { auth: "relay.a.test".into(), home: "relay.a.test".into() };
        crate::node::relay_denial::with_denials(crate::node::ws_client::with_relay_domain(dialed, f)).await
    }

    /// An owner names a home only where none of its own ops named one: an admin's value
    /// a 0.14.1 owner folded counts as none, so the owner names it (HOL-SEC-211).
    #[tokio::test]
    async fn the_owner_names_a_home_over_a_value_it_never_wrote() {
        on_relay_a(async {
            let mut s = ServerState::new("s1".into(), "S".into(), "owner".into());
            assert_eq!(super::missing_home(&s).as_deref(), Some("relay.a.test"));
            with_home(&mut s, "admin", "evil.example", 5);
            assert_eq!(super::missing_home(&s).as_deref(), Some("relay.a.test"), "an admin's value is no home");
            with_home(&mut s, "owner", "relay.b.test", 6);
            assert_eq!(super::missing_home(&s), None, "the owner's own is kept");
        })
        .await;
    }

    /// Dart hears where a server lives each time that changes, and when it lives here
    /// again; nothing while it stays the same.
    #[tokio::test]
    async fn every_change_of_where_a_server_lives_is_told() {
        on_relay_a(async {
            let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
            let mut states = crate::node::types::ServerStates::new();
            let mut s = ServerState::new("s1".into(), "S".into(), "owner".into());
            with_home(&mut s, "owner", "relay.b.test", 5);
            states.insert("s1".into(), s.clone());
            let told = |events: Vec<NetworkEvent>| -> Vec<(Option<String>, bool)> {
                events.into_iter().map(|e| match e {
                    NetworkEvent::ServerElsewhere { relay, owned, .. } => (relay, owned),
                    _ => panic!("only ServerElsewhere"),
                }).collect()
            };
            assert_eq!(told(super::sync(&states, "owner", &mut None, &tx)), vec![(Some("relay.b.test".into()), true)]);
            assert!(crate::node::relay_denial::denied("s1"), "nothing for it leaves here");
            assert!(super::sync(&states, "owner", &mut None, &tx).is_empty(), "the same home is told once");
            with_home(&mut s, "owner", "relay.c.test", 6);
            states.insert("s1".into(), s.clone());
            assert_eq!(told(super::sync(&states, "member", &mut None, &tx)), vec![(Some("relay.c.test".into()), false)]);
            with_home(&mut s, "owner", "relay.a.test", 7);
            states.insert("s1".into(), s.clone());
            assert_eq!(told(super::sync(&states, "member", &mut None, &tx)), vec![(None, false)]);
            assert!(!crate::node::relay_denial::denied("s1"), "it lives here again");
            while rx.try_recv().is_ok() {}
        })
        .await;
    }

    /// The same vectors as Dart's "normalizeRelayHost agrees with Rust" group: a
    /// server's home relay is compared in both languages.
    #[test]
    fn the_same_form_dart_gives() {
        for (input, want) in [
            ("relay.anonlisten.com", Some("relay.anonlisten.com")),
            ("  WSS://Relay.AnonListen.com/ws/ ", Some("relay.anonlisten.com")),
            ("https://relay.anonlisten.com:443", Some("relay.anonlisten.com")),
            ("relay.example.org:443", Some("relay.example.org")),
            ("myrelay.duckdns.org:8443", Some("myrelay.duckdns.org:8443")),
            ("HTTP://MyRelay.DuckDNS.org:8443/", Some("myrelay.duckdns.org:8443")),
            ("[::1]:8443", Some("[::1]:8443")),
            ("[::1]:443", Some("[::1]")),
            ("[2001:DB8::1]", Some("[2001:db8::1]")),
            ("10.0.0.2", Some("10.0.0.2")),
            ("relay.example.org.", None),
            ("", None),
            ("::1", None),
            ("host:0", None),
            ("host:99999", None),
            ("host:", None),
            ("bad_host", None),
            ("-bad.host", None),
            ("a..b", None),
            ("host/path", None),
        ] {
            assert_eq!(canonical(input).as_deref(), want, "{input}");
        }
    }
}
