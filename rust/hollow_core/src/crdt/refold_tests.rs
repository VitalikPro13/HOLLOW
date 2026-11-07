use super::super::operations::{CrdtOp, CrdtPayload as P, MemberRole, OpRef};
use super::super::server_state::{Founder, ServerState};
use super::super::testkeys::keys;
use super::*;

const OWNER: u8 = 31;
const PHONE: u8 = 32;
const MOD: u8 = 33;
const MOD_PHONE: u8 = 34;
const MOD_LAPTOP: u8 = 35;
const MEMBER: u8 = 36;
const OTHER_MOD: u8 = 37;

fn admit(owner: &mut ServerState, tag: u8) {
    let ask = super::super::operations::JoinAsk::sign(&owner.server_id, 1, &keys(tag).0);
    owner.author_checked(P::MemberAdded { peer_id: keys(tag).1, display_name: "m".into(), follow: None, ask: Some(ask) }).unwrap();
}

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

/// The owner's state R, then admin MOD's two devices writing: `phone` is the dropped one.
struct World {
    r: ServerState,
    owner: ServerState,
    phone: ServerState,
    laptop: ServerState,
    general: String,
}

fn world() -> World {
    let (master, m_id, pk) = keys(OWNER);
    let (phone_kp, phone_id, _) = keys(PHONE);
    let (mut owner, _) = ServerState::found_on("s".into(), m_id, Founder { device_peer_id: &phone_id, device: Some(&phone_kp), r_pub: None }, master, pk);
    for t in [MOD, MEMBER, OTHER_MOD] {
        admit(&mut owner, t);
    }
    owner.author_checked(P::RoleChanged { peer_id: keys(MOD).1, role: MemberRole::Admin, priority: 0 }).unwrap();
    owner.author_checked(P::RoleChanged { peer_id: keys(OTHER_MOD).1, role: MemberRole::Moderator, priority: 0 }).unwrap();
    let general = "c-general".to_string();
    owner.author_checked(P::ChannelAdded { channel_id: general.clone(), name: "general".into(), category: None, channel_type: "text".into() }).unwrap();
    assert!(owner.is_member(&keys(MOD).1), "precondition: the owner admitted MOD");
    let mut phone = replica(&owner.server_id, MOD, MOD_PHONE);
    let took = phone.ingest_remote(&log_of(&owner));
    assert!(phone.is_member(&keys(MOD).1), "precondition: MOD's phone folds its admission: {} admitted of {}, {} rejected", took.admitted.len(), log_of(&owner).len(), took.rejected);
    let mut laptop = replica(&owner.server_id, MOD, MOD_LAPTOP);
    laptop.ingest_remote(&log_of(&owner));
    World { r: owner.clone(), owner, phone, laptop, general }
}

impl World {
    /// `writer` authors `p`; the owner folds it.
    fn write(&mut self, laptop: bool, p: P) -> CrdtOp {
        let w = if laptop { &mut self.laptop } else { &mut self.phone };
        let op = w.author_checked(p.clone()).unwrap_or_else(|| panic!("the moderator may write {p:?}: member={}", w.is_member(&keys(MOD).1)));
        assert!(!self.owner.ingest_remote(std::slice::from_ref(&op)).admitted.is_empty(), "the owner folds it");
        op
    }

    fn lane(&self) -> Lane<'static> {
        Lane::new(Box::leak(keys(MOD).1.into_boxed_str()), &keys(MOD_PHONE).1, &[])
    }
}

/// The re-fold checkpoint's clock: after every write.
fn refold_at() -> HlcTimestamp {
    HlcTimestamp { physical_ms: super::super::hlc::wall_clock_ms() + 1_000, counter: 0, actor: keys(OWNER).1 }
}

fn keys_of(ws: &[LaneWrite]) -> Vec<ElementKey> {
    ws.iter().map(|w| w.key.clone()).collect()
}

#[test]
fn excluded_payloads_are_never_listed() {
    let stamp = P::FloorMark { cp: "00".into() };
    assert_eq!(payload_kind(&stamp), PayloadKind::Excluded);
    assert_eq!(payload_kind(&P::DeviceRetired { device: "d".into(), ops: vec![], posts_until_ms: None, restore: None }), PayloadKind::Excluded);
    assert_eq!(payload_kind(&P::ServerRenamed { new_name: "x".into() }), PayloadKind::Writes);
    let k = ElementKey::Grant("c".into(), "m".into());
    assert_eq!(ElementKey::from_key(&k.to_key()), Some(k), "an item key reads back");
    assert_eq!(ElementKey::from_key("{\"ban\":1}"), None, "a malformed key reads as nothing");
}

/// Only the dropped device's own lane, minus what its DR names, newer than R.
#[test]
fn the_walk_lists_only_the_dropped_lane() {
    let mut w = world();
    let member = keys(MEMBER).1;
    let ban = w.write(false, P::MemberBanned { peer_id: member.clone(), seen: None });
    let _rename = w.write(true, P::ChannelRenamed { channel_id: w.general.clone(), new_name: "laptop".into() });
    let named = w.write(false, P::ServerSettingChanged { key: "description".into(), value: "named".into() });
    let mod_id = keys(MOD).1;
    let lane = Lane::new(&mod_id, &keys(MOD_PHONE).1, &[OpRef { ms: named.hlc.physical_ms, c: named.hlc.counter, h: hex::encode(named.content_hash()) }]);
    let writes = lane_writes(&w.owner, &w.r, &w.r.name.hlc().clone(), &lane);
    assert_eq!(keys_of(&writes), vec![ElementKey::Ban(member.clone())], "the laptop's rename and the named write stay out; the ban and its Remove are one unit");
    assert_eq!(writes[0].stamp, ban.hlc);
    let none = lane_writes(&w.owner, &w.owner, &w.r.name.hlc().clone(), &lane);
    assert!(none.is_empty(), "nothing newer than an R that already dates it");
}

/// Decision 20: moderation, roles, access and existence wait for the owner; what the
/// member could write again itself reverts at once.
#[test]
fn classes_follow_the_owners_review_rule() {
    let mut w = world();
    let member = keys(MEMBER).1;
    w.write(false, P::MemberRemoved { peer_id: member.clone(), seen: None });
    w.write(false, P::ServerSettingChanged { key: "description".into(), value: "thief".into() });
    w.write(false, P::ChannelRenamed { channel_id: w.general.clone(), new_name: "thief".into() });
    w.write(false, P::ChannelVisibilityChanged { channel_id: w.general.clone(), visibility: "moderator".into() });
    w.write(false, P::NicknameChanged { peer_id: keys(MOD).1, nickname: "me".into() });
    w.write(false, P::NicknameChanged { peer_id: keys(OTHER_MOD).1, nickname: "you".into() });
    w.write(false, P::ServerSettingChanged { key: "is_private".into(), value: "true".into() });
    let lane = w.lane();
    let writes = lane_writes(&w.owner, &w.r, &w.r.name.hlc().clone(), &lane);
    let judge = Judge { base: &w.owner, r: &w.r, t_ms: Some(0), at: refold_at(), held: &[], lane: &lane };
    let class_of = |k: &ElementKey| writes.iter().find(|x| x.key == *k).map(|x| judge.class(x));
    assert_eq!(class_of(&ElementKey::Remove(member.clone())), Some(RefoldClass::Review), "a kick waits");
    assert_eq!(class_of(&ElementKey::ChannelField(w.general.clone(), ChannelField::Visibility)), Some(RefoldClass::Review), "access waits");
    assert_eq!(class_of(&ElementKey::Setting("description".into())), Some(RefoldClass::Auto), "an allowlisted setting an admin may write");
    assert_eq!(class_of(&ElementKey::ChannelField(w.general.clone(), ChannelField::Name)), Some(RefoldClass::Auto), "a rename it may write again");
    assert_eq!(class_of(&ElementKey::Nickname(keys(MOD).1)), Some(RefoldClass::Auto), "its own nickname");
    assert_eq!(class_of(&ElementKey::Nickname(keys(OTHER_MOD).1)), Some(RefoldClass::Review), "another member's nickname waits");
    assert_eq!(class_of(&ElementKey::Setting("is_private".into())), Some(RefoldClass::Review), "a join gate waits, whatever the role");
    // Demoted since: what it can no longer write itself waits for the owner.
    let mut demoted = w.owner.clone();
    demoted.author_checked(P::RoleChanged { peer_id: keys(MOD).1, role: MemberRole::Member, priority: 0 }).unwrap();
    let judge = Judge { base: &demoted, ..judge };
    let renamed = writes.iter().find(|x| x.key == ElementKey::ChannelField(w.general.clone(), ChannelField::Name)).unwrap();
    assert_eq!(judge.class(renamed), RefoldClass::Review, "a member may not rename a channel: review");
}

/// Decision 21: a channel the lane made public after T reverts at once; at or before T,
/// or one R already had public, waits.
#[test]
fn unpublish_needs_a_stamp_after_t_and_a_revert_that_closes_it() {
    let mut w = world();
    let op = w.write(false, P::ChannelPublicChanged { channel_id: w.general.clone(), is_public: true });
    let lane = w.lane();
    let writes = lane_writes(&w.owner, &w.r, &w.r.name.hlc().clone(), &lane);
    let unit = writes.iter().find(|x| x.key == ElementKey::ChannelPublic(w.general.clone())).expect("the public unit is the lane's");
    let at = refold_at();
    let t_before = Some(op.hlc.physical_ms as i64 - 1);
    let judge = Judge { base: &w.owner, r: &w.r, t_ms: t_before, at: at.clone(), held: &[], lane: &lane };
    assert_eq!(judge.class(unit), RefoldClass::Unpublish);
    let judge_t = Judge { t_ms: Some(op.hlc.physical_ms as i64), ..judge };
    assert_eq!(judge_t.class(unit), RefoldClass::Review, "a stamp at T is the member's own, before the theft");
    let mut r_public = w.r.clone();
    r_public.channels.get_mut(&w.general).unwrap().is_public = true;
    let judge_r = Judge { base: &w.owner, r: &r_public, t_ms: t_before, at, held: &[], lane: &lane };
    assert_eq!(judge_r.class(unit), RefoldClass::Review, "R had it public: nothing says the lane opened it");
}

/// The entry and its answer bind the writer and the judgment; a changed byte voids them.
#[test]
fn an_entry_and_its_answer_verify_only_as_signed() {
    let at = HlcTimestamp { physical_ms: 5, counter: 1, actor: keys(OWNER).1 };
    let mut e = Refolded {
        member: keys(MOD).1,
        device: keys(MOD_PHONE).1,
        dr: "a".repeat(64),
        r: "b".repeat(64),
        at: at.clone(),
        opened: Some(at.clone()),
        below: None,
        review: vec![RefoldItem { key: ElementKey::Ban(keys(MEMBER).1).to_key(), stamp: at.clone() }],
        unpublished: vec![],
        by: String::new(),
        sig: String::new(),
        answered: None,
    };
    e.sign("s", &keys(PHONE).0);
    assert!(e.sig_verifies("s") && e.by == keys(PHONE).1);
    assert!(!e.sig_verifies("other"), "bound to the server");
    let mut forged = e.clone();
    forged.review.clear();
    assert!(!forged.sig_verifies("s"), "items cannot be dropped under its signature");
    e.answer("s", &keys(PHONE).0, vec![e.review[0].key.clone()], vec![], vec![], false);
    assert!(e.valid_answer("s").is_some());
    let mut flipped = e.clone();
    flipped.answered.as_mut().unwrap().timeout = true;
    assert!(flipped.valid_answer("s").is_none(), "a void answer reads as none");
}

/// A reverted kick re-opens the span the lane closed; a later event of the member keeps
/// the item from applying at all (R33-3), and a ban reverts with its own `Remove`.
#[test]
fn a_reverted_kick_reopens_the_span_unless_the_member_moved_on() {
    let mut w = world();
    let member = keys(MEMBER).1;
    let kick = w.write(false, P::MemberRemoved { peer_id: member.clone(), seen: None });
    let r = w.r.clone();
    let mut undone = w.owner.clone();
    assert!(!undone.is_member(&member), "precondition: kicked");
    assert!(apply_revert(&mut undone, &r, &ElementKey::Remove(member.clone()), &kick.hlc), "the kick is reverted");
    assert!(undone.is_member(&member), "the span is open again");
    assert!(!apply_revert(&mut undone, &r, &ElementKey::Remove(member.clone()), &kick.hlc), "an item applies once");

    let ask = super::super::operations::JoinAsk::sign(&w.owner.server_id, 2, &keys(MEMBER).0);
    w.owner.author_checked(P::MemberAdded { peer_id: member.clone(), display_name: "m".into(), follow: None, ask: Some(ask) }).expect("the owner admits it again");
    let mut rejoined = w.owner.clone();
    assert!(!apply_revert(&mut rejoined, &r, &ElementKey::Remove(member.clone()), &kick.hlc), "an honest rejoin since: the kick item stays");

    let mut w = world();
    let ban = w.write(false, P::MemberBanned { peer_id: member.clone(), seen: None });
    let mut unbanned = w.owner.clone();
    assert!(apply_revert(&mut unbanned, &w.r, &ElementKey::Ban(member.clone()), &ban.hlc));
    assert!(!unbanned.is_banned(&member) && unbanned.is_member(&member), "the ban and its removal go together");
}

/// An AUTO revert puts R's value and stamp back; one changed since is skipped.
#[test]
fn a_revert_restores_r_and_skips_what_changed_since() {
    let mut w = world();
    let desc = w.write(false, P::ServerSettingChanged { key: "description".into(), value: "thief".into() });
    let renamed = w.write(false, P::ChannelRenamed { channel_id: w.general.clone(), new_name: "thief".into() });
    let mut s = w.owner.clone();
    assert!(apply_revert(&mut s, &w.r, &ElementKey::Setting("description".into()), &desc.hlc));
    assert!(!s.settings.contains_key("description"), "R had no description");
    let name = ElementKey::ChannelField(w.general.clone(), ChannelField::Name);
    assert!(apply_revert(&mut s, &w.r, &name, &renamed.hlc));
    assert_eq!(s.channels[&w.general].name, "general");
    assert_eq!(winning_stamp(&s, &name), winning_stamp(&w.r, &name), "R's stamp too");
    w.owner.author_checked(P::ChannelRenamed { channel_id: w.general.clone(), new_name: "owner".into() }).unwrap();
    let mut later = w.owner.clone();
    assert!(!apply_revert(&mut later, &w.r, &name, &renamed.hlc), "the owner renamed it since: it stays");
    assert_eq!(later.channels[&w.general].name, "owner");
}

fn entry(server: &str, member: u8, device: u8, signer: u8) -> Refolded {
    let at = HlcTimestamp { physical_ms: 7, counter: 0, actor: keys(OWNER).1 };
    let mut e = Refolded {
        member: keys(member).1,
        device: keys(device).1,
        dr: "d".repeat(64),
        r: "e".repeat(64),
        at,
        opened: None,
        below: None,
        review: vec![],
        unpublished: vec![],
        by: String::new(),
        sig: String::new(),
        answered: None,
    };
    e.sign(server, &keys(signer).0);
    e
}

/// Rule 3 for `cp_refolded`: an entry or answer survives a checkpoint only when it
/// verifies and an owner device this view counts wrote it; a forged or foreign entry
/// neither carries nor suppresses.
#[test]
fn only_counted_owner_devices_entries_carry_and_suppress() {
    let mut w = world();
    let sid = w.owner.server_id.clone();
    let covers = w.owner.checkpoint_covers();
    let json = w.owner.checkpoint_json(&keys(OWNER).1, &[], super::super::hlc::wall_clock_ms()).unwrap();
    w.owner.author_checkpoint(P::ServerCheckpoint { state: json, covers }).expect("cp0 is the base");
    let roster = crate::identity::roster::Roster::genesis(&keys(OWNER).0, &keys(38).0, &keys(PHONE).0, 1_000);
    let mut view = super::super::authority::AuthorityView::judging();
    view.insert(keys(OWNER).1, super::super::authority::judge(&keys(OWNER).1, &super::super::authority::KeyRule::FirstHeld, &[&roster]));
    w.owner.authority = std::sync::Arc::new(view);

    let good = entry(&sid, MOD, MOD_PHONE, PHONE);
    let mut forged = entry(&sid, MEMBER, 39, PHONE);
    forged.review.push(RefoldItem { key: ElementKey::Name.to_key(), stamp: good.at.clone() });
    let foreign = entry(&sid, OTHER_MOD, 40, MOD_PHONE);
    let mut answered = entry(&sid, MOD, MOD_LAPTOP, PHONE);
    answered.answer(&sid, &keys(MOD_PHONE).0, vec![], vec![], vec![], false);
    let base = w.owner.base.as_mut().unwrap();
    std::sync::Arc::make_mut(&mut base.state).cp_refolded = vec![good.clone(), forged, foreign, answered.clone()];

    let carried = w.owner.carried_refolded();
    let pairs: Vec<(&str, &str)> = carried.iter().map(|e| e.pair()).collect();
    assert_eq!(pairs.len(), 2, "the forged and the foreign entries drop: {pairs:?}");
    assert!(carried.iter().all(|e| e.answered.is_none()), "an answer by a device the view does not count re-opens its entry");
    let fits = |_: &Refolded| true;
    assert!(w.owner.refold_suppressed(&keys(MOD).1, &keys(MOD_PHONE).1, &fits), "a counted owner device's entry suppresses its pair");
    assert!(!w.owner.refold_suppressed(&keys(MEMBER).1, &keys(39).1, &fits), "a forged entry suppresses nothing");
    assert!(!w.owner.refold_suppressed(&keys(OTHER_MOD).1, &keys(40).1, &fits), "nor one another device signed");
    assert!(!w.owner.refold_suppressed(&keys(MOD).1, &keys(MOD_PHONE).1, &|_: &Refolded| false), "nor one naming a DR that does not fit");
    let json = w.owner.checkpoint_json(&keys(OWNER).1, &[], super::super::hlc::wall_clock_ms()).unwrap();
    let written = super::super::server_state::parse_state(&json);
    assert_eq!(written.map(|s| s.cp_refolded.len()), Some(2), "the next checkpoint carries them");
}
