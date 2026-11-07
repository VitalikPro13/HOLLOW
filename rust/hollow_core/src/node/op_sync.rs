//! CRDT catch-up asks, and the digest asks still open.
//!
//! Catch-up compares range digests (`crdt::digest`). The per-author state vector, which
//! loses ops (HOL-SEC-175), is read only for a server whose id is not self-certifying,
//! where a replica still on the legacy anchor (no owner checkpoint yet) applies in arrival
//! order and only the vector says what may be handed to it. A silent ask is sent again
//! unchanged, so a late first answer still counts and a lost one is replaced. A digest
//! answer that splits a range is followed only for the ask it names, while that ask is
//! open.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::crdt::digest::{self, DigestReply, KeptRef, OpDigest};
use crate::crdt::server_state::{Anchor, ServerState};
use crate::crdt::sync::StateVector;

use super::types::HavenMessage;

/// Identities whose last roster from us we remember.
const CAPS_MAX: usize = 4096;
/// An ask nothing answered in this long is sent again; each later wait doubles, and the
/// ask is judged once the last copy waited out its own (35 s, 21 s in tests).
const RESEND_AFTER: Duration = Duration::from_secs(if cfg!(test) { 3 } else { 5 });
/// Copies of a silent ask sent before it is judged.
const RESENDS: u32 = 2;
/// A digest device's ask stays open this long after its round left, copies or not, so a
/// late split is still followed.
const ASK_TTL: Duration = Duration::from_secs(60);
/// How long after our join completes we ask more members what we may have missed.
/// (In the harness, past the joiner's own first-contact syncs, so a test can tell them apart.)
const JOIN_FOLLOW_UP: Duration = Duration::from_secs(if cfg!(test) { 6 } else { 5 });
/// Member devices asked after a join.
pub(crate) const JOIN_FOLLOW_UP_PEERS: usize = 2;
/// Between two rounds an owner asks of one server for its due checkpoint (writer rule a).
const WITNESS_ROUND_GAP: Duration = Duration::from_secs(600);
/// Identities one such round asks, by standing.
const WITNESS_ROUND_ASKED: usize = 8;

#[derive(Debug, Clone)]
struct Ask {
    id: u64,
    salt: String,
    round: u8,
    nonce: Option<u64>,
    /// The first ask named our MLS epoch. Every later send names the epoch we are at
    /// then: an older one reads as a stale member, and the answerer repairs our leaf.
    hinted: bool,
    sent_at: Instant,
    round_at: Instant,
    /// Every copy went unanswered; kept only for a late answer.
    judged: bool,
    /// The ranges the last round asked: a split may only cover them.
    asked: Vec<(u64, u64)>,
    /// What the last round sent, and how often it was sent again unanswered.
    last: Box<HavenMessage>,
    resends: u32,
}

/// An open ask the silence clock acted on.
pub(crate) enum Silent {
    /// Send (server, device) this copy of the ask again.
    Again(String, String, Box<HavenMessage>),
    /// The device left every copy unanswered: no more copies go.
    Closed(String, String),
}

/// What to do with a digest answer.
pub(crate) enum Step {
    /// No open ask of ours names it: dropped.
    Unasked,
    /// The ask is complete.
    Done,
    /// The answer was not one an honest answerer sends: the ask is closed.
    Malformed,
    /// The ask is complete and the answerer holds rosters ours differ from: this asks
    /// for them (DEVICE_PROOF_DESIGN section 9).
    Rosters(Box<HavenMessage>),
    /// Ask the same device again, with this.
    Again(Box<HavenMessage>),
}

#[derive(Default)]
pub(crate) struct OpSync {
    /// (server, device) -> the open ask.
    asks: HashMap<(String, String), Ask>,
    follow_ups: Vec<(String, Instant)>,
    /// Our own ops on a server whose room we were not in yet when we authored them:
    /// carried to its members once the relay first lists the room for us.
    unseen: HashMap<String, Vec<HavenMessage>>,
    /// Per server, the identities (masters) whose digest round with us ended since the
    /// socket came up: what the owner's checkpoint writer rule reads.
    witnesses: HashMap<String, std::collections::HashSet<String>>,
    /// (server, identity) -> when its last digest round with us ended: what a retire's
    /// round waits on (DEVICE_PROOF_DESIGN 8.2, M4).
    ended_at: HashMap<(String, String), Instant>,
    /// Server -> when we last asked a round for its due checkpoint.
    witness_asked: HashMap<String, Instant>,
    /// Our store, master and device, for the roster parts of an ask; `None` in units.
    store: Option<(String, String, String)>,
    /// Identity -> our roster's digest when we last sent it there with an ask.
    roster_sent: HashMap<String, String>,
}

/// Ops kept per server for its first room listing.
const UNSEEN_MAX: usize = 16;

/// A request in the state-vector form, for a server whose id is not self-certifying
/// (`reads_vector`).
pub(crate) fn vector_ask(state: &ServerState, nonce: Option<u64>, mls_epoch: Option<u64>) -> HavenMessage {
    HavenMessage::SyncRequest {
        server_id: state.server_id.clone(),
        state_vector_json: serde_json::to_string(&StateVector::from_server_state(state)).unwrap_or_default(),
        mls_epoch,
        nonce,
        full: None,
        digest: None,
        x: None,
    }
}

/// Whether a sync of `server_id` may take the state-vector form: never for a
/// self-certifying id, whose replicas were all born anchored and always compare digests.
pub(crate) fn reads_vector(server_id: &str) -> bool {
    !crate::crdt::anchor::is_genesis_id(server_id)
}

/// An ask for rosters only: no digest and no vector, so an answerer reads no op from it.
pub(crate) fn roster_ask(server_id: &str, nonce: Option<u64>, wanted: Vec<String>) -> HavenMessage {
    HavenMessage::SyncRequest {
        server_id: server_id.to_string(),
        state_vector_json: String::new(),
        mls_epoch: None,
        nonce,
        full: None,
        digest: None,
        x: super::sync_ext::AskExt { rosters_wanted: wanted, ..Default::default() }.boxed(),
    }
}

/// Whether `msg` is a [`roster_ask`].
pub(crate) fn is_roster_ask(digest: Option<&OpDigest>, full: bool, state_vector_json: &str, x: Option<&super::sync_ext::AskExt>) -> bool {
    digest.is_none() && !full && state_vector_json.is_empty() && x.is_some_and(|x| !x.rosters_wanted.is_empty())
}

fn fresh_id() -> u64 {
    let mut b = [0u8; 8];
    let _ = getrandom::fill(&mut b);
    u64::from_le_bytes(b)
}

impl OpSync {
    /// Where our rosters live, so an ask carries the authority set's fingerprints and our
    /// own roster when an answerer may not hold it.
    pub(crate) fn set_store(&mut self, db_path: &str, db_passphrase: &str, local_master: &str) {
        self.store = Some((db_path.to_string(), db_passphrase.to_string(), local_master.to_string()));
    }

    /// The answerer refused our ask (`roster_needed`): it is not sent again as it is.
    pub(crate) fn close(&mut self, server: &str, device: &str) {
        self.asks.remove(&(server.to_string(), device.to_string()));
    }

    /// The last message of our open ask to `device` for `server`.
    pub(crate) fn last_ask(&self, server: &str, device: &str) -> Option<HavenMessage> {
        self.asks.get(&(server.to_string(), device.to_string())).map(|a| (*a.last).clone())
    }

    /// The next ask to `device`'s identity carries our roster even if it went there before:
    /// that answerer could not place us.
    pub(crate) fn resend_roster_to(&mut self, device: &str) {
        self.roster_sent.remove(&super::resolver::resolve(device));
    }

    /// The fingerprints of `state`'s authority set under `salt`, and our own roster when
    /// `device`'s identity has not had this version of it.
    fn roster_parts(&mut self, state: &ServerState, device: &str, salt: &str) -> (Option<Vec<String>>, Option<crate::identity::roster::Roster>) {
        let Some((db, pass, master)) = self.store.clone() else { return (None, None) };
        let Ok(store) = crate::storage::MessageStore::lease(&db, &pass) else { return (None, None) };
        let prints = super::server_rosters::prints(&super::server_rosters::entries(&store, &db, state), salt);
        let identity = super::resolver::resolve(device);
        let own = (identity != master)
            .then(|| super::roster_book::own_roster(&master, &db, &pass))
            .flatten()
            .filter(|r| self.roster_sent.get(&identity) != Some(&r.digest()));
        if let Some(r) = &own {
            if self.roster_sent.len() >= CAPS_MAX {
                self.roster_sent.clear();
            }
            self.roster_sent.insert(identity, r.digest());
        }
        (Some(prints), own)
    }

    /// The masters whose rosters `rd` says the answerer holds otherwise than we do.
    fn rosters_wanted(&self, state: &ServerState, rd: &[(String, String)]) -> Vec<String> {
        if rd.is_empty() {
            return Vec::new();
        }
        let Some((db, pass, _)) = self.store.as_ref() else { return Vec::new() };
        let Ok(store) = crate::storage::MessageStore::lease(db, pass) else { return Vec::new() };
        super::server_rosters::wanted(&super::server_rosters::entries(&store, db, state), rd)
    }

    /// The sync ask for `state` to `device`: the digest, or the vector while our replica
    /// is on the legacy anchor.
    pub(crate) fn ask(
        &mut self,
        state: &ServerState,
        kept: &[KeptRef<'_>],
        device: &str,
        nonce: Option<u64>,
        mls_epoch: Option<u64>,
    ) -> HavenMessage {
        if state.anchor() == Anchor::Legacy {
            let mut ask = vector_ask(state, nonce, mls_epoch);
            let (_, asker_roster) = self.roster_parts(state, device, "");
            if let HavenMessage::SyncRequest { x, .. } = &mut ask {
                *x = super::sync_ext::AskExt { asker_roster, ..Default::default() }.boxed();
            }
            return ask;
        }
        let id = fresh_id();
        let salt = digest::new_salt();
        let base = state.checkpoint_hlc.clone();
        let bref = state.base.as_ref().map(|b| b.hash_hex());
        let mut d = digest::first_ask(&digest::entries(state, kept, None), id, salt.clone(), base, bref);
        let (rs, asker_roster) = self.roster_parts(state, device, &salt);
        d.rs = rs;
        let x = super::sync_ext::AskExt { asker_roster, ..Default::default() }.boxed();
        let key = (state.server_id.clone(), device.to_string());
        // A newer ask replaces the open one, keeping the nonce a held join waits on.
        let nonce = nonce.or_else(|| self.asks.get(&key).and_then(|a| a.nonce));
        let asked = d.ranges.iter().map(|r| (r.0, r.1)).collect();
        let now = Instant::now();
        let msg = HavenMessage::SyncRequest {
            server_id: state.server_id.clone(),
            state_vector_json: String::new(),
            mls_epoch,
            nonce,
            full: None,
            digest: Some(d),
            x,
        };
        self.asks.insert(
            key,
            Ask {
                id, salt, round: 0, nonce, hinted: mls_epoch.is_some(), sent_at: now, round_at: now, judged: false,
                asked, last: Box::new(msg.clone()), resends: 0,
            },
        );
        msg
    }

    /// [`Self::ask`] with `base` as the base reference instead of our own base: an answerer
    /// leaves out what that checkpoint decides, and says `base_unknown` when it lacks it
    /// (`named_base`). `extra` rides along (a witness ask); our roster is added as usual.
    #[allow(dead_code)] // track C1's settling and witness rounds (INTERFACE R-C2-1)
    pub(crate) fn ask_on_base(
        &mut self,
        state: &ServerState,
        kept: &[KeptRef<'_>],
        device: &str,
        nonce: Option<u64>,
        base: &crate::crdt::operations::CrdtOp,
        extra: super::sync_ext::AskExt,
    ) -> HavenMessage {
        let mut msg = self.ask(state, kept, device, nonce, None);
        let covers = match &base.payload {
            crate::crdt::operations::CrdtPayload::ServerCheckpoint { covers, .. } => Some(covers.clone()),
            _ => None,
        };
        let bref = hex::encode(state.content_of(base));
        if let HavenMessage::SyncRequest { digest: Some(d), x, .. } = &mut msg {
            d.bref = Some(bref);
            d.base = covers;
            let mut ext = x.take().map(|b| *b).unwrap_or_default();
            ext.named_base = true;
            ext.witness = extra.witness.or(ext.witness);
            ext.floor |= extra.floor;
            ext.asker_roster = extra.asker_roster.or(ext.asker_roster);
            *x = ext.boxed();
            if let Some(ask) = self.asks.get_mut(&(state.server_id.clone(), device.to_string())) {
                *ask.last = msg.clone();
            }
        }
        msg
    }

    /// The next step for a digest answer from `device` about `state`; `epoch_now` is our
    /// MLS epoch of it.
    pub(crate) fn answered(
        &mut self,
        state: &ServerState,
        kept: &[KeptRef<'_>],
        device: &str,
        reply: &DigestReply,
        epoch_now: Option<u64>,
    ) -> Step {
        let key = (state.server_id.clone(), device.to_string());
        if !self.asks.get(&key).is_some_and(|a| a.id == reply.ask && a.round == reply.round) {
            return Step::Unasked;
        }
        if reply.vector {
            let ask = self.asks.remove(&key).expect("open");
            if !reads_vector(&state.server_id) {
                return Step::Malformed;
            }
            return Step::Again(Box::new(vector_ask(state, ask.nonce, epoch_now.filter(|_| ask.hinted))));
        }
        let wanted = self.rosters_wanted(state, &reply.rd);
        let ask = self.asks.get_mut(&key).expect("open");
        if reply.groups.is_empty() || reply.round >= digest::MAX_ROUNDS {
            let nonce = ask.nonce;
            self.asks.remove(&key);
            let identity = super::resolver::resolve(device);
            self.ended_at.insert((state.server_id.clone(), identity.clone()), Instant::now());
            self.witnesses.entry(state.server_id.clone()).or_default().insert(identity);
            if !wanted.is_empty() {
                return Step::Rosters(Box::new(roster_ask(&state.server_id, nonce, wanted)));
            }
            return Step::Done;
        }
        let Some(ranges) = digest::follow_up(&digest::entries(state, kept, None), &ask.salt, &ask.asked, reply) else {
            self.asks.remove(&key);
            return Step::Malformed;
        };
        ask.asked = ranges.iter().map(|r| (r.0, r.1)).collect();
        ask.round = reply.round + 1;
        ask.sent_at = Instant::now();
        ask.round_at = ask.sent_at;
        ask.resends = 0;
        ask.judged = false;
        // Sent even when empty: its answer is the final one a held join waits for.
        *ask.last = HavenMessage::SyncRequest {
            server_id: state.server_id.clone(),
            state_vector_json: String::new(),
            mls_epoch: None,
            nonce: ask.nonce,
            full: None,
            digest: Some(OpDigest {
                ask: ask.id,
                salt: ask.salt.clone(),
                base: state.checkpoint_hlc.clone(),
                bref: state.base.as_ref().map(|b| b.hash_hex()),
                from: None,
                ranges,
                round: ask.round,
                rs: None,
            }),
            x: super::sync_ext::AskExt { rosters_wanted: wanted, ..Default::default() }.boxed(),
        };
        Step::Again(ask.last.clone())
    }

    /// `msg` carries an op we authored on `server` before its room listed anyone for us:
    /// no receiver forwards it, so it goes to the members once the room is listed.
    pub(crate) fn carry_when_listed(&mut self, server: &str, msg: HavenMessage) {
        let kept = self.unseen.entry(server.to_string()).or_default();
        if kept.len() < UNSEEN_MAX {
            kept.push(msg);
        }
    }

    /// The ops waiting for `room`'s first listing.
    pub(crate) fn listed(&mut self, room: &str) -> Vec<HavenMessage> {
        self.unseen.remove(room).unwrap_or_default()
    }

    /// Our join of `server` completed: ask more members soon.
    pub(crate) fn joined(&mut self, server: &str) {
        if !self.follow_ups.iter().any(|(s, _)| s == server) {
            self.follow_ups.push((server.to_string(), Instant::now() + JOIN_FOLLOW_UP));
        }
    }

    /// What the silence clock does to open asks, and the servers whose post-join
    /// follow-up is due. `epoch_of` is our MLS epoch of a server now.
    pub(crate) fn tick(
        &mut self,
        now: Instant,
        lane_holds: &dyn Fn(&str) -> bool,
        epoch_of: &dyn Fn(&str) -> Option<u64>,
    ) -> (Vec<Silent>, Vec<String>) {
        let mut silent = Vec::new();
        self.asks.retain(|(server, device), ask| {
            if ask.judged {
                return now.saturating_duration_since(ask.round_at) < ASK_TTL;
            }
            // An ask still paced out, or waiting for an Olm session, has not left: its
            // silence clock has not started.
            if lane_holds(device) {
                ask.sent_at = now;
                ask.round_at = now;
                return true;
            }
            if now.saturating_duration_since(ask.sent_at) < RESEND_AFTER * (1 << ask.resends) {
                return true;
            }
            if ask.resends < RESENDS {
                ask.resends += 1;
                ask.sent_at = now;
                let mut copy = ask.last.clone();
                if let HavenMessage::SyncRequest { mls_epoch, .. } = copy.as_mut()
                    && mls_epoch.is_some()
                {
                    *mls_epoch = epoch_of(server);
                }
                silent.push(Silent::Again(server.clone(), device.clone(), copy));
                return true;
            }
            silent.push(Silent::Closed(server.clone(), device.clone()));
            ask.judged = true;
            now.saturating_duration_since(ask.round_at) < ASK_TTL
        });
        let (due, wait): (Vec<_>, Vec<_>) = self.follow_ups.drain(..).partition(|(_, at)| *at <= now);
        self.follow_ups = wait;
        (silent, due.into_iter().map(|(s, _)| s).collect())
    }

    /// The socket went away: no open ask can be answered any more.
    pub(crate) fn went_away(&mut self) {
        self.asks.clear();
        self.witnesses.clear();
        self.ended_at.clear();
        self.witness_asked.clear();
    }

    /// The member devices of `room` to ask a digest round of so that our due checkpoint
    /// on `state` can be witnessed: an owner whose members stay online is otherwise never
    /// the asker. One device per identity not heard since the socket came up and with no
    /// ask of ours open, by standing; at most one round per server per gap.
    pub(crate) fn witness_round(
        &mut self,
        state: &ServerState,
        room: Option<&std::collections::HashSet<String>>,
        us: &str,
        now: Instant,
    ) -> Vec<String> {
        let sid = &state.server_id;
        if self.witness_asked.get(sid).is_some_and(|at| now.saturating_duration_since(*at) < WITNESS_ROUND_GAP) {
            return Vec::new();
        }
        let heard = self.witnesses(sid);
        let mut devices: Vec<&String> = room
            .into_iter()
            .flatten()
            .filter(|d| state.keeps_peer(d) && !super::resolver::same_identity(d, us))
            .filter(|d| !heard.contains(&super::resolver::resolve(d)) && !self.asks.contains_key(&(sid.clone(), (*d).clone())))
            .collect();
        devices.sort();
        let masters = devices.iter().map(|d| super::resolver::resolve(d));
        let picked: Vec<String> = super::standing::rank_masters(state, masters)
            .into_iter()
            .take(WITNESS_ROUND_ASKED)
            .filter_map(|m| devices.iter().find(|d| super::resolver::resolve(d) == m).map(|d| (*d).clone()))
            .collect();
        if !picked.is_empty() {
            self.witness_asked.insert(sid.clone(), now);
        }
        picked
    }

    /// The identities whose digest round on `server` ended since the socket came up.
    pub(crate) fn witnesses(&self, server: &str) -> std::collections::HashSet<String> {
        self.witnesses.get(server).cloned().unwrap_or_default()
    }

    /// The identities whose digest round on `server` ended at or after `since`.
    pub(crate) fn ended_since(&self, server: &str, since: Instant) -> std::collections::HashSet<String> {
        self.ended_at.iter().filter(|((s, _), at)| s == server && **at >= since).map(|((_, id), _)| id.clone()).collect()
    }

    #[cfg(test)]
    pub(crate) fn open_asks(&self) -> usize {
        self.asks.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::digest::{DigestReply, Range};
    use crate::crdt::testkeys::keys;

    fn server() -> ServerState {
        let (kp, owner, pk) = keys(1);
        let (mut s, _) = ServerState::found("S".into(), owner, kp, pk);
        for i in 0..100 {
            s.author_checked(crate::crdt::operations::CrdtPayload::ServerSettingChanged { key: format!("k{i}"), value: "v".into() });
        }
        s
    }

    fn digest_of(msg: &HavenMessage) -> Option<&OpDigest> {
        match msg {
            HavenMessage::SyncRequest { digest, .. } => digest.as_ref(),
            _ => None,
        }
    }

    fn vector_of(msg: &HavenMessage) -> Option<&str> {
        match msg {
            HavenMessage::SyncRequest { digest: None, state_vector_json, .. } => Some(state_vector_json),
            _ => None,
        }
    }

    /// Writer rule a: an owner whose checkpoint waits on witnesses asks one device per
    /// member identity it has not heard, none of its own and none with an ask open, and
    /// asks again only after the gap or a new socket.
    #[test]
    fn a_witness_round_asks_each_unheard_member_once_per_gap() {
        let mut s = server();
        let us = s.current_owner().expect("the founder owns it");
        for m in ["m_a", "m_b", "m_c"] {
            s.members.insert(m.into(), crate::crdt::server_state::MemberInfo { peer_id: m.into(), display_name: m.into() });
        }
        let room: std::collections::HashSet<String> = ["m_a", "m_b", "m_c", "stranger", us.as_str()].iter().map(|d| d.to_string()).collect();
        let mut book = OpSync::default();
        let _ = book.ask(&s, &[], "m_c", None, None);
        book.witnesses.entry(s.server_id.clone()).or_default().insert("m_b".into());
        let now = Instant::now();
        assert_eq!(book.witness_round(&s, Some(&room), &us, now), vec!["m_a".to_string()]);
        assert!(book.witness_round(&s, Some(&room), &us, now + Duration::from_secs(60)).is_empty(), "one round per gap");
        book.went_away();
        let mut again = book.witness_round(&s, Some(&room), &us, now + Duration::from_secs(61));
        again.sort();
        assert_eq!(again, vec!["m_a".to_string(), "m_b".to_string(), "m_c".to_string()], "a new socket hears no one yet");
        assert!(book.witness_round(&s, None, &us, now + WITNESS_ROUND_GAP * 3).is_empty(), "no room, no round");
    }

    fn kinds(silent: &[Silent]) -> Vec<String> {
        silent
            .iter()
            .map(|s| match s {
                Silent::Again(_, d, _) => format!("again {d}"),
                Silent::Closed(_, d) => format!("closed {d}"),
            })
            .collect()
    }

    /// A silent ask goes again unchanged with a doubling wait, then closes: no device is
    /// ever sent the vector instead (t14-a).
    #[test]
    fn a_silent_ask_goes_again_then_closes_and_never_turns_into_the_vector() {
        let s = server();
        let mut book = OpSync::default();
        let t0 = Instant::now();
        let first = book.ask(&s, &[], "quiet", Some(5), Some(1));
        let _ = book.ask(&s, &[], "known", None, None);
        let (silent, _) = book.tick(t0 + RESEND_AFTER / 2, &|_| false, &|_| Some(7));
        assert!(silent.is_empty(), "an ask went again before its wait");
        let t1 = t0 + RESEND_AFTER + Duration::from_millis(50);
        let (silent, _) = book.tick(t1, &|_| false, &|_| Some(7));
        let mut k = kinds(&silent);
        k.sort();
        assert_eq!(k, ["again known", "again quiet"]);
        for step in &silent {
            if let Silent::Again(_, d, msg) = step
                && d == "quiet"
            {
                assert_eq!(digest_of(msg).map(|d| (d.ask, d.round)), digest_of(&first).map(|d| (d.ask, d.round)), "not the same ask");
                assert!(matches!(**msg, HavenMessage::SyncRequest { mls_epoch: Some(7), .. }), "the copy kept an old epoch hint");
            }
        }
        let (silent, _) = book.tick(t1 + RESEND_AFTER, &|_| false, &|_| Some(7));
        assert!(silent.is_empty(), "the second copy did not wait twice as long");
        let t2 = t1 + RESEND_AFTER * 2 + Duration::from_millis(50);
        assert_eq!(kinds(&book.tick(t2, &|_| false, &|_| Some(7)).0).len(), 2, "no second copy");
        let (silent, _) = book.tick(t2 + RESEND_AFTER * 3, &|_| false, &|_| Some(7));
        assert!(silent.is_empty(), "judged before the last copy waited four times as long");
        let (silent, _) = book.tick(t2 + RESEND_AFTER * 4 + Duration::from_millis(50), &|_| false, &|_| Some(7));
        let mut k = kinds(&silent);
        k.sort();
        assert_eq!(k, ["closed known", "closed quiet"]);
        assert_eq!(book.open_asks(), 2, "a judged ask closed before a late answer could land");
        let (silent, _) = book.tick(t0 + ASK_TTL - Duration::from_millis(50), &|_| false, &|_| Some(7));
        assert!(silent.is_empty(), "a judged ask was sent again");
        assert_eq!(book.open_asks(), 2);
        let _ = book.tick(t0 + ASK_TTL + Duration::from_millis(50), &|_| false, &|_| Some(7));
        assert_eq!(book.open_asks(), 0, "a judged ask outlived the TTL");
    }

    /// A silent device's ask closes after its copies, and an answer to an ask restarts its
    /// clock.
    #[test]
    fn a_silent_ask_closes_and_an_answer_restarts_the_clock() {
        let s = server();
        let mut book = OpSync::default();
        let t0 = Instant::now();
        let _ = book.ask(&s, &[], "slow", None, None);
        let mut silent = Vec::new();
        for i in 1..=8 {
            silent.extend(kinds(&book.tick(t0 + RESEND_AFTER * (i * 5), &|_| false, &|_| Some(7)).0));
        }
        assert_eq!(silent, ["again slow", "again slow", "closed slow"]);
        let ask = book.ask(&s, &[], "dev", None, Some(3));
        let d = digest_of(&ask).unwrap();
        let Range(lo, hi, _, _) = d.ranges[0].clone();
        let split = DigestReply { ask: d.ask, round: 0, groups: vec![vec![Range(lo, lo, 1, "x".into()), Range(lo + 1, hi, 1, "y".into())]], vector: false, rd: Vec::new() };
        let t1 = Instant::now();
        let _ = book.tick(t1 + RESEND_AFTER * 2, &|_| false, &|_| Some(7));
        let _ = book.tick(t1 + RESEND_AFTER * 5, &|_| false, &|_| Some(7));
        assert!(matches!(book.answered(&s, &[], "dev", &split, None), Step::Again(_)));
        let (silent, _) = book.tick(Instant::now() + RESEND_AFTER + Duration::from_millis(50), &|_| false, &|_| Some(7));
        match silent.as_slice() {
            [Silent::Again(_, d, msg)] if d == "dev" => {
                assert_eq!(digest_of(msg).map(|d| d.round), Some(1), "not the follow-up");
                assert!(matches!(**msg, HavenMessage::SyncRequest { mls_epoch: None, .. }), "a follow-up copy gained an epoch hint");
            }
            _ => panic!("the follow-up was not sent again: {:?}", kinds(&silent)),
        }
    }

    /// An ask still held by the pacer has not left: its clock starts once it leaves.
    #[test]
    fn a_paced_ask_starts_its_clock_when_it_leaves() {
        let s = server();
        let mut book = OpSync::default();
        let _ = book.ask(&s, &[], "paced", None, None);
        let later = Instant::now() + RESEND_AFTER * 2;
        let (silent, _) = book.tick(later, &|d| d == "paced", &|_| None);
        assert!(silent.is_empty(), "an ask still held by the pacer went again");
        let (silent, _) = book.tick(later + RESEND_AFTER, &|_| false, &|_| Some(7));
        assert_eq!(kinds(&silent), ["again paced"]);
    }

    /// A split continues only the open ask it names, in the round it names; a socket loss
    /// closes every ask.
    #[test]
    fn a_split_continues_only_its_own_open_ask() {
        let s = server();
        let mut book = OpSync::default();
        let ask = book.ask(&s, &[], "dev", Some(1), None);
        let d = digest_of(&ask).unwrap();
        let (id, Range(lo, hi, _, _)) = (d.ask, d.ranges[0].clone());
        assert!(hi > lo, "the first range spans several ms");
        let split = |ask: u64, round: u8| DigestReply {
            ask, round, groups: vec![vec![Range(lo, lo, 1, "x".into()), Range(lo + 1, hi, 1, "y".into())]], vector: false,
            rd: Vec::new(),
        };
        assert!(matches!(book.answered(&s, &[], "other", &split(id, 0), None), Step::Unasked), "another device's split");
        assert!(matches!(book.answered(&s, &[], "dev", &split(id ^ 1, 0), None), Step::Unasked), "a split for another ask");
        assert!(matches!(book.answered(&s, &[], "dev", &split(id, 3), None), Step::Unasked), "a split for another round");
        match book.answered(&s, &[], "dev", &split(id, 0), None) {
            Step::Again(next) => {
                let d = digest_of(&next).expect("a digest follow-up");
                assert_eq!((d.ask, d.round, d.from), (id, 1, None));
            }
            _ => panic!("the split was not followed"),
        }
        let done = DigestReply { ask: id, round: 1, groups: Vec::new(), vector: false, rd: Vec::new() };
        assert!(matches!(book.answered(&s, &[], "dev", &done, None), Step::Done));
        assert!(matches!(book.answered(&s, &[], "dev", &done, None), Step::Unasked), "a closed ask answered twice");
        let _ = book.ask(&s, &[], "dev", None, None);
        book.went_away();
        assert_eq!(book.open_asks(), 0);
    }

    /// A split outside what we asked, or overlapping itself, closes the ask unfollowed.
    #[test]
    fn a_malformed_split_closes_the_ask() {
        let s = server();
        let mut book = OpSync::default();
        let ask = book.ask(&s, &[], "dev", None, None);
        let d = digest_of(&ask).unwrap();
        let last = d.ranges.last().unwrap().1;
        let outside = DigestReply {
            ask: d.ask, round: 0, groups: vec![vec![Range(last + 1, last + 1, 1, "x".into()), Range(last + 2, last + 3, 1, "y".into())]], vector: false,
            rd: Vec::new(),
        };
        assert!(matches!(book.answered(&s, &[], "dev", &outside, None), Step::Malformed));
        assert_eq!(book.open_asks(), 0);
        let ask = book.ask(&s, &[], "dev", None, None);
        let d = digest_of(&ask).unwrap();
        let Range(lo, hi, _, _) = d.ranges[0].clone();
        let overlapping = DigestReply { ask: d.ask, round: 0, groups: vec![vec![Range(lo, hi, 1, "x".into()), Range(lo, hi, 1, "y".into())]], vector: false, rd: Vec::new() };
        assert!(matches!(book.answered(&s, &[], "dev", &overlapping, None), Step::Malformed));
    }

    /// A newer ask to the same device keeps the nonce a held join waits on.
    #[test]
    fn a_newer_ask_keeps_the_open_asks_nonce() {
        let s = server();
        let mut book = OpSync::default();
        let _ = book.ask(&s, &[], "dev", Some(42), None);
        match book.ask(&s, &[], "dev", None, None) {
            HavenMessage::SyncRequest { nonce, .. } => assert_eq!(nonce, Some(42)),
            _ => panic!("not a sync request"),
        }
    }

    /// A legacy-id server checkpointed here while the answerer's replica is still on the
    /// legacy anchor.
    fn checkpointed_legacy_server() -> ServerState {
        let (mut s, _) = crate::crdt::testkeys::owned_state("0123456789abcdef0123456789abcdef", "Old", 1);
        let hlc = s.name.hlc().clone();
        s.checkpoint_hlc = Some(hlc);
        assert!(reads_vector(&s.server_id) && s.anchor() == Anchor::Checkpoint);
        s
    }

    /// An answerer still on a legacy-id server's legacy anchor sends us to the vector;
    /// for a self-certifying id that answer is malformed and nothing more is asked (t14-a).
    #[test]
    fn a_vector_reply_asks_again_with_the_vector_only_for_a_legacy_id() {
        let s = checkpointed_legacy_server();
        let mut book = OpSync::default();
        let ask = book.ask(&s, &[], "dev", Some(8), Some(3));
        let id = digest_of(&ask).expect("a checkpointed replica asks with the digest").ask;
        match book.answered(&s, &[], "dev", &DigestReply { ask: id, round: 0, groups: Vec::new(), vector: true, rd: Vec::new() }, None) {
            Step::Again(next) => assert!(vector_of(&next).is_some_and(|v| !v.is_empty())),
            _ => panic!("no vector ask"),
        }

        let g = server();
        assert!(!reads_vector(&g.server_id));
        let ask = book.ask(&g, &[], "dev", Some(8), Some(3));
        let id = digest_of(&ask).unwrap().ask;
        let reply = DigestReply { ask: id, round: 0, groups: Vec::new(), vector: true, rd: Vec::new() };
        assert!(matches!(book.answered(&g, &[], "dev", &reply, None), Step::Malformed), "a self-certifying id was sent to the vector");
        assert_eq!(book.open_asks(), 0, "the ask stayed open");
    }

    /// Only a replica on the legacy anchor asks with the vector (t14-a).
    #[test]
    fn only_a_legacy_anchored_replica_asks_with_the_vector() {
        let (legacy, _) = crate::crdt::testkeys::owned_state("0123456789abcdef0123456789abcdef", "Old", 1);
        assert_eq!(legacy.anchor(), Anchor::Legacy);
        let mut book = OpSync::default();
        assert!(vector_of(&book.ask(&legacy, &[], "dev", None, None)).is_some_and(|v| !v.is_empty()));
        for s in [server(), checkpointed_legacy_server()] {
            let ask = book.ask(&s, &[], "dev", None, None);
            assert!(digest_of(&ask).is_some(), "an anchored replica asked without the digest");
            assert!(matches!(&ask, HavenMessage::SyncRequest { state_vector_json, .. } if state_vector_json.is_empty()));
        }
    }

    // ---- review (g13w2-g-sync-fallback) ----

    /// A vector reply to a copy re-asks with our epoch now, like the copy it answers.
    #[test]
    fn review_vector_reply_to_a_copy_carries_no_older_epoch_than_the_copy() {
        let s = checkpointed_legacy_server();
        let mut book = OpSync::default();
        let t0 = Instant::now();
        let ask = book.ask(&s, &[], "dev", Some(8), Some(1));
        let id = digest_of(&ask).unwrap().ask;
        let _ = book.tick(t0 + RESEND_AFTER + Duration::from_millis(50), &|_| false, &|_| Some(7));
        match book.answered(&s, &[], "dev", &DigestReply { ask: id, round: 0, groups: Vec::new(), vector: true, rd: Vec::new() }, Some(7)) {
            Step::Again(next) => assert!(
                matches!(*next, HavenMessage::SyncRequest { mls_epoch: Some(7), .. }),
                "the vector re-ask names the first ask's epoch, older than the copy it answers"
            ),
            _ => panic!("no vector ask"),
        }
    }

    /// A known digest device's split that lands after the verdict but inside the 60 s the
    /// ask used to stay open is still followed.
    #[test]
    fn review_a_late_split_inside_the_old_ttl_is_still_followed() {
        let s = server();
        let mut book = OpSync::default();
        let t0 = Instant::now();
        let ask = book.ask(&s, &[], "dev", None, None);
        let d = digest_of(&ask).unwrap();
        let Range(lo, hi, _, _) = d.ranges[0].clone();
        let split = DigestReply { ask: d.ask, round: 0, groups: vec![vec![Range(lo, lo, 1, "x".into()), Range(lo + 1, hi, 1, "y".into())]], vector: false, rd: Vec::new() };
        let mut verdict = Vec::new();
        for i in 1..=8u32 {
            verdict.extend(kinds(&book.tick(t0 + RESEND_AFTER * (i * 2), &|_| false, &|_| None).0));
        }
        assert_eq!(verdict, ["again dev", "again dev", "closed dev"]);
        assert!(matches!(book.answered(&s, &[], "dev", &split, None), Step::Again(_)), "a split 40 s after the ask was dropped as unasked");
    }

    /// M4 (8.2 step 1): a retire's round counts only identities whose digest round
    /// ended at or after it started, never one that ended before.
    #[test]
    fn a_round_hears_only_identities_that_ended_after_it_started() {
        let mut sync = OpSync::default();
        let t0 = Instant::now();
        sync.ended_at.insert(("s".into(), "early".into()), t0);
        let since = t0 + std::time::Duration::from_secs(1);
        sync.ended_at.insert(("s".into(), "late".into()), since);
        sync.ended_at.insert(("other".into(), "late".into()), since);
        let heard = sync.ended_since("s", since);
        assert_eq!(heard, ["late".to_string()].into_iter().collect(), "an earlier round and another server never count");
    }

}
