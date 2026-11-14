//! Debug builds only: the fleet's production relay guard inside the node. With the
//! `relay_guard` marker the fleet writes into a peer's data dir, no relay dial and no
//! push fetch reaches the official relay (a name under anonlisten.com, or one of its
//! addresses), and the addresses judged are the ones dialled. Release builds compile
//! none of it. The tooling half is scripts/fleet_relay_guard.ps1, which keeps the same
//! lists.

use std::net::{IpAddr, SocketAddr};
use std::path::Path;

/// The marker's file name in the data dir; its contents do not matter.
pub(crate) const MARKER: &str = "relay_guard";

const PRODUCTION_SUFFIX: &str = "anonlisten.com";
const PRODUCTION_ADDRS: [&str; 2] = ["141.227.186.209", "2001:41d0:ab01::4:0:d"];

pub(crate) fn armed_in(dir: &Path) -> bool {
    dir.join(MARKER).exists()
}

fn plain(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map_or(ip, IpAddr::V4),
        v4 => v4,
    }
}

pub(crate) fn is_production_addr(ip: IpAddr) -> bool {
    PRODUCTION_ADDRS.iter().filter_map(|a| a.parse::<IpAddr>().ok()).any(|p| plain(p) == plain(ip))
}

/// Why `host` (a name or an address literal, brackets allowed) is the official relay,
/// judged by its text; `None` when it is not.
pub(crate) fn production_reason(host: &str) -> Option<String> {
    let name = host.trim().trim_start_matches('[').trim_end_matches(']').trim_end_matches('.').to_ascii_lowercase();
    if name.is_empty() {
        return Some("names no relay, which means the official one".into());
    }
    if name == PRODUCTION_SUFFIX || name.ends_with(&format!(".{PRODUCTION_SUFFIX}")) {
        return Some(format!("{name} is under {PRODUCTION_SUFFIX}, the official relay"));
    }
    match name.parse::<IpAddr>() {
        Ok(ip) if is_production_addr(ip) => Some(format!("{name} is the official relay's address")),
        _ => None,
    }
}

/// The host of `host[:port]` (an IPv6 literal bare or in brackets).
fn host_of(text: &str) -> &str {
    if let Some(rest) = text.strip_prefix('[') {
        return rest.split(']').next().unwrap_or(rest);
    }
    match text.split_once(':') {
        Some((host, port)) if !port.contains(':') => host,
        _ => text,
    }
}

fn refusal(why: &str) -> String {
    format!("PRODUCTION RELAY GUARD refused the dial: {why}")
}

/// The addresses a guarded dial may use for `target` (`host:port`) of the relay
/// `host`: every one it resolves to, or a refusal when any is the official relay's.
pub(crate) async fn vetted(host: &str, target: &str) -> Result<Vec<SocketAddr>, String> {
    vetted_against(host, target, is_production_addr).await
}

/// [`vetted`] with the official relay's addresses as `production`, so a test can name one.
async fn vetted_against(host: &str, target: &str, production: fn(IpAddr) -> bool) -> Result<Vec<SocketAddr>, String> {
    if let Some(why) = production_reason(host) {
        return Err(refusal(&why));
    }
    if let Some(why) = production_reason(host_of(target)) {
        return Err(refusal(&why));
    }
    let found: Vec<SocketAddr> = tokio::net::lookup_host(target)
        .await
        .map_err(|e| refusal(&format!("{target} does not resolve ({e})")))?
        .collect();
    if found.is_empty() {
        return Err(refusal(&format!("{target} does not resolve")));
    }
    if let Some(hit) = found.iter().find(|a| production(a.ip())) {
        return Err(refusal(&format!("{target} resolves to the official relay ({})", plain(hit.ip()))));
    }
    Ok(found)
}

/// A push fetch's relay, judged against the marker beside its database.
pub(crate) fn fetch_refusal(relay_domain: &str, db_path: &str) -> Option<String> {
    let dir = Path::new(db_path).parent()?;
    if !armed_in(dir) {
        return None;
    }
    production_reason(host_of(relay_domain)).map(|why| refusal(&why))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_spelling_of_the_official_relay_is_refused() {
        for host in [
            "relay.anonlisten.com", "RELAY.ANONLISTEN.COM.", "anonlisten.com", "canary.relay.anonlisten.com",
            "141.227.186.209", "[2001:41d0:ab01::4:0:d]", "::ffff:141.227.186.209", "",
        ] {
            assert!(production_reason(host).is_some(), "{host:?}");
        }
        for host in ["hollowtest.duckdns.org", "anonlisten.com.evil.example", "notanonlisten.com", "192.168.18.2", "127.0.0.1"] {
            assert!(production_reason(host).is_none(), "{host:?}");
        }
    }

    #[tokio::test]
    async fn a_guarded_dial_uses_only_vetted_addresses() {
        assert_eq!(vetted("hollowtest.example", "127.0.0.1:443").await, Ok(vec!["127.0.0.1:443".parse().unwrap()]));
        for (host, target) in [
            ("relay.anonlisten.com", "127.0.0.1:18501"),
            ("hollowtest.example", "141.227.186.209:443"),
            ("hollowtest.example", "[::ffff:141.227.186.209]:443"),
            ("hollowtest.example", "[2001:41d0:ab01::4:0:d]:443"),
            ("hollowtest.example", "no-such-name.invalid:443"),
        ] {
            let got = vetted(host, target).await;
            assert!(got.as_ref().is_err_and(|e| e.contains("PRODUCTION RELAY GUARD")), "{host} {target}: {got:?}");
        }
    }

    /// Each layer alone: the text of the dial target, judged before any lookup, and where
    /// a name resolves, judged after it.
    #[tokio::test]
    async fn each_layer_of_a_guarded_dial_refuses_on_its_own() {
        let by_text = vetted("hollowtest.example", "nowhere.invalid.anonlisten.com:443").await;
        assert!(by_text.as_ref().is_err_and(|e| e.contains("is under anonlisten.com")), "{by_text:?}");
        fn loopback_is_production(ip: IpAddr) -> bool {
            plain(ip).is_loopback()
        }
        let by_lookup = vetted_against("hollowtest.example", "localhost:443", loopback_is_production).await;
        assert!(by_lookup.as_ref().is_err_and(|e| e.contains("resolves to the official relay")), "{by_lookup:?}");
        assert!(vetted_against("hollowtest.example", "localhost:443", is_production_addr).await.is_ok());
    }

    #[test]
    fn a_push_fetch_is_judged_only_under_the_marker() {
        let dir = crate::test_tmp::tempdir().unwrap();
        let db = dir.path().join("hollow.db");
        let db = db.to_str().unwrap();
        assert_eq!(fetch_refusal("relay.anonlisten.com", db), None, "no marker, no judgement");
        std::fs::write(dir.path().join(MARKER), "").unwrap();
        for domain in ["relay.anonlisten.com", "relay.anonlisten.com:443", "141.227.186.209", "2001:41d0:ab01::4:0:d"] {
            assert!(fetch_refusal(domain, db).is_some(), "{domain}");
        }
        assert_eq!(fetch_refusal("hollowtest.duckdns.org", db), None);
        assert_eq!(fetch_refusal("hollowtest.duckdns.org:8443", db), None);
    }
}
