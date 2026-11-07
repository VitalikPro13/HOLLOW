//! Who a fresh install asks about a server it is recovering (DEVICE_PROOF_DESIGN 8.4 and
//! 8.7, step 6, R31-9). Until the lock moves the stolen device still answers joins, with
//! a state of puppets if it likes, so the list is the UNION of every source: each join
//! answerer's state, each friend's `SharedServers` entry, each checkpoint a witness sends.
//! Contacts who share the server come first, then members a friend names, then the rest
//! by how many sources name them; a name never leaves the list.

use std::collections::{BTreeSet, HashMap};

/// Identities asked per server.
pub(crate) const MAX_ASKED: usize = 64;
/// Names kept per server, and servers kept.
const MAX_NAMED: usize = 1024;
const MAX_SERVERS: usize = 64;
/// Friend- or contact-named identities kept per server, apart from [`MAX_NAMED`]: a puppet
/// flood fills the shared list, never this one.
const MAX_VOUCHED: usize = 1024;

#[derive(Default, Debug)]
struct Sources {
    by_friend: BTreeSet<String>,
    /// Friend identities whose entry for this server already counted: one source each.
    friends: BTreeSet<String>,
    /// Named while a contact of ours: ranked first like a friend's names.
    by_contact: BTreeSet<String>,
    /// How many sources named each identity.
    named: HashMap<String, u32>,
}

impl Sources {
    fn vouched(&self, m: &str) -> bool {
        self.by_friend.contains(m) || self.by_contact.contains(m)
    }

    /// Count one more source for `m`. Past the cap a vouched name takes the place of the
    /// least-named one only join answers gave; anything else is not kept.
    fn name(&mut self, m: String) {
        if let Some(n) = self.named.get_mut(&m) {
            *n = n.saturating_add(1);
            return;
        }
        if self.named.len() >= MAX_NAMED {
            if !self.vouched(&m) {
                return;
            }
            let weakest = self
                .named
                .iter()
                .filter(|(k, _)| !self.vouched(k))
                .min_by(|(a, an), (b, bn)| an.cmp(bn).then_with(|| b.cmp(a)))
                .map(|(k, _)| k.clone());
            let Some(weakest) = weakest else { return };
            self.named.remove(&weakest);
        }
        self.named.insert(m, 1);
    }
}

/// Our contacts, for the list: accepted friends, read once per use (a state may name
/// thousands of members).
pub(crate) fn contacts(store: &crate::storage::MessageStore) -> std::collections::HashSet<String> {
    store.load_friends(Some("accepted")).unwrap_or_default().into_iter().map(|f| f.0).collect()
}

#[derive(Default, Debug)]
pub(crate) struct UnionList {
    servers: HashMap<String, Sources>,
}

impl UnionList {
    fn server(&mut self, server: &str) -> Option<&mut Sources> {
        if !self.servers.contains_key(server) && self.servers.len() >= MAX_SERVERS {
            return None;
        }
        Some(self.servers.entry(server.to_string()).or_default())
    }

    /// `friend`'s `SharedServers` entry named these members; a friend counts once per
    /// server, however many entries or frames repeat it.
    pub(crate) fn friend_named(&mut self, server: &str, friend: &str, members: &[String]) {
        let Some(s) = self.server(server) else { return };
        if s.friends.len() >= MAX_VOUCHED || !s.friends.insert(friend.to_string()) {
            return;
        }
        for m in members.iter().take(super::shared_servers::MAX_MEMBERS) {
            if s.by_friend.len() < MAX_VOUCHED {
                s.by_friend.insert(m.clone());
            }
            s.name(m.clone());
        }
    }

    /// A join answerer's state or a witnessed checkpoint named these members; `contact`
    /// is a friend of ours.
    pub(crate) fn state_named(&mut self, server: &str, members: impl IntoIterator<Item = String>, contact: &dyn Fn(&str) -> bool) {
        let Some(s) = self.server(server) else { return };
        for m in members {
            if s.by_contact.len() < MAX_VOUCHED && !s.by_contact.contains(&m) && contact(&m) {
                s.by_contact.insert(m.clone());
            }
            s.name(m);
        }
    }

    /// Whom to ask, in order, at most [`MAX_ASKED`]; `contact` is a friend sharing it,
    /// `skip` our own identity.
    pub(crate) fn order(&self, server: &str, contact: &dyn Fn(&str) -> bool, skip: &str) -> Vec<String> {
        let Some(s) = self.servers.get(server) else { return Vec::new() };
        let mut all: Vec<(&String, u32)> = s.named.iter().filter(|(m, _)| m.as_str() != skip).map(|(m, n)| (m, *n)).collect();
        all.sort_by(|(a, an), (b, bn)| {
            let key = |m: &str| (!(contact(m) || s.by_contact.contains(m)), !s.by_friend.contains(m));
            key(a).cmp(&key(b)).then_with(|| bn.cmp(an)).then_with(|| a.cmp(b))
        });
        all.into_iter().take(MAX_ASKED).map(|(m, _)| m.clone()).collect()
    }

    /// The list as track C1's witness desk takes it, each name with where we learned it.
    pub(crate) fn sources(&self, server: &str, contact: &dyn Fn(&str) -> bool, skip: &str) -> Vec<(String, super::witness::MemberSource)> {
        use super::witness::MemberSource;
        let Some(s) = self.servers.get(server) else { return Vec::new() };
        self.order(server, contact, skip)
            .into_iter()
            .map(|m| {
                let source = if contact(&m) || s.by_contact.contains(&m) {
                    MemberSource::Contact
                } else if s.by_friend.contains(&m) {
                    MemberSource::FriendEntry
                } else {
                    MemberSource::JoinAnswer
                };
                (m, source)
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_thief_answering_the_join_cannot_hide_honest_members() {
        let mut u = UnionList::default();
        // The stolen device's answer names only puppets; a friend names the honest ones.
        u.state_named("s", ["p1", "p2", "p3"].map(String::from), &|_| false);
        u.friend_named("s", "f1", &["h1".into(), "h2".into()]);
        u.state_named("s", ["h2", "p1"].map(String::from), &|_| false);
        u.state_named("s", ["p1"].map(String::from), &|_| false);
        let order = u.order("s", &|m| m == "h1", "me");
        assert_eq!(order[..2], ["h1".to_string(), "h2".to_string()], "contacts, then friend-named members, go first");
        assert!(order.contains(&"p3".to_string()), "a named identity left the list");
        assert_eq!(order.iter().position(|m| m == "p1"), Some(2), "a most-named puppet went before a friend-named member");
    }

    #[test]
    fn the_list_is_bounded() {
        let mut u = UnionList::default();
        u.state_named("s", (0..5000).map(|i| format!("m{i}")), &|_| false);
        assert_eq!(u.order("s", &|_| false, "me").len(), MAX_ASKED);
        for i in 0..200 {
            u.state_named(&format!("s{i}"), ["x".to_string()], &|_| false);
        }
        assert!(u.servers.len() <= MAX_SERVERS);
        assert!(u.servers.get("s").is_some_and(|s| s.named.len() <= MAX_NAMED));
    }
    /// REVIEW probe: a join answer from the stolen device that names more puppets than the
    /// list holds must not push out the members a friend names after it (R31-9).
    #[test]
    fn review_a_puppet_flood_first_never_hides_a_friend_named_member() {
        let mut u = UnionList::default();
        u.state_named("s", (0..1500).map(|i| format!("p{i}")), &|_| false);
        u.friend_named("s", "f1", &["h1".into()]);
        let order = u.order("s", &|_| false, "me");
        assert_eq!(order.first().map(String::as_str), Some("h1"), "the friend-named member is not asked first: {:?}", &order[..3]);
    }

    /// Review part B: ONE friend's `SharedServers` answer may name the same server in every
    /// entry of every frame; its names count as one source, so they never outrank the
    /// members another friend and the join answers name.
    #[test]
    fn review_b_one_friend_repeating_a_server_never_hides_the_members_others_name() {
        let mut u = UnionList::default();
        // An honest friend and two join answers name H.
        u.friend_named("s", "honest", &["h".into()]);
        u.state_named("s", ["h".to_string()], &|_| false);
        u.state_named("s", ["h".to_string()], &|_| false);
        // One hostile friend's single answer: 4 frames x 16 entries, all for "s".
        let puppets: Vec<String> = (0..64).map(|i| format!("p{i:02}")).collect();
        for _ in 0..(super::super::shared_servers::FRAMES * super::super::shared_servers::PER_FRAME) {
            u.friend_named("s", "hostile", &puppets);
        }
        let order = u.order("s", &|_| false, "me");
        assert!(order.contains(&"h".to_string()), "one friend's repeated entries hid the member every other source names: {:?}", &order[..4]);
    }

    #[test]
    fn a_contact_a_join_answer_names_after_a_flood_still_enters_first() {
        let mut u = UnionList::default();
        u.state_named("s", (0..1500).map(|i| format!("p{i}")), &|_| false);
        u.state_named("s", ["zc1".to_string()], &|m| m == "zc1");
        let order = u.order("s", &|_| false, "me");
        assert_eq!(order.first().map(String::as_str), Some("zc1"), "a contact a join answer named is lost: {:?}", &order[..3]);
        assert!(u.servers["s"].named.len() <= MAX_NAMED);
        let sources = u.sources("s", &|_| false, "me");
        assert!(matches!(sources.first(), Some((m, super::super::witness::MemberSource::Contact)) if m == "zc1"));
    }
}
