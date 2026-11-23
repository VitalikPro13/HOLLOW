//! An op's verdict under the replica's authority view, and the ranks it gives copies and
//! variants of one op (DEVICE_PROOF_DESIGN sections 3, 6 and 7).

use std::cmp::Reverse;

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use super::authority::{AuthorityView, Verdict, ViewEntry};
use super::operations::{CrdtOp, CrdtPayload, Endorsement, OpRef, MAX_ENDORSED_REFS};
use super::server_state::ServerState;

/// What fills a state's view: the node's own store (`node::authority_view::source`).
/// Called for an identity the view has no entry for; never the process-global resolver.
#[derive(Clone)]
/// `None` = the store could not be read: nothing is cached and the next fill asks again.
pub(crate) struct ViewSource(pub(crate) Arc<ViewFill>);

pub(crate) type ViewFill = dyn Fn(&ServerState, &str) -> Option<ViewEntry> + Send + Sync;

impl std::fmt::Debug for ViewSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ViewSource")
    }
}

/// The ops held `DeviceRetired`s name (section 8.2), each from a retire whose own proof
/// is directly `Counted`: (author, ms, counter) -> (retired device, content id hex).
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(crate) struct Endorsed(std::collections::HashMap<(String, u64, u32), Vec<(String, String)>>);

/// Lower ranks first: the better verdict, then (for variants) the lower content id, then
/// the lower proving device.
pub(crate) type CopyRank<'a> = (Reverse<u8>, [u8; 32], &'a str);

impl ServerState {
    /// Judge from now on with entries `source` fills: every identity it has not filled
    /// yet reads `Missing` until it is.
    pub(crate) fn set_view_source(&mut self, source: ViewSource) {
        self.view_source = Some(source);
        if !self.authority.is_set() {
            self.authority = Arc::new(AuthorityView::judging());
        }
    }

    /// Fill the view for the anchor owner and `extra`'s authors where it lacks them. The
    /// rest of the authority set is filled already: every op entered through here, and a
    /// rebuild judges the whole set again (`refresh_view`).
    pub(crate) fn fill_view<'a>(&mut self, extra: impl IntoIterator<Item = &'a CrdtOp>) {
        let Some(source) = self.view_source.clone() else { return };
        let mut want: std::collections::BTreeSet<String> = self.anchor_owner().into_iter().collect();
        want.extend(extra.into_iter().map(|o| o.author.clone()));
        let missing: Vec<String> = want.into_iter().filter(|m| self.authority.entry(m).is_none()).collect();
        if missing.is_empty() {
            return;
        }
        let entries: Vec<(String, ViewEntry)> = missing.into_iter().filter_map(|m| (source.0)(self, &m).map(|e| (self.round_entry(&m, e), m)).map(|(e, m)| (m, e))).collect();
        let view = Arc::make_mut(&mut self.authority);
        for (m, e) in entries {
            view.insert(m, e);
        }
    }

    /// Judge every identity of the authority set again from the source and forget the
    /// rest: a cached `Missing` never outlives a rebuild, and the view never outgrows
    /// what this replica holds. An identity the store cannot be read for keeps its entry.
    pub(crate) fn refresh_view(&mut self) {
        let Some(source) = self.view_source.clone() else { return };
        let mut view = AuthorityView::judging();
        for m in super::authority::authority_set(self) {
            if let Some(e) = (source.0)(self, &m).map(|e| self.round_entry(&m, e)).or_else(|| self.authority.entry(&m).cloned()) {
                view.insert(m, e);
            }
        }
        if *self.authority != view {
            self.authority = Arc::new(view);
        }
    }

    /// Judge `master` again from the source; true when its entry changed (the fold must
    /// run again).
    pub(crate) fn refresh_view_of(&mut self, master: &str) -> bool {
        let Some(source) = self.view_source.clone() else { return false };
        let Some(old) = self.authority.entry(master).cloned() else { return false };
        let Some(new) = (source.0)(self, master).map(|e| self.round_entry(master, e)) else { return false };
        if new == old {
            return false;
        }
        Arc::make_mut(&mut self.authority).insert(master.to_string(), new);
        true
    }

    /// The op's verdict: the view's word on the device its proof names. A stored copy
    /// only ever carries a proof that verifies (`strip_bad_proof` at the door). Until the
    /// node sets the view every op counts (section 11's seam); the node sets it on every
    /// state it holds (`node::authority_view`).
    pub(crate) fn verdict(&self, op: &CrdtOp) -> Verdict {
        match self.direct_verdict(op) {
            Verdict::Uncounted | Verdict::Missing if self.is_endorsed(op) => Verdict::Counted,
            // Part A (HOL-SEC-230, -231): what the fold held when the view dropped its
            // device keeps counting here until the recovery decides it.
            Verdict::Uncounted if self.recovery.as_ref().is_some_and(|r| r.keeps(op)) => Verdict::Counted,
            v => v,
        }
    }

    /// The verdict from the view alone: what a retire's own verdict is (an endorsement
    /// is direct only).
    pub(super) fn direct_verdict(&self, op: &CrdtOp) -> Verdict {
        if !self.authority.is_set() {
            return Verdict::Counted;
        }
        let Some(dev) = op.dev.as_deref() else { return Verdict::ProofLess };
        self.authority.device_verdict(&op.author, &dev.device).into()
    }

    /// A held retire names `op` (clock, content id) as written by its proving device.
    /// The id is `op`'s own, never `content_of`'s: that reads the op held at the key, so a
    /// variant there would pass as the op the retire named (HOL-SEC-224).
    pub(super) fn is_endorsed(&self, op: &CrdtOp) -> bool {
        let Some(dev) = op.dev.as_deref() else { return false };
        let Some(named) = self.endorsed.0.get(&(op.author.clone(), op.hlc.physical_ms, op.hlc.counter)) else { return false };
        let h = hex::encode(op.content_hash());
        named.iter().any(|(d, x)| *d == dev.device && *x == h)
    }

    /// The endorsements of every retire among `ops` whose own verdict is directly
    /// `Counted`. A member's lost-or-stolen retire endorses the ops it names (folded here
    /// before T, section 8.3); its restore point makes nothing eligible.
    pub(crate) fn endorsements<'a>(&self, ops: impl IntoIterator<Item = &'a CrdtOp>) -> Endorsed {
        let mut out = Endorsed::default();
        for op in ops {
            let CrdtPayload::DeviceRetired { device, ops: refs, .. } = &op.payload else { continue };
            if self.direct_verdict(op) != Verdict::Counted {
                continue;
            }
            for r in refs {
                out.0.entry((op.author.clone(), r.ms, r.c)).or_default().push((device.clone(), r.h.clone()));
            }
        }
        out
    }

    /// The base's carried endorsements whose signer this view counts (section 10, step 6),
    /// added to those of the held retires once the base is chosen.
    pub(crate) fn endorse_from_base(&mut self) {
        let Some(base) = self.base.as_ref() else { return };
        let mut endorsed = (*self.endorsed).clone();
        // A floor-only base was written by the dropped device: its owner entries wait for
        // the settling (section 8.8 item 6).
        let owner = self.floor_base.then(|| self.anchor_owner()).flatten();
        for e in base.state.cp_endorsed.iter().filter(|e| self.authority.counts(&e.author, &e.by) && owner.as_deref() != Some(e.author.as_str())) {
            for r in &e.refs {
                endorsed.0.entry((e.author.clone(), r.ms, r.c)).or_default().push((e.device.clone(), r.h.clone()));
            }
        }
        if *self.endorsed != endorsed {
            self.endorsed = Arc::new(endorsed);
        }
    }

    /// The retires a remover publishes for `device` (section 8.2, step 2): every op of
    /// `me`'s that `device` proved and this replica folded, the base and its parent
    /// included, in chunks of `MAX_RETIRED_REFS` sorted refs. Parked, held and unread ops
    /// are never named, nor ops a counted retire of `me`'s for `device` held here already
    /// names (a round that mints again names only what it gained).
    /// `posts_until` = the newest date of `device`'s posts here (section 13), carried by
    /// every chunk, and alone in one when it moved past what our retires hold.
    pub(crate) fn retire_payloads(&self, me: &str, device: &str, posts_until: Option<i64>) -> Vec<CrdtPayload> {
        let parent = self.stored.iter().filter(|(_, k)| matches!(k, super::fold::RowKind::Parent)).map(|(o, _)| o);
        let held = self.op_log.iter().chain(self.stored.iter().map(|(o, _)| o)).chain(self.held.iter().map(|(o, _)| o));
        let ours: Vec<(&Vec<OpRef>, Option<i64>)> = held
            .filter(|o| o.author == me && self.direct_verdict(o) == Verdict::Counted)
            .filter_map(|o| match &o.payload {
                CrdtPayload::DeviceRetired { device: d, ops, posts_until_ms, .. } if d == device => Some((ops, *posts_until_ms)),
                _ => None,
            })
            .collect();
        let window_held = ours.iter().filter_map(|(_, p)| *p).max();
        let named: HashSet<&OpRef> = ours.iter().flat_map(|(ops, _)| ops.iter()).collect();
        let mut refs: Vec<OpRef> = self
            .op_log
            .iter()
            .chain(parent)
            .filter(|o| o.author == me && o.dev.as_deref().is_some_and(|d| d.device == device))
            .filter(|o| !matches!(o.payload, CrdtPayload::DeviceRetired { .. }))
            .map(|o| OpRef { ms: o.hlc.physical_ms, c: o.hlc.counter, h: hex::encode(self.content_of(o)) })
            .filter(|r| !named.contains(r))
            .collect();
        refs.sort();
        refs.dedup();
        let posts_until_ms = posts_until.or(window_held);
        let mut out: Vec<CrdtPayload> = refs
            .chunks(super::operations::MAX_RETIRED_REFS)
            .map(|c| CrdtPayload::DeviceRetired { device: device.to_string(), ops: c.to_vec(), posts_until_ms, restore: None })
            .collect();
        if out.is_empty() && posts_until.is_some_and(|p| window_held.is_none_or(|h| p > h)) {
            out.push(CrdtPayload::DeviceRetired { device: device.to_string(), ops: Vec::new(), posts_until_ms, restore: None });
        }
        out
    }

    /// What a new checkpoint carries (section 8.2): the retires folded since the base
    /// (`cp_retired`), and the endorsements by rules 1 to 3 (inherit the base's, add every
    /// held retire that counts directly and the base does not carry, keep only signers this
    /// view counts), each without the refs this checkpoint decides, newest
    /// `MAX_ENDORSED_REFS` refs kept.
    pub(crate) fn carried_retires(&self) -> (Vec<String>, Vec<Endorsement>) {
        let retire = |o: &&CrdtOp| matches!(o.payload, CrdtPayload::DeviceRetired { .. });
        let mut retired: Vec<String> = self.op_log.iter().filter(retire).map(|o| hex::encode(self.content_of(o))).collect();
        retired.sort_unstable();
        retired.dedup();
        let decided: HashSet<(u64, u32, String)> =
            self.op_log.iter().map(|o| (o.hlc.physical_ms, o.hlc.counter, hex::encode(self.content_of(o)))).collect();
        let open = |refs: &[OpRef]| -> Vec<OpRef> {
            refs.iter().filter(|r| !decided.contains(&(r.ms, r.c, r.h.clone()))).cloned().collect()
        };
        let mut out: Vec<Endorsement> = Vec::new();
        if let Some(base) = &self.base {
            out.extend(base.state.cp_endorsed.iter().map(|e| Endorsement { refs: open(&e.refs), ..e.clone() }));
        }
        let held = self.op_log.iter().chain(self.stored.iter().map(|(o, _)| o)).chain(self.held.iter().map(|(o, _)| o));
        for op in held.filter(retire) {
            let CrdtPayload::DeviceRetired { device, ops: refs, .. } = &op.payload else { continue };
            let Some(dev) = op.dev.as_deref() else { continue };
            let dr = hex::encode(self.content_of(op));
            if self.direct_verdict(op) != Verdict::Counted || out.iter().any(|e| e.dr == dr) {
                continue;
            }
            out.push(Endorsement { dr, author: op.author.clone(), by: dev.device.clone(), device: device.clone(), refs: open(refs) });
        }
        out.retain(|e| !e.refs.is_empty() && self.authority.counts(&e.author, &e.by));
        let mut clocks: Vec<(u64, u32)> = out.iter().flat_map(|e| e.refs.iter().map(|r| (r.ms, r.c))).collect();
        if clocks.len() > MAX_ENDORSED_REFS {
            clocks.sort_unstable_by(|a, b| b.cmp(a));
            let floor = clocks[MAX_ENDORSED_REFS - 1];
            let mut room = MAX_ENDORSED_REFS - clocks[..MAX_ENDORSED_REFS].iter().filter(|c| **c > floor).count();
            for e in &mut out {
                e.refs.retain(|r| {
                    let c = (r.ms, r.c);
                    if c > floor {
                        return true;
                    }
                    let keep = c == floor && room > 0;
                    room -= usize::from(keep);
                    keep
                });
            }
            out.retain(|e| !e.refs.is_empty());
        }
        out.sort_by(|a, b| a.dr.cmp(&b.dr));
        (retired, out)
    }

    /// Section 13: the post windows this replica reads, (author, device) -> until_ms, as
    /// its next checkpoint would carry them.
    pub(crate) fn post_windows(&self) -> HashMap<(String, String), i64> {
        self.carried_posts_until().into_iter().map(|p| ((p.author, p.device), p.until_ms)).collect()
    }

    /// Section 13: whether a channel post of `master` dated `ts_ms` may enter, `device`
    /// being the device its proof verifies for. Nothing is judged before the cut; after
    /// it a device the view counts, a post window at or past the date (a recovering
    /// owner's own windows are not read while a floor holds), or a date before the
    /// lineage's cut clock.
    pub(crate) fn post_allowed(&self, master: &str, device: Option<&str>, ts_ms: i64) -> bool {
        self.post_gate().allows(master, device, ts_ms)
    }

    /// Section 13's gate for a run of posts (a page, one live post): what it reads is
    /// read once, and only when a post needs it.
    pub(crate) fn post_gate(&self) -> PostGate<'_> {
        PostGate { state: self, windows: std::cell::OnceCell::new(), looked_up: std::cell::RefCell::new(HashMap::new()) }
    }

    /// `master`'s entry as the view's source judges it, for an identity outside the
    /// authority set: posts come from every member, not only from authors of held ops.
    fn looked_up_entry(&self, master: &str) -> Option<ViewEntry> {
        let source = self.view_source.as_ref()?;
        (source.0)(self, master).map(|e| self.round_entry(master, e))
    }
}

/// [`ServerState::post_gate`].
pub(crate) struct PostGate<'a> {
    state: &'a ServerState,
    windows: std::cell::OnceCell<HashMap<(String, String), i64>>,
    looked_up: std::cell::RefCell<HashMap<String, Option<ViewEntry>>>,
}

impl PostGate<'_> {
    /// [`ServerState::post_allowed`].
    pub(crate) fn allows(&self, master: &str, device: Option<&str>, ts_ms: i64) -> bool {
        let s = self.state;
        if !s.cut {
            return true;
        }
        if let Some(d) = device {
            if self.counts(master, d) {
                return true;
            }
            let own_floor = s.floor_holds() && s.current_owner().as_deref() == Some(master);
            if !own_floor && self.windows.get_or_init(|| s.post_windows()).get(&(master.to_string(), d.to_string())).is_some_and(|until| *until >= ts_ms) {
                return true;
            }
        }
        s.base
            .as_ref()
            .filter(|b| b.state.cp_stamped)
            .map(|b| b.state.cp_cut.as_ref().unwrap_or(&b.hlc).physical_ms)
            .is_some_and(|cut| ts_ms < i64::try_from(cut).unwrap_or(i64::MAX))
    }

    /// The view's word on `device`, filled from its source for a member the view holds
    /// no entry for (a quiet member, or one whose ops a checkpoint compacted).
    fn counts(&self, master: &str, device: &str) -> bool {
        let view = &self.state.authority;
        if !view.is_set() || view.entry(master).is_some() {
            return view.counts(master, device);
        }
        let mut looked_up = self.looked_up.borrow_mut();
        let entry = looked_up.entry(master.to_string()).or_insert_with(|| self.state.looked_up_entry(master));
        entry.as_ref().and_then(|e| e.auth.as_ref()).is_some_and(|a| a.counts(device))
    }

    /// A refusal of `master`'s post or change in `channel` proven by `device`: when the
    /// view holds no roster of that member (`Missing`), the node asks for it, so a later
    /// catch-up can take it. No proof, or one by the bare master id, no roster can count.
    pub(crate) fn refused(&self, master: &str, device: Option<&str>, channel: &str) {
        let s = self.state;
        let view = &s.authority;
        if !view.is_set() || device.is_none_or(|d| d == master) || !s.is_member(master) {
            return;
        }
        let missing = match view.entry(master) {
            Some(e) => e.auth.is_none(),
            None => {
                let mut looked_up = self.looked_up.borrow_mut();
                looked_up.entry(master.to_string()).or_insert_with(|| s.looked_up_entry(master)).as_ref().is_none_or(|e| e.auth.is_none())
            }
        };
        if !missing {
            return;
        }
        let mut wanted = s.post_rosters_wanted.lock().unwrap_or_else(|e| e.into_inner());
        if wanted.len() < MAX_POST_ROSTERS_WANTED {
            wanted.insert((master.to_string(), channel.to_string()));
        }
    }
}

/// (member, channel) pairs a server's post gate queues for roster asks between two drains.
pub(crate) const MAX_POST_ROSTERS_WANTED: usize = 64;

impl ServerState {
    /// The (member, channel) pairs [`PostGate::refused`] queued since the last call.
    pub(crate) fn take_post_rosters_wanted(&self) -> std::collections::BTreeSet<(String, String)> {
        std::mem::take(&mut *self.post_rosters_wanted.lock().unwrap_or_else(|e| e.into_inner()))
    }
}

impl ServerState {

    /// What a new checkpoint carries as `cp_posts_until` (section 8.2 rules 1 to 3): the
    /// base's windows and every held directly counted retire's, the newest per (author,
    /// device), only those whose signer this view counts; at most
    /// `MAX_POSTS_UNTIL_PER_AUTHOR` per author and `MAX_POSTS_UNTIL` in all, the smallest
    /// windows going first.
    pub(crate) fn carried_posts_until(&self) -> Vec<super::operations::PostsUntil> {
        use super::operations::{PostsUntil, MAX_POSTS_UNTIL, MAX_POSTS_UNTIL_PER_AUTHOR};
        let mut all: Vec<PostsUntil> = self.base.iter().flat_map(|b| b.state.cp_posts_until.iter().cloned()).collect();
        let held = self.op_log.iter().chain(self.stored.iter().map(|(o, _)| o)).chain(self.held.iter().map(|(o, _)| o));
        for op in held {
            let CrdtPayload::DeviceRetired { device, posts_until_ms: Some(until_ms), .. } = &op.payload else { continue };
            let Some(dev) = op.dev.as_deref() else { continue };
            if self.direct_verdict(op) == Verdict::Counted {
                all.push(PostsUntil { author: op.author.clone(), device: device.clone(), until_ms: *until_ms, dr: hex::encode(self.content_of(op)), by: dev.device.clone() });
            }
        }
        all.retain(|p| self.authority.counts(&p.author, &p.by));
        all.sort_by(|a, b| (&a.author, &a.device, std::cmp::Reverse(a.until_ms), &a.dr).cmp(&(&b.author, &b.device, std::cmp::Reverse(b.until_ms), &b.dr)));
        all.dedup_by(|a, b| a.author == b.author && a.device == b.device);
        let mut per_author: std::collections::HashMap<String, Vec<PostsUntil>> = std::collections::HashMap::new();
        for p in all {
            per_author.entry(p.author.clone()).or_default().push(p);
        }
        let mut out: Vec<PostsUntil> = Vec::new();
        for (_, mut v) in per_author {
            v.sort_by_key(|p| std::cmp::Reverse(p.until_ms));
            v.truncate(MAX_POSTS_UNTIL_PER_AUTHOR);
            out.extend(v);
        }
        out.sort_by(|a, b| b.until_ms.cmp(&a.until_ms).then_with(|| (&a.author, &a.device).cmp(&(&b.author, &b.device))));
        out.truncate(MAX_POSTS_UNTIL);
        out.sort_by(|a, b| (&a.author, &a.device).cmp(&(&b.author, &b.device)));
        out
    }

    /// Whether `device` appears in `author`'s statements here (counted or removed); with
    /// no statements held, the device clause decides instead.
    pub(crate) fn states_device(&self, author: &str, device: &str) -> bool {
        if !self.authority.is_set() {
            return true;
        }
        self.authority
            .entry(author)
            .and_then(|e| e.auth.as_ref())
            .is_none_or(|a| a.counted.contains(device) || a.removed.contains_key(device))
    }

    /// Section 7's one rule: after the cut only a `Counted` op folds. The founding op is
    /// the anchor its id proves, and a checkpoint is judged by eligibility instead.
    pub(crate) fn device_counts_here(&self, op: &CrdtOp) -> bool {
        !self.cut || clause_exempt(op) || (self.verdict(op) == Verdict::Counted && self.lock_maker_counts(op))
    }

    /// Whether the fold still holds an owner op that `view` (a fresh read of the stored
    /// rosters) no longer counts and neither a retire nor the hold keeps: a roster saved
    /// since the last rebuild, which the next one takes (`ViewDirty`). What a witness
    /// names waits for that rebuild, else it names none where part A will hold a record.
    pub(crate) fn fold_lags(&self, view: &super::authority::AuthorityView) -> bool {
        let Some(owner) = self.anchor_owner() else { return false };
        let Some(entry) = view.entry(&owner).cloned().filter(|_| self.cut && view.is_set()) else { return false };
        let entry = self.round_entry(&owner, entry);
        let Some(auth) = entry.auth.as_ref() else { return false };
        self.op_log.iter().any(|o| {
            o.author == owner
                && !clause_exempt(o)
                && o.dev.as_deref().is_some_and(|d| !auth.counts(&d.device))
                && !self.is_endorsed(o)
                && !self.recovery.as_ref().is_some_and(|r| r.keeps(o))
        })
    }

    /// A new join lock link counts only from a device the view counts (t14-lock R3).
    fn lock_maker_counts(&self, op: &CrdtOp) -> bool {
        let CrdtPayload::JoinLock { link, .. } = &op.payload else { return true };
        self.anchor_owner()
            .is_some_and(|owner| self.join_lock.link_allowed(&self.server_id, link, &owner, &|m: &str, d: &str| self.authority.counts(m, d)))
    }

    /// Whether the device clause under `cut` refuses `op` for a reason a roster can end
    /// (`Missing` or `Uncounted`), so its author's roster is wanted (section 9).
    pub(crate) fn wants_roster(&self, op: &CrdtOp, cut: bool) -> bool {
        cut && !clause_exempt(op) && matches!(self.verdict(op), Verdict::Missing | Verdict::Uncounted)
    }

    /// A refusal by the device clause alone: `Some(true)` parks the op (the rules admit it
    /// and its author has a membership span), `Some(false)` drops it unstored.
    pub(crate) fn device_refusal(&self, op: &CrdtOp) -> Option<bool> {
        if self.device_counts_here(op) {
            return None;
        }
        Some(self.member_record.contains_key(&op.author) && self.op_allowed_by_rules(op))
    }

    /// H3's carve-out (lead decision 11-05): an op the rules refuse too is kept as the
    /// core keeps a refused op when a roster can still end the refusal: its device reads
    /// `Missing` or `Uncounted`, its author is known, and either `skipped` (an op that
    /// could admit others waits for a roster before it) or it admits us (the re-ask).
    pub(crate) fn refusal_may_end(&self, op: &CrdtOp, skipped: bool) -> bool {
        self.wants_roster(op, self.cut) && self.known_author(op) && (skipped || self.names_our_admission(op))
    }

    /// An op the device clause refuses for a reason a roster can end, and whose folding
    /// could admit others: a later rules refusal may rest on it.
    pub(crate) fn skipped_for_a_roster(&self, op: &CrdtOp) -> bool {
        super::fold::enables_others(&op.payload) && self.wants_roster(op, self.cut)
    }

    /// Whether any parked row or held op was skipped for a roster (the tail's `skipped`).
    pub(crate) fn holds_skipped(&self) -> bool {
        let parked = self.stored.iter().filter(|(_, k)| matches!(k, super::fold::RowKind::Parked(_))).map(|(o, _)| o);
        parked.chain(self.held.iter().map(|(o, _)| o)).any(|o| self.skipped_for_a_roster(o))
    }

    /// Where `op` (content id `hash`) ranks among the copies and variants at its key.
    pub(crate) fn copy_rank<'a>(&self, op: &'a CrdtOp, hash: [u8; 32]) -> CopyRank<'a> {
        let device = op.dev.as_deref().map_or("~", |d| d.device.as_str());
        (Reverse(self.verdict(op).rank()), hash, device)
    }

    /// The held copy at `op`'s key (folded, stored or held), to give it a better proof.
    pub(super) fn held_copy_mut(&mut self, op: &CrdtOp) -> Option<&mut CrdtOp> {
        let key = super::server_state::fold_key(op);
        let at = self.op_log.binary_search_by(|o| super::server_state::fold_key(o).cmp(&key)).ok();
        let at = at.filter(|&i| self.op_log[i].author == op.author).or_else(|| {
            self.op_log.iter().position(|o| o.author == op.author && o.hlc == op.hlc)
        });
        if let Some(i) = at {
            return Some(&mut self.op_log[i]);
        }
        if let Some(i) = self.stored.iter().position(|(o, _)| o.author == op.author && o.hlc == op.hlc) {
            return Some(&mut self.stored[i].0);
        }
        self.held.iter_mut().find(|(o, _)| o.author == op.author && o.hlc == op.hlc).map(|(o, _)| o)
    }
}

fn clause_exempt(op: &CrdtOp) -> bool {
    matches!(op.payload, CrdtPayload::ServerCreated { .. } | CrdtPayload::ServerCheckpoint { .. })
}

#[cfg(test)]
pub(crate) mod tests {
    use std::sync::Arc;

    use super::super::authority::{self, AuthorityView, DeviceVerdict, KeyRule, ViewEntry};
    use super::super::operations::{CrdtOp, CrdtPayload as P};
    use super::super::server_state::{Founder, ServerState};
    use super::super::testkeys::keys;
    use super::*;
    use crate::identity::native_identity::NativeKeypair;
    use crate::identity::roster::Roster;

    const OWNER: u8 = 1;
    const PHONE: u8 = 2;
    const RECOVERY: u8 = 3;
    const THIEF: u8 = 4;

    /// A server founded by OWNER's master on its PHONE device, every op device-proven.
    fn founded() -> (ServerState, CrdtOp) {
        let (master, id, pk) = keys(OWNER);
        let (phone, phone_id, _) = keys(PHONE);
        ServerState::found_on("s".into(), id, Founder { device_peer_id: &phone_id, device: Some(&phone), r_pub: None }, master, pk)
    }

    fn roster_counting(device: &NativeKeypair) -> Roster {
        Roster::genesis(&keys(OWNER).0, &keys(RECOVERY).0, device, 1_000)
    }

    fn view_of(rosters: &[Roster]) -> Arc<AuthorityView> {
        let mut v = AuthorityView::judging();
        let refs: Vec<&Roster> = rosters.iter().collect();
        v.insert(keys(OWNER).1, authority::judge(&keys(OWNER).1, &KeyRule::FirstHeld, &refs));
        Arc::new(v)
    }

    #[test]
    fn a_device_proof_verifies_only_under_its_key_and_in_its_lane() {
        let (mut s, founding) = founded();
        assert_eq!(founding.proven_device(), Some(keys(PHONE).1.as_str()), "the founder's device proves the founding op");
        let op = s.create_op(P::ServerRenamed { new_name: "n".into() });
        assert!(op.proven_device().is_some());

        let mut other_key = op.clone();
        other_key.dev.as_mut().unwrap().device = keys(THIEF).1;
        assert_eq!(other_key.proven_device(), None, "the signature checks under the key the id derives");

        let mut moved = op.clone();
        moved.payload = P::ServerRenamed { new_name: "m".into() };
        assert_eq!(moved.proven_device(), None, "the proof covers the master-signed payload");

        let mut lane = op.clone();
        lane.hlc.counter += 1;
        lane.sign(&keys(OWNER).0, &keys(OWNER).2);
        lane.sign_device(&keys(PHONE).0);
        assert_eq!(lane.proven_device(), None, "a clock outside the device's lane fails the proof");

        let mut stripped = other_key.clone();
        stripped.strip_bad_proof();
        assert!(stripped.dev.is_none(), "a failing proof reads as none");
        assert_eq!(stripped.content_hash(), op.content_hash(), "the content id ignores the proof");
    }

    #[test]
    fn a_proof_survives_the_tolerant_read() {
        let (mut s, _) = founded();
        let op = s.create_op(P::ServerRenamed { new_name: "n".into() });
        let json = serde_json::to_string(&op).unwrap();
        let super::super::operations::ReadOp::Op(read) = super::super::operations::read_op(&json) else { panic!("an op") };
        assert_eq!(read.proven_device(), op.proven_device());
    }

    #[test]
    fn the_view_counts_only_what_the_owners_statements_count() {
        let unset = AuthorityView::default();
        assert_eq!(unset.device_verdict("m", "d"), DeviceVerdict::Counted, "an unset view is the seam's no-op");
        let v = view_of(&[roster_counting(&keys(PHONE).0)]);
        assert_eq!(v.device_verdict(&keys(OWNER).1, &keys(PHONE).1), DeviceVerdict::Counted);
        assert_eq!(v.device_verdict(&keys(OWNER).1, &keys(THIEF).1), DeviceVerdict::Uncounted);
        assert_eq!(v.device_verdict(&keys(OWNER).1, &keys(OWNER).1), DeviceVerdict::Uncounted, "the bare master is no device");
        assert_eq!(v.device_verdict("nobody", &keys(PHONE).1), DeviceVerdict::Missing);
        let none = view_of(&[]);
        assert_eq!(none.device_verdict(&keys(OWNER).1, &keys(PHONE).1), DeviceVerdict::Missing);
    }

    #[test]
    fn a_committing_nonce_picks_its_key_over_a_forged_one_seen_first() {
        let (master, id, pk) = keys(OWNER);
        let (phone, phone_id, _) = keys(PHONE);
        let honest = roster_counting(&phone);
        let (s, _) = ServerState::found_on(
            "s".into(), id.clone(), Founder { device_peer_id: &phone_id, device: Some(&phone), r_pub: Some(&honest.r_pub) }, master, pk,
        );
        assert!(super::super::anchor::is_genesis_id(&s.server_id));
        let rule = authority::key_rule(&s, &id);
        assert!(matches!(rule, KeyRule::Commit(_)), "the owner of a 0.14 server is judged by the committed key");
        let forged = Roster::genesis(&keys(OWNER).0, &keys(THIEF).0, &keys(THIEF).0, 1_000);
        let entry = authority::judge(&id, &rule, &[&forged, &honest]);
        assert_eq!(entry.key.as_deref(), Some(honest.r_pub.as_str()));
        assert!(entry.auth.unwrap().counts(&phone_id));
        let only_forged = authority::judge(&id, &rule, &[&forged]);
        assert_eq!(only_forged, ViewEntry { key: None, auth: None }, "no statements under the committed key: Missing");
        assert_eq!(authority::key_rule(&s, &keys(THIEF).1), KeyRule::FirstHeld, "a member is judged by the first key held");
    }

    #[test]
    fn a_better_proof_replaces_the_held_copy_and_its_row() {
        let (mut owner, founding) = founded();
        let op = owner.create_op(P::ServerRenamed { new_name: "n".into() });
        let mut bare = op.clone();
        bare.dev = None;
        let mut member = ServerState::skeleton(owner.server_id.clone());
        member.ingest_remote(&[founding.clone(), bare]);
        assert!(member.op_log.iter().any(|o| o.hlc == op.hlc && o.dev.is_none()));

        let again = member.ingest_remote(std::slice::from_ref(&op));
        assert!(again.rows.iter().any(|(o, _)| o.hlc == op.hlc && o.dev.is_some()), "the row is rewritten with the proof");
        assert!(member.op_log.iter().any(|o| o.hlc == op.hlc && o.dev.is_some()), "and the folded copy carries it");

        let mut worse = op.clone();
        worse.dev = None;
        let after = member.ingest_remote(&[worse]);
        assert!(after.rows.is_empty(), "a worse copy writes nothing");
        assert!(member.op_log.iter().any(|o| o.hlc == op.hlc && o.dev.is_some()), "and never replaces a better one");
    }

    #[test]
    fn copies_rank_counted_then_uncounted_or_missing_then_proof_less() {
        let (mut owner, _) = founded();
        let op = owner.create_op(P::ServerRenamed { new_name: "n".into() });
        let h = op.content_hash();
        let mut bare = op.clone();
        bare.dev = None;
        let mut s = ServerState::skeleton(owner.server_id.clone());
        s.authority = view_of(&[roster_counting(&keys(PHONE).0)]);
        let counted = s.copy_rank(&op, h);
        s.authority = view_of(&[roster_counting(&keys(THIEF).0)]);
        let uncounted = s.copy_rank(&op, h);
        s.authority = view_of(&[]);
        let missing = s.copy_rank(&op, h);
        let proof_less = s.copy_rank(&bare, h);
        assert!(counted < uncounted && uncounted == missing && missing < proof_less);
        assert_eq!(s.verdict(&bare), Verdict::ProofLess);
    }

    #[test]
    fn equivocation_keeps_the_counted_variant_before_the_lowest_hash() {
        let (mut owner, founding) = founded();
        let a = owner.create_op(P::ServerRenamed { new_name: "a".into() });
        let mut b = a.clone();
        b.payload = P::ServerRenamed { new_name: "b".into() };
        b.sign(&keys(OWNER).0, &keys(OWNER).2);
        b.sign_device(&keys(PHONE).0);
        // One variant keeps the phone's proof; the other loses it (a 0.13 hop strips it).
        let (mut proven, mut bare) = (a.clone(), b.clone());
        if a.content_hash() < b.content_hash() {
            (proven, bare) = (b.clone(), a.clone());
        }
        bare.dev = None;
        assert!(bare.content_hash() < proven.content_hash(), "the proof-less variant has the lower content id");
        for order in [[bare.clone(), proven.clone()], [proven.clone(), bare.clone()]] {
            let mut member = ServerState::skeleton(owner.server_id.clone());
            member.authority = view_of(&[roster_counting(&keys(PHONE).0)]);
            member.ingest_remote(std::slice::from_ref(&founding));
            for op in &order {
                member.ingest_remote(std::slice::from_ref(op));
            }
            let kept = member.op_log.iter().find(|o| o.hlc == a.hlc).expect("one variant folds");
            assert_eq!(kept.content_hash(), proven.content_hash(), "the counted variant wins in every order");
        }
    }

    // -- The cut, the one rule, parking (section 7) --

    const MEMBER: u8 = 5;
    const MEMBER_PHONE: u8 = 6;
    const MEMBER_RECOVERY: u8 = 7;
    const OTHER: u8 = 8;

    fn owner_on(commit: bool) -> (ServerState, CrdtOp) {
        let (master, id, pk) = keys(OWNER);
        let (phone, phone_id, _) = keys(PHONE);
        let roster = roster_counting(&phone);
        let r_pub = commit.then_some(roster.r_pub.as_str());
        ServerState::found_on("s".into(), id, Founder { device_peer_id: &phone_id, device: Some(&phone), r_pub }, master, pk)
    }

    /// `tag`'s replica of `sid`, writing from device `device`.
    fn replica_of(sid: &str, tag: u8, device: u8) -> ServerState {
        let (kp, id, pk) = keys(tag);
        let (dkp, did, _) = keys(device);
        let mut s = ServerState::skeleton(sid.into());
        s.set_hlc(super::super::hlc::Hlc::for_device(id, &did));
        s.set_signer(kp, pk);
        s.set_device_signer(dkp);
        s
    }

    /// A view where the owner counts its phone and MEMBER counts `member_device`.
    fn view_with(member_device: u8) -> Arc<AuthorityView> {
        let owner = roster_counting(&keys(PHONE).0);
        let member = Roster::genesis(&keys(MEMBER).0, &keys(MEMBER_RECOVERY).0, &keys(member_device).0, 1_000);
        let mut v = AuthorityView::judging();
        v.insert(keys(OWNER).1, authority::judge(&keys(OWNER).1, &KeyRule::FirstHeld, &[&owner]));
        v.insert(keys(MEMBER).1, authority::judge(&keys(MEMBER).1, &KeyRule::FirstHeld, &[&member]));
        Arc::new(v)
    }

    fn admit(owner: &mut ServerState, tag: u8) -> CrdtOp {
        let ask = super::super::operations::JoinAsk::sign(&owner.server_id, 1, &keys(tag).0);
        owner.author_checked(P::MemberAdded { peer_id: keys(tag).1, display_name: "m".into(), follow: None, ask: Some(ask) }).unwrap()
    }

    /// The member's nickname op, written from its phone, and everything the replica needs first.
    fn member_writes(owner: &mut ServerState, founding: &CrdtOp) -> (Vec<CrdtOp>, CrdtOp) {
        let added = admit(owner, MEMBER);
        let mut member = replica_of(&owner.server_id, MEMBER, MEMBER_PHONE);
        member.ingest_remote(&[founding.clone(), added.clone()]);
        let nick = member
            .author_checked(P::NicknameChanged { peer_id: keys(MEMBER).1, nickname: "mm".into() })
            .expect("a member names itself");
        (vec![founding.clone(), added], nick)
    }

    fn folded(s: &ServerState, op: &CrdtOp) -> bool {
        s.op_log.iter().any(|o| o.author == op.author && o.hlc == op.hlc)
    }

    fn parked(s: &ServerState, op: &CrdtOp) -> bool {
        s.stored.iter().any(|(o, k)| o.author == op.author && o.hlc == op.hlc && matches!(k, super::super::fold::RowKind::Parked(_)))
    }

    /// A replica past the cut that reads MEMBER's phone as uncounted, the member's op it
    /// will park, and MEMBER's master (the node's roster-ask tests).
    pub(crate) fn uncounted_member_op() -> (ServerState, CrdtOp, String) {
        let (mut owner, founding) = owner_on(true);
        let (first, nick) = member_writes(&mut owner, &founding);
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_with(OTHER);
        r.ingest_remote(&first);
        (r, nick, keys(MEMBER).1)
    }

    #[test]
    fn before_the_cut_a_device_the_view_does_not_count_writes_as_today() {
        let (mut owner, founding) = owner_on(false);
        let (first, nick) = member_writes(&mut owner, &founding);
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_with(OTHER);
        r.ingest_remote(&first);
        r.ingest_remote(std::slice::from_ref(&nick));
        assert!(!r.cut);
        assert!(folded(&r, &nick), "no cut, no device clause");
    }

    #[test]
    fn after_the_cut_only_a_counted_device_writes_and_a_members_op_parks() {
        let (mut owner, founding) = owner_on(true);
        let (first, nick) = member_writes(&mut owner, &founding);
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_with(OTHER);
        r.ingest_remote(&first);
        assert!(r.cut, "a founding nonce that commits to a key puts the cut in force");
        let out = r.ingest_remote(std::slice::from_ref(&nick));
        assert!(!folded(&r, &nick), "an uncounted device writes nothing undominated");
        assert!(parked(&r, &nick), "a member's op the rules admit is parked");
        assert!(out.rows.iter().any(|(o, p)| o.hlc == nick.hlc && p.is_some()), "and stored as a parked row");
        assert!(out.wanted.contains(&keys(MEMBER).1), "its author's roster is wanted");

        let mut fresh = ServerState::skeleton(owner.server_id.clone());
        fresh.authority = view_with(MEMBER_PHONE);
        fresh.ingest_remote(&first);
        fresh.ingest_remote(std::slice::from_ref(&nick));
        assert!(folded(&fresh, &nick), "a counted device writes");

        let mut missing = ServerState::skeleton(owner.server_id.clone());
        let mut v = (*view_with(MEMBER_PHONE)).clone();
        v.insert(keys(MEMBER).1, ViewEntry::default());
        missing.authority = Arc::new(v);
        missing.ingest_remote(&first);
        missing.ingest_remote(std::slice::from_ref(&nick));
        assert!(!folded(&missing, &nick) && parked(&missing, &nick), "Missing parks like Uncounted");
    }

    #[test]
    fn after_the_cut_a_proof_less_op_parks_until_a_proven_copy_arrives() {
        let (mut owner, founding) = owner_on(true);
        let (first, nick) = member_writes(&mut owner, &founding);
        let mut bare = nick.clone();
        bare.dev = None;
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_with(MEMBER_PHONE);
        r.ingest_remote(&first);
        r.ingest_remote(&[bare]);
        assert!(!folded(&r, &nick) && parked(&r, &nick), "a stripped proof parks (a 0.13 hop)");
        r.ingest_remote(std::slice::from_ref(&nick));
        assert!(folded(&r, &nick), "the proven copy's proof replaces the stored one and the op folds");
        assert!(r.op_log.iter().any(|o| o.hlc == nick.hlc && o.dev.is_some()));
    }

    #[test]
    fn after_the_cut_an_uncounted_op_the_rules_refuse_too_is_dropped_unstored() {
        let (mut owner, founding) = owner_on(true);
        let added = admit(&mut owner, MEMBER);
        let mut member = replica_of(&owner.server_id, MEMBER, MEMBER_PHONE);
        member.ingest_remote(&[founding.clone(), added.clone()]);
        let rename = member.create_op(P::ServerRenamed { new_name: "mine".into() });
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_with(OTHER);
        r.ingest_remote(&[founding, added]);
        let out = r.ingest_remote(std::slice::from_ref(&rename));
        assert!(!folded(&r, &rename) && !parked(&r, &rename), "not parked");
        assert!(r.held.is_empty() && out.rows.is_empty(), "and not held either: nothing is kept");
    }

    /// A checkpoint by the owner as a 0.13 build writes it (no `cp_stamped`), child of `parent`.
    fn unstamped_child(owner: &mut ServerState, parent: &CrdtOp, generation: u64) -> CrdtOp {
        let mut old = owner.lean_snapshot();
        old.owner_pin = None;
        old.checkpoint_hlc = None;
        old.retained_print = None;
        *old.stamps = Default::default();
        old.member_events.clear();
        old.cp_stamped = false;
        old.cp_generation = generation;
        old.cp_parent = Some(hex::encode(parent.content_hash()));
        let covers = owner.checkpoint_covers();
        owner.create_op(P::ServerCheckpoint { state: serde_json::to_string(&old).unwrap(), covers })
    }

    fn stamped(owner: &mut ServerState) -> CrdtOp {
        let covers = owner.checkpoint_covers();
        let json = owner.checkpoint_json(&keys(OWNER).1, &[], super::super::hlc::wall_clock_ms()).unwrap();
        owner.author_checkpoint(P::ServerCheckpoint { state: json, covers }).expect("the owner's checkpoint").0
    }

    #[test]
    fn a_stamped_owner_checkpoint_puts_the_cut_in_force() {
        let (mut owner, founding) = owner_on(false);
        let (first, nick) = member_writes(&mut owner, &founding);
        let cp = stamped(&mut owner);
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_with(OTHER);
        r.ingest_remote(&first);
        assert!(!r.cut);
        r.ingest_remote(&[cp]);
        assert!(r.cut, "any owner-signed stamped checkpoint held");
        r.ingest_remote(std::slice::from_ref(&nick));
        assert!(!folded(&r, &nick));
    }

    #[test]
    fn a_rebuild_that_refuses_a_device_wants_its_authors_roster() {
        let (mut owner, founding) = owner_on(false);
        let (first, nick) = member_writes(&mut owner, &founding);
        let cp = stamped(&mut owner);
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_with(OTHER);
        r.ingest_remote(&first);
        r.ingest_remote(std::slice::from_ref(&nick));
        assert!(folded(&r, &nick), "precondition: no cut yet");
        let out = r.ingest_remote(&[cp]);
        assert!(r.cut && out.rebuilt && parked(&r, &nick), "precondition: the checkpoint's rebuild parks the member's op");
        assert!(out.wanted.contains(&keys(MEMBER).1), "the rebuild asks for the refused author's roster");
        assert!(!out.wanted.contains(&keys(OWNER).1), "never for an author whose device counts");
    }

    #[test]
    fn the_cut_mark_keeps_the_cut_once_its_checkpoint_drops_below_the_parent() {
        let (mut owner, founding) = owner_on(false);
        let (first, nick) = member_writes(&mut owner, &founding);
        let g0 = stamped(&mut owner);
        let g1 = unstamped_child(&mut owner, &g0, 1);
        let g2 = unstamped_child(&mut owner, &g1, 2);
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_with(OTHER);
        let mut rows: Vec<(CrdtOp, Option<u64>)> = Vec::new();
        for batch in [first.clone(), vec![g0.clone()], vec![g1.clone()], vec![g2.clone()]] {
            let out = r.ingest_remote(&batch);
            rows.retain(|(o, _)| !out.dropped.contains(&(o.author.clone(), o.hlc.clone())));
            for (o, p) in out.rows {
                rows.retain(|(x, _)| !(x.author == o.author && x.hlc == o.hlc));
                rows.push((o, p));
            }
        }
        assert_eq!(r.base.as_ref().map(|b| b.generation), Some(2), "the 0.13 grandchild is the base");
        assert!(
            r.stored.iter().any(|(o, k)| o.hlc == g0.hlc && *k == super::super::fold::RowKind::CutMark),
            "the stamped checkpoint below the parent stays as the cut's mark"
        );
        assert!(r.cut, "so the cut stays in force");
        r.ingest_remote(std::slice::from_ref(&nick));
        assert!(!folded(&r, &nick));

        let mut back = ServerState::skeleton(owner.server_id.clone());
        back.authority = view_with(OTHER);
        back.restore_op_log(rows);
        assert!(back.cut, "a restart from the stored rows keeps the cut");
    }

    /// Eligibility rule 1: after the cut an owner checkpoint whose writer device the
    /// owner's view does not count is no base (unless descent makes it one).
    #[test]
    fn after_the_cut_a_checkpoint_by_an_uncounted_owner_device_is_no_base() {
        let (mut owner, founding) = owner_on(true);
        let (first, _) = member_writes(&mut owner, &founding);
        let honest = stamped(&mut owner);
        let mut thief = owner.clone();
        thief.set_hlc(super::super::hlc::Hlc::for_device(keys(OWNER).1, &keys(THIEF).1));
        thief.set_device_signer(keys(THIEF).0);
        let forged = stamped(&mut thief);
        assert_eq!(forged.proven_device(), Some(keys(THIEF).1.as_str()));
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_with(MEMBER_PHONE);
        r.ingest_remote(&first);
        r.ingest_remote(&[honest.clone(), forged.clone()]);
        assert_eq!(r.base.as_ref().map(|b| b.hash), Some(honest.content_hash()), "the uncounted device's child is not the base");

        // Missing owner statements: no checkpoint this replica does not stand on yet becomes
        // a base (section 7, C4); the owner's roster is wanted.
        let mut missing = ServerState::skeleton(owner.server_id.clone());
        let mut v = (*view_with(MEMBER_PHONE)).clone();
        v.insert(keys(OWNER).1, ViewEntry::default());
        missing.authority = Arc::new(v);
        missing.ingest_remote(&first);
        let out = missing.ingest_remote(&[honest.clone(), forged.clone()]);
        assert!(missing.base.is_none(), "a Missing owner view folds no new base");
        assert!(out.wanted.contains(&keys(OWNER).1), "and asks for the owner's roster");

        // N2: statements that count no owner device freeze nothing away.
        let mut frozen = ServerState::skeleton(owner.server_id.clone());
        let mut v = (*view_with(MEMBER_PHONE)).clone();
        let none_counted = crate::identity::roster::Authority { key: "k".into(), ..Default::default() };
        v.insert(keys(OWNER).1, ViewEntry { key: Some("k".into()), auth: Some(none_counted) });
        frozen.authority = Arc::new(v);
        frozen.ingest_remote(&first);
        frozen.ingest_remote(&[honest, forged.clone()]);
        assert_eq!(frozen.base.as_ref().map(|b| b.hash), Some(forged.content_hash()), "owner statements counting no device: the freeze takes nothing away");
    }

    /// A stamped child that disagrees with its held parent on what it copies is no base.
    #[test]
    fn a_child_whose_lineage_disagrees_with_its_held_parent_is_no_base() {
        let (mut owner, founding) = owner_on(true);
        let (first, _) = member_writes(&mut owner, &founding);
        let parent = stamped(&mut owner);
        let covers = owner.checkpoint_covers();
        let mut st: ServerState = serde_json::from_str(&owner.checkpoint_json(&keys(OWNER).1, &[], 0).unwrap()).unwrap();
        assert_eq!(st.cp_lineage, vec![hex::encode(parent.content_hash())], "a child names its parent first");
        st.cp_lineage.push("ab".repeat(32));
        let bad = owner.create_op(P::ServerCheckpoint { state: serde_json::to_string(&st).unwrap(), covers });
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_with(MEMBER_PHONE);
        r.ingest_remote(&first);
        r.ingest_remote(&[parent.clone(), bad]);
        assert_eq!(r.base.as_ref().map(|b| b.hash), Some(parent.content_hash()));
    }

    /// The cut a committing founding op puts in force survives a restart (the plan finds
    /// it among the rows, not only the tail).
    #[test]
    fn a_restart_keeps_the_cut_of_a_committing_founding_op() {
        let (mut owner, founding) = owner_on(true);
        let (first, nick) = member_writes(&mut owner, &founding);
        let mut back = ServerState::skeleton(owner.server_id.clone());
        back.authority = view_with(OTHER);
        back.restore_op_log(first.into_iter().map(|o| (o, None)).collect());
        assert!(back.cut, "the restored rows hold the committing founding op");
        back.ingest_remote(std::slice::from_ref(&nick));
        assert!(!folded(&back, &nick));
    }

    /// Our own op is judged by the view before it is authored: the view is filled first.
    #[test]
    fn authoring_fills_the_view_before_it_judges_our_own_op() {
        let (mut owner, _) = owner_on(true);
        let entry = authority::judge(&keys(OWNER).1, &KeyRule::FirstHeld, &[&roster_counting(&keys(PHONE).0)]);
        owner.set_view_source(super::ViewSource(Arc::new(move |_: &ServerState, m: &str| (m == keys(OWNER).1).then(|| entry.clone()))));
        assert!(owner.cut);
        assert!(
            owner.author_checked(P::ServerRenamed { new_name: "mine".into() }).is_some(),
            "the owner's own counted device authors after the cut"
        );
    }

    /// Signed ops from identities nobody here admitted read no roster and leave no entry.
    #[test]
    fn signed_ops_from_strangers_never_grow_the_view() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let (_, founding) = owner_on(true);
        let calls = Arc::new(AtomicUsize::new(0));
        let c = calls.clone();
        let mut r = ServerState::skeleton(founding.server_id.clone());
        r.set_view_source(ViewSource(Arc::new(move |_: &ServerState, _: &str| {
            c.fetch_add(1, Ordering::SeqCst);
            Some(ViewEntry::default())
        })));
        r.ingest_remote(std::slice::from_ref(&founding));
        let (before, size) = (calls.load(Ordering::SeqCst), r.authority.masters().count());
        let strangers: Vec<CrdtOp> = (0..50u32)
            .map(|i| {
                let (kp, id, pk) = super::super::testkeys::keys_n(i);
                let mut s = replica_of(&founding.server_id, 0, 0);
                s.set_hlc(super::super::hlc::Hlc::for_device(id, &keys(OTHER).1));
                s.set_signer(kp, pk);
                s.create_op(P::ServerRenamed { new_name: "x".into() })
            })
            .collect();
        let out = r.ingest_remote(&strangers);
        assert_eq!(out.rejected, 50, "no stranger's op folds");
        assert_eq!(
            (r.authority.masters().count() - size, calls.load(Ordering::SeqCst) - before),
            (0, 0),
            "a stranger's signed op read the store or grew the view",
        );
    }

    /// A view where the owner counts its phone and has removed THIEF, and MEMBER counts
    /// OTHER and has removed its old phone (both retired: still in the statements).
    fn view_retired() -> Arc<AuthorityView> {
        let auth = |counted: u8, removed: u8| crate::identity::roster::Authority {
            key: "k".into(),
            counted: [keys(counted).1].into(),
            removed: [(keys(removed).1, keys(counted).1)].into(),
            ..Default::default()
        };
        let mut v = AuthorityView::judging();
        v.insert(keys(OWNER).1, ViewEntry { key: Some("k".into()), auth: Some(auth(PHONE, THIEF)) });
        v.insert(keys(MEMBER).1, ViewEntry { key: Some("k".into()), auth: Some(auth(OTHER, MEMBER_PHONE)) });
        Arc::new(v)
    }

    fn retire(by: &mut ServerState, device: u8, named: &[&CrdtOp]) -> CrdtOp {
        let mut ops: Vec<super::super::operations::OpRef> = named.iter().map(|o| super::super::operations::OpRef::of(o)).collect();
        ops.sort();
        by.create_op(P::DeviceRetired { device: keys(device).1, ops, posts_until_ms: None, restore: None })
    }

    /// The member's phone writes `nick` and a later nickname; a laptop (OTHER) holds both.
    fn phone_then_laptop(owner: &mut ServerState, founding: &CrdtOp) -> (Vec<CrdtOp>, CrdtOp, CrdtOp, ServerState) {
        let (first, nick) = member_writes(owner, founding);
        let mut phone = replica_of(&owner.server_id, MEMBER, MEMBER_PHONE);
        phone.ingest_remote(&first);
        phone.ingest_remote(std::slice::from_ref(&nick));
        let later = phone.create_op(P::NicknameChanged { peer_id: keys(MEMBER).1, nickname: "late".into() });
        let mut laptop = replica_of(&owner.server_id, MEMBER, OTHER);
        laptop.ingest_remote(&first);
        (first, nick, later, laptop)
    }

    #[test]
    fn a_retire_keeps_exactly_the_ops_it_names_of_the_retired_device() {
        let (mut owner, founding) = owner_on(true);
        let (first, nick, later, mut laptop) = phone_then_laptop(&mut owner, &founding);
        let dr = retire(&mut laptop, MEMBER_PHONE, &[&nick]);
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_retired();
        r.ingest_remote(&first);
        r.ingest_remote(&[nick.clone(), later.clone()]);
        assert!(parked(&r, &nick) && parked(&r, &later), "precondition: the retired phone writes nothing by itself");
        r.ingest_remote(std::slice::from_ref(&dr));
        assert!(folded(&r, &dr), "a counted device's retire is admitted");
        assert!(folded(&r, &nick), "the op it names counts as the phone wrote it");
        assert!(!folded(&r, &later) && parked(&r, &later), "an op it does not name stays refused");
        assert_eq!(r.nicknames.get(&keys(MEMBER).1).map(|n| n.read().clone()).as_deref(), Some("mm"));
    }

    #[test]
    fn a_variant_at_an_endorsed_ops_key_is_not_endorsed() {
        let (mut owner, founding) = owner_on(true);
        let (first, nick, _, mut laptop) = phone_then_laptop(&mut owner, &founding);
        let dr = retire(&mut laptop, MEMBER_PHONE, &[&nick]);
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_retired();
        r.ingest_remote(&first);
        r.ingest_remote(&[nick.clone(), dr.clone()]);
        assert!(folded(&r, &nick) && r.verdict(&nick) == Verdict::Counted, "precondition: the retire endorses nick");
        // The retired phone signs another op at nick's clock, with a lower content id.
        let variant = (0..64)
            .map(|i| {
                let mut v = nick.clone();
                v.payload = P::NicknameChanged { peer_id: keys(MEMBER).1, nickname: format!("v{i}") };
                v.sign(&keys(MEMBER).0, &keys(MEMBER).2);
                v.sign_device(&keys(MEMBER_PHONE).0);
                v
            })
            .find(|v| v.content_hash() < nick.content_hash())
            .expect("a variant with a lower content id");
        assert_eq!(variant.proven_device(), Some(keys(MEMBER_PHONE).1.as_str()), "precondition: the phone's proof verifies");
        r.ingest_remote(std::slice::from_ref(&variant));
        let kept = r.op_log.iter().find(|o| o.author == nick.author && o.hlc == nick.hlc).expect("an op folds at the key");
        assert_eq!(kept.content_hash(), nick.content_hash(), "the endorsed op keeps its key");
        assert_ne!(r.verdict(&variant), Verdict::Counted, "the retire named nick's content, not the variant's");
        assert_eq!(r.nicknames.get(&keys(MEMBER).1).map(|n| n.read().clone()).as_deref(), Some("mm"));
    }

    #[test]
    fn a_retire_from_a_device_that_does_not_count_endorses_nothing() {
        let (mut owner, founding) = owner_on(true);
        let (first, nick, _, _) = phone_then_laptop(&mut owner, &founding);
        let mut phone = replica_of(&owner.server_id, MEMBER, MEMBER_PHONE);
        phone.ingest_remote(&first);
        let own = retire(&mut phone, MEMBER_PHONE, &[&nick]);
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_retired();
        r.ingest_remote(&first);
        r.ingest_remote(&[nick.clone(), own.clone()]);
        assert!(!folded(&r, &own) && !folded(&r, &nick), "the retired device vouches for nothing of its own");
    }

    #[test]
    fn a_retire_is_judged_by_its_shape_and_the_authors_statements() {
        let (mut owner, founding) = owner_on(true);
        let (first, nick, later, mut laptop) = phone_then_laptop(&mut owner, &founding);
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_retired();
        r.ingest_remote(&first);
        let refs = |ops: &[&CrdtOp]| ops.iter().map(|o| super::super::operations::OpRef::of(o)).collect::<Vec<_>>();
        let mut sorted = refs(&[&nick, &later]);
        sorted.sort();
        let make = |laptop: &mut ServerState, device: u8, ops: Vec<super::super::operations::OpRef>, posts: Option<i64>, restore: Option<String>| {
            laptop.create_op(P::DeviceRetired { device: keys(device).1, ops, posts_until_ms: posts, restore })
        };
        let ok = make(&mut laptop, MEMBER_PHONE, sorted.clone(), Some(5), None);
        assert!(r.op_allowed_by_rules(&ok), "control: a well-formed retire of a stated device");
        let mut unsorted = sorted.clone();
        unsorted.reverse();
        let bad = [
            ("unsorted refs", make(&mut laptop, MEMBER_PHONE, unsorted, None, None)),
            ("a repeated ref", make(&mut laptop, MEMBER_PHONE, vec![sorted[0].clone(), sorted[0].clone()], None, None)),
            ("too many refs", make(&mut laptop, MEMBER_PHONE, (0..257u64).map(|i| super::super::operations::OpRef { ms: i, c: 0, h: "a".repeat(64) }).collect(), None, None)),
            ("a ref that is no content id", make(&mut laptop, MEMBER_PHONE, vec![super::super::operations::OpRef { ms: 1, c: 0, h: "XY".into() }], None, None)),
            ("a device its statements never name", make(&mut laptop, THIEF, sorted.clone(), None, None)),
            ("a negative post window", make(&mut laptop, MEMBER_PHONE, sorted.clone(), Some(-1), None)),
            ("a restore point that is no content id", make(&mut laptop, MEMBER_PHONE, Vec::new(), None, Some("x".into()))),
        ];
        for (why, op) in bad {
            assert!(!r.op_allowed_by_rules(&op), "{why} passed");
        }
        let member_restore = make(&mut laptop, MEMBER_PHONE, Vec::new(), None, Some("b".repeat(64)));
        assert!(r.op_allowed_by_rules(&member_restore), "a member's lost-or-stolen retire names its restore point");
        let owner_restore = owner.create_op(P::DeviceRetired { device: keys(THIEF).1, ops: Vec::new(), posts_until_ms: None, restore: Some("b".repeat(64)) });
        assert!(!r.op_allowed_by_rules(&owner_restore), "an owner's retire names no restore point");
    }

    #[test]
    fn an_owner_retire_makes_the_checkpoint_it_names_eligible() {
        let (mut owner, founding) = owner_on(true);
        let (first, _) = member_writes(&mut owner, &founding);
        let mut thief = owner.clone();
        thief.set_hlc(super::super::hlc::Hlc::for_device(keys(OWNER).1, &keys(THIEF).1));
        thief.set_device_signer(keys(THIEF).0);
        let laptop_cp = stamped(&mut thief);
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_retired();
        r.ingest_remote(&first);
        r.ingest_remote(std::slice::from_ref(&laptop_cp));
        assert!(r.base.is_none(), "precondition: a removed owner device's checkpoint is no base");
        let dr = retire(&mut owner, THIEF, &[&laptop_cp]);
        r.ingest_remote(std::slice::from_ref(&dr));
        assert_eq!(r.base.as_ref().map(|b| b.hash), Some(laptop_cp.content_hash()), "rule 2: the retire names it");
    }

    #[test]
    fn a_retire_the_base_lists_is_decided_at_the_door() {
        let (mut owner, founding) = owner_on(true);
        let (first, nick, _, mut laptop) = phone_then_laptop(&mut owner, &founding);
        let dr = retire(&mut laptop, MEMBER_PHONE, &[&nick]);
        let covers = owner.checkpoint_covers();
        let mut st: ServerState = serde_json::from_str(&owner.checkpoint_json(&keys(OWNER).1, &[], 0).unwrap()).unwrap();
        st.cp_retired = vec![hex::encode(dr.content_hash())];
        let cp = owner.create_op(P::ServerCheckpoint { state: serde_json::to_string(&st).unwrap(), covers });
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_retired();
        r.ingest_remote(&first);
        r.ingest_remote(std::slice::from_ref(&cp));
        assert_eq!(r.base.as_ref().map(|b| b.hash), Some(cp.content_hash()), "precondition: the base");
        r.ingest_remote(std::slice::from_ref(&dr));
        assert!(!folded(&r, &dr), "a retire the base already folded is decided");
    }

    // -- Carried retires: cp_retired, cp_endorsed, the base's endorsements (8.2, 10 step 6) --

    fn endorsement(dr: &str, author: u8, by: u8, device: u8, named: &[&CrdtOp]) -> super::super::operations::Endorsement {
        super::super::operations::Endorsement {
            dr: dr.into(),
            author: keys(author).1,
            by: keys(by).1,
            device: keys(device).1,
            refs: named.iter().map(|o| super::super::operations::OpRef::of(o)).collect(),
        }
    }

    /// The owner's checkpoint of what it holds, carrying `endorsed` instead of its own.
    fn carrying(owner: &mut ServerState, endorsed: Vec<super::super::operations::Endorsement>) -> CrdtOp {
        let covers = owner.checkpoint_covers();
        let mut st: ServerState = serde_json::from_str(&owner.checkpoint_json(&keys(OWNER).1, &[], 0).unwrap()).unwrap();
        st.cp_endorsed = endorsed;
        owner.create_op(P::ServerCheckpoint { state: serde_json::to_string(&st).unwrap(), covers })
    }

    #[test]
    fn a_checkpoint_carries_the_retires_it_folded_and_what_they_name_it_does_not_decide() {
        let (mut owner, founding) = owner_on(true);
        let (_, nick, later, mut laptop) = phone_then_laptop(&mut owner, &founding);
        let dr = retire(&mut laptop, MEMBER_PHONE, &[&nick, &later]);
        owner.authority = view_retired();
        owner.ingest_remote(std::slice::from_ref(&dr));
        assert!(folded(&owner, &dr), "precondition: the retire is admitted");
        owner.ingest_remote(std::slice::from_ref(&nick));
        assert!(folded(&owner, &nick), "precondition: the named op folds");
        let st: ServerState = serde_json::from_str(&owner.checkpoint_json(&keys(OWNER).1, &[], 0).unwrap()).unwrap();
        let id = hex::encode(dr.content_hash());
        assert_eq!(st.cp_retired, vec![id.clone()], "the retire folded since the base");
        assert_eq!(
            st.cp_endorsed,
            vec![endorsement(&id, MEMBER, OTHER, MEMBER_PHONE, &[&later])],
            "rule 2, without the op this checkpoint decides",
        );
    }

    #[test]
    fn a_checkpoint_inherits_its_bases_endorsements_by_counted_signers_only() {
        let (mut owner, founding) = owner_on(true);
        let (first, nick, later, _) = phone_then_laptop(&mut owner, &founding);
        let kept = endorsement(&"a".repeat(64), MEMBER, OTHER, MEMBER_PHONE, &[&nick]);
        let cp = carrying(&mut owner, vec![kept.clone(), endorsement(&"b".repeat(64), MEMBER, MEMBER_PHONE, MEMBER_PHONE, &[&later])]);
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_retired();
        r.ingest_remote(&first);
        r.ingest_remote(std::slice::from_ref(&cp));
        assert_eq!(r.base.as_ref().map(|b| b.hash), Some(cp.content_hash()), "precondition: the base");
        assert_eq!(r.carried_retires().1, vec![kept], "rule 1 inherits, rule 3 drops a removed signer's entry");
        r.ingest_remote(std::slice::from_ref(&nick));
        assert!(folded(&r, &nick), "precondition: the named op folds");
        assert!(r.carried_retires().1.is_empty(), "an op the next checkpoint decides leaves the set");
    }

    /// REVIEW-C F2: a member the owner admitted, whose roster counts its phone, posts by
    /// that phone after the cut even when it authored no op this replica holds (a quiet
    /// member, or one whose ops a checkpoint compacted).
    #[test]
    fn review_c_a_member_who_wrote_no_held_op_posts_by_its_counted_device() {
        let (mut owner, founding) = owner_on(true);
        let added = admit(&mut owner, MEMBER);
        let mut r = ServerState::skeleton(owner.server_id.clone());
        let source = view_with(MEMBER_PHONE);
        r.set_view_source(ViewSource(Arc::new(move |_: &ServerState, m: &str| source.entry(m).cloned())));
        r.ingest_remote(&[founding, added]);
        r.refresh_view();
        assert!(r.cut && r.is_member(&keys(MEMBER).1), "precondition: a member past the cut");
        assert!(
            r.post_allowed(&keys(MEMBER).1, Some(&keys(MEMBER_PHONE).1), 2_000_000_000_000),
            "a member's post by its counted phone was refused: the view holds {:?}",
            r.authority.device_verdict(&keys(MEMBER).1, &keys(MEMBER_PHONE).1),
        );
    }

    /// Lead decision 1: a refusal queues a roster ask only for a member the view holds no
    /// roster of, proven by a device other than its bare master id, at most 64 per drain.
    #[test]
    fn lead_c_only_a_members_missing_roster_is_queued_for_an_ask() {
        let (mut owner, founding) = owner_on(true);
        let added = admit(&mut owner, MEMBER);
        let (m, phone, other) = (keys(MEMBER).1, keys(MEMBER_PHONE).1, keys(OTHER).1);
        let replica = |source: Arc<AuthorityView>| {
            let mut r = ServerState::skeleton(owner.server_id.clone());
            r.set_view_source(ViewSource(Arc::new(move |_: &ServerState, x: &str| source.entry(x).cloned())));
            r.ingest_remote(&[founding.clone(), added.clone()]);
            r.refresh_view();
            r
        };
        let owner_only = {
            let mut v = AuthorityView::judging();
            v.insert(keys(OWNER).1, authority::judge(&keys(OWNER).1, &KeyRule::FirstHeld, &[&roster_counting(&keys(PHONE).0)]));
            Arc::new(v)
        };
        let missing = replica(owner_only);
        assert!(missing.cut && missing.is_member(&m), "precondition: a member past the cut");
        let gate = missing.post_gate();
        gate.refused(&m, None, "c");
        gate.refused(&m, Some(&m), "c");
        gate.refused(&other, Some(&phone), "c");
        assert!(missing.take_post_rosters_wanted().is_empty(), "no proof, the bare master id, or a stranger asked a roster");
        gate.refused(&m, Some(&phone), "c");
        gate.refused(&m, Some(&phone), "c");
        let want: Vec<(String, String)> = missing.take_post_rosters_wanted().into_iter().collect();
        assert_eq!(want, vec![(m.clone(), "c".to_string())], "a member's post with no roster held asks once");
        assert!(missing.take_post_rosters_wanted().is_empty(), "a drain leaves nothing behind");
        for n in 0..200 {
            gate.refused(&m, Some(&phone), &format!("c{n}"));
        }
        assert_eq!(missing.take_post_rosters_wanted().len(), MAX_POST_ROSTERS_WANTED, "the queue is bounded");

        let held = replica(view_with(MEMBER_PHONE));
        held.post_gate().refused(&m, Some(&other), "c");
        assert!(held.take_post_rosters_wanted().is_empty(), "a roster held that does not count the device asks nothing");
    }

    /// Section 13's gate: nothing is judged before the cut; after it a post passes by a
    /// device the view counts, by a post window at or past its date (a held counted
    /// retire's or the base's, a recovering owner's own skipped while a floor holds), or
    /// by a date before the base lineage's cut clock, and by nothing else.
    #[test]
    fn a_post_after_the_cut_needs_a_counted_device_a_window_or_a_pre_cut_date() {
        let (member, phone, other, thief) = (keys(MEMBER).1, keys(MEMBER_PHONE).1, keys(OTHER).1, keys(THIEF).1);
        let (mut open, founding) = owner_on(false);
        let (first, _, _, _) = phone_then_laptop(&mut open, &founding);
        let mut r = ServerState::skeleton(open.server_id.clone());
        r.authority = view_retired();
        r.ingest_remote(&first);
        assert!(!r.cut && r.post_allowed(&member, Some(&phone), 10), "before the cut nothing is judged");

        let (mut owner, founding) = owner_on(true);
        let (first, _, _, mut laptop) = phone_then_laptop(&mut owner, &founding);
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_retired();
        r.ingest_remote(&first);
        assert!(r.cut, "precondition: a committing founding puts the cut in force");
        assert!(r.post_allowed(&member, Some(&other), 10), "a device the view counts");
        assert!(!r.post_allowed(&member, Some(&phone), 10), "a removed device with no window");
        assert!(!r.post_allowed(&member, None, 10), "no proof and no cut clock to be older than");

        let dr = laptop.create_op(P::DeviceRetired { device: phone.clone(), ops: Vec::new(), posts_until_ms: Some(500), restore: None });
        r.ingest_remote(std::slice::from_ref(&dr));
        assert!(folded(&r, &dr), "precondition: the retire is admitted");
        assert!(r.post_allowed(&member, Some(&phone), 500) && !r.post_allowed(&member, Some(&phone), 501), "the retire's window, inclusive");
        assert!(!r.post_allowed(&member, None, 400), "a window needs the proof of its device");
        assert!(!r.post_allowed(&keys(OWNER).1, Some(&phone), 400), "a window is its author's alone");

        let owner_dr = owner.create_op(P::DeviceRetired { device: thief.clone(), ops: Vec::new(), posts_until_ms: Some(700), restore: None });
        r.ingest_remote(std::slice::from_ref(&owner_dr));
        assert!(r.post_allowed(&keys(OWNER).1, Some(&thief), 700), "precondition: the owner's own window");
        r.floor_base = true;
        assert!(!r.post_allowed(&keys(OWNER).1, Some(&thief), 700), "a floor skips the recovering owner's own windows");
        assert!(r.post_allowed(&member, Some(&phone), 500), "and only the owner's");
        r.floor_base = false;

        let covers = owner.checkpoint_covers();
        let cp = owner.create_op(P::ServerCheckpoint { state: owner.checkpoint_json(&keys(OWNER).1, &[], 0).unwrap(), covers });
        r.ingest_remote(std::slice::from_ref(&cp));
        assert_eq!(r.base.as_ref().map(|b| b.hash), Some(cp.content_hash()), "precondition: the base");
        let cut = i64::try_from(cp.hlc.physical_ms).unwrap();
        assert!(r.post_allowed(&member, None, cut - 1), "a post dated before the lineage's cut clock");
        assert!(!r.post_allowed(&member, None, cut), "and none at or after it");
        assert!(!r.post_allowed(&member, Some(&phone), cut), "a removed device past its window and the cut");
    }

    /// A retire carries the newest date of the device's posts: on every chunk, alone when
    /// nothing else is named, and again only once the date moved past what it holds.
    #[test]
    fn a_retire_carries_the_retired_devices_newest_post_date() {
        let (mut owner, founding) = owner_on(true);
        let (_, nick, _, mut laptop) = phone_then_laptop(&mut owner, &founding);
        let (member, phone) = (keys(MEMBER).1, keys(MEMBER_PHONE).1);
        assert!(laptop.retire_payloads(&member, &phone, None).is_empty(), "nothing named, no window: nothing to publish");
        let alone = laptop.retire_payloads(&member, &phone, Some(900));
        assert!(matches!(alone.as_slice(), [P::DeviceRetired { ops, posts_until_ms: Some(900), .. }] if ops.is_empty()), "{alone:?}");
        laptop.ingest_remote(std::slice::from_ref(&nick));
        let named = laptop.retire_payloads(&member, &phone, Some(900));
        assert!(matches!(named.as_slice(), [P::DeviceRetired { ops, posts_until_ms: Some(900), .. }] if !ops.is_empty()), "{named:?}");
        for p in named {
            laptop.author_checked(p).expect("the laptop retires the phone");
        }
        assert!(laptop.retire_payloads(&member, &phone, Some(900)).is_empty(), "the held window covers it");
        assert!(matches!(laptop.retire_payloads(&member, &phone, Some(901)).as_slice(), [P::DeviceRetired { posts_until_ms: Some(901), .. }]), "a newer post moves it");
    }

    /// Section 8.2 for `cp_posts_until`: rule 1 inherits the base's windows, rule 2 adds
    /// a held counted retire's, rule 3 drops a removed signer's; one window per device,
    /// the newest, and at most `MAX_POSTS_UNTIL_PER_AUTHOR` per author, the smallest going.
    #[test]
    fn a_checkpoint_carries_the_newest_post_window_per_device_by_counted_signers() {
        use super::super::operations::{PostsUntil, MAX_POSTS_UNTIL_PER_AUTHOR};
        let (mut owner, founding) = owner_on(true);
        let (first, _, _, mut laptop) = phone_then_laptop(&mut owner, &founding);
        let window = |device: &str, by: u8, until_ms: i64, dr: &str| PostsUntil { author: keys(MEMBER).1, device: device.into(), until_ms, dr: dr.into(), by: keys(by).1 };
        let phone = keys(MEMBER_PHONE).1;
        let covers = owner.checkpoint_covers();
        let mut st: ServerState = serde_json::from_str(&owner.checkpoint_json(&keys(OWNER).1, &[], 0).unwrap()).unwrap();
        st.cp_posts_until = vec![window(&phone, OTHER, 100, &"a".repeat(64)), window("gone", MEMBER_PHONE, 999, &"b".repeat(64))];
        let cp = owner.create_op(P::ServerCheckpoint { state: serde_json::to_string(&st).unwrap(), covers });
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_retired();
        r.ingest_remote(&first);
        r.ingest_remote(std::slice::from_ref(&cp));
        assert_eq!(r.base.as_ref().map(|b| b.hash), Some(cp.content_hash()), "precondition: the base");
        assert_eq!(r.carried_posts_until(), vec![window(&phone, OTHER, 100, &"a".repeat(64))], "rule 1 inherits, rule 3 drops a removed signer's");

        let dr = laptop.create_op(P::DeviceRetired { device: phone.clone(), ops: Vec::new(), posts_until_ms: Some(500), restore: None });
        r.ingest_remote(std::slice::from_ref(&dr));
        assert!(folded(&r, &dr), "precondition: the retire is admitted");
        assert_eq!(r.carried_posts_until(), vec![window(&phone, OTHER, 500, &hex::encode(dr.content_hash()))], "rule 2 adds it, the newest per device");
        let written: ServerState = serde_json::from_str(&r.checkpoint_json(&keys(OWNER).1, &[], 0).unwrap()).unwrap();
        assert_eq!(written.cp_posts_until, r.carried_posts_until(), "and the next checkpoint carries them");

        let mut st = st;
        st.cp_posts_until = (0..=MAX_POSTS_UNTIL_PER_AUTHOR as i64).map(|i| window(&format!("d{i:02}"), OTHER, 1_000 + i, &"c".repeat(64))).collect();
        let covers = owner.checkpoint_covers();
        let many = owner.create_op(P::ServerCheckpoint { state: serde_json::to_string(&st).unwrap(), covers });
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_retired();
        r.ingest_remote(&first);
        r.ingest_remote(std::slice::from_ref(&many));
        let carried = r.carried_posts_until();
        assert_eq!(carried.len(), MAX_POSTS_UNTIL_PER_AUTHOR, "bounded per author");
        assert!(!carried.iter().any(|p| p.device == "d00"), "the smallest window goes");
    }

    #[test]
    fn a_bases_endorsement_by_a_counted_signer_seats_an_op_that_arrives_later() {
        let (mut owner, founding) = owner_on(true);
        let (first, nick, later, _) = phone_then_laptop(&mut owner, &founding);
        let cp = carrying(
            &mut owner,
            vec![
                endorsement(&"a".repeat(64), MEMBER, OTHER, MEMBER_PHONE, &[&nick]),
                endorsement(&"b".repeat(64), MEMBER, MEMBER_PHONE, MEMBER_PHONE, &[&later]),
            ],
        );
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_retired();
        r.ingest_remote(&first);
        r.ingest_remote(std::slice::from_ref(&cp));
        r.ingest_remote(&[nick.clone(), later.clone()]);
        assert!(folded(&r, &nick), "section 10 step 6: the base's counted endorsement");
        assert!(!folded(&r, &later) && parked(&r, &later), "an entry its view does not count endorses nothing");
        let rows: Vec<(CrdtOp, Option<u64>)> =
            r.op_log.iter().map(|o| (o.clone(), None)).chain(r.stored.iter().map(|(o, k)| (o.clone(), k.parked_until()))).collect();
        let mut again = ServerState::skeleton(owner.server_id.clone());
        again.authority = view_retired();
        let _ = again.restore_rows(rows.clone());
        assert!(folded(&again, &nick), "and after a restart that folds again");
        let mut saved = r.lean_snapshot();
        saved.authority = view_retired();
        let restored = saved.restore_rows(rows);
        assert!(!restored.refolded && folded(&saved, &nick), "and after one that keeps its saved fold");
        assert!(saved.is_endorsed(&nick), "with the base's endorsement in force for what arrives next");
    }

    #[test]
    fn a_checkpoint_carries_at_most_the_newest_endorsed_refs() {
        let (mut owner, founding) = owner_on(true);
        let (first, ..) = phone_then_laptop(&mut owner, &founding);
        let refs = |from: u64, n: u64| (from..from + n).map(|ms| super::super::operations::OpRef { ms, c: 0, h: "0".repeat(64) }).collect::<Vec<_>>();
        let mut a = endorsement(&"a".repeat(64), MEMBER, OTHER, MEMBER_PHONE, &[]);
        a.refs = refs(1, 3_000);
        let mut b = endorsement(&"b".repeat(64), MEMBER, OTHER, MEMBER_PHONE, &[]);
        b.refs = refs(3_001, 2_000);
        let cp = carrying(&mut owner, vec![a, b]);
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.authority = view_retired();
        r.ingest_remote(&first);
        r.ingest_remote(std::slice::from_ref(&cp));
        let carried = r.carried_retires().1;
        let all: Vec<u64> = carried.iter().flat_map(|e| e.refs.iter().map(|r| r.ms)).collect();
        assert_eq!(all.len(), super::super::operations::MAX_ENDORSED_REFS, "bounded");
        assert_eq!(all.iter().min(), Some(&905), "the oldest by clock go");
    }

    #[test]
    fn an_eligible_checkpoints_endorsement_makes_the_checkpoint_it_names_eligible() {
        let (mut owner, founding) = owner_on(true);
        let (first, _) = member_writes(&mut owner, &founding);
        let mut thief = owner.clone();
        thief.set_hlc(super::super::hlc::Hlc::for_device(keys(OWNER).1, &keys(THIEF).1));
        thief.set_device_signer(keys(THIEF).0);
        let mut laptop_cp = stamped(&mut thief);
        laptop_cp.hlc.physical_ms += 5_000;
        laptop_cp.sign(&keys(OWNER).0, &keys(OWNER).2);
        laptop_cp.sign_device(&keys(THIEF).0);
        let earlier_as = |by: u8, device: u8| carrying(&mut owner.clone(), vec![endorsement(&"c".repeat(64), OWNER, by, device, &[&laptop_cp])]);
        let earlier = |by: u8| earlier_as(by, THIEF);
        let base_of = |cp: &CrdtOp| {
            let mut r = ServerState::skeleton(owner.server_id.clone());
            r.authority = view_retired();
            r.ingest_remote(&first);
            r.ingest_remote(&[laptop_cp.clone(), cp.clone()]);
            r.base.as_ref().map(|b| b.hash)
        };
        let honest = earlier(PHONE);
        assert_eq!(base_of(&honest), Some(laptop_cp.content_hash()), "rule 2: an eligible checkpoint's counted entry names it");
        let forged = earlier(THIEF);
        assert_eq!(base_of(&forged), Some(forged.content_hash()), "an entry by a device the view does not count names nothing");
        let elsewhere = earlier_as(PHONE, PHONE);
        assert_eq!(base_of(&elsewhere), Some(elsewhere.content_hash()), "nor one for another device than the one that wrote it");
    }

    #[test]
    fn a_remover_names_every_folded_op_the_device_proved_in_sorted_chunks() {
        let (mut owner, founding) = owner_on(true);
        let (first, nick) = member_writes(&mut owner, &founding);
        let mut phone = replica_of(&owner.server_id, MEMBER, MEMBER_PHONE);
        phone.ingest_remote(&first);
        phone.ingest_remote(std::slice::from_ref(&nick));
        let mut written = vec![nick.clone()];
        for k in 0..300 {
            written.push(phone.create_op(P::NicknameChanged { peer_id: keys(MEMBER).1, nickname: format!("n{k}") }));
        }
        let mut laptop = replica_of(&owner.server_id, MEMBER, OTHER);
        laptop.ingest_remote(&first);
        laptop.ingest_remote(&written);
        let payloads = laptop.retire_payloads(&keys(MEMBER).1, &keys(MEMBER_PHONE).1, None);
        let refs: Vec<super::super::operations::OpRef> = payloads
            .iter()
            .flat_map(|p| match p {
                P::DeviceRetired { device, ops, restore: None, .. } if *device == keys(MEMBER_PHONE).1 => ops.clone(),
                _ => panic!("a plain retire of the phone"),
            })
            .collect();
        let mut want: Vec<_> = written.iter().filter(|o| folded(&laptop, o)).map(super::super::operations::OpRef::of).collect();
        want.sort();
        assert!(want.len() > super::super::operations::MAX_RETIRED_REFS, "precondition: more than one chunk folded ({})", want.len());
        assert_eq!(payloads.len(), want.len().div_ceil(super::super::operations::MAX_RETIRED_REFS), "chunks of at most 256 refs");
        assert_eq!(refs, want, "every folded op the phone proved, sorted, nothing else");
        assert!(!laptop.op_log.iter().any(|o| o.hlc == written[300].hlc), "precondition: the phone is over its share here");
        for p in payloads {
            assert!(laptop.author_checked(p).is_some(), "each chunk passes the remover's own rules, past its share too");
        }
        assert!(laptop.retire_payloads(&keys(MEMBER).1, &keys(MEMBER_PHONE).1, None).is_empty(), "minting again names nothing already named");
        let late = phone.create_op(P::NicknameChanged { peer_id: keys(MEMBER).1, nickname: "late".into() });
        laptop.ingest_remote(std::slice::from_ref(&late));
        if folded(&laptop, &late) {
            let again = laptop.retire_payloads(&keys(MEMBER).1, &keys(MEMBER_PHONE).1, None);
            assert!(
                matches!(again.as_slice(), [P::DeviceRetired { ops, .. }] if ops == &vec![super::super::operations::OpRef::of(&late)]),
                "only the op folded since: {again:?}",
            );
        }
    }

    // -- H3 carve-outs (lead decision 11-05): a refusal a roster can still end is kept --

    const JOINER: u8 = 9;
    const JOINER_PHONE: u8 = 10;
    const JOINER_RECOVERY: u8 = 11;
    const OTHER_PHONE: u8 = 12;

    fn ask_of(sid: &str, tag: u8, at: i64) -> Option<super::super::operations::JoinAsk> {
        Some(super::super::operations::JoinAsk::sign(sid, at, &keys(tag).0))
    }

    fn admits_joiner(by: &mut ServerState, at: i64) -> CrdtOp {
        let ask = ask_of(&by.server_id, JOINER, at);
        by.author_checked(P::MemberAdded { peer_id: keys(JOINER).1, display_name: "j".into(), follow: None, ask }).expect("a member admits")
    }

    /// MEMBER (from its phone) admits JOINER, who then names itself: (what comes first,
    /// the admission, the nickname).
    fn member_admits_joiner(owner: &mut ServerState, founding: &CrdtOp) -> (Vec<CrdtOp>, CrdtOp, CrdtOp) {
        let sid = owner.server_id.clone();
        let added = admit(owner, MEMBER);
        let mut member = replica_of(&sid, MEMBER, MEMBER_PHONE);
        member.ingest_remote(&[founding.clone(), added.clone()]);
        let admits = admits_joiner(&mut member, 1);
        let mut joiner = replica_of(&sid, JOINER, JOINER_PHONE);
        joiner.ingest_remote(&[founding.clone(), added.clone(), admits.clone()]);
        let nick = joiner
            .author_checked(P::NicknameChanged { peer_id: keys(JOINER).1, nickname: "jj".into() })
            .expect("the joiner names itself");
        (vec![founding.clone(), added], admits, nick)
    }

    /// The owner's phone always counts; MEMBER's and JOINER's phones read `Missing`
    /// until their rosters `arrive`; anyone else reads `Missing`.
    fn rosters_arrive(arrived: Arc<std::sync::atomic::AtomicBool>) -> ViewSource {
        let entry = |master: u8, recovery: u8, device: u8| {
            let r = Roster::genesis(&keys(master).0, &keys(recovery).0, &keys(device).0, 1_000);
            authority::judge(&keys(master).1, &KeyRule::FirstHeld, &[&r])
        };
        let owner = entry(OWNER, RECOVERY, PHONE);
        let late = [(keys(MEMBER).1, entry(MEMBER, MEMBER_RECOVERY, MEMBER_PHONE)), (keys(JOINER).1, entry(JOINER, JOINER_RECOVERY, JOINER_PHONE))];
        let o = keys(OWNER).1;
        ViewSource(Arc::new(move |_: &ServerState, who: &str| {
            if who == o {
                return Some(owner.clone());
            }
            let now = arrived.load(std::sync::atomic::Ordering::SeqCst);
            Some(late.iter().find(|(m, _)| now && m == who).map_or_else(ViewEntry::default, |(_, e)| e.clone()))
        }))
    }

    fn held(s: &ServerState, op: &CrdtOp) -> bool {
        s.held.iter().any(|(o, _)| o.author == op.author && o.hlc == op.hlc)
    }

    fn own_parked(s: &ServerState) -> usize {
        s.stored
            .iter()
            .filter(|(o, k)| {
                matches!(k, super::super::fold::RowKind::Parked(_)) && matches!(&o.payload, P::MemberAdded { peer_id, .. } if *peer_id == keys(JOINER).1)
            })
            .count()
    }

    #[test]
    fn after_the_cut_a_refusal_resting_on_a_skipped_admission_waits_for_the_rosters() {
        let (mut owner, founding) = owner_on(true);
        let (first, admits, nick) = member_admits_joiner(&mut owner, &founding);
        let arrived = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.set_view_source(rosters_arrive(arrived.clone()));
        r.ingest_remote(&first);
        r.ingest_remote(std::slice::from_ref(&admits));
        assert!(parked(&r, &admits), "precondition: a Missing member's admission parks (H3)");
        let out = r.ingest_remote(std::slice::from_ref(&nick));
        assert!(held(&r, &nick), "the joiner's op is refused only because its admission waits: kept as the core keeps a refused op");
        assert!(out.wanted.contains(&keys(JOINER).1), "and its author's roster is wanted");

        arrived.store(true, std::sync::atomic::Ordering::SeqCst);
        let _ = r.rebuild_now();
        assert!(folded(&r, &admits) && folded(&r, &nick), "the rosters arrive: both fold");
    }

    #[test]
    fn a_rebuild_parks_a_refusal_resting_on_a_skipped_admission() {
        let (mut owner, founding) = owner_on(false);
        let (first, admits, nick) = member_admits_joiner(&mut owner, &founding);
        let cp = stamped(&mut owner);
        let arrived = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.set_view_source(rosters_arrive(arrived.clone()));
        r.ingest_remote(&first);
        r.ingest_remote(&[admits.clone(), nick.clone()]);
        assert!(folded(&r, &nick), "precondition: no cut yet");
        r.ingest_remote(&[cp]);
        assert!(r.cut && parked(&r, &admits), "precondition: the checkpoint's rebuild parks the member's admission");
        assert!(parked(&r, &nick), "and the joiner's row whose refusal rests on it, never dropped");

        arrived.store(true, std::sync::atomic::Ordering::SeqCst);
        let _ = r.rebuild_now();
        assert!(folded(&r, &admits) && folded(&r, &nick), "the rosters arrive: both fold");
    }

    #[test]
    fn a_skipped_op_that_enables_nothing_leaves_a_refusal_final() {
        let (mut owner, founding) = owner_on(true);
        let (first, nick) = member_writes(&mut owner, &founding);
        let mut member = replica_of(&owner.server_id, MEMBER, MEMBER_PHONE);
        member.ingest_remote(&first);
        member.ingest_remote(std::slice::from_ref(&nick));
        let rename = member.create_op(P::ServerRenamed { new_name: "mine".into() });
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.set_view_source(rosters_arrive(Arc::new(std::sync::atomic::AtomicBool::new(false))));
        r.ingest_remote(&first);
        r.ingest_remote(std::slice::from_ref(&nick));
        assert!(parked(&r, &nick), "precondition: a Missing member's nickname parks");
        r.ingest_remote(std::slice::from_ref(&rename));
        assert!(!folded(&r, &rename) && !parked(&r, &rename) && !held(&r, &rename), "a rename no skipped admission could allow is dropped");
    }

    #[test]
    fn a_proof_less_refusal_stays_dropped_whatever_was_skipped() {
        let (mut owner, founding) = owner_on(true);
        let (first, admits, nick) = member_admits_joiner(&mut owner, &founding);
        let mut bare = nick.clone();
        bare.dev = None;
        let mut r = ServerState::skeleton(owner.server_id.clone());
        r.set_view_source(rosters_arrive(Arc::new(std::sync::atomic::AtomicBool::new(false))));
        r.ingest_remote(&first);
        r.ingest_remote(std::slice::from_ref(&admits));
        r.ingest_remote(std::slice::from_ref(&bare));
        assert!(!parked(&r, &nick) && !held(&r, &nick), "a missing proof is no roster's to end: the proven copy comes by the digest");
    }

    /// The F1 cascade on the joiner's own replica: MEMBER admitted us and left, the owner's
    /// checkpoint holds the leave but not our admission, and we lack MEMBER's roster.
    #[test]
    fn our_own_admission_refused_by_a_missing_admitter_parks_for_the_silent_reask() {
        let (mut owner, founding) = owner_on(false);
        let (first, admits, _) = member_admits_joiner(&mut owner, &founding);
        let mut member = replica_of(&owner.server_id, MEMBER, MEMBER_PHONE);
        member.ingest_remote(&first);
        member.ingest_remote(std::slice::from_ref(&admits));
        let leave = member.author_checked(P::MemberRemoved { peer_id: keys(MEMBER).1, seen: None }).expect("a member leaves");
        owner.ingest_remote(std::slice::from_ref(&leave));
        let cp = stamped(&mut owner);
        let mut us = replica_of(&owner.server_id, JOINER, JOINER_PHONE);
        us.set_view_source(rosters_arrive(Arc::new(std::sync::atomic::AtomicBool::new(false))));
        us.ingest_remote(&first);
        us.ingest_remote(&[admits.clone(), leave]);
        assert!(us.is_member(&keys(JOINER).1), "precondition: no cut yet, we are in");
        us.ingest_remote(&[cp]);
        assert!(us.cut && us.base.is_some() && !us.is_member(&keys(JOINER).1), "precondition: the owner's base holds MEMBER's leave");
        assert!(parked(&us, &admits), "our own admission is parked, never dropped");
        assert!(us.refused_own_admission(&keys(JOINER).1), "so we ask to join again");
    }

    #[test]
    fn our_own_admission_parks_once_per_server() {
        let (mut owner, founding) = owner_on(false);
        let sid = owner.server_id.clone();
        let first = vec![founding.clone(), admit(&mut owner, MEMBER), admit(&mut owner, OTHER)];
        let source = rosters_arrive(Arc::new(std::sync::atomic::AtomicBool::new(false)));
        let mut member = replica_of(&sid, MEMBER, MEMBER_PHONE);
        member.ingest_remote(&first);
        let admits = admits_joiner(&mut member, 1);
        let mut us = replica_of(&sid, JOINER, JOINER_PHONE);
        us.ingest_remote(&first);
        us.ingest_remote(std::slice::from_ref(&admits));
        let left = us.author_checked(P::MemberRemoved { peer_id: keys(JOINER).1, seen: None }).expect("we leave");
        let mut other = replica_of(&sid, OTHER, OTHER_PHONE);
        other.ingest_remote(&first);
        other.ingest_remote(&[admits.clone(), left]);
        let again = admits_joiner(&mut other, super::super::hlc::wall_clock_ms() as i64);
        us.ingest_remote(std::slice::from_ref(&again));
        assert!(us.is_member(&keys(JOINER).1), "precondition: admitted again before the cut");
        let gone = [
            member.author_checked(P::MemberRemoved { peer_id: keys(MEMBER).1, seen: None }).expect("MEMBER leaves"),
            other.author_checked(P::MemberRemoved { peer_id: keys(OTHER).1, seen: None }).expect("OTHER leaves"),
        ];
        owner.ingest_remote(&gone);
        let cp = stamped(&mut owner);
        us.set_view_source(source);
        us.ingest_remote(&gone);
        us.ingest_remote(&[cp]);
        assert!(us.cut && us.base.is_some(), "precondition: the owner's base");
        assert_eq!(own_parked(&us), 1, "two refused admissions of us: one row, the rest waits in RAM");
        assert!(held(&us, &admits) || held(&us, &again), "the other is held, not dropped");
    }

    /// The hostile review's probes of part 1, kept as regression tests.
    mod review {
        use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
        use std::sync::Arc;

        use super::super::super::authority::{self, KeyRule, ViewEntry};
        use super::super::super::operations::{CrdtOp, CrdtPayload as P};
        use super::super::super::server_state::ServerState;
        use super::super::super::testkeys::keys;
        use super::*;
        use crate::identity::roster::Roster;

        /// Design 7 (the freeze): "for `Missing`, the rebuild waits for the owner's roster and the
        /// state stays at its last fold". A replica whose view has no owner statements under the
        /// committed key must not move its base to a checkpoint the master key alone signed.
        #[test]
        fn review_a_missing_owner_view_keeps_the_last_base() {
            let (mut owner, founding) = owner_on(true);
            let (first, _) = member_writes(&mut owner, &founding);
            let honest = stamped(&mut owner);

            // A holder of the owner's master key alone: no device proof at all.
            let mut thief = owner.clone();
            thief.set_signer(keys(OWNER).0, keys(OWNER).2);
            let rename = thief.create_op(P::ServerRenamed { new_name: "thief".into() });
            let _ = thief.apply_op(&rename);
            let forged = stamped(&mut thief);
            assert!(forged.dev.is_none(), "the forged checkpoint carries no device proof");

            // The replica holds only a roster the thief forged under another recovery key: under
            // the founding commit that is Missing (the AR-15 case the commit exists to close).
            let forged_roster = Roster::genesis(&keys(OWNER).0, &keys(THIEF).0, &keys(THIEF).0, 1_000);
            let mut r = ServerState::skeleton(owner.server_id.clone());
            r.ingest_remote(std::slice::from_ref(&founding));
            let rule = authority::key_rule(&r, &keys(OWNER).1);
            assert!(matches!(rule, KeyRule::Commit(_)));
            // (Builder: the honest base folds while the view counts the owner's phone; C4 lets
            // nothing fold under Missing, so the view turns Missing only after it.)
            r.authority = view_with(MEMBER_PHONE);
            r.ingest_remote(&first);
            r.ingest_remote(std::slice::from_ref(&honest));
            assert_eq!(r.base.as_ref().map(|b| b.hash), Some(honest.content_hash()), "the honest base folds first");
            let mut v = (*view_with(MEMBER_PHONE)).clone();
            v.insert(keys(OWNER).1, authority::judge(&keys(OWNER).1, &rule, &[&forged_roster]));
            assert!(v.entry(&keys(OWNER).1).is_some_and(|e| e.auth.is_none()), "the forged roster leaves the owner Missing");
            r.authority = Arc::new(v);

            r.ingest_remote(std::slice::from_ref(&forged));
            assert_eq!(
                r.base.as_ref().map(|b| b.hash),
                Some(honest.content_hash()),
                "a proof-less master-key checkpoint became the base of a replica that reads the owner as Missing (name now {:?})",
                r.name.read()
            );
        }

        /// Design 9/10 + INTERFACE R2.3: C2 marks a server dirty (`ViewDirty::mark`) after a
        /// co-member roster lands; the event loop then calls `rebuild_now`. The rebuild must judge
        /// the member again from the source, or the member's parked op stays parked.
        #[test]
        fn review_a_rebuild_after_a_mark_judges_a_cached_missing_entry_again() {
            let (mut owner, founding) = owner_on(true);
            let (first, nick) = member_writes(&mut owner, &founding);
            let owner_entry = authority::judge(&keys(OWNER).1, &KeyRule::FirstHeld, &[&roster_counting(&keys(PHONE).0)]);
            let member_roster = Roster::genesis(&keys(MEMBER).0, &keys(MEMBER_RECOVERY).0, &keys(MEMBER_PHONE).0, 1_000);
            let member_entry = authority::judge(&keys(MEMBER).1, &KeyRule::FirstHeld, &[&member_roster]);
            let arrived = Arc::new(AtomicBool::new(false));
            let seen = arrived.clone();
            let (o, m) = (keys(OWNER).1, keys(MEMBER).1);
            let mut r = ServerState::skeleton(owner.server_id.clone());
            r.set_view_source(ViewSource(Arc::new(move |_: &ServerState, who: &str| {
                Some(if who == o {
                    owner_entry.clone()
                } else if who == m && seen.load(Ordering::SeqCst) {
                    member_entry.clone()
                } else {
                    ViewEntry::default()
                })
            })));
            r.ingest_remote(&first);
            r.ingest_remote(std::slice::from_ref(&nick));
            assert!(parked(&r, &nick), "Missing member: parked");

            arrived.store(true, Ordering::SeqCst); // C2's server_rosters now holds the member's roster
            let _ = r.rebuild_now(); // what swarm.rs's ViewDirty::due loop runs for a marked server
            assert!(folded(&r, &nick), "the marked rebuild never asked the source again: the honest member stays parked");
        }

        /// Section 14 / CLAUDE.md fair tables: an op whose signature fails is rejected before
        /// anything is spent on it. `fill_view` runs before `stateless_check`, so every fresh
        /// author string in a batch costs a store lease + roster read (event loop) and stays in
        /// the view for the state's lifetime.
        #[test]
        fn review_unsigned_ops_from_fresh_authors_never_grow_the_view() {
            let (_, founding) = owner_on(true);
            let calls = Arc::new(AtomicUsize::new(0));
            let c = calls.clone();
            let mut r = ServerState::skeleton(founding.server_id.clone());
            r.set_view_source(ViewSource(Arc::new(move |_: &ServerState, _: &str| {
                c.fetch_add(1, Ordering::SeqCst);
                Some(ViewEntry::default())
            })));
            r.ingest_remote(std::slice::from_ref(&founding));
            let (calls_before, size_before) = (calls.load(Ordering::SeqCst), r.authority.masters().count());
            let junk: Vec<CrdtOp> = (0..2_000)
                .map(|i| {
                    let mut op = founding.clone();
                    op.author = format!("junk{i}");
                    op.hlc.actor = op.author.clone();
                    op.auth = None;
                    op.dev = None;
                    op.payload = P::ServerRenamed { new_name: "x".into() };
                    op
                })
                .collect();
            let out = r.ingest_remote(&junk);
            assert_eq!(out.rejected, 2_000, "every junk op fails its signature");
            let grew = r.authority.masters().count() - size_before;
            let reads = calls.load(Ordering::SeqCst) - calls_before;
            assert_eq!((grew, reads), (0, 0), "the view grew by {grew} entries and read the store {reads} times for rejected ops");
        }

        /// Section 14 "Parked ops ... the core's quota": a removed owner device's in-order stream
        /// parks at the tail without `cap_parked` (the owner is exempt from the quota), so the
        /// parked rows of one group pass `PARK_GROUP_BYTES` until some rebuild trims them.
        #[test]
        fn review_a_removed_owner_devices_stream_parks_within_its_group_bound() {
            let (mut owner, founding) = owner_on(true);
            let (first, _) = member_writes(&mut owner, &founding);
            let mut thief = owner.clone();
            thief.set_hlc(super::super::super::hlc::Hlc::for_device(keys(OWNER).1, &keys(THIEF).1));
            thief.set_device_signer(keys(THIEF).0);
            let mut r = ServerState::skeleton(owner.server_id.clone());
            r.authority = view_with(MEMBER_PHONE);
            r.ingest_remote(&first);
            let mut rows = 0usize;
            for i in 0..300 {
                let op = thief.create_op(P::ServerRenamed { new_name: format!("flood-{i:04}-{}", "y".repeat(60)) });
                rows += r.ingest_remote(&[op]).rows.len();
            }
            let parked: Vec<&CrdtOp> =
                r.stored.iter().filter(|(_, k)| matches!(k, super::super::super::fold::RowKind::Parked(_))).map(|(o, _)| o).collect();
            let bytes: usize = parked.iter().map(|o| serde_json::to_string(o).unwrap().len()).sum();
            assert!(
                bytes <= super::super::super::fold::PARK_GROUP_BYTES,
                "{} parked rows, {bytes} bytes held and {rows} rows written for one group (bound {})",
                parked.len(),
                super::super::super::fold::PARK_GROUP_BYTES
            );
        }

        /// Section 7: the cut is monotone, a fact of held rows. A stamped owner checkpoint that
        /// disagrees with its held (unstamped) parent puts the cut in force for one fold, then
        /// drops unstored, so a restart from the rows forgets the cut.
        #[test]
        fn review_the_cut_of_a_dropped_stamped_checkpoint_survives_a_restart() {
            let (mut owner, founding) = owner_on(false);
            let (first, _) = member_writes(&mut owner, &founding);
            // An unstamped generation-0 checkpoint (a 0.13 owner), the owner's base.
            let mut old = owner.lean_snapshot();
            old.owner_pin = None;
            old.checkpoint_hlc = None;
            old.retained_print = None;
            *old.stamps = Default::default();
            old.member_events.clear();
            old.cp_stamped = false;
            old.cp_generation = 0;
            old.cp_parent = None;
            let covers = owner.checkpoint_covers();
            let g0 = owner.create_op(P::ServerCheckpoint { state: serde_json::to_string(&old).unwrap(), covers });
            owner.ingest_remote(std::slice::from_ref(&g0));
            assert_eq!(owner.base.as_ref().map(|b| b.hash), Some(g0.content_hash()));
            // Its stamped child, lineage tampered.
            let covers = owner.checkpoint_covers();
            let mut st: ServerState = serde_json::from_str(&owner.checkpoint_json(&keys(OWNER).1, &[], 0).unwrap()).unwrap();
            assert!(st.cp_stamped);
            st.cp_lineage.push("ab".repeat(32));
            let bad = owner.create_op(P::ServerCheckpoint { state: serde_json::to_string(&st).unwrap(), covers });

            let mut r = ServerState::skeleton(owner.server_id.clone());
            r.authority = view_with(MEMBER_PHONE);
            let mut rows: Vec<(CrdtOp, Option<u64>)> = Vec::new();
            for batch in [first.clone(), vec![g0.clone()], vec![bad.clone()]] {
                let out = r.ingest_remote(&batch);
                rows.retain(|(o, _)| !out.dropped.contains(&(o.author.clone(), o.hlc.clone())));
                for (o, p) in out.rows {
                    rows.retain(|(x, _)| !(x.author == o.author && x.hlc == o.hlc));
                    rows.push((o, p));
                }
            }
            let live = r.cut;
            let mut back = ServerState::skeleton(owner.server_id.clone());
            back.authority = view_with(MEMBER_PHONE);
            back.restore_op_log(rows);
            let again = r.rebuild_now();
            let _ = again;
            assert_eq!((live, back.cut, r.cut), (true, true, true), "(after ingest, after restart, after a rebuild)");
        }

        /// t14-lock R2: the frozen chain the request names is one a 0.13 relay took. A replica
        /// that got it inside a checkpoint's state (or any state written before `base_at`
        /// existed) has no `base_at` for the frozen base, so the owner's later restart must still
        /// start the chain.
        #[test]
        fn review_a_frozen_chain_from_an_older_state_gives_way_to_the_restart() {
            use crate::crdt::lock_state::JoinLockState;
            use crate::identity::native_identity::NativeKeypair;
            use crate::node::join_lock::{mint_owner_base, MAX_N};
            let owner = NativeKeypair::from_secret_bytes(&[1; 32]);
            let device = NativeKeypair::from_secret_bytes(&[11; 32]);
            let nonce = "00112233445566778899aabbccddeeff".to_string();
            let server = crate::crdt::anchor::derive_server_id(&owner.peer_id(), &nonce);
            let at = |ms: u64| crate::crdt::hlc::HlcTimestamp { physical_ms: ms, counter: 0, actor: "o".into() };
            let none = std::collections::BTreeMap::new();
            let frozen = mint_owner_base(&server, MAX_N, &owner, Some(&nonce), &device).unwrap();
            let mut lock = JoinLockState::default();
            lock.apply(&frozen.link, None, &none, &at(1));
            // The same state as a 0.13 (or pre-C1) writer serialized it: no `base_at`.
            let mut json = serde_json::to_value(&lock).unwrap();
            json.as_object_mut().unwrap().remove("base_at");
            let mut old: JoinLockState = serde_json::from_value(json).unwrap();
            assert_eq!(old.chain().first().map(|l| l.n), Some(MAX_N));
            let restart = mint_owner_base(&server, 1, &owner, Some(&nonce), &device).unwrap();
            old.apply(&restart.link, None, &none, &at(5));
            assert_eq!(old.chain().first(), Some(&restart.link), "the restart is pruned: the frozen chain never gives way here");
        }
    }

    /// t14-hidden: a stranger joiner folds the join answer before it holds the owner's
    /// roster. The owner's join lock op then parks like its other ops and folds with the
    /// roster, so the joiner holds the door; a link made by a device the roster does not
    /// count never folds.
    #[test]
    fn a_join_lock_waits_for_the_owners_roster_and_never_folds_from_an_uncounted_maker() {
        use std::sync::atomic::{AtomicBool, Ordering};
        let lock_op = |device: u8| {
            let (mut owner, founding) = owner_on(true);
            let new = crate::node::join_lock::mint_owner_base(&owner.server_id, 1, &keys(OWNER).0, owner.founding_nonce().as_deref(), &keys(device).0)
                .expect("a base");
            let door = Some(super::super::operations::JoinSecret(hex::encode(new.door.as_slice())));
            let op = owner.author_checked(P::JoinLock { link: new.link, door, grants: Default::default() }).expect("the owner locks");
            (founding, op)
        };
        let owner_arrives = |arrived: Arc<AtomicBool>| {
            let entry = authority::judge(&keys(OWNER).1, &KeyRule::FirstHeld, &[&roster_counting(&keys(PHONE).0)]);
            ViewSource(Arc::new(move |_: &ServerState, _: &str| {
                Some(if arrived.load(Ordering::SeqCst) { entry.clone() } else { ViewEntry::default() })
            }))
        };

        let (founding, lock) = lock_op(PHONE);
        let arrived = Arc::new(AtomicBool::new(false));
        let mut r = ServerState::skeleton(founding.server_id.clone());
        r.set_view_source(owner_arrives(arrived.clone()));
        r.ingest_remote(&[founding.clone(), lock.clone()]);
        assert!(r.cut && r.join_lock.newest_door().is_none(), "precondition: no roster, no door yet");
        assert!(parked(&r, &lock), "the lock op waits for the owner's roster, never dropped");
        arrived.store(true, Ordering::SeqCst);
        let _ = r.rebuild_now();
        assert!(folded(&r, &lock), "the roster arrives: the lock op folds");
        assert!(r.join_lock.newest_door().is_some_and(|(n, _, _)| n == 1), "and the joiner holds the door");

        let (founding, stolen) = lock_op(THIEF);
        let mut t = ServerState::skeleton(founding.server_id.clone());
        t.set_view_source(owner_arrives(Arc::new(AtomicBool::new(true))));
        t.ingest_remote(&[founding, stolen.clone()]);
        assert!(!folded(&t, &stolen) && t.join_lock.newest_door().is_none(), "a link a device the roster does not count made folds");
    }

    /// An owner lock op signed for (`base`, then each successor).
    fn lock_ops(owner: &mut ServerState, maker: u8, moves: usize) -> Vec<CrdtOp> {
        use super::super::operations::JoinSecret;
        let door = |d: &[u8; 32]| Some(JoinSecret(hex::encode(d)));
        let mut new = crate::node::join_lock::mint_owner_base(&owner.server_id, 1, &keys(OWNER).0, owner.founding_nonce().as_deref(), &keys(maker).0)
            .expect("a base");
        let mut ops = vec![owner.author_checked(P::JoinLock { link: new.link.clone(), door: door(&new.door), grants: Default::default() }).expect("the base")];
        for _ in 0..moves {
            new = crate::node::join_lock::mint_successor(&owner.server_id, &new.link, &new.change, &keys(OWNER).1, &keys(PHONE).0).expect("a move");
            ops.push(owner.author_checked(P::JoinLock { link: new.link.clone(), door: door(&new.door), grants: Default::default() }).expect("the move"));
        }
        ops
    }

    fn door_n(s: &ServerState) -> Option<u64> {
        s.join_lock.newest_door().map(|(n, _, _)| n)
    }

    /// t14-hidden F1 (i): the lock moved before anyone joined. A stranger joiner holds
    /// neither lock op's maker until the owner's roster lands, so the base parks; the move
    /// rests on it and waits too, never dropped, in one batch or two.
    #[test]
    fn a_lock_moved_before_a_stranger_joins_folds_whole_with_the_owners_roster() {
        use std::sync::atomic::{AtomicBool, Ordering};
        let (mut owner, founding) = owner_on(true);
        let ops = lock_ops(&mut owner, PHONE, 1);
        assert_eq!(door_n(&owner), Some(2), "precondition: the owner holds door 2");
        let entry = authority::judge(&keys(OWNER).1, &KeyRule::FirstHeld, &[&roster_counting(&keys(PHONE).0)]);
        let joiner = |batches: &[&[CrdtOp]]| {
            let arrived = Arc::new(AtomicBool::new(false));
            let (a, entry) = (arrived.clone(), entry.clone());
            let mut r = ServerState::skeleton(founding.server_id.clone());
            r.set_view_source(ViewSource(Arc::new(move |_: &ServerState, _: &str| {
                Some(if a.load(Ordering::SeqCst) { entry.clone() } else { ViewEntry::default() })
            })));
            for batch in batches {
                r.ingest_remote(batch);
            }
            assert!(door_n(&r).is_none(), "precondition: no roster, no door");
            arrived.store(true, Ordering::SeqCst);
            let _ = r.rebuild_now();
            door_n(&r)
        };
        assert_eq!(joiner(&[&[founding.clone(), ops[0].clone(), ops[1].clone()]]), Some(2), "one batch: the move was lost");
        assert_eq!(joiner(&[&[founding.clone(), ops[0].clone()], &[ops[1].clone()]]), Some(2), "two batches: the move was lost");
    }

    /// t14-hidden F1 (ii): the device that made the base was removed, the lock moved on a
    /// counted device and the owner compacted. The base never folds again, nor the move
    /// that rests on it, so the owner's re-signing of the tip carries its door.
    #[test]
    fn a_joiner_after_the_base_makers_removal_holds_the_newest_door() {
        let (mut owner, founding) = owner_on(true);
        let ops = lock_ops(&mut owner, THIEF, 1);
        let tip = owner.join_lock.chain().last().cloned().expect("a tip");
        let base = crate::node::join_lock::owner_signed(&owner.server_id, &tip, &keys(OWNER).0, owner.founding_nonce().as_deref(), &keys(PHONE).0);
        let compact = owner.author_checked(crate::node::lock_keeper::compact_op(&owner, base)).expect("the owner compacts");
        let entry = authority::judge(&keys(OWNER).1, &KeyRule::FirstHeld, &[&roster_counting(&keys(PHONE).0)]);
        let mut j = ServerState::skeleton(founding.server_id.clone());
        j.set_view_source(ViewSource(Arc::new(move |_: &ServerState, _: &str| Some(entry.clone()))));
        j.ingest_remote(&[founding, ops[0].clone(), ops[1].clone(), compact.clone()]);
        assert!(!folded(&j, &ops[0]) && !folded(&j, &ops[1]), "precondition: the removed maker's base and the move on it stay out");
        assert!(folded(&j, &compact), "the compaction folds");
        assert_eq!(door_n(&j), Some(2), "the joiner holds the relay's newest door");
    }

    /// A link a device the owner's roster does not count made parks as a row, and no
    /// rebuild folds it while its maker stays uncounted.
    #[test]
    fn a_link_an_uncounted_device_made_never_folds_on_a_rebuild() {
        let (mut owner, founding) = owner_on(true);
        let ops = lock_ops(&mut owner, THIEF, 0);
        let entry = authority::judge(&keys(OWNER).1, &KeyRule::FirstHeld, &[&roster_counting(&keys(PHONE).0)]);
        let mut t = ServerState::skeleton(founding.server_id.clone());
        t.set_view_source(ViewSource(Arc::new(move |_: &ServerState, _: &str| Some(entry.clone()))));
        t.ingest_remote(&[founding, ops[0].clone()]);
        assert!(parked(&t, &ops[0]), "the link waits as a row");
        for _ in 0..3 {
            let _ = t.rebuild_now();
            assert!(!folded(&t, &ops[0]) && door_n(&t).is_none(), "a link an uncounted device made folded on a rebuild");
        }
    }
}
