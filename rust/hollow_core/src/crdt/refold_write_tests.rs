use std::sync::Arc;

use super::super::authority::{AuthorityView, ViewEntry};
use super::super::fold::RowKind;
use super::super::operations::{CrdtOp, CrdtPayload as P, MemberRole};
use super::super::refold::{ChannelField, ElementKey, Unpublished};
use super::super::server_state::{Founder, ServerState};
use super::super::testkeys::keys;
use super::*;

const OWNER: u8 = 41;
const PHONE: u8 = 42;
const MOD: u8 = 43;
const MOD_PHONE: u8 = 44;
const MOD_LAPTOP: u8 = 45;
const MEMBER: u8 = 46;
const OTHER_MOD: u8 = 47;
const OWNER_LAPTOP: u8 = 48;

fn replica(sid: &str, tag: u8, device: u8) -> ServerState {
    let (kp, id, pk) = keys(tag);
    let (dkp, did, _) = keys(device);
    let mut s = ServerState::skeleton(sid.into());
    s.set_hlc(super::super::hlc::Hlc::for_device(id, &did));
    s.set_signer(kp, pk);
    s.set_device_signer(dkp);
    s
}

fn log_of(s: &ServerState) -> Vec<CrdtOp> {
    s.op_log.iter().chain(s.stored.iter().map(|(o, _)| o)).cloned().collect()
}

fn auth(counted: &[String], removed: &[String]) -> ViewEntry {
    let first = counted.first().cloned().unwrap_or_default();
    ViewEntry {
        key: Some("k".into()),
        auth: Some(crate::identity::roster::Authority {
            key: "k".into(),
            counted: counted.iter().cloned().collect(),
            removed: removed.iter().map(|d| (d.clone(), first.clone())).collect(),
            ..Default::default()
        }),
    }
}

/// The owner counts PHONE (and OWNER_LAPTOP when `two_owner_devices`); MOD counts
/// `mod_counted` and has removed MOD_PHONE; everyone else counts its own key.
fn view(mod_counted: &[String], two_owner_devices: bool) -> Arc<AuthorityView> {
    let mut v = AuthorityView::judging();
    let mut owner = vec![keys(PHONE).1];
    if two_owner_devices {
        owner.push(keys(OWNER_LAPTOP).1);
    }
    v.insert(keys(OWNER).1, auth(&owner, &[]));
    v.insert(keys(MOD).1, auth(mod_counted, &[keys(MOD_PHONE).1]));
    for t in [MEMBER, OTHER_MOD] {
        v.insert(keys(t).1, auth(&[keys(t).1], &[]));
    }
    Arc::new(v)
}

/// An owner checkpoint of `s` that becomes its base.
fn checkpoint(s: &mut ServerState) -> CrdtOp {
    let now = super::super::hlc::wall_clock_ms();
    let covers = s.checkpoint_covers();
    let json = s.checkpoint_json(&keys(OWNER).1, &[], now).expect("a checkpoint state");
    let (op, _) = s.author_checkpoint(P::ServerCheckpoint { state: json, covers }).expect("it becomes the base");
    op
}

/// The owner's server with R (`cp_r`), then admin MOD's phone writing after T, the
/// owner's base folding it, and MOD's laptop's lost-or-stolen DR naming R.
struct World {
    owner: ServerState,
    phone: ServerState,
    laptop: ServerState,
    general: String,
    cp_r: CrdtOp,
    t_ms: i64,
}

impl World {
    fn new() -> Self {
        let (master, m_id, pk) = keys(OWNER);
        let (phone_kp, phone_id, _) = keys(PHONE);
        let (mut owner, _) =
            ServerState::found_on("s".into(), m_id, Founder { device_peer_id: &phone_id, device: Some(&phone_kp), r_pub: None }, master, pk);
        for t in [MOD, MEMBER, OTHER_MOD] {
            let ask = super::super::operations::JoinAsk::sign(&owner.server_id, 1, &keys(t).0);
            owner.author_checked(P::MemberAdded { peer_id: keys(t).1, display_name: "m".into(), follow: None, ask: Some(ask) }).unwrap();
        }
        owner.author_checked(P::RoleChanged { peer_id: keys(MOD).1, role: MemberRole::Admin, priority: 0 }).unwrap();
        owner.author_checked(P::RoleChanged { peer_id: keys(OTHER_MOD).1, role: MemberRole::Moderator, priority: 0 }).unwrap();
        let general = "c-general".to_string();
        owner
            .author_checked(P::ChannelAdded { channel_id: general.clone(), name: "general".into(), category: None, channel_type: "text".into() })
            .unwrap();
        owner.author_checked(P::ChannelAdded { channel_id: "c-two".into(), name: "two".into(), category: None, channel_type: "text".into() }).unwrap();
        let cp_r = checkpoint(&mut owner);
        let mut phone = replica(&owner.server_id, MOD, MOD_PHONE);
        phone.ingest_remote(&log_of(&owner));
        let mut laptop = replica(&owner.server_id, MOD, MOD_LAPTOP);
        laptop.ingest_remote(&log_of(&owner));
        assert!(phone.is_member(&keys(MOD).1) && laptop.is_member(&keys(MOD).1), "precondition: MOD's devices fold R");
        let t_ms = i64::try_from(super::super::hlc::wall_clock_ms()).unwrap() - 1;
        World { owner, phone, laptop, general, cp_r, t_ms }
    }

    /// The laptop or the phone writes `p`; the owner and the laptop fold it.
    fn write(&mut self, laptop: bool, p: P) -> CrdtOp {
        let w = if laptop { &mut self.laptop } else { &mut self.phone };
        let op = w.author_checked(p.clone()).unwrap_or_else(|| panic!("MOD may write {p:?}"));
        assert!(!self.owner.ingest_remote(std::slice::from_ref(&op)).admitted.is_empty(), "the owner folds {p:?}");
        if !laptop {
            self.laptop.ingest_remote(std::slice::from_ref(&op));
        }
        op
    }

    /// The base folds the lane's writes; then MOD's laptop retires its phone naming
    /// `restore`, and the owner's view counts `mod_counted` for MOD.
    fn steal(&mut self, restore: Option<String>, mod_counted: &[String]) -> CrdtOp {
        checkpoint(&mut self.owner);
        self.laptop.ingest_remote(&log_of(&self.owner));
        let dr = self.laptop.create_op(P::DeviceRetired { device: keys(MOD_PHONE).1, ops: Vec::new(), posts_until_ms: Some(self.t_ms), restore });
        self.owner.authority = view(mod_counted, false);
        self.owner.ingest_remote(std::slice::from_ref(&dr));
        assert!(self.owner.every_held().any(|o| o.hlc == dr.hlc), "the owner holds the DR");
        self.fold_recently();
        dr
    }

    fn r_hex(&self) -> String {
        hex::encode(self.cp_r.content_hash())
    }

    /// Every checkpoint of the base's line first folded now.
    fn fold_recently(&mut self) {
        let now = super::super::hlc::wall_clock_ms();
        let b = self.owner.base.as_ref().unwrap();
        let line: Vec<String> = std::iter::once(b.hash_hex()).chain(b.state.cp_lineage.iter().cloned()).collect();
        self.owner.first_folds = Arc::new(line.into_iter().map(|h| (h, now)).collect());
    }

    /// The owner's next due checkpoint; its base's entries.
    fn refold(&mut self) -> Vec<Refolded> {
        let now = super::super::hlc::wall_clock_ms();
        assert!(self.owner.checkpoint_due(&keys(OWNER).1, now), "a re-fold is due");
        self.owner.author_due_checkpoint(&keys(OWNER).1, &[], now).expect("the re-fold checkpoint becomes the base");
        self.fold_recently();
        self.owner.base.as_ref().unwrap().state.cp_refolded.clone()
    }

    fn pinned(&self, h: &str) -> bool {
        self.owner.stored.iter().any(|(o, k)| *k == RowKind::RefoldPin && hex::encode(o.content_hash()) == h)
    }
}

fn laptop_counted() -> Vec<String> {
    vec![keys(MOD_LAPTOP).1]
}

fn answer_of(e: &Refolded, chosen: &[ElementKey], put_back: &[Unpublished]) -> LocalAnswer {
    LocalAnswer {
        member: e.member.clone(),
        device: e.device.clone(),
        dr: e.dr.clone(),
        below: e.below.clone(),
        shown: e.review.clone(),
        chosen: chosen.iter().map(ElementKey::to_key).collect(),
        put_back: put_back.to_vec(),
    }
}

/// The core case (decisions 20, 21): a stolen admin's post-T writes an owner checkpoint
/// folded; AUTO and Unpublish revert at once, the ban waits for the owner's answer.
#[test]
fn a_stolen_mods_post_t_ban_inside_an_owner_checkpoint_is_refolded() {
    let mut w = World::new();
    let member = keys(MEMBER).1;
    w.write(false, P::ServerSettingChanged { key: "description".into(), value: "thief".into() });
    w.write(false, P::MemberBanned { peer_id: member.clone(), seen: None });
    w.write(false, P::ChannelPublicChanged { channel_id: w.general.clone(), is_public: true });
    let dr = w.steal(Some(w.r_hex()), &laptop_counted());
    assert!(w.owner.is_banned(&member) && w.owner.channels[&w.general].effective_public(), "precondition: the base folded the thief's writes");
    assert_eq!(w.owner.refold_triggers().len(), 1, "the DR triggers a re-fold");

    let entries = w.refold();
    assert!(!w.owner.settings.contains_key("description"), "AUTO: the description R lacked is gone");
    assert!(!w.owner.channels[&w.general].effective_public(), "UNPUBLISH: the channel made public after T is closed");
    assert!(w.owner.is_banned(&member), "REVIEW: the ban stands until the owner answers");
    let [e] = entries.as_slice() else { panic!("one entry: {entries:?}") };
    assert_eq!(e.pair(), (keys(MOD).1.as_str(), keys(MOD_PHONE).1.as_str()));
    assert_eq!((e.by.clone(), e.dr.clone(), e.r.clone()), (keys(PHONE).1, hex::encode(dr.content_hash()), w.r_hex()));
    assert!(e.sig_verifies(&w.owner.server_id) && e.opened.is_some() && e.answered.is_none(), "listed, signed by the writing owner device: sig {} opened {:?} answered {:?}", e.sig_verifies(&w.owner.server_id), e.opened, e.answered);
    assert_eq!(e.review.iter().map(|i| i.key.clone()).collect::<Vec<_>>(), vec![ElementKey::Ban(member.clone()).to_key()]);
    assert_eq!(e.unpublished.len(), 1);
    assert!(w.owner.refold_triggers().is_empty(), "the base's entry suppresses the pair");
    assert!(!w.owner.checkpoint_due(&keys(OWNER).1, super::super::hlc::wall_clock_ms()), "nothing more is due");
    assert!(w.pinned(&w.r_hex()) && w.pinned(&e.dr), "R and the DR are pinned while the entry is unanswered");

    let a = answer_of(e, &[ElementKey::Ban(member.clone())], &e.unpublished);
    assert!(w.owner.refold_entry_valid(e), "the entry checks out before it is answered");
    w.owner.refold_answers.push(a);
    let entries = w.refold();
    assert!(!w.owner.is_banned(&member) && w.owner.is_member(&member), "the confirmed ban is undone with its removal");
    assert!(w.owner.channels[&w.general].effective_public(), "Put back opens the channel again");
    let answered = entries[0].valid_answer(&w.owner.server_id).expect("answered, signed by the answering device");
    assert!(!answered.timeout && answered.undone.contains(&ElementKey::Ban(member.clone()).to_key()) && answered.put_back == vec![w.general.clone()]);
    assert!(entries[0].review.is_empty() && entries[0].unpublished.is_empty());
    assert!(!w.pinned(&w.r_hex()), "R goes once no unanswered entry needs it");
    assert!(w.pinned(&entries[0].dr), "the DR stays 30 days after the entry");
    assert!(w.owner.refold_triggers().is_empty(), "an answered entry still suppresses");
}
/// A device id sharing MOD_PHONE's HLC lane (found offline: 24-bit lanes).
const PHONE_TWIN: &str = "twin-34228178";

/// The world with the phone's description write after R, stolen with `restore` and the
/// view counting `mod_counted`: whether a re-fold is due.
fn due_after(restore: impl FnOnce(&World) -> Option<String>, mod_counted: &[String]) -> (World, bool) {
    let mut w = World::new();
    w.write(false, P::ServerSettingChanged { key: "description".into(), value: "thief".into() });
    let restore = restore(&w);
    w.steal(restore, mod_counted);
    let due = !w.owner.refold_triggers().is_empty() || w.owner.checkpoint_due(&keys(OWNER).1, super::super::hlc::wall_clock_ms());
    (w, due)
}

#[test]
fn trigger_clauses_hold_or_nothing_refolds() {
    assert_eq!(super::super::hlc::lane_of(PHONE_TWIN), super::super::hlc::lane_of(&keys(MOD_PHONE).1), "precondition: the twin shares the lane");
    let (_, due) = due_after(|w| Some(w.r_hex()), &laptop_counted());
    assert!(due, "control: a counted DR naming R on the line re-folds");
}

#[test]
fn a_member_retire_never_refolds() {
    let (_, due) = due_after(|_| None, &laptop_counted());
    assert!(!due, "a retire (no restore) re-folds nothing");
}

#[test]
fn a_dr_without_restore_or_off_the_line_never_refolds() {
    let (_, due) = due_after(|_| Some("a".repeat(64)), &laptop_counted());
    assert!(!due, "a restore off the base's line re-folds nothing");
}

#[test]
fn a_dr_naming_a_still_counted_device_never_refolds() {
    let (_, due) = due_after(|w| Some(w.r_hex()), &[keys(MOD_LAPTOP).1, keys(MOD_PHONE).1]);
    assert!(!due, "the member still counts the device: nothing is reverted");
}

#[test]
fn a_dr_whose_lane_collides_with_a_sibling_never_refolds() {
    let (_, due) = due_after(|w| Some(w.r_hex()), &[keys(MOD_LAPTOP).1, PHONE_TWIN.to_string()]);
    assert!(!due, "a counted sibling in the dropped lane: its writes cannot be told apart");
}

/// R34-4: a twin the stolen device vouched into its own lane is removed with it, so it
/// blocks nothing.
#[test]
fn a_lane_twin_vouched_by_the_stolen_device_never_blocks_its_refold() {
    let mut w = World::new();
    w.write(false, P::ServerSettingChanged { key: "description".into(), value: "thief".into() });
    let restore = Some(w.r_hex());
    w.steal(restore, &laptop_counted());
    let mut v = (*view(&laptop_counted(), false)).clone();
    v.insert(keys(MOD).1, auth(&laptop_counted(), &[keys(MOD_PHONE).1, PHONE_TWIN.to_string()]));
    w.owner.authority = Arc::new(v);
    assert_eq!(w.owner.refold_triggers().len(), 1, "a removed twin shares only writes being dropped anyway");
    w.refold();
    assert!(!w.owner.settings.contains_key("description"));
}

/// R is never older than what this owner device first folded within 30 days.
#[test]
fn a_members_refold_never_reaches_past_30_days() {
    let mut w = World::new();
    w.write(false, P::ServerSettingChanged { key: "description".into(), value: "thief".into() });
    let restore = Some(w.r_hex());
    w.steal(restore, &laptop_counted());
    let old = super::super::hlc::wall_clock_ms() - super::super::refold::R_REACH_MS - 1;
    let mut folds = (*w.owner.first_folds).clone();
    folds.insert(w.r_hex(), old);
    w.owner.first_folds = Arc::new(folds);
    let base = w.owner.base.as_ref().unwrap().hash_hex();
    assert_eq!(w.owner.refold_point(&w.r_hex(), super::super::hlc::wall_clock_ms()).map(|b| b.hash_hex()), Some(base), "R clamps to the base");
    let entries = w.refold();
    assert_eq!(w.owner.settings.get("description").map(|r| r.read().clone()), Some("thief".to_string()), "nothing older than 30 days comes back");
    assert!(entries[0].answered.is_some(), "an entry with nothing to list is written answered");
}

/// Only the dropped device's own lane: the member's laptop and another master's ban stay.
#[test]
fn a_refold_reverts_only_the_dropped_devices_lane() {
    let mut w = World::new();
    let member = keys(MEMBER).1;
    w.write(false, P::ServerRenamed { new_name: "thief".into() });
    w.write(true, P::ServerSettingChanged { key: "description".into(), value: "laptop".into() });
    let other_ban = {
        let mut other = replica(&w.owner.server_id, OTHER_MOD, OTHER_MOD);
        other.ingest_remote(&log_of(&w.owner));
        let op = other.author_checked(P::MemberBanned { peer_id: member.clone(), seen: None }).expect("a moderator bans");
        w.owner.ingest_remote(std::slice::from_ref(&op));
        op
    };
    let restore = Some(w.r_hex());
    w.steal(restore, &laptop_counted());
    let entries = w.refold();
    assert_ne!(w.owner.name.read(), "thief", "the phone's rename is undone");
    assert_eq!(w.owner.settings.get("description").map(|r| r.read().clone()), Some("laptop".to_string()), "the laptop's write stays");
    assert!(w.owner.is_banned(&member) && w.owner.banned_members[&member].hlc() == &other_ban.hlc, "another master's ban stays");
    assert!(entries[0].answered.is_some(), "nothing to review");
}

/// R33-10 and R34-7: a reverted rename folds the honest held rename on top; undoing the
/// lane's deletion brings R's entry back with R's sub-stamps, for admins only.
#[test]
fn a_reverted_existence_resets_its_sub_stamps_and_refolds_held_ops() {
    let mut w = World::new();
    let general = w.general.clone();
    w.write(true, P::ChannelRenamed { channel_id: general.clone(), new_name: "honest".into() });
    w.write(false, P::ChannelRenamed { channel_id: general.clone(), new_name: "thief".into() });
    let two = "c-two".to_string();
    let gone = w.write(false, P::ChannelRemoved { channel_id: two.clone() });
    let restore = Some(w.r_hex());
    w.steal(restore, &laptop_counted());
    let entries = w.refold();
    assert_eq!(w.owner.channels[&general].name, "honest", "the honest rename held lands again on the revert, the thief's does not");
    let written = &w.owner.base.as_ref().expect("the re-fold checkpoint").state;
    assert_eq!(written.channels[&general].name, "honest", "the checkpoint a joiner installs carries the honest rename, not R's");
    assert!(!w.owner.channels.contains_key(&two), "existence waits for the owner");
    let e = &entries[0];
    let key = ElementKey::ChannelExist(two.clone());
    assert!(e.review.iter().any(|i| i.key == key.to_key() && i.stamp == gone.hlc), "the deletion is listed: {:?}", e.review);
    w.owner.refold_answers.push(answer_of(e, &[key], &[]));
    w.refold();
    let ch = w.owner.channels.get(&two).expect("the channel is back");
    assert_eq!(ch.name, "two", "R's entry, its sub-stamps reset to R's");
    let name = ElementKey::ChannelField(two.clone(), ChannelField::Name);
    let r_state = w.owner.base_by_hash(&w.r_hex()).map(|b| super::super::refold::winning_stamp(&b.state, &name));
    assert_eq!(r_state, Some(super::super::refold::winning_stamp(&w.owner, &name)));
    assert_eq!(ch.visibility, super::super::server_state::ChannelVisibility::AdminPlus, "back for admins only");
    assert_eq!(ch.posting, super::super::server_state::ChannelPosting::AdminPlus);
}

#[test]
fn undoing_a_deletion_brings_access_back_at_its_most_restrictive() {
    let mut w = World::new();
    let general = w.general.clone();
    w.write(true, P::ChannelPublicChanged { channel_id: general.clone(), is_public: true });
    w.write(false, P::ChannelRemoved { channel_id: general.clone() });
    let restore = Some(w.r_hex());
    w.steal(restore, &laptop_counted());
    let entries = w.refold();
    w.owner.refold_answers.push(answer_of(&entries[0], &[ElementKey::ChannelExist(general.clone())], &[]));
    w.refold();
    let ch = w.owner.channels.get(&general).expect("the channel is back");
    assert!(ch.restricted() && !ch.effective_public(), "an honest public flag from before the deletion never comes back with it");
}

/// The first re-fold per pair wins: a sibling owner device whose base carries the entry
/// re-folds nothing; an entry not signed by a counted owner device suppresses nothing.
#[test]
fn a_sibling_owner_device_never_refolds_a_pair_in_cp_refolded() {
    let mut w = World::new();
    w.write(false, P::ServerSettingChanged { key: "description".into(), value: "thief".into() });
    let restore = Some(w.r_hex());
    w.steal(restore, &laptop_counted());
    w.refold();
    let mut sibling = replica(&w.owner.server_id, OWNER, OWNER_LAPTOP);
    sibling.authority = view(&laptop_counted(), true);
    sibling.ingest_remote(&log_of(&w.owner));
    assert!(sibling.base.as_ref().is_some_and(|b| !b.state.cp_refolded.is_empty()), "precondition: the sibling folds the re-fold");
    assert!(sibling.refold_triggers().is_empty(), "its entry stops a second re-fold");
}

#[test]
fn a_fabricated_or_uncounted_cp_refolded_entry_suppresses_nothing() {
    for (signer, by) in [(MOD_LAPTOP, None), (PHONE, Some(OWNER_LAPTOP))] {
        let mut w = World::new();
        w.write(false, P::ServerSettingChanged { key: "description".into(), value: "thief".into() });
        let restore = Some(w.r_hex());
        let dr = w.steal(restore, &laptop_counted());
        let mut fake = Refolded {
            member: keys(MOD).1,
            device: keys(MOD_PHONE).1,
            dr: hex::encode(dr.content_hash()),
            r: w.r_hex(),
            at: dr.hlc.clone(),
            opened: None,
            below: None,
            review: vec![],
            unpublished: vec![],
            by: String::new(),
            sig: String::new(),
            answered: None,
        };
        fake.sign(&w.owner.server_id, &keys(signer).0);
        if let Some(other) = by {
            fake.by = keys(other).1;
        }
        let base = w.owner.base.as_mut().unwrap();
        Arc::make_mut(&mut base.state).cp_refolded = vec![fake];
        assert_eq!(w.owner.refold_triggers().len(), 1, "an entry by {signer} as {by:?} suppresses nothing");
        let entries = w.refold();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].by, keys(PHONE).1, "the real re-fold replaces it");
        assert!(!w.owner.settings.contains_key("description"));
    }
}

/// R31-10: a re-fold that loses a same-generation tie to a sibling's ordinary
/// checkpoint is written again on top of the winner.
#[test]
fn a_refold_that_loses_a_tie_runs_again() {
    let mut w = World::new();
    w.write(false, P::ServerSettingChanged { key: "description".into(), value: "thief".into() });
    let restore = Some(w.r_hex());
    w.steal(restore, &laptop_counted());
    let mut sibling = replica(&w.owner.server_id, OWNER, OWNER_LAPTOP);
    sibling.ingest_remote(&log_of(&w.owner).into_iter().filter(|o| !matches!(o.payload, P::DeviceRetired { .. })).collect::<Vec<_>>());
    let lost = w.owner.clone();
    w.refold();
    std::thread::sleep(std::time::Duration::from_millis(5));
    let theirs = checkpoint(&mut sibling);
    w.owner = lost;
    w.owner.authority = view(&laptop_counted(), true);
    w.owner.ingest_remote(std::slice::from_ref(&theirs));
    assert_eq!(w.owner.base.as_ref().unwrap().hlc, theirs.hlc, "precondition: the sibling's checkpoint won");
    w.fold_recently();
    assert_eq!(w.owner.refold_triggers().len(), 1, "the pair is not on the base: the re-fold is owed again");
    let entries = w.refold();
    assert_eq!(entries.len(), 1);
    assert!(!w.owner.settings.contains_key("description"));
}

/// T is read only on the member's clock: a public write at or before T waits for the owner.
#[test]
fn a_refold_reads_t_only_on_the_members_clock() {
    let mut w = World::new();
    w.write(false, P::ChannelPublicChanged { channel_id: w.general.clone(), is_public: true });
    w.t_ms = i64::try_from(super::super::hlc::wall_clock_ms()).unwrap() + 60_000;
    let restore = Some(w.r_hex());
    w.steal(restore, &laptop_counted());
    let entries = w.refold();
    assert!(w.owner.channels[&w.general].effective_public(), "stamped before the member's T: not undone without the owner");
    assert!(entries[0].unpublished.is_empty() && entries[0].review.iter().any(|i| i.key == ElementKey::ChannelPublic(w.general.clone()).to_key()));
}

/// A listed entry closes as kept 30 days after it opened (owner clocks); a person's
/// answer stored meanwhile replaces the timeout once.
#[test]
fn a_listed_entry_times_out_and_a_stored_answer_still_applies() {
    let mut w = World::new();
    let member = keys(MEMBER).1;
    w.write(false, P::MemberBanned { peer_id: member.clone(), seen: None });
    let restore = Some(w.r_hex());
    w.steal(restore, &laptop_counted());
    let entries = w.refold();
    let shown = entries[0].clone();
    let sid = w.owner.server_id.clone();
    let base = w.owner.base.as_mut().unwrap();
    let st = Arc::make_mut(&mut base.state);
    let e = &mut st.cp_refolded[0];
    e.opened.as_mut().unwrap().physical_ms -= super::super::refold::LISTED_TIMEOUT_MS + 1;
    e.sign(&sid, &keys(PHONE).0);
    let entries = w.refold();
    assert!(entries[0].valid_answer(&sid).is_some_and(|a| a.timeout), "closed after 30 days");
    assert!(w.owner.is_banned(&member), "a timeout keeps everything");
    w.owner.refold_answers.push(answer_of(&shown, &[ElementKey::Ban(member.clone())], &[]));
    let entries = w.refold();
    assert!(entries[0].valid_answer(&sid).is_some_and(|a| !a.timeout), "the person's answer replaces the timeout");
    assert!(!w.owner.is_banned(&member));
}

/// D35-1: a settling carries R's entries; a re-fold written after R is not among them,
/// so the pair re-folds again on the settling and its post-R answer opens again.
#[test]
fn a_settling_reruns_a_post_r_refold_and_reopens_its_answer() {
    let mut w = World::new();
    let member = keys(MEMBER).1;
    w.write(false, P::ServerSettingChanged { key: "description".into(), value: "thief".into() });
    w.write(false, P::MemberBanned { peer_id: member.clone(), seen: None });
    let restore = Some(w.r_hex());
    w.steal(restore, &laptop_counted());
    let entries = w.refold();
    w.owner.refold_answers.push(answer_of(&entries[0], &[], &[]));
    let entries = w.refold();
    assert!(entries[0].answered.is_some(), "precondition: answered after R");
    w.owner.refold_answers.clear();
    // What a settling from R carries: R's entries (none), re-signed and filtered.
    let mut carried = Vec::new();
    let counts = |d: &str| d == keys(PHONE).1;
    resign_for_settling(&mut carried, &w.owner.server_id, &[keys(OWNER_LAPTOP).1], &keys(PHONE).0, &counts);
    let base = w.owner.base.as_mut().unwrap();
    Arc::make_mut(&mut base.state).cp_refolded = carried;
    assert_eq!(w.owner.refold_triggers().len(), 1, "the pair is owed again on the settling");
    let entries = w.refold();
    assert!(entries[0].answered.is_none() && !entries[0].review.is_empty(), "the review opens again: a post-R answer is not re-applied");
    assert!(w.owner.is_banned(&member));
}

/// D35-1 and section 8.5: what a dropped device signed is signed again by the settler;
/// an answer no counted owner device signed is void.
#[test]
fn a_settling_resigns_what_its_dropped_devices_signed() {
    let sid = "s";
    let at = HlcTimestamp { physical_ms: 9, counter: 0, actor: keys(OWNER).1 };
    let mk = |member: u8, signer: u8, answerer: Option<u8>| {
        let mut e = Refolded {
            member: keys(member).1,
            device: keys(MOD_PHONE).1,
            dr: "a".repeat(64),
            r: "b".repeat(64),
            at: at.clone(),
            opened: None,
            below: None,
            review: vec![],
            unpublished: vec![],
            by: String::new(),
            sig: String::new(),
            answered: None,
        };
        e.sign(sid, &keys(signer).0);
        if let Some(a) = answerer {
            e.answer(sid, &keys(a).0, vec!["k".into()], vec![], vec![], false);
        }
        e
    };
    let mut entries = vec![mk(MOD, OWNER_LAPTOP, Some(OWNER_LAPTOP)), mk(MEMBER, PHONE, Some(MOD_LAPTOP)), mk(OTHER_MOD, MOD_LAPTOP, None)];
    let counts = |d: &str| d == keys(PHONE).1;
    resign_for_settling(&mut entries, sid, &[keys(OWNER_LAPTOP).1], &keys(PHONE).0, &counts);
    assert_eq!(entries.len(), 2, "an entry no owner device signed goes");
    let a = &entries[0];
    assert!(a.by == keys(PHONE).1 && a.sig_verifies(sid), "the dropped device's entry is the settler's now");
    assert!(a.valid_answer(sid).is_some_and(|x| x.by == keys(PHONE).1 && x.undone == vec!["k".to_string()]), "its answer too, unchanged");
    assert!(entries[1].answered.is_none(), "an answer by a device the view does not count re-opens its entry");
}

/// Section 8.5: an honest retire of an owner device keeps the reviews it answered.
#[test]
fn an_honest_retire_of_an_owner_device_keeps_its_answers() {
    let mut w = World::new();
    w.write(false, P::MemberBanned { peer_id: keys(MEMBER).1, seen: None });
    let restore = Some(w.r_hex());
    w.steal(restore, &laptop_counted());
    let entries = w.refold();
    let sid = w.owner.server_id.clone();
    let mut by_laptop = entries[0].clone();
    by_laptop.review.clear();
    by_laptop.sign(&sid, &keys(OWNER_LAPTOP).0);
    by_laptop.answer(&sid, &keys(OWNER_LAPTOP).0, vec![], vec![], vec![], false);
    let base = w.owner.base.as_mut().unwrap();
    Arc::make_mut(&mut base.state).cp_refolded = vec![by_laptop];
    let mut v = (*view(&laptop_counted(), false)).clone();
    v.insert(keys(OWNER).1, auth(&[keys(PHONE).1], &[keys(OWNER_LAPTOP).1]));
    w.owner.authority = Arc::new(v);
    assert!(w.owner.carried_refolded().is_empty(), "control: rule 3 drops what an uncounted device signed");
    let retire = w.owner.create_op(P::DeviceRetired { device: keys(OWNER_LAPTOP).1, ops: Vec::new(), posts_until_ms: None, restore: None });
    w.owner.ingest_remote(std::slice::from_ref(&retire));
    let now = super::super::hlc::wall_clock_ms();
    w.owner.author_due_checkpoint(&keys(OWNER).1, &[], now + 3_600_001).or_else(|| {
        let covers = w.owner.checkpoint_covers();
        let json = w.owner.checkpoint_json(&keys(OWNER).1, &[], now).unwrap();
        w.owner.author_checkpoint(P::ServerCheckpoint { state: json, covers })
    });
    let entries = &w.owner.base.as_ref().unwrap().state.cp_refolded;
    assert_eq!(entries.len(), 1, "the retired device's entry is carried");
    assert!(entries[0].by == keys(PHONE).1 && entries[0].valid_answer(&sid).is_some_and(|a| a.by == keys(PHONE).1), "re-signed by the remover, answer kept");
}

/// R34-5: at most eight entries list at once, one per author, by standing; the rest wait
/// with no items and no `opened`, re-signed by the writer.
#[test]
fn a_flood_of_reviews_never_displaces_an_established_members_listing() {
    let mut w = World::new();
    let tags: Vec<u8> = (60..69).collect();
    for t in &tags {
        let ask = super::super::operations::JoinAsk::sign(&w.owner.server_id, 1, &keys(*t).0);
        w.owner.author_checked(P::MemberAdded { peer_id: keys(*t).1, display_name: "f".into(), follow: None, ask: Some(ask) }).unwrap();
    }
    checkpoint(&mut w.owner);
    let mut v = (*view(&laptop_counted(), false)).clone();
    for t in &tags {
        v.insert(keys(*t).1, auth(&[keys(*t).1], &[]));
    }
    w.owner.authority = Arc::new(v);
    let sid = w.owner.server_id.clone();
    let at = HlcTimestamp { physical_ms: 9, counter: 0, actor: keys(OWNER).1 };
    let mut fake: Vec<Refolded> = std::iter::once(MOD)
        .chain(tags.iter().copied())
        .map(|t| {
            let mut e = Refolded {
                member: keys(t).1,
                device: format!("dev-{t}"),
                dr: "a".repeat(64),
                r: "b".repeat(64),
                at: at.clone(),
                opened: Some(at.clone()),
                below: None,
                review: vec![RefoldItem { key: ElementKey::Name.to_key(), stamp: at.clone() }],
                unpublished: vec![],
                by: String::new(),
                sig: String::new(),
                answered: None,
            };
            e.sign(&sid, &keys(PHONE).0);
            e
        })
        .collect();
    fake.reverse();
    let base = w.owner.base.as_mut().unwrap();
    Arc::make_mut(&mut base.state).cp_refolded = fake;
    checkpoint(&mut w.owner);
    let entries = &w.owner.base.as_ref().unwrap().state.cp_refolded;
    assert_eq!(entries.len(), 10);
    let listed: Vec<&Refolded> = entries.iter().filter(|e| e.opened.is_some()).collect();
    assert_eq!(listed.len(), MAX_LISTED, "eight listed");
    assert!(listed.iter().any(|e| e.member == keys(MOD).1), "the admin's review stays listed");
    let waiting: Vec<&Refolded> = entries.iter().filter(|e| e.opened.is_none()).collect();
    assert!(waiting.iter().all(|e| e.review.is_empty() && e.sig_verifies(&sid)), "the rest wait, re-signed");
    assert!(waiting.iter().all(|e| [keys(67).1, keys(68).1].contains(&e.member)), "the newest members wait: {:?}", waiting.iter().map(|e| &e.member).collect::<Vec<_>>());
}

/// R33-7: an entry naming a DR that is not a counted DR for its own pair suppresses nothing.
#[test]
fn an_entry_naming_another_pairs_dr_suppresses_nothing() {
    let mut w = World::new();
    w.write(false, P::ServerSettingChanged { key: "description".into(), value: "thief".into() });
    let restore = Some(w.r_hex());
    w.steal(restore, &laptop_counted());
    let entries = w.refold();
    let sid = w.owner.server_id.clone();
    let mut other = entries[0].clone();
    other.dr = w.r_hex();
    other.sign(&sid, &keys(PHONE).0);
    let base = w.owner.base.as_mut().unwrap();
    Arc::make_mut(&mut base.state).cp_refolded = vec![other];
    assert_eq!(w.owner.refold_triggers().len(), 1, "a held op under that id that is no DR of the pair stops nothing");
}

/// R34-1: every owner device shows only an entry signed by an owner device its view
/// counts, and of it only the items still in the dropped lane.
#[test]
fn a_forged_entry_is_never_shown() {
    let mut w = World::new();
    let member = keys(MEMBER).1;
    w.write(false, P::MemberBanned { peer_id: member.clone(), seen: None });
    let other_mute = {
        let mut other = replica(&w.owner.server_id, OTHER_MOD, OTHER_MOD);
        other.ingest_remote(&log_of(&w.owner));
        let op = other.author_checked(P::MemberMuted { peer_id: keys(MEMBER).1, expires_at: u64::MAX }).expect("a moderator mutes");
        w.owner.ingest_remote(std::slice::from_ref(&op));
        op
    };
    let restore = Some(w.r_hex());
    w.steal(restore, &laptop_counted());
    let entries = w.refold();
    let me = keys(OWNER).1;
    let shown = w.owner.refold_shown(&me);
    assert_eq!(shown.len(), 1, "control: the real entry is shown");
    assert_eq!(shown[0].items.len(), 1, "control: with its ban");
    assert!(w.owner.refold_shown(&keys(MOD).1).is_empty(), "nobody but the owner is shown a list");
    let sid = w.owner.server_id.clone();
    let mut tampered = entries[0].clone();
    tampered.by = keys(OWNER_LAPTOP).1;
    let mut by_member = entries[0].clone();
    by_member.sign(&sid, &keys(MOD_LAPTOP).0);
    let mut smuggled = entries[0].clone();
    smuggled.review.push(RefoldItem { key: ElementKey::Mute(member.clone()).to_key(), stamp: other_mute.hlc.clone() });
    smuggled.sign(&sid, &keys(PHONE).0);
    let mut altered = entries[0].clone();
    altered.at.counter += 1;
    for (what, e) in [("a broken signature", tampered), ("a member's device", by_member), ("a field changed after its counted device signed", altered)] {
        let base = w.owner.base.as_mut().unwrap();
        Arc::make_mut(&mut base.state).cp_refolded = vec![e];
        assert!(w.owner.refold_shown(&me).is_empty(), "an entry with {what} shows nothing");
    }
    let base = w.owner.base.as_mut().unwrap();
    Arc::make_mut(&mut base.state).cp_refolded = vec![smuggled];
    let shown = w.owner.refold_shown(&me);
    assert_eq!(shown[0].items.len(), 1, "an item another master wrote is never shown, even inside a signed entry");
}

/// REVIEW (part A): an entry the base carries (its owner signer counts) whose own DR no
/// longer counts here does not suppress the pair (`entry_dr_fits`), but the writer skips
/// every pair the carried entries name. A second counted DR for the same device then
/// keeps `refold_due` true after every checkpoint, past `CHECKPOINT_MIN_GAP_MS`.
#[test]
fn review_a_second_dr_after_the_first_signer_is_removed_never_keeps_a_refold_due() {
    const MOD_TABLET: u8 = 49;
    let mut w = World::new();
    w.write(false, P::MemberBanned { peer_id: keys(MEMBER).1, seen: None });
    w.steal(Some(w.r_hex()), &laptop_counted());
    let entries = w.refold();
    assert_eq!(entries.len(), 1, "precondition: one unanswered entry for (MOD, phone)");
    // MOD drops its laptop (DR1's signer) and its tablet writes a second lost-or-stolen DR.
    let mut tablet = replica(&w.owner.server_id, MOD, MOD_TABLET);
    tablet.ingest_remote(&log_of(&w.owner));
    w.owner.authority = view(&[keys(MOD_TABLET).1], false);
    let mut forced = 0;
    for k in 0..4i64 {
        let dr = tablet.create_op(P::DeviceRetired { device: keys(MOD_PHONE).1, ops: Vec::new(), posts_until_ms: Some(w.t_ms - k), restore: Some(w.r_hex()) });
        w.owner.ingest_remote(std::slice::from_ref(&dr));
        for _ in 0..5 {
            let now = super::super::hlc::wall_clock_ms();
            if !w.owner.checkpoint_due(&keys(OWNER).1, now) {
                break;
            }
            forced += 1;
            w.owner.author_due_checkpoint(&keys(OWNER).1, &[], now).expect("a checkpoint");
            w.fold_recently();
        }
    }
    assert_eq!(forced, 0, "four DRs for a pair the base already names forced {forced} owner checkpoints past the hourly gap");
}

/// Section 8.3, "Suppression": an entry whose DR no longer counts suppresses nothing, so
/// the writer replaces it. Once the hourly gap has passed, a counted DR for the same pair
/// re-folds ONE checkpoint, its entry naming the new DR, and nothing more is due.
#[test]
fn an_entry_whose_dr_no_longer_counts_is_replaced_once_past_the_gap() {
    const MOD_TABLET: u8 = 49;
    let mut w = World::new();
    w.write(false, P::MemberBanned { peer_id: keys(MEMBER).1, seen: None });
    w.steal(Some(w.r_hex()), &laptop_counted());
    assert_eq!(w.refold().len(), 1, "precondition: one entry for (MOD, phone)");
    let mut tablet = replica(&w.owner.server_id, MOD, MOD_TABLET);
    tablet.ingest_remote(&log_of(&w.owner));
    w.owner.authority = view(&[keys(MOD_TABLET).1], false);
    let dr = tablet.create_op(P::DeviceRetired { device: keys(MOD_PHONE).1, ops: Vec::new(), posts_until_ms: Some(w.t_ms), restore: Some(w.r_hex()) });
    w.owner.ingest_remote(std::slice::from_ref(&dr));
    let later = super::super::hlc::wall_clock_ms() + 3_600_000 + 1;
    assert!(w.owner.checkpoint_due(&keys(OWNER).1, later), "past the gap the second DR re-folds");
    w.owner.author_due_checkpoint(&keys(OWNER).1, &[], later).expect("a checkpoint");
    let entries = &w.owner.base.as_ref().unwrap().state.cp_refolded;
    assert_eq!(entries.iter().map(|e| e.dr.clone()).collect::<Vec<_>>(), vec![hex::encode(dr.content_hash())], "the entry names the counted DR");
    assert!(!w.owner.checkpoint_due(&keys(OWNER).1, later), "nothing more is due once the entry suppresses its pair");
}

/// Section 8.3, "Confirm": the owner's answer is kept across a restart until a checkpoint
/// carries it, so the chosen undo still happens; a restart that holds no stored answer
/// changes nothing.
#[test]
fn an_owner_answer_survives_a_restart_until_a_checkpoint_carries_it() {
    let mut w = World::new();
    let member = keys(MEMBER).1;
    w.write(false, P::MemberBanned { peer_id: member.clone(), seen: None });
    w.steal(Some(w.r_hex()), &laptop_counted());
    let entries = w.refold();
    let e = &entries[0];
    w.owner
        .take_refold_answer(&keys(OWNER).1, &e.member, &e.device, e.below.clone(), &[ElementKey::Ban(member.clone()).to_key()], &[])
        .expect("the owner confirms the ban's undo");
    let stored = w.owner.refold_answers_json().expect("an answer to keep");
    let rows: Vec<(CrdtOp, Option<u64>)> =
        w.owner.op_log.iter().map(|o| (o.clone(), None)).chain(w.owner.stored.iter().map(|(o, k)| (o.clone(), k.parked_until()))).collect();
    let mut back = w.owner.lean_snapshot();
    back.set_hlc(super::super::hlc::Hlc::for_device(keys(OWNER).1, &keys(PHONE).1));
    back.set_signer(keys(OWNER).0, keys(OWNER).2);
    back.set_device_signer(keys(PHONE).0);
    back.authority = w.owner.authority.clone();
    let _ = back.restore_rows(rows);
    assert!(back.refold_answers.is_empty(), "precondition: the restart itself keeps nothing in RAM");
    back.restore_refold_answers(&stored);
    w.owner = back;
    w.fold_recently();
    let entries = w.refold();
    assert!(!w.owner.is_banned(&member), "the confirmed undo is applied after the restart");
    assert!(entries[0].valid_answer(&w.owner.server_id).is_some_and(|a| a.undone == vec![ElementKey::Ban(member.clone()).to_key()]));
    assert!(w.owner.settle_refold_answers() && w.owner.refold_answers_json().is_none(), "carried: the stored answer goes");
}
